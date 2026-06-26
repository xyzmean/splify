#!/usr/bin/env bats
# Unit tests for wg-split's pure logic (no router, no uci/nft/ip).
# Run: bats tests/   — or off-box, the doctor selftest: WG_SPLIT_SELFTEST=1 wg-split-doctor

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

# Second privileged-firewall gate: even a name in wg-split UCI must be a REAL
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
    load_fn "$COMMON_SH" fw_zone_is_tunnel_only
    # NB: bracket patterns are single-quoted so case treats '[0]' literally, not as
    # a glob character class. `uci show network` lists the interface sections.
    uci() {
        if [ "$1" = show ] && [ "$2" = network ]; then
            printf 'network.wg0=interface\nnetwork.awg0=interface\nnetwork.guest=interface\n'; return
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
