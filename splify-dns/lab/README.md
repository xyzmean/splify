# splify-dnsd lab

Runs the daemon against a real kernel — real nftables, real netlink — inside a
network namespace with a fake DNS upstream. Nothing here can touch a router, or
the machine's own networking.

This exists because the alternative was testing on a live router, and that cost
an outage: an experimental build of this daemon takes over DNS for the LAN and
writes into the same nftables sets that decide where traffic goes, so a wrong
element there reroutes or blackholes real traffic. Every netlink bug found so far
reproduces in here in seconds.

## Use

```sh
gcc -static -O2 -o splify-dns/lab/splify-dnsd splify-dns/src/splify-dnsd.c
cd splify-dns/lab
sudo ./lab.sh up                 # namespace + nft table + fake upstream + daemon
sudo ./lab.sh q example.com      # one A query, prints the answer address
sudo ./lab.sh show               # contents of the vpn set and the fake-IP map
sudo ./lab.sh rotate 203.0.113.77  # the CDN moved the domain to a new backend
sudo ./lab.sh log 20             # daemon stderr (SPLIFY_DNSD_DEBUG is on)
sudo ./lab.sh rss                # daemon resident size
sudo ./lab.sh down
```

The table is named `inet fw4` and the sets/map carry their production names and
flags (`type ipv4_addr; flags interval,timeout; auto-merge`), because those flags
are exactly what the daemon has to get right — see below.

## What it caught

Four defects, each confirmed by the kernel's own reply and none of them visible
from reading the code:

| defect | kernel says | effect on a router |
|---|---|---|
| element sent outside a `BATCH_BEGIN`/`BATCH_END` transaction | `-22 EINVAL` | every insert fails, daemon silently relays real answers, domain routing never works |
| element timeout written in host byte order (kernel reads big-endian) | `-34 ERANGE` | inserts into the timeout-flagged VPN/direct sets fail; the map (no timeout) works, so it looks half-broken |
| `-17 EEXIST` on re-insert treated as failure | `-17 EEXIST` | fake IP handed out once, then the fail-open path returns the REAL address — the domain leaves the tunnel from the second query on |
| single address added to an interval set without an end-boundary element | accepted (!) | the set stores `198.18.0.0-255.255.255.255`, so one resolved domain routes every higher address into the tunnel — "one request and the router is dead" |

The last one is the reason the lab uses production set flags: with a plain
(non-interval) set the daemon looks perfectly healthy.

## interval-encoding-probe.c

Answers "what wire form does this kernel accept for one address in an interval
set?" by trying each candidate and printing the verdict. Measured:

```
start only, no end marker            -> OK, but stores 198.18.9.0-255.255.255.255
start + end marker, timeout on both  -> EINVAL
start + end marker, timeout on start -> OK, stores 198.18.9.0
start + end marker, no timeout       -> OK, stores 198.18.9.0
single element with KEY_END          -> EINVAL
```

Flush the set between runs: an open-ended interval left by an earlier variant
makes every later insert report EEXIST.
