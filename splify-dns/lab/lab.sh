#!/bin/bash
# splify-dnsd lab: a network namespace with its own nft table and a fake DNS
# upstream. Everything the daemon touches lives here, so a wedged daemon costs
# nothing — the two netlink bugs found so far (EINVAL for a non-transactional
# message, ERANGE for a host-order timeout) both reproduce in here, which is
# where they should have been found instead of on a router carrying real traffic.
set -u
NS=splifylab
TMP="$(cd "$(dirname "$0")" && pwd)"
BIN=${SPLIFY_DNSD_BIN:-$TMP/splify-dnsd}
IPFILE=$TMP/lab-answer.ip
LOG=$TMP/lab-dnsd.log
UPLOG=$TMP/lab-upstream.log

nsx() { ip netns exec "$NS" "$@"; }

lab_up() {
    ip netns del "$NS" 2>/dev/null
    ip netns add "$NS"
    nsx ip link set lo up
    # The table name matches production so the daemon runs with its real args.
    nsx nft add table inet fw4
    nsx nft add set inet fw4 splify_vpn_v4    '{ type ipv4_addr; flags interval,timeout; auto-merge; }'
    nsx nft add set inet fw4 splify_direct_v4 '{ type ipv4_addr; flags interval,timeout; auto-merge; }'
    nsx nft add map inet fw4 splify_fakeip_map '{ type ipv4_addr : ipv4_addr; }'
    echo "203.0.113.10" > "$IPFILE"
    printf 'example.com\nblocked.test\n' > "$TMP/lab-vpn.rules"
    printf 'direct.test\n' > "$TMP/lab-direct.rules"
    rm -f "$TMP/lab-fakeip.state" "$LOG" "$UPLOG"
    nsx python3 "$TMP/fakeupstream.py" --port 5353 --ip-file "$IPFILE" >"$UPLOG" 2>&1 &
    sleep 0.5
    SPLIFY_DNSD_DEBUG=1 nsx "$BIN" \
        --listen-port 5399 --upstream-port 5353 \
        --vpn-set splify_vpn_v4 --direct-set splify_direct_v4 \
        --vpn-rules "$TMP/lab-vpn.rules" --direct-rules "$TMP/lab-direct.rules" \
        --fakeip-state "$TMP/lab-fakeip.state" --fakeip-map splify_fakeip_map \
        --table "inet fw4" >>"$LOG" 2>&1 &
    sleep 0.5
    echo "lab up (ns=$NS, daemon pid $(nsx pgrep -f splify-dnsd | head -1))"
}

lab_down() {
    ip netns del "$NS" 2>/dev/null
    pkill -f "fakeupstream.py" 2>/dev/null
    pkill -f "splify-dnsd-x86" 2>/dev/null
    echo "lab down"
}

# dig replacement with no dependencies: send an A query, print the answer address
q() {
    nsx python3 - "$1" <<'PY'
import socket, struct, sys
name = sys.argv[1]
qname = b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\0"
pkt = struct.pack("!HHHHHH", 0x1234, 0x0100, 1, 0, 0, 0) + qname + struct.pack("!HH", 1, 1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
s.sendto(pkt, ("127.0.0.1", 5399))
try:
    r, _ = s.recvfrom(4096)
except socket.timeout:
    print("TIMEOUT"); sys.exit(1)
an = struct.unpack("!H", r[6:8])[0]
if an == 0: print("NOANSWER"); sys.exit(0)
off = 12
while r[off]: off += r[off] + 1      # question name
off += 1 + 4                          # zero byte + qtype/qclass
if r[off] & 0xC0 == 0xC0:             # answer name: pointer or literal
    off += 2
else:
    while r[off]: off += r[off] + 1
    off += 1
t, c, ttl, dl = struct.unpack("!HHIH", r[off:off+10]); off += 10
print(socket.inet_ntoa(r[off:off+dl]) if dl == 4 else f"rdlen={dl}")
PY
}

show() {
    echo "  vpn set : $(nsx nft list set inet fw4 splify_vpn_v4 | tr -d '\n' | sed -n 's/.*elements = {\([^}]*\)}.*/\1/p' | tr -s ' ')"
    echo "  map     : $(nsx nft list map inet fw4 splify_fakeip_map | tr -d '\n' | sed -n 's/.*elements = {\([^}]*\)}.*/\1/p' | tr -s ' ')"
}

case "${1:-}" in
    up)   lab_up ;;
    down) lab_down ;;
    q)    q "$2" ;;
    show) show ;;
    rotate) echo "$2" > "$IPFILE"; echo "upstream answer is now $2" ;;
    log)  tail -"${2:-20}" "$LOG" ;;
    rss)  p=$(nsx pgrep -f splify-dnsd | head -1); grep VmRSS "/proc/$p/status" ;;
    *) echo "usage: lab.sh {up|down|q <name>|show|rotate <ip>|log [n]|rss}"; exit 2 ;;
esac
