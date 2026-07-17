#!/usr/bin/env bats
# Unit tests for splify's pure logic (no router, no uci/nft/ip).
# Run: bats tests/   — or off-box, the doctor selftest: SPLIFY_SELFTEST=1 splify-doctor

load helper

# ---- clean_ip_list: validate/strip/dedup an IPv4-CIDR list ------------------
# Note: this helper feeds nft interval sets and requires CIDR notation — a bare
# host address (no /prefix) is intentionally rejected (the ipsum/ru lists are
# all subnets). Tests pin that contract.
setup_clean() { load_fn "$COMMON_SH" clean_ip_list; }

@test "clean_ip_list keeps valid v4/cidr in order" {
    setup_clean
    out="$(printf '%s\n' '1.2.3.4/32' '10.0.0.0/8' | clean_ip_list)"
    [ "$out" = "$(printf '1.2.3.4/32\n10.0.0.0/8')" ]
}

@test "clean_ip_list strips comments, CR, whitespace and dedups" {
    setup_clean
    out="$(printf '%s\r\n' '  1.1.1.1/32  # dns' '1.1.1.1/32' '' 'not.an.ip' '256.1.1.1/24' '8.8.8.8/33' | clean_ip_list)"
    [ "$out" = "1.1.1.1/32" ]
}

@test "clean_ip_list rejects bare hosts, out-of-range octets and bad prefixes" {
    setup_clean
    out="$(printf '%s\n' '1.1.1.1' '300.0.0.1/24' '1.2.3.4/40' '1.2.3' 'abc' | clean_ip_list)"
    [ -z "$out" ]
}

# ---- fw_bool: mirror fw4's parse_bool --------------------------------------
@test "fw_bool true values" {
    load_fn "$COMMON_SH" fw_bool
    for v in 1 on true yes enabled ON True YES Enabled; do
        run fw_bool "$v"; [ "$status" -eq 0 ] || { echo "expected true for '$v'"; return 1; }
    done
}

@test "fw_bool false / unset / garbage values" {
    load_fn "$COMMON_SH" fw_bool
    for v in 0 off false no disabled "" maybe 2; do
        run fw_bool "$v"; [ "$status" -ne 0 ] || { echo "expected false for '$v'"; return 1; }
    done
}

# ---- json_esc: escape backslash + double-quote ------------------------------
@test "json_esc escapes backslash and quote" {
    load_fn "$DOCTOR_SH" json_esc
    [ "$(json_esc 'a"b\c')" = 'a\"b\\c' ]
    [ "$(json_esc 'plain')" = 'plain' ]
}

# ---- _rank: severity ordering OK<WARN<FIXABLE<FAIL --------------------------
@test "_rank orders severities" {
    load_fn "$DOCTOR_SH" _rank
    [ "$(_rank OK)" -eq 0 ]
    [ "$(_rank WARN)" -gt "$(_rank OK)" ]
    [ "$(_rank FIXABLE)" -gt "$(_rank WARN)" ]
    [ "$(_rank FAIL)" -gt "$(_rank FIXABLE)" ]
    [ "$(_rank bogus)" -eq 0 ]
}

# ---- endpoint parsing: priority sort + type default (design §2.2) -----------
# Stub OpenWrt's config layer with a fixture, then run the REAL endpoint helpers.
load_endpoint_helpers() {
    load_fn "$COMMON_SH" _collect_endpoint
    load_fn "$COMMON_SH" endpoints_by_priority
    load_fn "$COMMON_SH" top_endpoint
    load_fn "$COMMON_SH" _ep_type_emit
    load_fn "$COMMON_SH" ep_type
    load_fn "$COMMON_SH" is_endpoint
}

# Stub OpenWrt's config layer: config_foreach forwards extra args to the callback
# (as the real one does: `config_foreach cb type extra…` -> `cb section extra…`);
# config_get returns the fixture value or the default when unset/empty.
config_foreach() { local cb="$1"; shift 2; for s in $SECTIONS; do "$cb" "$s" "$@"; done; }
config_get() { eval "$1=\"\${cfg_${2}_${3}:-$4}\""; }

@test "endpoints_by_priority orders best (lowest number) first, skips ifaceless" {
    load_endpoint_helpers
    SECTIONS="a b c d"
    cfg_a_iface=wg2 cfg_a_priority=2
    cfg_b_iface=wg1 cfg_b_priority=1
    cfg_c_iface=wg9 cfg_c_priority=9
    cfg_d_iface=""  cfg_d_priority=5     # no iface -> dropped
    run endpoints_by_priority
    [ "$status" -eq 0 ]
    [ "$output" = "wg1 wg2 wg9 " ] || { echo "got: [$output]"; return 1; }
}

@test "top_endpoint is the lowest priority number" {
    load_endpoint_helpers
    SECTIONS="a b"
    cfg_a_iface=awg0 cfg_a_priority=3
    cfg_b_iface=wg0  cfg_b_priority=1
    [ "$(top_endpoint)" = "wg0" ]
}

@test "ep_type defaults to wg and honors explicit type" {
    load_endpoint_helpers
    SECTIONS="a b"
    cfg_a_iface=wg0  cfg_a_priority=1            # no type -> wg
    cfg_b_iface=sb0  cfg_b_priority=2 cfg_b_type=singbox
    [ "$(ep_type wg0)" = "wg" ]
    [ "$(ep_type sb0)" = "singbox" ]
}

# Security gate for privileged firewall fixes: only configured endpoints pass,
# so the ubus action can never target a foreign iface like `wan`.
@test "is_endpoint accepts configured ifaces and rejects foreign ones" {
    load_endpoint_helpers
    SECTIONS="a b"
    cfg_a_iface=wg0  cfg_a_priority=1
    cfg_b_iface=awg0 cfg_b_priority=2
    run is_endpoint wg0;  [ "$status" -eq 0 ]
    run is_endpoint awg0; [ "$status" -eq 0 ]
    run is_endpoint wan;  [ "$status" -ne 0 ]
    run is_endpoint "";   [ "$status" -ne 0 ]
    run is_endpoint wg;   [ "$status" -ne 0 ]   # substring must not match
}

# Second privileged-firewall gate: even a name in splify UCI must be a REAL
# wireguard/amneziawg interface, so a write-ACL caller can't add `guest` as an
# endpoint and fw_fix its zone.
@test "iface_is_wg accepts wireguard/amneziawg proto, rejects others" {
    load_fn "$COMMON_SH" iface_is_wg
    # stub `uci -q get network.<iface>.proto` (args: -q get network.X.proto)
    uci() {
        case "$3" in
            network.wg0.proto)  echo wireguard ;;
            network.awg0.proto) echo amneziawg ;;
            network.wan.proto)  echo dhcp ;;
            *) echo "" ;;
        esac
    }
    run iface_is_wg wg0;   [ "$status" -eq 0 ]
    run iface_is_wg awg0;  [ "$status" -eq 0 ]
    run iface_is_wg wan;   [ "$status" -ne 0 ]
    run iface_is_wg guest; [ "$status" -ne 0 ]
}

# Shared-zone guard: a tunnel sharing the WAN/LAN zone must be refused by fix and
# flagged by the doctor (not silently reported healthy).
@test "fw_zone_is_shared flags WAN/LAN zones, passes a dedicated tunnel zone" {
    load_fn "$COMMON_SH" fw_zone_is_shared
    fw_wan_zone() { echo wan; }
    fw_lan_zone() { echo lan; }
    run fw_zone_is_shared wan;  [ "$status" -eq 0 ]; [ "$output" = WAN ]
    run fw_zone_is_shared lan;  [ "$status" -eq 0 ]; [ "$output" = LAN ]
    run fw_zone_is_shared wg0;  [ "$status" -ne 0 ]
    run fw_zone_is_shared "";   [ "$status" -ne 0 ]
}

# A zone is tunnel-only iff every member is a wg/awg tunnel — by network name OR by
# an exact wg L3 device. A non-tunnel network or a device glob disqualifies it.
@test "fw_zone_is_tunnel_only: network names, exact wg device, rejects mixed/glob" {
    load_fn "$COMMON_SH" iface_is_wg
    load_fn "$COMMON_SH" iface_l3dev
    load_fn "$COMMON_SH" device_is_wg
    load_fn "$COMMON_SH" singbox_section_of
    load_fn "$COMMON_SH" _singbox_section_emit
    load_fn "$COMMON_SH" singbox_l3dev
    load_fn "$COMMON_SH" iface_is_singbox
    load_fn "$COMMON_SH" iface_is_tunnel
    load_fn "$COMMON_SH" device_is_singbox
    load_fn "$COMMON_SH" device_is_tunnel
    load_fn "$COMMON_SH" fw_zone_is_tunnel_only
    # No `config singbox` sections in this fixture -> config_foreach/config_get
    # are no-ops (singbox_section_of never matches), so iface_is_tunnel /
    # device_is_tunnel degrade to plain iface_is_wg / device_is_wg here.
    config_foreach() { :; }
    config_get() { eval "$1="; }
    # NB: bracket patterns are single-quoted so case treats '[0]' literally, not as
    # a glob character class. `uci show network` lists the interface sections.
    uci() {
        if [ "$1" = show ] && [ "$2" = network ]; then
            printf 'network.wg0=interface\nnetwork.awg0=interface\nnetwork.guest=interface\n'; return
        fi
        if [ "$1" = -q ] && [ "$2" = show ] && [ "$3" = splify ]; then
            return
        fi
        case "$3" in
            'firewall.@zone[0]') echo x ;;
            'firewall.@zone[0].name') echo vpn ;;
            'firewall.@zone[0].network') echo "wg0 awg0" ;;
            'firewall.@zone[1]') echo x ;;
            'firewall.@zone[1].name') echo mixed ;;
            'firewall.@zone[1].network') echo "wg0 guest" ;;
            'firewall.@zone[2]') echo x ;;
            'firewall.@zone[2].name') echo devx ;;
            'firewall.@zone[2].device') echo wg0 ;;
            'firewall.@zone[3]') echo x ;;
            'firewall.@zone[3].name') echo devg ;;
            'firewall.@zone[3].device') echo 'wg+' ;;
            network.wg0.proto) echo wireguard ;;
            network.awg0.proto) echo amneziawg ;;
            network.guest.proto) echo static ;;
            *) echo "" ;;
        esac
    }
    run fw_zone_is_tunnel_only vpn;   [ "$status" -eq 0 ]   # all-wg by network name
    run fw_zone_is_tunnel_only mixed; [ "$status" -ne 0 ]   # non-tunnel member
    run fw_zone_is_tunnel_only devx;  [ "$status" -eq 0 ]   # exact wg device qualifies
    run fw_zone_is_tunnel_only devg;  [ "$status" -ne 0 ]   # device glob, unprovable
    run fw_zone_is_tunnel_only none;  [ "$status" -ne 0 ]   # unknown zone
}

# Auto-create must refuse an iface already covered by a device-wildcard zone — by
# its own name OR its resolved L3 device — or fw4 would see overlapping zones.
@test "fw_zone_glob_covering matches by iface name and resolved device" {
    load_fn "$COMMON_SH" fw_bool
    load_fn "$COMMON_SH" fw_sec_active
    load_fn "$COMMON_SH" iface_l3dev
    load_fn "$COMMON_SH" fw_zone_glob_covering
    # endpoint 'vpn' resolves to L3 device wg0; zone 'vpnzone' covers 'wg+'.
    uci() {
        case "$3" in
            'firewall.@zone[0]') echo x ;;
            'firewall.@zone[0].name') echo vpnzone ;;
            'firewall.@zone[0].device') echo 'wg+' ;;
            'firewall.@zone[1]') echo x ;;
            'firewall.@zone[1].name') echo lan ;;
            'firewall.@zone[1].device') echo 'eth0' ;;
            network.vpn.device) echo wg0 ;;
            *) echo "" ;;
        esac
    }
    run fw_zone_glob_covering wg0;  [ "$status" -eq 0 ]; [ "$output" = vpnzone ]  # name matches glob
    run fw_zone_glob_covering vpn;  [ "$status" -eq 0 ]; [ "$output" = vpnzone ]  # device wg0 matches glob
    run fw_zone_glob_covering tun0; [ "$status" -ne 0 ]   # nothing covers it
    run fw_zone_glob_covering eth0; [ "$status" -ne 0 ]   # exact device, not a glob
}

# ---- wg_handshake_age: freshest peer wins -----------------------------------
# A multi-peer iface must report liveness from the peer that handshook most
# recently, not from whichever peer `wg show` lists first.
@test "wg_handshake_age picks the freshest peer" {
    load_fn "$COMMON_SH" wg_handshake_age
    date()   { echo 1000; }
    wgshow() { printf 'pkA\t400\npkB\t900\npkC\t0\n'; }
    [ "$(wg_handshake_age wg0)" = "100" ]
}

@test "wg_handshake_age: never handshaken / no output -> 999999" {
    load_fn "$COMMON_SH" wg_handshake_age
    date()   { echo 1000; }
    wgshow() { printf 'pkA\t0\n'; }
    [ "$(wg_handshake_age wg0)" = "999999" ]
    wgshow() { :; }
    [ "$(wg_handshake_age wg0)" = "999999" ]
}

# ---- probe_candidate: degraded-path healing ----------------------------------
# The regression this pins: after a degrade nothing was ever re-setup — `ifup`
# on an up-but-wedged tunnel is a netifd no-op, so a recovered WG server (or a
# DDNS endpoint move) was never picked up until a manual ifdown/ifup. A
# present-but-unhealthy candidate must now get a full re-setup (ep_restart).
setup_probe() {
    load_fn "$FAILOVER_SH" probe_candidate
    CALLS=""
    log()            { :; }
    bring_up()       { CALLS="$CALLS bring_up"; }
    ep_restart()     { CALLS="$CALLS ep_restart"; }
    wait_handshake() { CALLS="$CALLS wait_handshake"; }
}

@test "probe_candidate: present+healthy -> ok, no bounce" {
    setup_probe
    ep_present()    { return 0; }
    iface_healthy() { return 0; }
    probe_candidate wg0
    [ -z "$CALLS" ] || { echo "unexpected calls:$CALLS"; return 1; }
}

@test "probe_candidate: absent -> plain parallel bring_up, no restart" {
    setup_probe
    ep_present()    { return 1; }
    iface_healthy() { return 0; }
    probe_candidate wg0
    [ "$CALLS" = " bring_up" ] || { echo "calls:$CALLS"; return 1; }
}

@test "probe_candidate: present but unhealthy -> full re-setup heals it" {
    setup_probe
    ep_present() { return 0; }
    HP_N=0
    iface_healthy() { HP_N=$((HP_N + 1)); [ "$HP_N" -ge 2 ]; }   # sick, then healed
    probe_candidate wg0
    [ "$CALLS" = " ep_restart wait_handshake" ] || { echo "calls:$CALLS"; return 1; }
}

@test "probe_candidate: re-setup did not help -> reports unhealthy" {
    setup_probe
    ep_present()    { return 0; }
    iface_healthy() { return 1; }
    run probe_candidate wg0
    [ "$status" -ne 0 ]
}

# The simple Главная toggle relies on two allow-listed actions, on/off. The rpcd
# plugin is now a thin wrapper that funnels `action` into splify-ctl's cmd_action,
# so the on)/off) branches live there (mirrored by the inbound REST API + agent).
@test "action handler covers on/off" {
    run grep -nE '^[[:space:]]*(on|off)\)' splify/files/usr/local/sbin/splify-ctl
    [ "$status" -eq 0 ]
}

# ---- sing-box URI parser: uri_unescape / uri_qparam -------------------------
setup_uri_helpers() {
    load_fn "$COMMON_SH" uri_unescape
    load_fn "$COMMON_SH" uri_qparam
}

@test "uri_unescape decodes %40 to @ and + to space" {
    setup_uri_helpers
    [ "$(printf '%%40' | uri_unescape)" = "@" ]
    [ "$(printf 'a+b' | uri_unescape)" = "a b" ]
    [ "$(printf 'foo%%2Fbar' | uri_unescape)" = "foo/bar" ]
}

@test "uri_qparam extracts a decoded value, empty when the param is absent" {
    setup_uri_helpers
    [ "$(uri_qparam 'a=1&b=hello%40world' b)" = "hello@world" ]
    [ "$(uri_qparam 'a=1&b=2' c)" = "" ]
}

# ---- sing-box URI parser: singbox_parse_vless / singbox_parse_hysteria2 ----
setup_singbox_parser() {
    load_fn "$COMMON_SH" uri_unescape
    load_fn "$COMMON_SH" uri_qparam
    load_fn "$COMMON_SH" _singbox_reject
    load_fn "$COMMON_SH" singbox_parse_vless
    load_fn "$COMMON_SH" singbox_parse_hysteria2
    load_fn "$COMMON_SH" singbox_parse_uri
    warn() { :; }   # silence stderr noise from rejected-URI tests
}

@test "singbox_parse_vless emits every field from a full-featured URI" {
    setup_singbox_parser
    uri='vless://a1b2c3d4-1234-5678-9abc-def012345678@example.com:443?flow=xtls-rprx-vision&security=reality&sni=www.example.com&pbk=abc123PBK&sid=abcd&type=tcp&host=example.com&path=%2Fws&serviceName=grpcsvc&fp=chrome&alpn=h2#My%20Node'
    run singbox_parse_vless "$uri"
    [ "$status" -eq 0 ]
    for line in \
        'protocol=vless' 'server=example.com' 'port=443' \
        'uuid=a1b2c3d4-1234-5678-9abc-def012345678' 'name=My Node' \
        'flow=xtls-rprx-vision' 'security=reality' 'sni=www.example.com' \
        'pbk=abc123PBK' 'sid=abcd' 'network=tcp' 'host=example.com' \
        'path=/ws' 'svc=grpcsvc'
    do
        case "$output" in *"$line"*) : ;; *) echo "missing line: $line"; return 1 ;; esac
    done
    # ignored params never emitted
    case "$output" in *fp=*|*alpn=*|*encryption=*) echo "leaked ignored param: $output"; return 1 ;; esac
}

@test "singbox_parse_vless defaults security=none and network=tcp when absent" {
    setup_singbox_parser
    run singbox_parse_vless 'vless://uuid-1234@example.com:443'
    [ "$status" -eq 0 ]
    case "$output" in *'security=none'*) : ;; *) echo "$output"; return 1 ;; esac
    case "$output" in *'network=tcp'*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "singbox_parse_hysteria2 emits every field from a full-featured URI" {
    setup_singbox_parser
    uri='hysteria2://mypassword@host.example.com:443/?insecure=1&sni=sni.example.com&obfs=salamander&obfs-password=secretpw#Remote%201'
    run singbox_parse_hysteria2 "$uri"
    [ "$status" -eq 0 ]
    for line in \
        'protocol=hysteria2' 'server=host.example.com' 'port=443' \
        'password=mypassword' 'name=Remote 1' 'sni=sni.example.com' \
        'insecure=1' 'obfs=salamander' 'obfspw=secretpw'
    do
        case "$output" in *"$line"*) : ;; *) echo "missing line: $line"; return 1 ;; esac
    done
}

@test "singbox_parse_hysteria2 accepts the without-slash form and hy2:// alias, defaults insecure=0" {
    setup_singbox_parser
    run singbox_parse_hysteria2 'hysteria2://pw@host.example.com:443?sni=x.com'
    [ "$status" -eq 0 ]
    case "$output" in *'insecure=0'*) : ;; *) echo "$output"; return 1 ;; esac
    run singbox_parse_uri 'hy2://pw@host.example.com:443'
    [ "$status" -eq 0 ]
    case "$output" in *'protocol=hysteria2'*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "singbox_parse_hysteria2 keeps a comma port-hop suffix verbatim" {
    setup_singbox_parser
    run singbox_parse_hysteria2 'hysteria2://pw@host.example.com:443,5000-6000/?sni=x.com'
    [ "$status" -eq 0 ]
    case "$output" in *'port=443,5000-6000'*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "singbox_parse_hysteria2 url-decodes a percent-encoded password" {
    setup_singbox_parser
    # p%40ss -> p@ss: the userinfo is percent-encoded like query params/fragment
    # are — a reserved character in the password must not reach sing-box raw.
    run singbox_parse_hysteria2 'hysteria2://p%40ss@host.example.com:443'
    [ "$status" -eq 0 ]
    case "$output" in *'password=p@ss'*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "singbox_parse_uri rejects an unrecognized scheme with empty stdout" {
    setup_singbox_parser
    run singbox_parse_uri 'ss://foo@bar.example.com:1'
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "singbox_parse_uri rejects a missing host with empty stdout" {
    setup_singbox_parser
    run singbox_parse_uri 'vless://uuid-1234@:443'
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    run singbox_parse_uri 'hysteria2://pw@:443'
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "singbox_parse_uri rejects a missing vless uuid with empty stdout" {
    setup_singbox_parser
    run singbox_parse_uri 'vless://@example.com:443'
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "singbox_parse_uri rejects a bracketed IPv6 host literal with empty stdout" {
    setup_singbox_parser
    run singbox_parse_uri 'vless://uuid-1234@[::1]:443'
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    run singbox_parse_uri 'hysteria2://pw@[::1]:443'
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

# ---- ep_present / ep_egress_dev: real singbox dispatch (not the stub) ------
# Stub iface_present/singbox_l3dev the same way probe_candidate's tests stub
# collaborators, so this exercises the real case-branch wiring in ep_type's
# dispatch, not a re-implementation of it.
setup_ep_singbox() {
    load_endpoint_helpers
    load_fn "$COMMON_SH" ep_present
    load_fn "$COMMON_SH" ep_egress_dev
    SECTIONS="a b"
    cfg_a_iface=wg0 cfg_a_priority=1
    cfg_b_iface=sb0 cfg_b_priority=2 cfg_b_type=singbox
}

@test "ep_present/ep_egress_dev use the real singbox_l3dev branch for a singbox endpoint" {
    setup_ep_singbox
    singbox_l3dev()  { [ "$1" = sb0 ] && echo tun-sb0; }
    iface_present()  { [ "$1" = tun-sb0 ]; }
    run ep_present sb0;     [ "$status" -eq 0 ]
    run ep_egress_dev sb0;  [ "$status" -eq 0 ]; [ "$output" = "tun-sb0" ]
}

@test "ep_present reports down when the singbox l3dev is absent" {
    setup_ep_singbox
    singbox_l3dev() { echo tun-sb0; }
    iface_present() { return 1; }
    run ep_present sb0
    [ "$status" -ne 0 ]
}

@test "ep_present/ep_egress_dev still use plain iface logic for a wg endpoint" {
    setup_ep_singbox
    iface_present() { [ "$1" = wg0 ]; }
    run ep_present wg0;    [ "$status" -eq 0 ]
    run ep_egress_dev wg0; [ "$output" = "wg0" ]
}

# ---- iface_is_singbox / iface_is_tunnel / device_is_tunnel ------------------
# Mirrors the existing iface_is_wg UCI-stubbing style: stub `uci` directly.
@test "iface_is_singbox / iface_is_tunnel / device_is_tunnel across wg and singbox" {
    load_fn "$COMMON_SH" iface_is_wg
    load_fn "$COMMON_SH" iface_l3dev
    load_fn "$COMMON_SH" device_is_wg
    load_fn "$COMMON_SH" singbox_section_of
    load_fn "$COMMON_SH" _singbox_section_emit
    load_fn "$COMMON_SH" singbox_l3dev
    load_fn "$COMMON_SH" iface_is_singbox
    load_fn "$COMMON_SH" iface_is_tunnel
    load_fn "$COMMON_SH" device_is_singbox
    load_fn "$COMMON_SH" device_is_tunnel
    config_foreach() { local cb="$1"; shift 2; for s in $SECTIONS; do "$cb" "$s" "$@"; done; }
    config_get() { eval "$1=\"\${cfg_${2}_${3}:-$4}\""; }
    SECTIONS="sb0"
    cfg_sb0_iface=sb0 cfg_sb0_l3dev=tun-sb0
    uci() {
        if [ "$1" = show ] && [ "$2" = network ]; then
            printf 'network.wg0=interface\n'; return
        fi
        if [ "$1" = -q ] && [ "$2" = show ] && [ "$3" = splify ]; then
            printf 'splify.sb0=singbox\n'; return
        fi
        case "$3" in
            network.wg0.proto) echo wireguard ;;
            *) echo "" ;;
        esac
    }
    run iface_is_singbox sb0;  [ "$status" -eq 0 ]
    run iface_is_singbox wg0;  [ "$status" -ne 0 ]
    run iface_is_tunnel sb0;   [ "$status" -eq 0 ]
    run iface_is_tunnel wg0;   [ "$status" -eq 0 ]
    run iface_is_tunnel wan;   [ "$status" -ne 0 ]
    run device_is_tunnel tun-sb0; [ "$status" -eq 0 ]
    run device_is_tunnel wg0;     [ "$status" -eq 0 ]
    run device_is_tunnel eth0;    [ "$status" -ne 0 ]
}

# ---- fw_zone_is_tunnel_only: sing-box device= member also qualifies --------
@test "fw_zone_is_tunnel_only recognises a sing-box device= zone member" {
    load_fn "$COMMON_SH" iface_is_wg
    load_fn "$COMMON_SH" iface_l3dev
    load_fn "$COMMON_SH" device_is_wg
    load_fn "$COMMON_SH" singbox_section_of
    load_fn "$COMMON_SH" _singbox_section_emit
    load_fn "$COMMON_SH" singbox_l3dev
    load_fn "$COMMON_SH" iface_is_singbox
    load_fn "$COMMON_SH" iface_is_tunnel
    load_fn "$COMMON_SH" device_is_singbox
    load_fn "$COMMON_SH" device_is_tunnel
    load_fn "$COMMON_SH" fw_zone_is_tunnel_only
    config_foreach() { local cb="$1"; shift 2; for s in $SECTIONS; do "$cb" "$s" "$@"; done; }
    config_get() { eval "$1=\"\${cfg_${2}_${3}:-$4}\""; }
    SECTIONS="sb0"
    cfg_sb0_iface=sb0 cfg_sb0_l3dev=tun-sb0
    uci() {
        if [ "$1" = show ] && [ "$2" = network ]; then
            printf 'network.wg0=interface\n'; return
        fi
        if [ "$1" = -q ] && [ "$2" = show ] && [ "$3" = splify ]; then
            printf 'splify.sb0=singbox\n'; return
        fi
        case "$3" in
            'firewall.@zone[0]') echo x ;;
            'firewall.@zone[0].name') echo vpn ;;
            'firewall.@zone[0].device') echo tun-sb0 ;;
            network.wg0.proto) echo wireguard ;;
            *) echo "" ;;
        esac
    }
    run fw_zone_is_tunnel_only vpn;  [ "$status" -eq 0 ]
}

# ---- faceit_url_for: provider name -> fetch descriptor ----------------------
# Pure function (reads $FACEIT_PROVIDERS, prints "kind<TAB>url" per known
# provider). Defined at the top of splify-update-faceit BEFORE any nft/uci/curl
# call specifically so it can be tested off-box via extract_fn, mirroring
# nozapret_current's placement in splify-sync-nozapret.
setup_faceit() {
    load_fn "$UPDATE_FACEIT_SH" faceit_url_for
    # silence the log()/die() the sourced body might reach if test mis-uses it
    log() { :; }
}

@test "faceit_url_for: each known provider yields a kind+url line" {
    setup_faceit
    FACEIT_PROVIDERS='ovh'
    out="$(faceit_url_for)"
    [ "$out" = "$(printf 'cidr\thttps://cdn.jsdelivr.net/gh/rezmoss/cloud-provider-ip-addresses@main/ovhcloud/ovhcloud_ips_v4.txt')" ] || { echo "got:[$out]"; return 1; }

    FACEIT_PROVIDERS='hetzner'
    out="$(faceit_url_for)"
    case "$out" in *hetzner/hetzner_ips_v4.txt*) : ;; *) echo "bad hetzner url:[$out]"; return 1 ;; esac

    FACEIT_PROVIDERS='gcp'
    out="$(faceit_url_for)"
    case "$out" in *googlecloud/googlecloud_ips_v4.txt*) : ;; *) echo "bad gcp url:[$out]"; return 1 ;; esac

    # i3d is the only CSV source (geofeed) — kind must be 'csv' so the fetcher
    # strips the first comma-column instead of feeding raw CSV to clean_ip_list.
    FACEIT_PROVIDERS='i3d'
    out="$(faceit_url_for)"
    [ "$out" = "$(printf 'csv\thttps://geofeed.i3d.net/i3d_geofeed.csv')" ] || { echo "got:[$out]"; return 1; }
}

@test "faceit_url_for: multiple providers -> one line each, in order" {
    setup_faceit
    FACEIT_PROVIDERS='ovh gcp'
    out="$(faceit_url_for)"
    n=$(printf '%s\n' "$out" | wc -l)
    [ "$n" = "2" ] || { echo "expected 2 lines, got $n:[$out]"; return 1; }
    # order follows FACEIT_PROVIDERS
    first="$(printf '%s\n' "$out" | head -1)"
    case "$first" in *ovhcloud*) : ;; *) echo "first line not ovh:[$first]"; return 1 ;; esac
    second="$(printf '%s\n' "$out" | tail -1)"
    case "$second" in *googlecloud*) : ;; *) echo "second line not gcp:[$second]"; return 1 ;; esac
}

@test "faceit_url_for: unknown tokens silently skipped" {
    setup_faceit
    # a typo in faceit_providers must never break the refresh — unknown names
    # produce no line, known ones still resolve.
    FACEIT_PROVIDERS='ovh bogusname hetzner'
    out="$(faceit_url_for)"
    n=$(printf '%s\n' "$out" | wc -l)
    [ "$n" = "2" ] || { echo "expected 2 lines (typo dropped), got $n:[$out]"; return 1; }
}

@test "faceit_url_for: empty providers list yields nothing" {
    setup_faceit
    FACEIT_PROVIDERS=''
    out="$(faceit_url_for)"
    [ -z "$out" ] || { echo "expected empty, got:[$out]"; return 1; }
}
