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

IPSUM_FILE="/etc/splify/ipsum.lst"
IPSUM_NFT_FILE="/etc/splify/ipsum-set.nft"
IPSUM_SET="splify_ipsum_v4"; IPSUM_TABLE="inet fw4"
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

# ---- nft / routing helpers (unchanged) -------------------------------------
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

# Emit a single compact `flush set; add element { a,b,c }` nft command stream for
# set "$1 $2" from a cleaned list on stdin. ONE comma-block (not per-line add) —
# parses in ~10MB vs OOM at 38k+ entries on 240MB routers. Shared by ipsum/ru/noz.
emit_nft_set_block() {
    printf 'flush set %s %s\n' "$1" "$2"
    printf 'add element %s %s {\n' "$1" "$2"
    awk 'NR > 1 { printf "," } { printf "%s", $0 } END { print "" }'
    printf '}\n'
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
