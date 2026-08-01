# splify common helpers. Sourced (not exec'd) by every splify-* script.
# Config now lives in UCI (/etc/config/splify) — loaded here into the same
# variable names the scripts have always used. Requires: busybox ash, nft, ip,
# logger, and OpenWrt's /lib/functions.sh (uci config helpers).

# NOTE: OpenWrt's /lib/functions.sh and its config_* helpers are NOT nounset-safe
# — they dereference internal state ($IPKG_INSTROOT, $CONFIG_LIST_STATE, …)
# unguarded, both at load and during config_foreach/config_get at runtime. So the
# scripts that source this file must NOT run with `set -u`, or the failover daemon
# crash-loops every tick. Don't add `set -u` to splify-{failover,apply,status}.

# shellcheck disable=SC1091
. /lib/functions.sh
config_load splify

# ---- user-tunable knobs (UCI 'global' section) -----------------------------
config_get        MODE            global mode            blocklist
config_get        INTERVAL        global interval        180
config_get_bool   KILLSWITCH      global killswitch      0
config_get        LAN_IFACE       global lan_iface       br-lan
config_get        LAN_CIDR        global lan_cidr        ''

# Auto-detect the LAN subnet(s) from lan_iface's connected (proto kernel) routes,
# so policy marking always follows the real bridge. A stale or blank lan_cidr was
# the #1 "nothing gets routed" gotcha: after renumbering the LAN the saddr-matched
# chains kept matching the old subnet and no client traffic was ever marked. Any
# configured lan_cidr is still unioned in, so it can add extra subnets (e.g. VLANs
# not on lan_iface). Result is a comma-joined, nft-ready list (possibly empty if
# the bridge has no IPv4 yet — callers already treat empty as "sets only").
LAN_CIDR="$(
    { ip -4 route show dev "$LAN_IFACE" proto kernel scope link 2>/dev/null \
        | awk '{print $1}'
      printf '%s\n' "$LAN_CIDR" | tr ', ' '\n'
    } | grep -Ex '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}' | sort -u | tr '\n' ',' | sed 's/,$//'
)"
config_get        HEALTH_TARGETS  global health_target   '1.1.1.1 8.8.8.8'
config_get        HEALTH_CURL_URL global health_url       'https://1.1.1.1/cdn-cgi/trace'
config_get_bool   ZAPRET_ENABLED  global zapret_enabled  1
config_get_bool   IPSUM_ENABLED   global ipsum_enabled   1
config_get        IPSUM_URL       global ipsum_url       ''
config_get_bool   RU_ENABLED      global ru_enabled      1
config_get        RU_URL          global ru_url          ''
config_get        VPN_DOMAINS_URL    global vpn_domains_url    ''
config_get        IGNORE_DOMAINS_URL global ignore_domains_url ''
config_get        VPN_CIDRS       global vpn_cidr        ''
config_get        DIRECT_CIDRS    global direct_cidr     ''
config_get        VPN_DOMAINS     global vpn_domain      ''
config_get        DIRECT_DOMAINS  global direct_domain   ''

# ---- static constants (not user-tunable; were operator-owned, effectively fixed) ----
WG_TABLE="200"
WG_MARK="0x40000";        WG_MARK_MASK="0x40000";   WG_RULE_PRIO="999"
ANTI_LOOP_MARK="0x10000"; ANTI_LOOP_MASK="0x10000"; ANTI_LOOP_PRIO="1000"
# Isolated table+rule for health probes: the endpoints run route_allowed_ips=0
# (so an ifup can't hijack main routes), which also means they have no main-table
# route to public targets — the probe installs a scoped route via the candidate's
# own source IP for the duration of the ping. Prio above the wg mark rule.
PROBE_TABLE="201"; PROBE_PRIO="998"
DOH_IPS="8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1 9.9.9.9 149.112.112.112"

VPN_SET="splify_vpn_v4"
DIRECT_SET="splify_direct_v4"
POLICY_NFT_FILE="/etc/nftables.d/30-splify.nft"
DNSMASQ_NFTSET_FILE="/tmp/dnsmasq.d/splify-domains.conf"

# ---- native domain-routing backend (splify-dns, optional runtime dep) ------
# splify-dnsd replaces dnsmasq's nftset= role: it's a transparent DNS
# forwarding proxy (client -> splify-dnsd -> dnsmasq@127.0.0.1:53 -> client)
# that inspects the question name + A-record answers read-only and, on a
# domain-rule match, adds the resolved IP straight into $VPN_SET/$DIRECT_SET
# with a timeout matching the record's own TTL — everything downstream
# (mark chains, table 200, failover) is untouched. Soft/runtime-detected
# dependency, same convention as zapret_available()/sing-box: a plain
# `splify` install never requires the splify-dns package, and its absence
# (or an unsupported CPU arch) silently falls back to the dnsmasq nftset
# path with zero behavior change.
SPLIFY_DNS_BIN="/usr/sbin/splify-dnsd"
SPLIFY_DNS_PORT="5300"
SPLIFY_DNS_DIR="/etc/splify"
SPLIFY_DNS_VPN_RULES="$SPLIFY_DNS_DIR/dns-vpn-rules.lst"
SPLIFY_DNS_DIRECT_RULES="$SPLIFY_DNS_DIR/dns-direct-rules.lst"
# Fake-IP: a matched domain gets a synthetic, domain-exclusive IP from this
# pool instead of its real (possibly CDN-shared, collision-prone) address —
# see splify-dnsd.c's own comment for why. RFC 2544 benchmarking range, same
# convention already used by Clash/sing-box/mihomo for this exact purpose.
SPLIFY_DNS_FAKEIP_POOL="198.18.0.0/15"
SPLIFY_DNS_FAKEIP_MAP="splify_fakeip_map"
SPLIFY_DNS_FAKEIP_STATE="$SPLIFY_DNS_DIR/dns-fakeip.state"
splify_dns_available() { [ -x "$SPLIFY_DNS_BIN" ]; }
# $1 = domain_backend UCI value -> echoes the resolved backend ('native' |
# 'dnsmasq'). 'dnsmasq' forces the legacy path (rollback/support); anything
# else (default '', i.e. auto) prefers native whenever the package is
# present, and falls back to dnsmasq automatically otherwise.
resolve_domain_backend() {
    if [ "$1" = "dnsmasq" ]; then
        echo dnsmasq
    elif splify_dns_available; then
        echo native
    else
        echo dnsmasq
    fi
}
config_get _DOMAIN_BACKEND_CFG global domain_backend ''
DOMAIN_BACKEND="$(resolve_domain_backend "$_DOMAIN_BACKEND_CFG")"

IPSUM_FILE="/etc/splify/ipsum.lst"
IPSUM_NFT_FILE="/etc/splify/ipsum-set.nft"
IPSUM_SET="splify_ipsum_v4"; IPSUM_TABLE="inet fw4"
# Must match `size` in /etc/nftables.d/30-splify.nft: a load that runs past the
# declared capacity fails part-way and leaves the set half-populated.
IPSUM_SET_CAPACITY="65536"
IPSUM_MIN_COUNT="5000"; IPSUM_FALLBACK_SKIP="1"

RU_FILE="/etc/splify/ru_subnets.lst"
RU_NFT_FILE="/etc/splify/ru-set.nft"
RU_SET="splify_ru_subnets_v4"; RU_TABLE="inet fw4"; RU_MIN_COUNT="5000"

DOMAINS_VPN_FILE="/etc/splify/vpn-domains.lst"
DOMAINS_IGNORE_FILE="/etc/splify/ignore-domains.lst"

# zapret version detection: support BOTH zapret1 and zapret2, preferring
# zapret2 (newer). zapret1: /etc/init.d/zapret, /opt/zapret/nfq/nfqws, table
# "inet zapret". zapret2: /etc/init.d/zapret2, /opt/zapret2/nfq2/nfqws2, table
# "inet zapret2". Both expose a "nozapret" set splify repopulates; the table
# name differs, so it is resolved at source-time, not hardcoded.
# Detection order: init script presence wins (authoritative), else binary path,
# else fall back to zapret1 (the historical default) so a missing install does
# not change the resolved names spuriously — zapret_available() is the real
# gate that decides whether to act on these vars at all.
_zapret_detect_init() {
    if [ -x /etc/init.d/zapret2 ]; then
        ZAPRET_INIT="/etc/init.d/zapret2"
        ZAPRET_NOZAPRET_TABLE="inet zapret2"
        ZAPRET_VERSION="zapret2"
    elif [ -x /etc/init.d/zapret ]; then
        ZAPRET_INIT="/etc/init.d/zapret"
        ZAPRET_NOZAPRET_TABLE="inet zapret"
        ZAPRET_VERSION="zapret"
    elif [ -x /opt/zapret2/nfq2/nfqws2 ]; then
        ZAPRET_INIT=""
        ZAPRET_NOZAPRET_TABLE="inet zapret2"
        ZAPRET_VERSION="zapret2"
    elif [ -x /opt/zapret/nfq/nfqws ]; then
        ZAPRET_INIT=""
        ZAPRET_NOZAPRET_TABLE="inet zapret"
        ZAPRET_VERSION="zapret"
    else
        ZAPRET_INIT="/etc/init.d/zapret"
        ZAPRET_NOZAPRET_TABLE="inet zapret"
        ZAPRET_VERSION="zapret"
    fi
}
_zapret_detect_init
ZAPRET_NOZAPRET_SET="nozapret"; ZAPRET_NOZAPRET_MIN="1000"
ZAPRET_PRIVATES="10.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8 100.64.0.0/10 224.0.0.0/4 240.0.0.0/4"

# health probing (ping THROUGH the tunnel iface). count=2 so the first packet
# can wake an idle/keepalive-less tunnel (triggers a handshake) and the second
# still confirms it within a single probe.
HEALTH_PING_COUNT="2"; HEALTH_PING_TIMEOUT="2"; HEALTH_CURL_TIMEOUT="5"
# handshake wait when probing a freshly-upped candidate
HS_WAIT="10"

LOG_TAG="splify"
STATE_FILE="/var/run/splify-state"
FAIL_COUNTER_FILE="/var/run/splify-failcount"

log()  { logger -t "$LOG_TAG" "$*"; }
die()  { log "ERROR: $*"; echo "ERROR: $*" >&2; exit 1; }
warn() { log "WARN: $*"; }
# warn once per EVERY seconds for a given key. For conditions the failover daemon
# re-discovers on every tick (a list too large to load, see nft_set_fits): the
# operator needs to see it, but not 480 times a day, and on a small box the log
# ring itself is memory.
warn_throttled() {  # KEY EVERY_SECONDS MESSAGE…
    _wt_key="$1"; _wt_every="$2"; shift 2
    _wt_stamp="/var/run/splify-warn.$(printf '%s' "$_wt_key" | tr -c 'A-Za-z0-9._-' '_')"
    _wt_now="$(date +%s)"
    # `|| true` is load-bearing, exactly as for the nozapret sig: the stamp lives
    # on tmpfs, so the FIRST call after a boot reads a missing file, the bare `cat`
    # exits 1, and callers running with `set -e` (every updater, sync-nozapret) die
    # right there — which is how a first-ever throttled warning aborted the whole
    # nozapret rebuild it was only supposed to annotate.
    _wt_last="$(cat "$_wt_stamp" 2>/dev/null || true)"
    case "$_wt_last" in ''|*[!0-9]*) _wt_last=0 ;; esac
    [ $(( _wt_now - _wt_last )) -ge "$_wt_every" ] || return 0
    echo "$_wt_now" > "$_wt_stamp" 2>/dev/null || true
    warn "$*"
}

# ---- failover endpoints (UCI 'endpoint' sections, lowest priority wins) -----
# emit "priority<TAB>iface" per section; callers sort.
_collect_endpoint() {
    local iface prio
    config_get iface "$1" iface ''
    config_get prio  "$1" priority 99
    [ -n "$iface" ] && printf '%s\t%s\n' "$prio" "$iface"
}
# space-separated iface list, ordered by priority (best first).
endpoints_by_priority() {
    config_foreach _collect_endpoint endpoint | sort -n -k1,1 | cut -f2 | tr '\n' ' '
}
# the single highest-priority iface (used as default/active fallback).
top_endpoint() { endpoints_by_priority | awk '{print $1}'; }
# True iff $1 is a configured splify endpoint iface. Used to gate privileged,
# operator-invoked mutations (e.g. firewall-zone fixes) so they can only ever
# touch splify's own tunnels — never an arbitrary iface like `wan`.
is_endpoint() {
    [ -n "$1" ] || return 1   # empty would match the gap between list entries
    case " $(endpoints_by_priority) " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}
# True iff $1 is an actual WireGuard/AmneziaWG interface in /etc/config/network.
# A SECOND gate for privileged firewall mutation: is_endpoint only proves a name
# appears in splify's UCI, but a caller holding the splify write ACL could add
# an arbitrary iface (e.g. `guest`, already in its own firewall zone) as an
# endpoint section and then fw_fix it. Requiring a real tunnel proto confines
# masq/forwarding fixes to genuine tunnels — they can never be pointed at a
# foreign zone. (2.0.0 ships only the `wg` transport; sing-box lands in 3.0.)
iface_is_wg() {
    case "$(uci -q get "network.$1.proto" 2>/dev/null)" in
        wireguard|amneziawg) return 0 ;;
        *) return 1 ;;
    esac
}
# The L3 device a network section binds to: its explicit `device` option, else the
# section name (wg/awg sections name the kernel device after the section).
iface_l3dev() { _d="$(uci -q get "network.$1.device" 2>/dev/null)"; [ -n "$_d" ] && echo "$_d" || echo "$1"; }
# True iff L3 device $1 is the device of some WireGuard/AmneziaWG network section.
# Lets the zone helpers recognise a firewall zone that lists a tunnel by its exact
# device (`list device 'wg0'`) rather than by network name.
device_is_wg() {  # device
    [ -n "$1" ] || return 1
    for _dw in $(uci show network 2>/dev/null | sed -n 's/^network\.\([^.=]*\)=interface$/\1/p'); do
        iface_is_wg "$_dw" || continue
        [ "$(iface_l3dev "$_dw")" = "$1" ] && return 0
    done
    return 1
}
# True iff $1 is the iface of a configured `config singbox` section (no netifd
# proto check possible — sing-box has none).
#
# SECURITY NOTE: unlike iface_is_wg (whose truth depends on network.$1.proto,
# something splify's own write ACL can never set — a real WG interface can
# only be provisioned via LuCI's separate Network page), a `config singbox`
# section lives entirely inside splify's own UCI and the SAME write-ACL grant
# that lets an operator import a legitimate sing-box endpoint could just as
# easily create one named `guest`/`wan`/`lan`. This function alone is NOT a
# safe "genuine tunnel, not an arbitrary existing network" gate the way
# iface_is_wg is — that guarantee instead comes from splify-ctl's
# cmd_singbox_import REFUSING to create/rename a `config singbox` section
# whose iface collides with any already-existing network.<iface> section, so
# a sing-box endpoint name can never alias a real interface in the first
# place. Do not remove that check without re-deriving an equivalent guarantee.
iface_is_singbox() { [ -n "$(singbox_section_of "$1")" ]; }
# True iff $1 is ANY splify-managed tunnel iface, regardless of transport.
iface_is_tunnel() { iface_is_wg "$1" || iface_is_singbox "$1"; }
# True iff L3 device $1 is the l3dev/iface of some `config singbox` section.
# Mirrors device_is_wg's pattern above, but checks config singbox sections
# instead of netifd interfaces (sing-box has no network.*.proto to query).
device_is_singbox() {  # device
    [ -n "$1" ] || return 1
    for _ds in $(uci -q show splify 2>/dev/null | sed -n "s/^splify\.\([^.=]*\)=singbox\$/\1/p"); do
        config_get _ds_iface "$_ds" iface ''
        [ -n "$_ds_iface" ] || continue
        [ "$(singbox_l3dev "$_ds_iface")" = "$1" ] && return 0
    done
    return 1
}
# True iff device $1 is ANY splify-managed tunnel device, regardless of transport.
device_is_tunnel() { device_is_wg "$1" || device_is_singbox "$1"; }

# ---- endpoint type dispatch (transport-agnostic seam; design §2.2) ----------
# Every endpoint carries a `type` (default wg, covering wireguard+amneziawg). All
# type-specific logic funnels through these narrow helpers so 3.0.0 can add a
# sing-box (vless/hysteria) backend without touching failover/doctor/ubus/UI.
# 2.0.0 implements only `wg`; an unknown/future type falls back to wg behavior so
# an existing config can never silently break. (`wg|*)` = "wg, and anything not
# yet implemented behaves as wg".)
_ep_type_emit() {  # $1=section $2=wanted iface — print type if it matches
    config_get _ete_i "$1" iface ''
    [ "$_ete_i" = "$2" ] || return 0
    config_get _ete_t "$1" type 'wg'; [ -n "$_ete_t" ] || _ete_t=wg
    printf '%s\n' "$_ete_t"
}
ep_type() { config_foreach _ep_type_emit endpoint "$1" | head -1; }

# A `singbox` endpoint falls back to this stub ONLY when the sing-box package
# itself isn't installed — so failover never crash-loops chasing a missing
# binary. Warn once per process to avoid log spam. (When sing-box IS installed,
# ep_bringup/ep_restart below drive the real procd instance instead.)
_SINGBOX_WARNED=
_ep_singbox_down() {
    [ -n "$_SINGBOX_WARNED" ] || {
        logger -t splify "sing-box not installed (endpoint $1); treated as down"
        _SINGBOX_WARNED=1
    }
}

# Is there a live egress device for this endpoint? (wg = kernel link present;
# singbox = its TUN l3dev present — no separate netifd proto to query).
ep_present() { case "$(ep_type "$1")" in singbox) iface_present "$(singbox_l3dev "$1")" ;; wg|*) iface_present "$1" ;; esac; }
# L3 device for `ip route … dev` (wg = the iface itself; singbox = cached l3dev).
ep_egress_dev() { case "$(ep_type "$1")" in singbox) singbox_l3dev "$1" ;; wg|*) echo "$1" ;; esac; }
# Liveness age in seconds, smaller = healthier (wg = handshake age; 999999 down).
# singbox has no cheap handshake-age equivalent to `wg show latest-handshakes`,
# so this is a binary present/absent signal (0 or 999999) — a known v1 fidelity
# gap (no gradual staleness signal), documented in the design plan.
ep_liveness() { case "$(ep_type "$1")" in singbox) ep_present "$1" >/dev/null 2>&1 && echo 0 || echo 999999 ;; wg|*) wg_handshake_age "$1" ;; esac; }
# rx/tx cumulative bytes — echoes "rx tx" (wg = summed `wg show transfer`).
# singbox has no free rx/tx counters without enabling its Clash-API stats port
# per instance (extra attack surface) — v1 always reports "0 0", documented
# limitation (UI shows flat/zero speed for sing-box rows).
ep_transfer() {
    case "$(ep_type "$1")" in
        singbox) echo "0 0" ;;
        wg|*) wgshow "$1" transfer \
            | awk '{rx+=$2; tx+=$3} END{printf "%d %d", rx+0, tx+0}' ;;
    esac
}
# Bring an endpoint up / restart it (wg = ifup / ifdown+ifup). Callers that need
# to wait for liveness do so themselves (failover's wait_handshake).
# singbox = start/restart its named procd instance via ubus, guarded on the
# package actually being installed so failover never crash-loops on a missing
# binary (falls back to _ep_singbox_down, same as before sing-box support
# existed). Re-renders the config first (best-effort — the render script may
# not exist yet if it hasn't landed from a parallel change).
ep_bringup() {
    case "$(ep_type "$1")" in
        singbox)
            command -v sing-box >/dev/null 2>&1 || { _ep_singbox_down "$1"; return; }
            [ -x /usr/local/sbin/splify-singbox-render ] && /usr/local/sbin/splify-singbox-render "$1"
            _singbox_instance_ctl "$1" start ;;
        wg|*) ifup "$1" >/dev/null 2>&1 \
            || /etc/init.d/network reload >/dev/null 2>&1 || true ;;
    esac
}
# MUST actually stop then start (full teardown+rebuild), not just start —
# splify-failover's probe_candidate() calls ep_restart specifically for the
# "present but unhealthy, needs a full re-setup" rung and depends on this
# rebuilding the instance, mirroring wg's ifdown+ifup. (_singbox_instance_ctl's
# underlying primitive is already a full service restart regardless of the
# start|stop argument, so one call already gives stop+start semantics — a
# second call would just restart the whole service twice.)
ep_restart() {
    case "$(ep_type "$1")" in
        singbox)
            command -v sing-box >/dev/null 2>&1 || { _ep_singbox_down "$1"; return; }
            [ -x /usr/local/sbin/splify-singbox-render ] && /usr/local/sbin/splify-singbox-render "$1"
            _singbox_instance_ctl "$1" start ;;
        wg|*) ifdown "$1" >/dev/null 2>&1 || true
              ifup "$1" >/dev/null 2>&1 || true ;;
    esac
}

# ---- sing-box: UCI lookups + rendered-config path (design §5/§3) -----------
SINGBOX_CONF_DIR="/var/etc"
# Absolute path to the rendered sing-box config.json for endpoint iface $1.
singbox_conf_file() { printf '%s/splify-singbox-%s.json' "$SINGBOX_CONF_DIR" "$1"; }

# UCI section name (not iface) of the `config singbox` entry whose `iface` option
# matches $1, or empty if none. Mirrors _ep_type_emit's config_foreach-scan pattern.
_singbox_section_emit() {  # $1=section $2=wanted iface
    config_get _sse_i "$1" iface ''
    [ "$_sse_i" = "$2" ] || return 0
    printf '%s\n' "$1"
}
singbox_section_of() { config_foreach _singbox_section_emit singbox "$1" | head -1; }

# TUN device name for a singbox endpoint iface: the section's cached `l3dev`
# option if set, else the iface name itself. Does NOT validate/truncate for
# IFNAMSIZ (<=15 chars) — callers that CREATE the l3dev value own that check.
singbox_l3dev() {
    _sl_sec="$(singbox_section_of "$1")"
    [ -n "$_sl_sec" ] || { printf '%s\n' "$1"; return; }
    config_get _sl_dev "$_sl_sec" l3dev ''
    [ -n "$_sl_dev" ] && printf '%s\n' "$_sl_dev" || printf '%s\n' "$1"
}

# Bounce the sing-box service to (re)start a named endpoint's instance. procd's
# `service` ubus object has no `start_instance`/`stop_instance` methods (its
# real surface is set/add/list/delete/signal/update_start/update_complete/
# event/validate/get_data/set_data/state/watchdog) — calling those silently
# no-ops, so `ep_bringup`/`ep_restart` would never actually start/rebuild
# anything. The correct, always-available primitive is the init script's own
# restart, which re-renders+starts every configured+referenced sing-box
# endpoint via config_foreach. Coarser than WG's per-iface ifdown/ifup (this
# bounces EVERY sing-box instance, not just $1), but correct — acceptable
# given sing-box endpoints are expected to be few. $1 (iface) is accepted for
# call-site clarity/future use but unused; $2 is ignored (both callers just
# need "make sure this instance is freshly (re)started").
_singbox_instance_ctl() {  # iface start|stop
    [ -x /etc/init.d/splify-singbox ] || return 1
    /etc/init.d/splify-singbox restart >/dev/null 2>&1
}

# ---- sing-box URI parser (design §2) ---------------------------------------
# Pure string parsing — NEVER touches UCI. singbox_parse_uri dispatches on
# scheme to singbox_parse_vless/singbox_parse_hysteria2 (hy2:// is an alias for
# hysteria2). On success: "key=value" lines to stdout (one per non-empty
# recognized field), return 0. On failure: nothing to stdout, an error to
# stderr, return 1.

# stdin -> stdout: decode the fixed set of %XX escapes + '+' (space) actually
# seen in vless/hysteria2 share links (UUIDs, base64url tokens, hostnames,
# short obfuscator names — not free text). A small fixed table is realistically
# sufficient and safer than a generic decoder loop under busybox awk, which
# does NOT support strtonum() (verified: only gawk/mawk do, not the busybox
# awk applet OpenWrt actually ships) — see the bats test proving %40/+ decode.
#
# ORDER MATTERS: the '+' -> space substitution (form-encoded space in the query
# string) MUST run BEFORE %2B is decoded to a literal '+'. Otherwise the '+'
# just produced from %2B gets clobbered back to a space, corrupting base64url
# tokens (Reality pbk/sid, vless host/path, hysteria2 passwords) that
# legitimately contain '+'. See the bats test (uri_unescape_plus) — it failed
# before this reordering and passes after.
uri_unescape() {
    sed \
        -e 's/%40/@/g' -e 's/%3[Aa]/:/g' -e 's/%2[Ff]/\//g' \
        -e 's/%3[Dd]/=/g' -e 's/%2[Cc]/,/g' -e 's/%20/ /g' \
        -e 's/+/ /g' -e 's/%2[Bb]/+/g'
}
# $1 = query string (a=b&c=d, no leading '?'), $2 = param name -> prints
# decoded value on stdout, or nothing if absent.
uri_qparam() {
    printf '&%s&' "$1" | sed -n "s/.*&$2=\([^&]*\)&.*/\1/p" | uri_unescape
}

_singbox_reject() { warn "singbox_parse_uri: $*"; return 1; }

# vless://uuid@host:port?query#fragment (query, fragment optional).
singbox_parse_vless() {
    _sbv_x="${1#*://}"
    _sbv_frag=""
    case "$_sbv_x" in *'#'*) _sbv_frag="${_sbv_x#*#}"; _sbv_x="${_sbv_x%%#*}" ;; esac
    _sbv_query=""
    case "$_sbv_x" in *'?'*) _sbv_query="${_sbv_x#*\?}"; _sbv_x="${_sbv_x%%\?*}" ;; esac
    _sbv_userinfo=""
    case "$_sbv_x" in *'@'*) _sbv_userinfo="${_sbv_x%%@*}"; _sbv_x="${_sbv_x#*@}" ;; esac
    _sbv_hostport="${_sbv_x%%/*}"

    case "$_sbv_hostport" in
        '['*) _singbox_reject "IPv6 bracketed host literals are not supported (vless)"; return 1 ;;
    esac
    _sbv_port="${_sbv_hostport##*:}"
    _sbv_host="${_sbv_hostport%:*}"

    [ -n "$_sbv_host" ] || { _singbox_reject "empty host (vless)"; return 1; }
    case "$_sbv_port" in ''|*[!0-9]*) _singbox_reject "empty/non-numeric port (vless)"; return 1 ;; esac
    _sbv_uuid="$_sbv_userinfo"
    [ -n "$_sbv_uuid" ] || { _singbox_reject "empty uuid (vless)"; return 1; }

    _sbv_name=""
    [ -n "$_sbv_frag" ] && _sbv_name="$(printf '%s' "$_sbv_frag" | uri_unescape)"

    _sbv_flow="$(uri_qparam "$_sbv_query" flow)"
    _sbv_security="$(uri_qparam "$_sbv_query" security)"; [ -n "$_sbv_security" ] || _sbv_security=none
    _sbv_sni="$(uri_qparam "$_sbv_query" sni)"
    _sbv_pbk="$(uri_qparam "$_sbv_query" pbk)"
    _sbv_sid="$(uri_qparam "$_sbv_query" sid)"
    _sbv_network="$(uri_qparam "$_sbv_query" type)"; [ -n "$_sbv_network" ] || _sbv_network=tcp
    _sbv_thost="$(uri_qparam "$_sbv_query" host)"
    _sbv_tpath="$(uri_qparam "$_sbv_query" path)"
    _sbv_svc="$(uri_qparam "$_sbv_query" serviceName)"
    # Explicitly ignored (never emitted, never rejected): fp, alpn, spx,
    # headerType, mode, authority, pinSHA256, encryption (vless encryption is
    # always "none" and carries no information).

    printf 'protocol=vless\n'
    printf 'server=%s\n' "$_sbv_host"
    printf 'port=%s\n' "$_sbv_port"
    printf 'uuid=%s\n' "$_sbv_uuid"
    [ -n "$_sbv_name" ] && printf 'name=%s\n' "$_sbv_name"
    [ -n "$_sbv_flow" ] && printf 'flow=%s\n' "$_sbv_flow"
    printf 'security=%s\n' "$_sbv_security"
    [ -n "$_sbv_sni" ] && printf 'sni=%s\n' "$_sbv_sni"
    [ -n "$_sbv_pbk" ] && printf 'pbk=%s\n' "$_sbv_pbk"
    [ -n "$_sbv_sid" ] && printf 'sid=%s\n' "$_sbv_sid"
    printf 'network=%s\n' "$_sbv_network"
    [ -n "$_sbv_thost" ] && printf 'host=%s\n' "$_sbv_thost"
    [ -n "$_sbv_tpath" ] && printf 'path=%s\n' "$_sbv_tpath"
    [ -n "$_sbv_svc" ] && printf 'svc=%s\n' "$_sbv_svc"
    return 0
}

# hysteria2://auth@host:port[/][?query][#fragment] (hy2:// is the same shape).
# port MAY carry a comma port-hop suffix (e.g. "443,5000-6000") — kept verbatim.
singbox_parse_hysteria2() {
    _sbh_x="${1#*://}"
    _sbh_frag=""
    case "$_sbh_x" in *'#'*) _sbh_frag="${_sbh_x#*#}"; _sbh_x="${_sbh_x%%#*}" ;; esac
    _sbh_query=""
    case "$_sbh_x" in *'?'*) _sbh_query="${_sbh_x#*\?}"; _sbh_x="${_sbh_x%%\?*}" ;; esac
    _sbh_userinfo=""
    case "$_sbh_x" in *'@'*) _sbh_userinfo="${_sbh_x%%@*}"; _sbh_x="${_sbh_x#*@}" ;; esac
    _sbh_hostport="${_sbh_x%%/*}"

    case "$_sbh_hostport" in
        '['*) _singbox_reject "IPv6 bracketed host literals are not supported (hysteria2)"; return 1 ;;
    esac
    _sbh_port="${_sbh_hostport##*:}"
    _sbh_host="${_sbh_hostport%:*}"

    [ -n "$_sbh_host" ] || { _singbox_reject "empty host (hysteria2)"; return 1; }
    # port MAY carry a comma port-hop suffix (e.g. "443,5000-6000") — don't
    # validate it as a single integer, just require it starts with digits.
    case "$_sbh_port" in [0-9]*) : ;; *) _singbox_reject "empty/non-numeric port (hysteria2)"; return 1 ;; esac
    # userinfo is percent-encoded like everything else in the URI (a password
    # containing e.g. '@' would arrive as %40) — decode it the same way query
    # params and the fragment already are, or auth fails on any password with
    # a reserved character in it.
    _sbh_password="$(printf '%s' "$_sbh_userinfo" | uri_unescape)"
    [ -n "$_sbh_password" ] || { _singbox_reject "empty password (hysteria2)"; return 1; }

    _sbh_name=""
    [ -n "$_sbh_frag" ] && _sbh_name="$(printf '%s' "$_sbh_frag" | uri_unescape)"

    _sbh_sni="$(uri_qparam "$_sbh_query" sni)"
    _sbh_insecure="$(uri_qparam "$_sbh_query" insecure)"; [ -n "$_sbh_insecure" ] || _sbh_insecure=0
    _sbh_obfs="$(uri_qparam "$_sbh_query" obfs)"
    _sbh_obfspw="$(uri_qparam "$_sbh_query" obfs-password)"

    printf 'protocol=hysteria2\n'
    printf 'server=%s\n' "$_sbh_host"
    printf 'port=%s\n' "$_sbh_port"
    printf 'password=%s\n' "$_sbh_password"
    [ -n "$_sbh_name" ] && printf 'name=%s\n' "$_sbh_name"
    [ -n "$_sbh_sni" ] && printf 'sni=%s\n' "$_sbh_sni"
    printf 'insecure=%s\n' "$_sbh_insecure"
    [ -n "$_sbh_obfs" ] && printf 'obfs=%s\n' "$_sbh_obfs"
    [ -n "$_sbh_obfspw" ] && printf 'obfspw=%s\n' "$_sbh_obfspw"
    return 0
}

# $1 = full URI string. Dispatches on scheme; rejects unknown schemes. NEVER
# touches UCI — pure string parsing.
singbox_parse_uri() {
    case "$1" in
        vless://*)              singbox_parse_vless "$1" ;;
        hysteria2://*|hy2://*)  singbox_parse_hysteria2 "$1" ;;
        *) _singbox_reject "unrecognized scheme"; return 1 ;;
    esac
}

# ---- active-path state -----------------------------------------------------
# State file holds the live path: "vpn:<iface>" | "zapret" | "wan".
read_state()  { cat "$STATE_FILE" 2>/dev/null || true; }
write_state() { printf '%s\n' "$1" > "$STATE_FILE"; }
# iface currently carrying VPN traffic (from state), else top-priority endpoint.
# A saved iface that is no longer a configured endpoint (removed/renamed in UCI)
# is ignored so we never probe/route a stale device.
active_iface() {
    _s="$(read_state)"
    case "$_s" in
        vpn:*)
            _cur="${_s#vpn:}"
            case " $(endpoints_by_priority) " in
                *" $_cur "*) echo "$_cur"; return ;;
            esac
            ;;
    esac
    top_endpoint
}
# VPN_IFACE keeps backward-compat for scripts that reference a single iface
# (apply/status). It is the live active iface, or the top-priority one at boot.
VPN_IFACE="$(active_iface)"
[ -n "$VPN_IFACE" ] || VPN_IFACE="$(top_endpoint)"

# source IP of an iface (for route `src`, DoH pins). Empty if down/none.
iface_src_ip() {
    ip -4 -o addr show dev "$1" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1
}

# ---- nft: keeping `nft` inside this router's memory -------------------------
#
# THE PROBLEM, measured on a 240MB filogic box with production lists (ipsum
# ~24k prefixes, nozapret ~44k): every `nft` process that touches a large set
# builds the whole thing in its OWN address space. Observed RSS 54-65MB per
# process — against ~96MB free with dnsmasq already holding ~28MB. The kernel
# OOM-killer fired four times in one hour, killing `nft` mid-load every time
# (and `dnsmasq` in earlier rounds). A killed loader leaves the set PARTIALLY
# populated, which is worse than not reloading at all: zapret's bypass is then
# wrong, traffic that should be direct rides the tunnel or vice versa, and the
# box looks "up" while splify behaves incorrectly.
#
# Two habits were feeding it, both fixed below:
#   1. COUNTING. `nft list set` expands every interval into text just to count
#      lines. The failover loop did that on the ipsum set EVERY tick, and
#      sync-nozapret did it on the 44k bypass set before every rebuild. Neither
#      needs a count — they need "is this set populated?", which `nft get
#      element` answers with an O(1) lookup and a few hundred KB.
#   2. LOADING. One `add element { … }` block with 44k entries is a single
#      command nft must parse whole. Loading in chunks of a few thousand keeps
#      each process small; the set is briefly incomplete mid-load, which is an
#      acceptable trade against being OOM-killed at an arbitrary point.
#
# Elements per `nft` invocation, and the address-space ceiling each one runs
# under. The cap is a backstop: if a chunk somehow still grows past it, nft dies
# with ENOMEM and we log a failure, instead of the kernel choosing a victim
# process elsewhere on the box.
NFT_CHUNK_ELEMS="${SPLIFY_NFT_CHUNK:-4000}"
# Re-exec the CALLING SCRIPT at the lowest priority, once. List refreshes are
# nightly cron work whose aggregation is minutes of solid CPU on a 380-BogoMIPS
# MT7628 — it must never be the reason the router feels slow. busybox has `nice`
# but not `renice`, so a process cannot demote itself; it has to start again under
# nice. The guard variable keeps that to exactly one re-exec.
run_low_priority() {  # "$0" "$@" from the caller
    [ -n "${SPLIFY_LOW_PRIO:-}" ] && return 0
    command -v nice >/dev/null 2>&1 || return 0
    SPLIFY_LOW_PRIO=1
    export SPLIFY_LOW_PRIO
    exec nice -n 19 "$@"
}

# Chunking bounds the LOADER. It does nothing about the other half of the cost:
# the set itself, which the kernel keeps in an unswappable rbtree — measured
# ~150 bytes per interval element, so a 24k-prefix ipsum set is ~3.5MB of kernel
# memory that must stay resident for as long as the set exists.
#
# On a Xiaomi Mi Router 4C (MT7628AN, 58MB RAM, ~13MB available) that is enough,
# together with the loader and whatever else is running, to take the box into an
# OOM reboot — a reboot which then replays the same load on the next failover
# tick, i.e. a boot loop. A router that reboots is worse than a router without a
# blocklist, so a load that cannot fit is REFUSED and reported, loudly, instead
# of being attempted.
#
# NFT_ELEM_BYTES: total memory a set element costs while it is being worked on.
#   It is NOT just the kernel's rbtree node, and this is the part that makes small
#   routers fail: libnftables builds a CACHE OF THE WHOLE TABLE — every element of
#   every set — before it executes ANY command. Measured on a Mi Router 4C against
#   a 13 886-element ipsum set:
#
#     nft get element … { 1.2.3.4 }        15 MB      <- a single lookup!
#     nft -a -t list table inet fw4         2 MB      <- terse: no elements fetched
#     nft flush set …                       2 MB
#     nft get element (same set, emptied)    1 MB
#
#   ~1.1KB per element, per invocation. Two consequences: (1) an element-level
#   "cheap probe" does not exist at this layer, which is why set health is tracked
#   with a stamp below instead; (2) CHUNKED LOADING DOES NOT BOUND MEMORY on its
#   own — chunk N pays for the N-1 chunks already in the set, so the last chunk of
#   a 30k list is the expensive one. Chunking still helps (early chunks are cheap,
#   each process is short-lived and the ulimit contains it), but the only thing
#   that keeps a small router alive is refusing a list that cannot fit at all.
#   Calibrated from BOTH sides, because this number has two ways to be wrong: too
#   low and the router OOMs, too high and a healthy router is denied a list it can
#   actually hold (which silently disables the bypass).
#
#     upper bound  Mi 4C, ~13MB free: a 30 726-prefix load OOM-rebooted it.
#                  To refuse that, the estimate must exceed ~443 B/prefix.
#     lower bound  filogic, 85MB free: a 74 648-prefix load COMPLETED — 19 chunks,
#                  71MB peak RSS on the last one, and MemAvailable troughed at
#                  61MB (i.e. it cost ~330 B/prefix of actual headroom; nft's RSS
#                  is much larger than the pressure it adds, because a good part
#                  of what MemAvailable reports is reclaimable). To allow that,
#                  the estimate must stay under ~845 B/prefix.
#
#   800 sits inside that window, deliberately toward the cautious end: the 4C is
#   refused until it has >24MB free (it never does — 58MB of RAM total, ~16-20MB
#   free in practice), while the filogic load still passes with room to spare
#   (58MB needed vs 85MB). At 600 the 4C would have started that load again as
#   soon as free memory drifted to ~18MB, and the one data point we have says a
#   load of that size killed it.
# NFT_MEM_RESERVE_KB: the floor under which the box counts as already critical and
#   we will not start a big load at all, whatever the arithmetic says.
# NFT_ELEM_KERNEL_BYTES: the part of the above that the KERNEL holds for as long
#   as the set exists (rbtree nodes; an interval element is two of them). It
#   matters for one thing: a reload flushes the old contents first, so that memory
#   comes back before the new load needs it. Without crediting it, a router in its
#   normal steady state — sets loaded, memory accounted for — would refuse every
#   subsequent refresh of a list it is already successfully holding.
NFT_ELEM_BYTES="${SPLIFY_NFT_ELEM_BYTES:-800}"
NFT_ELEM_KERNEL_BYTES="${SPLIFY_NFT_ELEM_KERNEL_BYTES:-300}"
# NFT_ELEM_RESIDENT_BYTES: what an element costs for as long as the set EXISTS, as
#   opposed to the peak during loading. This decides how big a list a router can
#   KEEP, which is a different question from whether it can survive the load — and
#   the one that matters, because a box left with almost nothing free starts
#   OOM-killing uhttpd and its own diagnostics afterwards.
#
#   Measured on the Mi 4C twice, and the first reading was wrong: right after a
#   load MemAvailable had fallen from 16MB to 6MB (~550 bytes per prefix), but once
#   the caches settled the same 17 365-prefix set sat at 12MB free — i.e. the
#   lasting cost is ~300 bytes per prefix, and 550 was a transient dip. 350 keeps a
#   margin over the settled figure. Reading the dip as permanent made the fitter
#   throw away ~40% more of the list than the router actually needed it to.
NFT_ELEM_RESIDENT_BYTES="${SPLIFY_NFT_ELEM_RESIDENT_BYTES:-350}"
NFT_MEM_RESERVE_KB="${SPLIFY_NFT_MEM_RESERVE_KB:-10240}"

# NO ulimit here, deliberately. Two attempts at an address-space backstop were
# tried and both broke real loads, because `ulimit -v` bounds VIRTUAL address
# space and nft's VA sits far above its RSS:
#
#   * a fixed 32MB cap: flushing an already-populated set failed outright, and the
#     set was left empty;
#   * a cap derived from MemAvailable (70MB on a box with 80MB free): the nozapret
#     load died at chunk 15 of 19 with "src/utils.c:33: Memory allocation failure"
#     while MemAvailable never dropped below 73MB — i.e. the cap, not the router,
#     was the limit.
#
# A backstop that fails loads the box could actually complete is worse than none:
# it leaves sets half-loaded, which is the exact failure mode all of this exists
# to prevent. The real guard is nft_set_fits() below — it refuses up front, from
# measured per-element cost, and never interrupts a load in progress.

mem_available_kb() { awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo 2>/dev/null || echo 0; }

# Can this box hold a set of $1 elements right now? Echoes a human explanation on
# stdout when it cannot, so callers can put it straight into a log/diagnostic.
# The comparison deliberately does NOT also subtract the reserve from the
# estimate: the measured 74 648-prefix load needed 71MB on a box with 85MB free
# and succeeded, so demanding need+reserve would have refused a working
# configuration. The reserve is instead a hard floor on its own — if the router is
# already that low, no big load starts, period.
nft_set_fits() {  # ELEMENT_COUNT [SET_BEING_REPLACED]
    _nsf_need_kb=$(( ($1 * NFT_ELEM_BYTES) / 1024 ))
    _nsf_avail_kb="$(mem_available_kb)"
    case "$_nsf_avail_kb" in ''|*[!0-9]*) return 0 ;; esac   # unknown -> don't block
    # Replacing a set we already hold? The flush comes first, so count the kernel
    # memory it releases as available.
    if [ -n "${2:-}" ]; then
        _nsf_avail_kb=$(( _nsf_avail_kb + ($(_set_prev_count "$2") * NFT_ELEM_RESIDENT_BYTES) / 1024 ))
    fi
    if [ "$_nsf_avail_kb" -le "$NFT_MEM_RESERVE_KB" ]; then
        printf 'only %sMB of memory is available, below the %sMB floor for loading a list at all' \
            "$(( _nsf_avail_kb / 1024 ))" "$(( NFT_MEM_RESERVE_KB / 1024 ))"
        return 1
    fi
    [ "$_nsf_avail_kb" -gt "$_nsf_need_kb" ] && return 0
    printf '%s elements need ~%sMB to load but only %sMB is available' \
        "$1" "$(( _nsf_need_kb / 1024 ))" "$(( _nsf_avail_kb / 1024 ))"
    return 1
}

# ---- set health without touching the elements -------------------------------
# What we need to know on every failover tick is "does the kernel still hold the
# list we loaded?" — and per the measurements above, asking nft about an element
# costs ~1.1KB per element in the set. So we do not ask. We record what we loaded
# and compare cheap identifiers instead:
#
#   * the stamp lives in /var/run (tmpfs) -> a REBOOT loses it, and a reboot does
#     drain the sets, so that is exactly right;
#   * an fw4 reload REPLACES `table inet fw4`, which changes the table's and the
#     set's handles -> recorded and compared, via one 2MB terse listing;
#   * a list refresh changes the source file -> its size+mtime are in the stamp,
#     so the loader that wrote the stamp is always the one that matches it.
#
# Not covered: someone flushing the set out of band (`nft flush set` by hand)
# without touching handles. The failover tick would not notice until the next
# reboot/reload or list refresh. That is a deliberate trade — the alternative is
# a 15MB probe every 180s on a router with 13MB free.
_set_stamp_file() {  # SET -> path
    printf '/var/run/splify-set.%s' "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
}
# "<table handle>:<set handle>" for TABLE/SET, or empty. Terse (-t) is what keeps
# this cheap: it lists the table's structure WITHOUT fetching set elements.
_set_ident() {  # TABLE SET
    nft -a -t list table "$1" 2>/dev/null | awk -v s="$2" '
        /^table/ { for (i = 1; i <= NF; i++) if ($i == "handle") th = $(i+1) }
        $1 == "set" && $2 == s { for (i = 1; i <= NF; i++) if ($i == "handle") sh = $(i+1) }
        END { if (th != "" && sh != "") printf "%s:%s", th, sh }
    '
}
_src_ident() {  # FILE -> "<size>:<mtime>"
    printf '%s:%s' "$(wc -c < "$1" 2>/dev/null)" "$(stat -c %Y "$1" 2>/dev/null || date -r "$1" +%s 2>/dev/null)"
}
set_stamp_write() {  # TABLE SET FILE
    printf '%s %s\n' "$(_set_ident "$1" "$2")" "$(_src_ident "$3")" > "$(_set_stamp_file "$2")" 2>/dev/null || true
    # Companion file, not a third field in the stamp: set_healthy compares the
    # stamp verbatim, so its format must stay exactly two fields.
    grep -cE '^[0-9]' "$3" > "$(_set_stamp_file "$2").n" 2>/dev/null || true
}
set_stamp_clear() { rm -f "$(_set_stamp_file "$1")" "$(_set_stamp_file "$1").n" 2>/dev/null || true; }
# How many elements WE last loaded into this set (0 if we never did / after a
# reboot). Used to credit the memory a flush will hand back.
_set_prev_count() {  # SET
    _spc="$(cat "$(_set_stamp_file "$1").n" 2>/dev/null || true)"
    case "$_spc" in ''|*[!0-9]*) echo 0 ;; *) echo "$_spc" ;; esac
}
# 0 iff the kernel still holds what we loaded from FILE.
set_healthy() {  # TABLE SET FILE
    [ -s "$3" ] || return 1
    _sh_stamp="$(cat "$(_set_stamp_file "$2")" 2>/dev/null)" || return 1
    [ -n "$_sh_stamp" ] || return 1
    [ "$_sh_stamp" = "$(_set_ident "$1" "$2") $(_src_ident "$3")" ]
}

# Is ADDR a member of set TABLE/SET? Interval sets match a CONTAINED host address
# against the stored prefix, so a plain address is a valid probe for a CIDR list.
#
# EXPENSIVE — see the cache measurements above: this costs ~1.1KB per element
# ALREADY IN THE SET (15MB against a 14k-element set), not O(1) as the kernel-side
# lookup would suggest. Gate every call on nft_cache_affordable, and never use it
# on a path that runs unattended.
set_has() { nft get element "$1" "$2" "{ $3 }" >/dev/null 2>&1; }

# Can this box afford an nft command that pulls a set of ~$1 elements into the
# CLI's cache right now?
nft_cache_affordable() {  # ELEMENT_COUNT
    _nca_avail="$(mem_available_kb)"
    case "$_nca_avail" in ''|*[!0-9]*) return 0 ;; esac
    [ "$_nca_avail" -gt $(( ($1 * NFT_ELEM_BYTES) / 1024 + NFT_MEM_RESERVE_KB )) ]
}

# Declared maximum size of a set, or empty when it is unbounded. Cheap: terse
# listing, no elements. Load-bearing for the zapret bypass — zapret creates its
# `nozapret` set with `size 65536`, and once splify's ru+ipsum lists together
# exceed that, the load fails PART WAY and leaves the bypass in whatever state it
# reached (observed: 74 648 entries offered, set left empty, so zapret then
# mangled traffic that was supposed to be exempt).
nft_set_capacity() {  # TABLE SET
    nft -t list set "$1" "$2" 2>/dev/null | awk '$1 == "size" { print $2 + 0; exit }'
}

# Exact element count. EXPENSIVE (see above) — for interactive debugging only
# (splify-status); no automated path may call this. Capped so that even there it
# can only ever kill itself.
set_count() {
    _cnt="$(nft list set "$1" "$2" 2>/dev/null \
        | tr ',' '\n' \
        | grep -cE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
        || true)"
    echo "${_cnt:-0}"
}

# Validate+clean an IPv4/CIDR list on stdin -> stdout: strip CR, trailing
# comments and whitespace, drop anything that isn't a well-formed v4 addr/prefix,
# dedup. Shared by the ipsum/ru updaters (identical rules).
clean_ip_list() {
    awk '
        function vnum(x, lo, hi) { return x ~ /^[0-9]+$/ && x >= lo && x <= hi }
        function valid(line, a, n) {
            n = split(line, a, "[./]")
            return n == 5 && vnum(a[1],0,255) && vnum(a[2],0,255) \
                && vnum(a[3],0,255) && vnum(a[4],0,255) && vnum(a[5],0,32)
        }
        { l = $0; sub(/\r$/, "", l); sub(/[ \t]*#.*/, "", l); gsub(/[ \t]/, "", l)
          if (l == "" || !valid(l) || seen[l]++) next
          print l }
    '
}

# ---- prefix aggregation: fewer set elements for the same coverage -----------
# Every element of an nft interval set costs memory both in the kernel and, worse,
# in each nft invocation's table cache (see the nft section above). The lists we
# load are full of prefixes that are adjacent or contained in one another —
# ipsum in particular is largely runs of consecutive /24s — so the SAME coverage
# can be expressed with far fewer elements.
#
# Measured on the production lists (30 672-prefix ipsum, 44 023-prefix ru/cn):
#
#   slack      ipsum          ru/cn        union (nozapret)
#   0          28 505 (-8%)   44 023 (0%)  70 042 (-7%)
#   64         15 284 (-51%)  43 689 (-1%) 56 299 (-25%)
#
# So lossless merging alone is nearly useless here — the ru/cn list arrives
# already aggregated, and the union stays ABOVE the 65 536 set capacity. The win
# comes from bridging small gaps, which is why SLACK exists:
#
#   slack = 0   strictly lossless: only merge ranges that touch or overlap.
#               Coverage identical. Always tried first.
#   slack > 0   also bridge gaps up to that many addresses and round a range
#               outward to one aligned prefix at no more than that cost. This ADDS
#               addresses to the set, so it is used only as far as a router needs
#               it, and the total is reported (see fit_list_for_set).
#
# EXCLUDE is what makes widening safe for a ROUTING set. Bridging a gap in the
# ipsum (via-VPN) list would send every address in that gap through the tunnel —
# including Russian addresses that must stay direct, where a foreign exit IP can
# mean a bank or a state service simply refuses the connection. With the ru/cn
# list passed as EXCLUDE, a gap that touches it is never bridged. Measured cost of
# that safety: 15 284 prefixes instead of 14 477 (and slightly FEWER extra
# addresses), i.e. essentially free.
#
# The intermediate sort is a PLAIN BYTE SORT over zero-padded numbers, not
# `sort -n`. On the mipsel Mi 4C, busybox sort -n compares numerically as 32-bit
# SIGNED: every address above 2^31 (128.0.0.0 and up) came out before the smaller
# ones, e.g. 908522308 sorted after 3323410856. The merge pass then absorbed
# unrelated ranges into each other and a 30 726-prefix list "aggregated" to 28
# entries — silent, catastrophic, and invisible on aarch64, where sort -n uses
# 64-bit longs and the same code was correct. Fixed-width zero padding makes
# lexicographic order equal numeric order on any platform.
#
# Implemented as awk -> sort -> awk, and the exclusion list is walked with a
# monotonic cursor via getline rather than loaded into an array — on a 58MB router
# holding 27k ranges in awk would defeat the purpose. A probe that would need to
# look BACKWARDS returns "hits" instead, so the cursor trick can only ever be
# conservative (refuse to bridge), never wrong in the dangerous direction.
#
# Total extra addresses go to stderr as "#WASTE <n>" for the caller to report.
#
# NOTE: no apostrophes in the awk comments below (single-quoted shell).
aggregate_ip_list() {  # SLACK [EXCLUDE_FILE]  (CIDR list on stdin) -> stdout
    awk '
        function ip2int(s, a) { split(s, a, "."); return ((a[1] * 256 + a[2]) * 256 + a[3]) * 256 + a[4] }
        {
            n = split($0, p, "/")
            ip = ip2int(p[1]); len = (n > 1 ? p[2] + 0 : 32)
            size = 2 ^ (32 - len)
            start = ip - (ip % size)          # normalise to the network address
            # Zero-padded to a FIXED WIDTH so the plain byte sort below orders them
            # numerically. See the sort note above: -n cannot be trusted here.
            printf "%010.0f %010.0f\n", start, start + size - 1
        }
    ' | sort | awk -v slack="${1:-0}" -v excl="${2:-}" '
        function int2ip(x,   a, b, c, d) {
            d = x % 256; x = int(x / 256); c = x % 256; x = int(x / 256)
            b = x % 256; a = int(x / 256)
            return a "." b "." c "." d
        }
        # Does [a,b] touch the exclusion list? Cursor-based: advance past ranges
        # that end below a, then test the one in front. A probe that starts behind
        # where the cursor already is cannot be answered without looking back, so
        # it answers "yes" and the caller declines to widen.
        function hits(a, b,   line, f) {
            if (excl == "") return 0
            if (a < probe_floor) return 1
            probe_floor = a
            while (!x_done && x_e < a) {
                if ((getline line < excl) > 0) { split(line, f, " "); x_s = f[1] + 0; x_e = f[2] + 0 }
                else x_done = 1
            }
            return (!x_done && x_s <= b)
        }
        # Cover [s,e] with ONE aligned prefix when the extra addresses fit the slack
        # budget and the widening stays clear of the exclusion list; else decompose
        # it exactly.
        function emit(s, e,   len, size, bs, be, extra) {
            for (len = 32; len >= 0; len--) {
                size = 2 ^ (32 - len)
                bs = s - (s % size); be = bs + size - 1
                if (be >= e) {
                    extra = (s - bs) + (be - e)
                    if (extra > 0 && extra <= slack && !hits(bs, be)) {
                        printf "%s/%d\n", int2ip(bs), len; waste += extra; return
                    }
                    if (extra == 0) { printf "%s/%d\n", int2ip(bs), len; return }
                    break
                }
            }
            while (s <= e) {
                for (len = 0; len <= 32; len++) {
                    size = 2 ^ (32 - len)
                    if (s % size == 0 && s + size - 1 <= e) break
                }
                printf "%s/%d\n", int2ip(s), len
                s += size
            }
        }
        BEGIN { cs = -1; x_e = -1; probe_floor = 0 }
        {
            s = $1 + 0; e = $2 + 0
            if (cs < 0) { cs = s; ce = e; next }
            if (s <= ce + 1) {                              # touching or overlapping: always merge
                if (e > ce) ce = e
                next
            }
            if (s <= ce + 1 + slack && !hits(ce + 1, s - 1)) {   # bridgeable, and the gap is clear
                waste += s - ce - 1
                if (e > ce) ce = e
                next
            }
            emit(cs, ce); cs = s; ce = e
        }
        END { if (cs >= 0) emit(cs, ce); printf "#WASTE %.0f\n", waste + 0 > "/dev/stderr" }
    '
}

# Merged, sorted "start end" ranges for an exclusion list — the form
# aggregate_ip_list can walk with a cursor. Written to stdout.
ip_list_ranges() {  # (CIDR list on stdin) -> "start end" ranges on stdout
    awk '
        function ip2int(s, a) { split(s, a, "."); return ((a[1] * 256 + a[2]) * 256 + a[3]) * 256 + a[4] }
        { n = split($0, p, "/"); ip = ip2int(p[1]); len = (n > 1 ? p[2] + 0 : 32)
          size = 2 ^ (32 - len); s = ip - (ip % size)
          printf "%010.0f %010.0f\n", s, s + size - 1 }
    ' | sort | awk '
        { s = $1 + 0; e = $2 + 0
          if (cs == "") { cs = s; ce = e; next }
          if (s <= ce + 1) { if (e > ce) ce = e; next }
          printf "%.0f %.0f\n", cs, ce; cs = s; ce = e }
        END { if (cs != "") printf "%.0f %.0f\n", cs, ce }
    '
}

# Aggregate FILE just enough that the result fits both limits that apply to SET,
# writing it to DEST:
#   * MEMORY  — what this router can actually load (nft_set_fits);
#   * CAPACITY — the `size N` the set was declared with, if any. Both splify's own
#     ipsum set and zapret's nozapret are declared `size 65536`, and a load that
#     runs past it fails part-way, leaving the set in whatever state it reached.
#
# Starts lossless and only widens the slack while the result still does not fit,
# so a router with room to spare never routes one extra address, while a router
# that would otherwise get NO blocklist at all gets one — with the cost written to
# the log. Sets _FIT_COUNT/_FIT_SLACK/_FIT_WASTE, and _FIT_TRUNCATED=1 if entries
# had to be dropped outright.
#
# FIT_SLACK_LADDER lets the CALLER bound how far widening may go, because "extra
# addresses" mean different things per set and the acceptable amount differs:
#   * ipsum (via-VPN): extra addresses ride the tunnel. Mildly wasteful, and the
#     ru/cn exclusion keeps it off addresses that must stay direct.
#   * nozapret (zapret must-not-touch): extra addresses lose their DPI bypass, so
#     a blocked site inside a widened range becomes unreachable on the WAN path.
#     Measured: an unbounded ladder reached slack 65536 = +225M addresses (5% of
#     IPv4) on a 16MB box. Callers cap it low and drop a whole tier instead.
fit_list_for_set() {  # SET SRC DEST [MAXCOUNT] [EXCLUDE_RANGES] -> 0 fitted, 1 impossible
    _FIT_COUNT=0; _FIT_SLACK=0; _FIT_WASTE=0; _FIT_TRUNCATED=0   # never report a previous call's outcome
    _flf_src_n="$(grep -cE '^[0-9]' "$2" 2>/dev/null || echo 0)"
    for _flf_slack in ${FIT_SLACK_LADDER:-0 64 256 1024}; do
        _flf_waste="$(aggregate_ip_list "$_flf_slack" "${5:-}" < "$2" 2>&1 >"$3.work" \
            | sed -n 's/^#WASTE //p')"
        _flf_n="$(grep -cE '^[0-9]' "$3.work" 2>/dev/null || echo 0)"
        # Capacity first: it is a hard property of the set, not of the moment.
        if [ -n "${4:-}" ] && [ "${4:-0}" -gt 0 ] 2>/dev/null && [ "$_flf_n" -gt "$4" ]; then
            continue
        fi
        nft_set_fits "$_flf_n" "$1" >/dev/null || continue
        # Surviving the load is not enough — the set stays resident afterwards.
        # Require the router to still have its reserve free once it is loaded,
        # crediting whatever the flush of the current contents gives back.
        _flf_avail="$(mem_available_kb)"
        case "$_flf_avail" in ''|*[!0-9]*) _flf_avail=0 ;; esac
        if [ "$_flf_avail" -gt 0 ]; then
            _flf_credit=$(( ($(_set_prev_count "$1") * NFT_ELEM_RESIDENT_BYTES) / 1024 ))
            _flf_after=$(( _flf_avail + _flf_credit - (_flf_n * NFT_ELEM_RESIDENT_BYTES) / 1024 ))
            [ "$_flf_after" -ge "$NFT_MEM_RESERVE_KB" ] || continue
        fi
        mv "$3.work" "$3"
        _FIT_COUNT="$_flf_n"; _FIT_SLACK="$_flf_slack"; _FIT_WASTE="${_flf_waste:-0}"
        if [ "$_flf_slack" = 0 ]; then
            log "$1: $_flf_src_n -> $_flf_n prefixes (lossless aggregation)"
        else
            log "$1: $_flf_src_n -> $_flf_n prefixes, slack $_flf_slack (+${_FIT_WASTE} extra addresses) to fit this router"
        fi
        return 0
    done
    # No amount of (safe) widening fits. Last resort: keep as much of the most
    # aggregated list as the router can hold, and say how much was left out.
    #
    # For a BLOCKLIST this degrades in the right direction — the prefixes that are
    # kept work exactly as intended, and the rest simply behave as they did before
    # splify was installed. It is also strictly safer than widening further: on the
    # 4C the ru/cn exclusion (correctly) blocks the widest merges, so the list
    # plateaus around 14k prefixes, and pushing past that would have meant either
    # tunnelling Russian addresses or leaving the box with no memory reserve.
    if [ -s "$3.work" ]; then
        _flf_avail="$(mem_available_kb)"
        case "$_flf_avail" in ''|*[!0-9]*) _flf_avail=0 ;; esac
        _flf_credit=$(( ($(_set_prev_count "$1") * NFT_ELEM_RESIDENT_BYTES) / 1024 ))
        # Both limits must hold, so the target is whichever is smaller:
        #   transient — the peak while loading (NFT_ELEM_BYTES per element),
        #   resident  — what stays afterwards, leaving the reserve free.
        # Taking only the resident one is what produced "keeping 18409 prefixes"
        # immediately followed by the loader refusing those same 18409.
        _flf_max=$(( ((_flf_avail + _flf_credit) * 1024) / NFT_ELEM_BYTES ))
        _flf_max_res=$(( ((_flf_avail + _flf_credit - NFT_MEM_RESERVE_KB) * 1024) / NFT_ELEM_RESIDENT_BYTES ))
        [ "$_flf_max_res" -lt "$_flf_max" ] && _flf_max="$_flf_max_res"
        [ -n "${4:-}" ] && [ "${4:-0}" -gt 0 ] 2>/dev/null && [ "$_flf_max" -gt "$4" ] && _flf_max="$4"
        if [ "$_flf_max" -gt 1000 ]; then
            head -n "$_flf_max" "$3.work" > "$3"
            rm -f "$3.work"
            _FIT_COUNT="$_flf_max"; _FIT_SLACK="$_flf_slack"; _FIT_WASTE="${_flf_waste:-0}"
            _FIT_TRUNCATED=1
            _flf_agg_n="$(grep -cE '^[0-9]' "$3" 2>/dev/null || echo 0)"
            warn_throttled "fit.$1" 3600 \
                "$1: this router can hold about $_flf_max prefixes; keeping $_flf_agg_n of the aggregated list (raw list had $_flf_src_n). Addresses beyond the cut behave as if splify were not installed"
            return 0
        fi
    fi
    rm -f "$3.work"
    return 1
}

# Emit ONE `add element … { a,b,c }` command per NFT_CHUNK_ELEMS entries, read
# from a cleaned list on stdin. Deliberately NOT the old single giant block: that
# was one command nft had to parse whole (54-65MB for a 44k list, OOM-killed on a
# 240MB box — see the nft section above). One element per `add` would be the other
# extreme: 44k forks.
emit_nft_set_chunks() {  # TABLE SET  (elements on stdin) -> commands on stdout
    awk -v tbl="$1" -v set="$2" -v n="$NFT_CHUNK_ELEMS" '
        { if (c == 0) printf "add element %s %s { %s", tbl, set, $0
          else printf ",%s", $0
          if (++c >= n) { print " }"; c = 0 } }
        END { if (c > 0) print " }" }
    '
}

# Replace the contents of set TABLE/SET with a cleaned list from FILE, chunk by
# chunk, each chunk its own bounded nft process.
#
# NOT ATOMIC, by choice: `flush` lands first and the set is incomplete until the
# last chunk applies (a second or so). The atomic alternative — one command — is
# what the OOM-killer was interrupting at an ARBITRARY point, leaving a partial
# set with no error and no retry. Here a failed chunk is a reported failure, the
# caller retries on its next tick, and set_healthy() detects the partial state in
# the meantime because chunks apply in file order (its last-element probe fails).
nft_load_set() {  # TABLE SET FILE
    [ -s "$3" ] || { warn "nft_load_set: empty source list $3"; return 1; }
    # Refuse rather than reboot (see the memory notes above). Checked BEFORE the
    # flush so a refusal leaves the current — possibly still working — set alone.
    _nls_n="$(grep -cE '^[0-9]' "$3" 2>/dev/null || echo 0)"
    if ! _nls_why="$(nft_set_fits "$_nls_n" "$2")"; then
        # Throttled: the failover daemon re-checks this every tick and the answer
        # will not change until the operator acts or memory frees up.
        warn_throttled "nftfit.$2" 3600 \
            "refusing to load $2: $_nls_why — shrink the list or disable it (the router would otherwise OOM)"
        return 2
    fi
    printf 'flush set %s %s\n' "$1" "$2" | nft -f - 2>/dev/null \
        || { warn "nft_load_set: cannot flush $1 $2"; return 1; }
    # The stamp describes a set that matches its source. It stops being true the
    # moment we flush, and stays untrue until the last chunk lands.
    set_stamp_clear "$2"
    _nls_cmds="/tmp/splify-nftload.$$"
    emit_nft_set_chunks "$1" "$2" < "$3" > "$_nls_cmds" || { rm -f "$_nls_cmds"; return 1; }
    _nls_rc=0
    _nls_i=0
    # Redirect (not a pipe) so the loop body runs in THIS shell and _nls_rc
    # survives it.
    while IFS= read -r _nls_cmd; do
        _nls_i=$(( _nls_i + 1 ))
        printf '%s\n' "$_nls_cmd" | nft -f - 2>/dev/null || {
            warn "nft_load_set: chunk $_nls_i failed for $1 $2 (set is now partial; will retry)"
            _nls_rc=1
            break
        }
    done < "$_nls_cmds"
    rm -f "$_nls_cmds"
    # Only a COMPLETE load earns a stamp — a partial set must read as unhealthy so
    # the next tick retries it.
    [ "$_nls_rc" = 0 ] && set_stamp_write "$1" "$2" "$3"
    return "$_nls_rc"
}

has_rule() { ip -4 rule show | grep -q "$1"; }

delete_rule_prio() {
    while ip -4 rule del priority "$1" >/dev/null 2>&1; do :; done
}

# Ensure ip rule at PRIO matches PATTERN; recreates if missing/wrong.
ensure_rule() {
    _prio="$1"; _pattern="$2"; shift 2
    if ! has_rule "${_prio}:.*${_pattern}"; then
        delete_rule_prio "$_prio"
        "$@" || die "failed to add rule prio $_prio: $*"
    fi
}

pin_route() {
    _dst="$1"; _dev="$2"; _src="$3"
    if [ -n "$_src" ]; then
        ip -4 route replace "$_dst" dev "$_dev" src "$_src" 2>/dev/null \
            || ip -4 route replace "$_dst" dev "$_dev" 2>/dev/null || true
    else
        ip -4 route replace "$_dst" dev "$_dev" 2>/dev/null || true
    fi
}

fail_inc() {
    _n=$(cat "$FAIL_COUNTER_FILE" 2>/dev/null || echo 0)
    _n=$((_n + 1)); echo "$_n" > "$FAIL_COUNTER_FILE"; echo "$_n"
}
fail_reset() { echo 0 > "$FAIL_COUNTER_FILE"; }
fail_get()   { cat "$FAIL_COUNTER_FILE" 2>/dev/null || echo 0; }

# ---- failover event journal (RAM ring buffer; backs the LuCI timeline) ------
# Append "ts<TAB>kind<TAB>from<TAB>to<TAB>reason" to a tmpfs file (/var/run — no
# flash wear), trimmed to the last EVENTS_MAX lines. kind ∈ switch | recover |
# restart | killswitch | zapret_fallback | wan_fallback. Read back as JSON by
# `splify-doctor --events`. Best-effort: a failed write never breaks failover.
EVENTS_FILE="/var/run/splify-events"
EVENTS_MAX="200"
journal() {  # kind [from] [to] [reason]
    { printf '%s\t%s\t%s\t%s\t%s\n' \
        "$(date +%s)" "$1" "${2:-}" "${3:-}" "${4:-}" >> "$EVENTS_FILE"; } 2>/dev/null || return 0
    _je="$(tail -n "$EVENTS_MAX" "$EVENTS_FILE" 2>/dev/null)" \
        && printf '%s\n' "$_je" > "$EVENTS_FILE" 2>/dev/null || true
}

# ---- firewall sanity (query helpers) ---------------------------------------
# splify owns ROUTING (marks + table 200) but never touches the firewall — a
# tunnel iface still needs a firewall zone (masq on) and lan->that-zone
# forwarding, or fw4 REJECTs the forwarded LAN->tunnel packets and the tunnel
# looks dead though it's up. These read the firewall config with `uci` directly
# (NOT OpenWrt's config_load, which would clobber the splify config context
# that config_foreach endpoint/device callers rely on).

# Mirror fw4's parse_bool (see OpenWrt fw4.uc): 1/on/true/yes/enabled (any case)
# are true, everything else (0/off/false/no/disabled/unset/garbage) is false.
fw_bool() {
    case "$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')" in
        1|on|true|yes|enabled) return 0 ;;
        *) return 1 ;;
    esac
}

# Is a firewall section one fw4 actually applies to our IPv4 LAN->tunnel path?
# i.e. not disabled (enabled defaults ON when unset) and not ipv6-only (family
# unset/any/both/ipv4). splify routes only IPv4, so an ipv6-only zone/forwarding
# leaves IPv4 traffic rejected and must not count as covering the endpoint. $1 =
# section selector, e.g. "@zone[2]" / "@forwarding[0]".
fw_sec_active() {
    _e="$(uci -q get "firewall.$1.enabled" 2>/dev/null)"
    [ -n "$_e" ] && ! fw_bool "$_e" && return 1
    case "$(uci -q get "firewall.$1.family" 2>/dev/null | tr 'A-Z' 'a-z')" in
        ''|any|both|ipv4|4) return 0 ;;
        *) return 1 ;;
    esac
}

# Echo the firewall zone name covering logical iface $1; non-zero if none. Mirrors
# fw4: a zone matches via its `network` OR `device` list (also resolving the
# network's own L3 device); disabled / ipv6-only zones are ignored. (Glob device
# patterns like `tun+` aren't expanded — at worst a spurious warning, never a
# wrong route, since splify only warns here.)
fw_zone_of_net() {
    _want="$1"
    _wantdev="$(uci -q get "network.$1.device" 2>/dev/null)"   # network's L3 device, if any
    _fz=0
    while [ -n "$(uci -q get "firewall.@zone[$_fz]" 2>/dev/null)" ]; do
        if fw_sec_active "@zone[$_fz]"; then
            for _m in $(uci -q get "firewall.@zone[$_fz].network" 2>/dev/null) \
                      $(uci -q get "firewall.@zone[$_fz].device"  2>/dev/null); do
                if [ "$_m" = "$_want" ] || { [ -n "$_wantdev" ] && [ "$_m" = "$_wantdev" ]; }; then
                    uci -q get "firewall.@zone[$_fz].name"; return 0
                fi
            done
        fi
        _fz=$((_fz + 1))
    done
    return 1
}

# Is masquerading enabled on the (active) zone named $1? masq is an fw4 bool.
fw_zone_has_masq() {
    _fz=0
    while [ -n "$(uci -q get "firewall.@zone[$_fz]" 2>/dev/null)" ]; do
        if [ "$(uci -q get "firewall.@zone[$_fz].name" 2>/dev/null)" = "$1" ] \
           && fw_sec_active "@zone[$_fz]"; then
            fw_bool "$(uci -q get "firewall.@zone[$_fz].masq" 2>/dev/null)"
            return
        fi
        _fz=$((_fz + 1))
    done
    return 1
}

# Is MSS clamping (mtu_fix) enabled on the (active) zone named $1? fw4 bool. Off
# (or unset) stalls large packets on low-MTU wg/PPPoE paths.
fw_zone_has_mtu_fix() {
    _fz=0
    while [ -n "$(uci -q get "firewall.@zone[$_fz]" 2>/dev/null)" ]; do
        if [ "$(uci -q get "firewall.@zone[$_fz].name" 2>/dev/null)" = "$1" ] \
           && fw_sec_active "@zone[$_fz]"; then
            fw_bool "$(uci -q get "firewall.@zone[$_fz].mtu_fix" 2>/dev/null)"
            return
        fi
        _fz=$((_fz + 1))
    done
    return 1
}

# Are zone $1's input/output/forward policies all ACCEPT? The reference tunnel zone
# is accept-all; a REJECT/DROP (or unset -> restrictive fw4 default) input/forward
# blocks router-originated tunnel probes and site-to-site / intra-zone traffic.
fw_zone_policies_open() {  # zone-name
    _fz=0
    while [ -n "$(uci -q get "firewall.@zone[$_fz]" 2>/dev/null)" ]; do
        if [ "$(uci -q get "firewall.@zone[$_fz].name" 2>/dev/null)" = "$1" ]; then
            for _fp in input output forward; do
                [ "$(uci -q get "firewall.@zone[$_fz].$_fp" 2>/dev/null)" = "ACCEPT" ] || return 1
            done
            return 0
        fi
        _fz=$((_fz + 1))
    done
    return 1
}

# Is there an active (enabled, IPv4) firewall forwarding src zone $1 -> dest $2?
fw_has_forwarding() {
    _ff=0
    while [ -n "$(uci -q get "firewall.@forwarding[$_ff]" 2>/dev/null)" ]; do
        if fw_sec_active "@forwarding[$_ff]" \
           && [ "$(uci -q get "firewall.@forwarding[$_ff].src"  2>/dev/null)" = "$1" ] \
           && [ "$(uci -q get "firewall.@forwarding[$_ff].dest" 2>/dev/null)" = "$2" ]; then
            return 0
        fi
        _ff=$((_ff + 1))
    done
    return 1
}

# Firewall zone carrying the LAN — the src side of the lan->tunnel forwarding.
# Tries $LAN_IFACE's network(s), then $LAN_IFACE bound directly (by device), then
# the conventional 'lan'. Empty if it can't be resolved (the caller then skips the
# forwarding check to avoid false warnings).
fw_lan_zone() {
    for _ln in $(uci show network 2>/dev/null \
            | sed -n "s/^network\.\([^.]*\)\.device='\{0,1\}${LAN_IFACE}'\{0,1\}\$/\1/p"); do
        _lz="$(fw_zone_of_net "$_ln")" && { echo "$_lz"; return 0; }
    done
    _lz="$(fw_zone_of_net "$LAN_IFACE")" && { echo "$_lz"; return 0; }
    _lz="$(fw_zone_of_net lan)"          && { echo "$_lz"; return 0; }
    return 1
}

# WAN firewall zone name: the zone covering the 'wan' network, else the
# conventional 'wan'. The dest of the tunnel's egress forwarding.
fw_wan_zone() { fw_zone_of_net wan 2>/dev/null || echo wan; }

# Is zone $1 a SHARED infrastructure zone — the WAN or LAN zone? Echoes the role
# ("WAN"/"LAN") and returns 0 if so. A splify endpoint placed in such a zone
# must NOT get masq / reverse-forwarding fixes: that would open the ENTIRE WAN/LAN
# zone, not just the tunnel. Used by splify-firewall (refuse to touch it) and by
# the doctor (flag it instead of reporting the shared zone's state as healthy).
fw_zone_is_shared() {  # zone-name
    [ -n "$1" ] || return 1
    [ "$1" = "$(fw_wan_zone)" ] && { echo WAN; return 0; }
    [ "$1" = "$(fw_lan_zone)" ] && { echo LAN; return 0; }
    return 1
}

# True iff EVERY network the firewall zone named $1 covers is a WireGuard/AmneziaWG
# tunnel (no plain LAN/guest/etc. member). Gates the reverse zone->LAN forwarding:
# adding it to a zone that ALSO holds non-tunnel networks would grant those
# networks inbound LAN access, not just the tunnel. A zone with a bound `device`
# entry (raw L3 dev or glob we can't map back to a tunnel network) is NOT
# tunnel-only. An unknown zone name returns false.
fw_zone_is_tunnel_only() {  # zone-name
    [ -n "$1" ] || return 1
    _zt=0; _zt_seen=0
    while [ -n "$(uci -q get "firewall.@zone[$_zt]" 2>/dev/null)" ]; do
        if [ "$(uci -q get "firewall.@zone[$_zt].name" 2>/dev/null)" = "$1" ]; then
            _zt_seen=1
            for _ztn in $(uci -q get "firewall.@zone[$_zt].network" 2>/dev/null); do
                iface_is_tunnel "$_ztn" || return 1
            done
            for _ztd in $(uci -q get "firewall.@zone[$_zt].device" 2>/dev/null); do
                # an exact device that IS a tunnel's L3 device qualifies; a glob (or
                # any non-tunnel device) can't be proven tunnel-only -> reject.
                case "$_ztd" in *[*+?]*) return 1 ;; esac
                device_is_tunnel "$_ztd" || return 1
            done
        fi
        _zt=$((_zt + 1))
    done
    [ "$_zt_seen" = 1 ]
}

# If iface $1 is already covered by an existing firewall zone via a DEVICE
# wildcard (e.g. device 'wg+' / 'tun+' / 'wg*'), echo that zone's name and return
# 0. fw_zone_of_net() deliberately does NOT expand globs, so without this an
# auto-create would add a SECOND, overlapping zone for an iface a glob zone
# already covers. Only trailing-wildcard device patterns are recognised.
fw_zone_glob_covering() {  # iface
    [ -n "$1" ] || return 1
    _gdev="$(iface_l3dev "$1")"   # resolve the endpoint's L3 device too (it may differ from the section name)
    _zg=0
    while [ -n "$(uci -q get "firewall.@zone[$_zg]" 2>/dev/null)" ]; do
        if fw_sec_active "@zone[$_zg]"; then
            for _zgd in $(uci -q get "firewall.@zone[$_zg].device" 2>/dev/null); do
                case "$_zgd" in
                    *[*+])
                        _zgp="${_zgd%[*+]}"
                        case "$1"     in "$_zgp"*) uci -q get "firewall.@zone[$_zg].name"; return 0 ;; esac
                        case "$_gdev" in "$_zgp"*) uci -q get "firewall.@zone[$_zg].name"; return 0 ;; esac ;;
                esac
            done
        fi
        _zg=$((_zg + 1))
    done
    return 1
}

# ---- list-updater mutex ----------------------------------------------------
# The daily cron AND the Save&Apply / daemon self-heal both fire the list
# updaters, so two copies can run at once; the loser's redundant download then
# fails curl and spams ERROR into the log. Serialize on a flock. Degrades to a
# plain run if flock isn't installed. Call as `single_run <tag>` near the top of
# an updater (uses fd 9).
#
# Two intents, by SPLIFY_WAIT_LOCK:
#   unset/0 (cron): a concurrent run already refreshes the same list with the same
#                   UCI, so just skip — exit cleanly, no ERROR spam.
#   1 (Save&Apply / self-heal): the new UCI (e.g. a changed list URL) MUST be
#                   applied, so don't drop it — wait out the holder, then run.
single_run() {
    command -v flock >/dev/null 2>&1 || return 0
    exec 9>"/tmp/splify-$1.lock" || return 0
    if [ "${SPLIFY_WAIT_LOCK:-0}" = "1" ]; then
        # busybox flock has no -w; poll -n up to SPLIFY_LOCK_WAIT seconds.
        _sr_n=0
        until flock -n 9; do
            _sr_n=$((_sr_n + 1))
            [ "$_sr_n" -ge "${SPLIFY_LOCK_WAIT:-240}" ] \
                && { log "$1: timed out waiting for lock — not refreshed this run"; exit 1; }
            sleep 1
        done
    else
        flock -n 9 || { log "$1: another run in progress — skipping"; exit 0; }
    fi
}

# `wg show` for either tool — AmneziaWG ifaces answer to `awg`, plain WG to `wg`.
# The wrong tool errors with no output, so concatenating is safe.
wgshow() { awg show "$@" 2>/dev/null; wg show "$@" 2>/dev/null; }

# Live tunnel handshake age in seconds (huge number if never), for one iface.
# FRESHEST peer wins (max timestamp), not the first listed one: on a multi-peer
# iface an extra/dead peer sorted first would report the tunnel as down although
# the peer actually carrying traffic handshook seconds ago.
wg_handshake_age() {
    _hs=$(wgshow "${1:-$VPN_IFACE}" latest-handshakes | awk '$2 > m { m = $2 } END { print m + 0 }')
    [ -n "$_hs" ] && [ "$_hs" -gt 0 ] 2>/dev/null && echo $(( $(date +%s) - _hs )) || echo 999999
}

# ---- iface / zapret predicates (shared by failover, status, doctor) --------
iface_present() { ip link show dev "$1" >/dev/null 2>&1; }

# Health-probe an iface end-to-end. Because endpoints run route_allowed_ips=0,
# they have no main-table route to public targets and a locally-generated ping is
# not policy-routed through table 200 — so `ping -I iface` alone finds no route.
# Install an ISOLATED probe route (default via the iface in PROBE_TABLE, selected
# by the iface's own source IP) for the duration of the ping, touching neither the
# main table, table 200, nor the DoH pins. Works for the active iface and parallel
# candidates alike. Only the failover daemon calls this — it MUTATES routing
# (adds/deletes an ip rule + replaces/flushes PROBE_TABLE), so it must never be
# reachable from a read-only/diagnostic path. splify-doctor is passive and does
# NOT probe; it reads handshake age + daemon state instead.
health_ping() {
    _hpif="$1"; _hpsrc="$(iface_src_ip "$_hpif")"
    [ -n "$_hpsrc" ] || return 1
    ip -4 rule del from "$_hpsrc" table "$PROBE_TABLE" priority "$PROBE_PRIO" 2>/dev/null || true
    ip -4 route replace default dev "$_hpif" table "$PROBE_TABLE" 2>/dev/null || true
    ip -4 rule add from "$_hpsrc" table "$PROBE_TABLE" priority "$PROBE_PRIO" 2>/dev/null || true
    _hpok=1
    for _t in $HEALTH_TARGETS; do
        if ping -c "$HEALTH_PING_COUNT" -W "$HEALTH_PING_TIMEOUT" -I "$_hpif" -q "$_t" >/dev/null 2>&1; then
            _hpok=0; break
        fi
    done
    ip -4 rule del from "$_hpsrc" table "$PROBE_TABLE" priority "$PROBE_PRIO" 2>/dev/null || true
    ip -4 route flush table "$PROBE_TABLE" 2>/dev/null || true
    return "$_hpok"
}
zapret_running()   { (ps w 2>/dev/null || ps 2>/dev/null) | grep -q '[n]fqws'; }
zapret_available() {
    # init script (zapret1 OR zapret2)
    [ -x /etc/init.d/zapret2 ] && return 0
    [ -x /etc/init.d/zapret ]  && return 0
    # binary path (both install layouts)
    [ -x /opt/zapret2/nfq2/nfqws2 ] && return 0
    [ -x /opt/zapret/nfq/nfqws ]    && return 0
    # binary in PATH (nfqws2 for zapret2, nfqws for zapret1)
    command -v nfqws2 >/dev/null 2>&1 && return 0
    command -v nfqws  >/dev/null 2>&1 && return 0
    zapret_running && return 0
    return 1
}
