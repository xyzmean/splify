# wg-split

Turn an OpenWrt router into a **local, self-contained split-tunnel gateway**.
LAN traffic is policy-routed over one of several WireGuard/AmneziaWG tunnels with
**priority failover**; blocked/foreign IPs ride the VPN, RU/CN stays direct, and
optional **zapret** does DPI-bypass on WAN. Everything is configured locally via
**UCI / LuCI** — no dashboard, no API, no tokens.

```
[LAN device] ─▶ [tunnel #1] ─▶ … failover … ─▶ [tunnel #N]
              └▶ direct (WAN) ─▶ zapret DPI-bypass for RU/clearnet
```

## What's new in 2.0

- **Operator dashboard, split from settings.** The LuCI app is now two tabs:
  **Status** (hero state, live routing chain, **live rx/tx per tunnel**, lists,
  diagnostics, **failover timeline**) and **Settings** (the UCI form).
- **One-click firewall fix.** Every firewall finding gets a **“Fix automatically”**
  button (and a `wg-split-firewall check|fix <iface>` CLI) that creates/repairs the
  tunnel’s zone — accept-all + masquerading + lan↔tunnel↔wan forwarding — modelled
  on a known-good AmneziaWG zone. No more three `FAIL`s you have to solve by hand.
- **Failover event journal.** Switch/recover/restart/fallback transitions are
  recorded to a RAM ring buffer and shown as a timeline (`wg-split-doctor --events`).
- **Least-privilege ubus.** LuCI now talks to a `wg-split` rpcd object
  (`status`/`events`/`action`) instead of broad `file:exec` — the ACL grants only
  those three methods.
- **Site-to-site aware.** “VPN subnets” are labelled for peer LANs, and the doctor
  flags a VPN subnet that isn’t actually routed into the tunnel.
- **Transport-agnostic seam.** Endpoints carry a `type` (default `wg`); all
  transport-specific logic goes through `ep_*` dispatch helpers so a future
  sing-box (VLESS/Hysteria) backend drops in without touching the core.
- **Release hygiene.** CI now runs `shellcheck` + `bats` unit tests; a uci-defaults
  migration adds the new defaults to existing configs (fully backward-compatible).

Configs from 1.7.x keep working unchanged — the UCI schema only grew, additively.

## What it does

nftables marks → `ip rule` → table 200 → the active tunnel. The policy chains are
regenerated from UCI by `wg-split-apply`; the `wg-split` service runs the failover
loop and self-heals the IP sets.

- **`blocklist` mode (default):** only the `ipsum` set (blocked/foreign IPs) rides
  the VPN; everything else exits WAN with zapret. RU/CN stays direct.
- **`full` mode:** default route via VPN; the direct list is the WAN exception.
- **`split` mode:** only your explicit VPN lists/domains ride the VPN.

Lists are **downloaded by URL** and refreshed daily (cron): an IP list → VPN
(`ipsum`), an IP list → direct (`ru/cn`, also feeds the zapret bypass), and
optional **domain** lists tagged at dnsmasq resolve time. You can also add CIDRs,
domains, and per-device pins by hand in LuCI.

## Failover

List several tunnel interfaces with a priority. Each tick the service:

1. keeps the current tunnel if it's healthy (`ping -I <iface>` a target through it);
2. **restarts a stuck tunnel first** (WG often unsticks on `ifdown/ifup`);
3. otherwise probes the others **non-disruptively** (brings a candidate up in
   parallel and pings through it — the live path is never torn down) and switches
   to the first healthy one, always preferring the highest priority;
4. if no tunnel works and zapret is available → WAN fallback with the VPN IPs
   pulled **out** of `nozapret` so zapret DPI-bypasses them on WAN;
5. if zapret is unavailable/failing → plain WAN (or, with the kill switch on,
   table 200 is blackholed so policy traffic never leaks).

It always tries to recover toward priority #1. The check interval is set in LuCI.

## Install

OpenWrt 24.10+ (apk). Build the two packages in CI (see `.github/workflows/build.yml`)
or with an OpenWrt SDK, then:

```sh
apk add ./wg-split-*.apk ./luci-app-wg-split-*.apk ./luci-i18n-wg-split-*.apk
```

(`luci-i18n-wg-split-*` is the LuCI translation package — install it for the
localized UI; it's optional and English is built in.)

`zapret` is optional — install it separately if you want the DPI-bypass rung; it's
detected at runtime.

## Configure

1. Create your WireGuard/AmneziaWG tunnel interface(s) the normal way under
   **Network → Interfaces** (the app does not manage WG keys/params).
2. Open **Services → wg-split**: pick mode, add each tunnel interface with a
   priority, set the list URLs and the failover interval, toggle zapret, and add
   any manual CIDRs/domains/device pins. Save & Apply.

CLI: `wg-split-doctor` (diagnose; `--json` for tooling), `wg-split-status`
(snapshot), `wg-split-apply` (regenerate from UCI), `wg-split-disable` (emergency
WAN-only), `wg-split-uninstall` (teardown), `logread -e wg-split` (service log).
Config lives in `/etc/config/wg-split`.

## Verify

After configuring, run the doctor — it answers "what is broken and what should I
fix?" without SSH spelunking:

```sh
wg-split-doctor          # human-readable report
wg-split-doctor --json   # machine-readable (this is what the LuCI panel shows)
```

It exits `0` when everything is OK and non-zero otherwise, so it also works in a
post-install check. Each finding carries a severity and a fix:

- **OK** — working.
- **WARN** — suboptimal/stale (e.g. a list a couple days old), not breaking routing.
- **FIXABLE** — broken now, but self-heals on the next failover tick or via one
  named command (e.g. an empty `ipsum` set, zapret not yet started).
- **FAIL** — broken and needs a decision from you (almost always firewall config).

A healthy `blocklist` setup reports overall **OK**, the active path as `vpn:<iface>`,
each tunnel with a recent handshake + `OK` health + a firewall zone with masq and
LAN forwarding, and the `ipsum` set above its minimum. The same flow applies to
`full` and `split` — only the routing mode and which lists matter differ.

## Troubleshooting

`wg-split-doctor` names each of these directly; the fix is in its `→ fix:` line.

| Symptom (doctor message) | Fix |
|---|---|
| `no failover tunnels configured` | Add a tunnel under Services → wg-split. |
| `LAN subnet not set or not detected` | Set the LAN subnet/interface; until then all traffic exits WAN. |
| `<if>: interface does not exist` | Create the WG/AWG interface under Network → Interfaces, or remove it from wg-split. |
| `<if>: not in any firewall zone` | Add the tunnel iface to a firewall zone (fw4 REJECTs LAN→tunnel otherwise — the #1 post-reflash gotcha). |
| `<if>: zone '…' has masquerading disabled` | Enable masq on that zone, or VPN replies won't route back. |
| `<if>: no forwarding '…' -> '…'` | Add firewall forwarding from the LAN zone to the tunnel zone. |
| `<if>: route_allowed_ips not 0` | `wg-split-apply` — it forces `route_allowed_ips=0` so the tunnel can't hijack main routes. |
| `<if>: health probe failed` | Check the peer endpoint/keys; failover will pick another tunnel meanwhile. |
| `ipsum/ru set has N (<min)` | `wg-split-update-ipsum` / `-ru`; also reloads automatically next tick. |
| `… list is stale` / `not yet downloaded` | Check the list URL; run the matching `wg-split-update-*`. |
| `zapret is installed but not running` | The failover loop starts it; or `/etc/init.d/zapret start`. |
| `zapret is enabled … but not installed` | Install zapret, or untick it in Services → wg-split. |
| `dnsmasq nftset drop-in is missing` | `wg-split-apply` regenerates it and reloads dnsmasq. |
| `killswitch is ON but active path is 'wan'/'zapret'` | No tunnel is healthy; under killswitch traffic should blackhole — check the tunnels. |

## Files

| Path | Role |
|------|------|
| `wg-split/files/etc/config/wg-split` | UCI config (global + endpoint + device) |
| `wg-split/files/usr/local/sbin/wg-split-failover` | failover state machine + procd daemon |
| `wg-split/files/usr/local/sbin/wg-split-doctor` | structured diagnostics (text + `--json`) |
| `wg-split/files/usr/local/sbin/wg-split-apply` | regenerate nft/dnsmasq layer from UCI |
| `wg-split/files/usr/local/sbin/wg-split-firewall` | create/repair the tunnel firewall zone (`check`/`fix`) |
| `wg-split/files/usr/libexec/rpcd/wg-split` | least-privilege ubus object (`status`/`events`/`action`) for LuCI |
| `wg-split/files/usr/local/sbin/wg-split-update-{ipsum,ru,domains}` | list downloaders |
| `wg-split/files/usr/local/sbin/wg-split-sync-nozapret` | rebuild zapret bypass set |
| `wg-split/files/usr/local/lib/wg-split/common.sh` | shared helpers (loads UCI) |
| `luci-app-wg-split/` | LuCI configuration page |

## Documentation

A full Russian wiki lives in [`docs/ru/`](docs/ru/Home.md) — installation,
configuration & the LuCI panel, routing modes, failover, lists/zapret,
diagnostics, troubleshooting, CLI reference and FAQ.
