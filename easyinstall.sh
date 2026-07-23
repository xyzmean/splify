#!/bin/sh
# splify one-line easy installer with auto-configured WARP tunnel.
#
# Does everything install.sh does (splify + luci-app-splify + i18n + AmneziaWG
# kernel module/tools), AND on top:
#   - registers a Cloudflare WARP device (anonymous, registration flow from
#     nellimonix/warp-config-generator-vercel). Registration goes through a CF
#     Worker proxy (WORKER_URL) because api.cloudflareclient.com is blocked by
#     some ISPs while *.workers.dev is not — see contrib/warp-api-proxy.worker.js.
#   - brings up a single `warp0` interface as AmneziaWG (proto amneziawg) with
#     the WARP endpoint + the AWG obfuscation knobs baked in. The obfuscation
#     (Jc/Jmin/Jmax/H1–H4/I1/S1/S2) is what pierces DPI blocking on the UDP
#     tunnel — a plain WireGuard handshake gets dropped, an AWG one passes.
#   - registers warp0 as the first splify endpoint and enables routing.
#
# After it finishes you have a working obfuscated WARP tunnel + splify routing,
# no manual tunnel creation needed. Re-runnable: skips steps already done.
#
# Worker proxy: registration needs a CF Worker that reverse-proxies
# api.cloudflareclient.com (the API is blocked on some ISPs). Deploy the Worker
# from contrib/warp-api-proxy.worker.js (1 min on dash.cloudflare.com) and pass
# its URL either way:
#   WORKER_URL="https://warp-api-proxy.<acct>.workers.dev" sh easyinstall.sh
#   wget -O - …/easyinstall.sh | WORKER_URL="https://…" sh
# Without WORKER_URL the script tries api.cloudflareclient.com directly and
# falls back gracefully if that is blocked.
#
#   wget -O - https://raw.githubusercontent.com/xyzmean/splify/main/easyinstall.sh | sh
set -eu

REPO="xyzmean/splify"
API="https://api.github.com/repos/$REPO/releases/latest"
# Cloudflare WARP registration API — version + UA/headers match the wgcf tool
# (github.com/ViRb3/wgcf): path v0a1922, User-Agent okhttp/3.12.1 and the
# CF-Client-Version header. Cloudflare keys its rate-limit policy partly on
# these, so they must be sent verbatim.
CF_API_VERSION="v0a1922"
CF_DIRECT="https://api.cloudflareclient.com"
CF_UA="okhttp/3.12.1"
CF_CLIENT_VER="a-6.3-1922"
# Reverse proxy to api.cloudflareclient.com — bypasses ISP blocking of the
# registration API. Use the Vercel variant (contrib/warp-api-proxy-vercel): a
# CF Worker on *.workers.dev hits Cloudflare error 1015 (rate-limit on shared
# egress IP), while Vercel's AWS egress does not. Empty = try direct.
# The proxy prefixes /v0a1922 itself, so WORKER_URL requests use short paths.
# Default points at the project's public Vercel deploy (xyzmean/wgcli); override
# with your own WORKER_URL env to use a private proxy.
WORKER_URL="${WORKER_URL:-https://wgcli.vercel.app}"
# WARP UDP endpoint for the tunnel itself. AWG obfuscation on the handshake is
# what makes it reachable where plain WireGuard is DPI-blocked. 162.159.195.1 is
# a stable anycast WARP ingress; :500 is a widely-open port.
WARP_EP="engage.cloudflareclient.com:4500"
WARP_IFACE="warp0"
TMP="$(mktemp -d /tmp/splify.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# AWG obfuscation profile for the WARP tunnel (AmneziaWG "awg15"-style). These
# are the transport knobs the warp0 interface carries alongside the WG keys.
AWG_JC=4
AWG_JMIN=40
AWG_JMAX=70
AWG_H1=1
AWG_H2=2
AWG_H3=3
AWG_H4=4
AWG_S1=0
AWG_S2=0
# I1 is the QUIC initial-packet mask. It is intentionally long; store it in a
# file to avoid quoting hell, then read into UCI.
AWG_I1="<b 0xce000000010897a297ecc34cd6dd000044d0ec2e2e1ea2991f467ace4222129b5a098823784694b4897b9986ae0b7280135fa85e196d9ad980b150122129ce2a9379531b0fd3e871ca5fdb883c369832f730e272d7b8b74f393f9f0fa43f11e510ecb2219a52984410c204cf875585340c62238e14ad04dff382f2c200e0ee22fe743b9c6b8b043121c5710ec289f471c91ee414fca8b8be8419ae8ce7ffc53837f6ade262891895f3f4cecd31bc93ac5599e18e4f01b472362b8056c3172b513051f8322d1062997ef4a383b01706598d08d48c221d30e74c7ce000cdad36b706b1bf9b0607c32ec4b3203a4ee21ab64df336212b9758280803fcab14933b0e7ee1e04a7becce3e2633f4852585c567894a5f9efe9706a151b615856647e8b7dba69ab357b3982f554549bef9256111b2d67afde0b496f16962d4957ff654232aa9e845b61463908309cfd9de0a6abf5f425f577d7e5f6440652aa8da5f73588e82e9470f3b21b27b28c649506ae1a7f5f15b876f56abc4615f49911549b9bb39dd804fde182bd2dcec0c33bad9b138ca07d4a4a1650a2c2686acea05727e2a78962a840ae428f55627516e73c83dd8893b02358e81b524b4d99fda6df52b3a8d7a5291326e7ac9d773c5b43b8444554ef5aea104a738ed650aa979674bbed38da58ac29d87c29d387d80b526065baeb073ce65f075ccb56e47533aef357dceaa8293a523c5f6f790be90e4731123d3c6152a70576e90b4ab5bc5ead01576c68ab633ff7d36dcde2a0b2c68897e1acfc4d6483aaaeb635dd63c96b2b6a7a2bfe042f6aed82e5363aa850aace12ee3b1a93f30d8ab9537df483152a5527faca21efc9981b304f11fc95336f5b9637b174c5a0659e2b22e159a9fed4b8e93047371175b1d6d9cc8ab745f3b2281537d1c75fb9451871864efa5d184c38c185fd203de206751b92620f7c369e031d2041e152040920ac2c5ab5340bfc9d0561176abf10a147287ea90758575ac6a9f5ac9f390d0d5b23ee12af583383d994e22c0cf42383834bcd3ada1b3825a0664d8f3fb678261d57601ddf94a8a68a7c273a18c08aa99c7ad8c6c42eab67718843597ec9930457359dfdfbce024afc2dcf9348579a57d8d3490b2fa99f278f1c37d87dad9b221acd575192ffae1784f8e60ec7cee4068b6b988f0433d96d6a1b1865f4e155e9fe020279f434f3bf1bd117b717b92f6cd1cc9bea7d45978bcc3f24bda631a36910110a6ec06da35f8966c9279d130347594f13e9e07514fa370754d1424c0a1545c5070ef9fb2acd14233e8a50bfc5978b5bdf8bc1714731f798d21e2004117c61f2989dd44f0cf027b27d4019e81ed4b5c31db347c4a3a4d85048d7093cf16753d7b0d15e078f5c7a5205dc2f87e330a1f716738dce1c6180e9d02869b5546f1c4d2748f8c90d9693cba4e0079297d22fd61402dea32ff0eb69ebd65a5d0b687d87e3a8b2c42b648aa723c7c7daf37abcc4bb85caea2ee8f55bec20e913b3324ab8f5c3304f820d42ad1b9f2ffc1a3af9927136b4419e1e579ab4c2ae3c776d293d397d575df181e6cae0a4ada5d67ecea171cca3288d57c7bbdaee3befe745fb7d634f70386d873b90c4d6c6596bb65af68f9e5121e67ebf0d89d3c909ceedfb32ce9575a7758ff080724e1ab5d5f43074ecb53a479af21ed03d7b6899c36631c0166f9d47e5e1d4528a5d3d3f744029c4b1c190cbfbad06f5f83f7ad0429fa9a2719c56ffe3783460e166de2d8>"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mВнимание:\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31mОшибка:\033[0m %s\n' "$*" >&2; exit 1; }

# ──────────────────────────── 1. environment checks ────────────────────────
[ "$(id -u)" = "0" ] || err "запустите от root."
command -v apk   >/dev/null 2>&1 || err "нужен OpenWrt 24.10+/25.12+ с менеджером apk."
command -v wget  >/dev/null 2>&1 || err "не найден wget."
# curl + jq are needed for WARP registration; install them if missing (they are
# not part of a minimal OpenWrt image, but apk pulls them quickly).
for _dep in curl jq; do
  if ! command -v "$_dep" >/dev/null 2>&1; then
    say "Ставлю зависимость: $_dep…"
    apk add "$_dep" >/dev/null 2>&1 || err "не удалось установить $_dep (apk add $_dep)."
  fi
done

# ──────────────────────────── 2. install splify packages ───────────────────
install_splify() {
  if command -v splify-ctl >/dev/null 2>&1 || [ -x /usr/local/sbin/splify-ctl ]; then
    say "splify уже установлен."
    return 0
  fi
  say "Ищу последний релиз splify…"
  META="$TMP/meta.json"
  wget -qO "$META" "$API" || err "не удалось получить данные релиза (нет интернета?)."
  # GitHub may serve JSON as one line; split on commas so each asset URL is on
  # its own line, otherwise a greedy sed grabs only the last URL.
  URLS="$(tr ',' '\n' <"$META" | sed -n 's/.*"browser_download_url": *"\([^"]*\.apk\)".*/\1/p')"
  [ -n "$URLS" ] || err "в последнем релизе нет .apk. Возможно, релиз ещё не собран."

  say "Скачиваю пакеты…"
  for u in $URLS; do
    case "$u" in
      *splify*) wget -qO "$TMP/${u##*/}" "$u" || err "не удалось скачать $u" ;;
    esac
  done
  for pkg in splify- luci-app-splify- luci-i18n-splify-ru-; do
    ls "$TMP/$pkg"*.apk >/dev/null 2>&1 || err "в релизе не хватает пакета $pkg*.apk"
  done

  say "Устанавливаю splify…"
  apk add --allow-untrusted "$TMP"/*.apk || err "apk add не выполнился."

  rm -f /tmp/luci-indexcache* /tmp/luci-modulecache* 2>/dev/null || true
  /etc/init.d/rpcd reload 2>/dev/null || /etc/init.d/rpcd restart 2>/dev/null || true
  for s in splify splify-agent; do
    if [ -x "/etc/init.d/$s" ] && "/etc/init.d/$s" enabled 2>/dev/null; then
      "/etc/init.d/$s" restart 2>/dev/null || true
    fi
  done
}

# ──────────────────────────── 3. install AmneziaWG ──────────────────────────
install_awg() {
  if apk info -e kmod-amneziawg >/dev/null 2>&1; then
    say "AmneziaWG (kmod) уже установлен."
  else
    say "AmneziaWG не найден — устанавливаю поддержку…"
    if wget -qO "$TMP/awg-install.sh" \
        "https://raw.githubusercontent.com/Slava-Shchipunov/awg-openwrt/refs/heads/master/amneziawg-install.sh"; then
      sh "$TMP/awg-install.sh" -n -e \
        || warn "AmneziaWG: установка не удалась — WARP-туннель не поднимется без kmod."
    else
      err "Не удалось скачать установщик AmneziaWG (нет WARP без него)."
    fi
  fi
  # Load the kernel module NOW. awg-install.sh installs the kmod package but
  # never calls modprobe, and OpenWrt's /etc/init.d/kmod only loads modules at
  # boot — so on a fresh install the module is on disk but not in the kernel,
  # `ifup warp0` silently fails (no handshake → looks dead → the firewall-zone
  # step "hangs"), and the operator must reboot. modprobe pulls amneziawg + all
  # its deps into the running kernel right away; it's a no-op if already loaded,
  # so this also covers a pre-installed-but-unloaded kmod. Verified on OpenWrt
  # 25.12 (kmod-amneziawg 6.12.87): handshakes pass in the same session, no reboot.
  if ! lsmod 2>/dev/null | grep -q '^amneziawg '; then
    modprobe amneziawg 2>/dev/null \
      || insmod "/lib/modules/$(uname -r)/amneziawg.ko" 2>/dev/null \
      || warn "amneziawg: не удалось загрузить kmod — может потребоваться перезагрузка."
  fi
  # `awg` binary comes from amneziawg-tools (pulled by the installer above).
  command -v awg >/dev/null 2>&1 || command -v wg >/dev/null 2>&1 \
    || err "не найден awg/wg — невозможно сгенерировать ключи WARP."
}

# ──────────────────────────── 4. register Cloudflare WARP ───────────────────
# Registration flow mirrors wgcf (github.com/ViRb3/wgcf): POST /v0a1922/reg with
# okhttp/3.12.1 UA + CF-Client-Version header. Registration goes through a
# reverse proxy (WORKER_URL) when set — direct api.cloudflareclient.com is
# blocked on some ISPs, and a CF Worker on *.workers.dev hits error 1015
# (rate-limit on shared egress), so the Vercel proxy is the working path.
# wgcf does NOT send a PATCH warp_enabled — the Register response already
# carries config.peers[0].public_key and the interface addresses. Sets
# WARP_PEER/WARP_V4/WARP_V6 in the caller's scope.
#
# Registration URL: proxy short-path (/api/reg via Vercel catch-all, which
# prepends /v0a1922) or direct full-path with the version baked in.
reg_url() {
  if [ -n "$WORKER_URL" ]; then
    # Vercel catch-all: /api/<path> → upstream /v0a1922/<path>
    printf '%s/api/%s' "${WORKER_URL%/}" "$1"
  else
    printf '%s/%s/%s' "$CF_DIRECT" "$CF_API_VERSION" "$1"
  fi
}

register_warp() {
  say "Регистрирую устройство Cloudflare WARP…"
  [ -n "$WORKER_URL" ] \
    && say "Через прокси: $WORKER_URL" \
    || warn "WORKER_URL не задан — пробую api.cloudflareclient.com напрямую (может быть заблокирован)."

  # X25519 keypair — `awg genkey`/`wg genkey` produce the exact base64 format
  # the WARP API expects (same curve as wgcf/tweetnacl).
  if command -v awg >/dev/null 2>&1; then GEN=awg; else GEN=wg; fi
  PRIV="$("$GEN" genkey)"
  PUB="$(printf '%s\n' "$PRIV" | "$GEN" pubkey)"
  TOS="$(date -u +%Y-%m-%dT%H:%M:%S.000000000Z)"

  # Register the device (wgcf format). UA + CF-Client-Version are required.
  REG="$TMP/reg.json"
  curl -fsSL --max-time 30 -X POST "$(reg_url reg)" \
    -H "User-Agent: $CF_UA" \
    -H "CF-Client-Version: $CF_CLIENT_VER" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "{\"key\":\"$PUB\",\"install_id\":\"\",\"fcm_token\":\"\",\"model\":\"PC\",\"locale\":\"en_US\",\"tos\":\"$TOS\",\"type\":\"Android\"}" \
    -o "$REG" \
    || err "регистрация WARP не удалась. Если API заблокирован вашим провайдером — задайте WORKER_URL (см. contrib/warp-api-proxy-vercel)."

  REG_ID="$(jq -r '.id'    "$REG")"
  REG_TOK="$(jq -r '.token' "$REG")"
  [ -n "$REG_ID" ] && [ "$REG_ID" != "null" ] || err "WARP: нет id в ответе."
  [ -n "$REG_TOK" ] && [ "$REG_TOK" != "null" ] || err "WARP: нет token в ответе."

  # The Register response already carries config.* in v0a1922 (wgcf format) —
  # peer pubkey, interface addresses and endpoint are all there. Re-fetch the
  # full device record via GET /reg/{id} only as a fallback if the POST response
  # somehow lacked config.* (older API versions); authenticated with the token.
  WARP="$TMP/warp.json"
  if ! jq -e '.config.peers[0].public_key' "$REG" >/dev/null 2>&1; then
    if ! curl -fsSL --max-time 30 -X GET "$(reg_url "reg/$REG_ID")" \
          -H "User-Agent: $CF_UA" \
          -H "CF-Client-Version: $CF_CLIENT_VER" \
          -H "Accept: application/json" \
          -H "Authorization: Bearer $REG_TOK" \
          -o "$WARP" 2>/dev/null; then
      cp "$REG" "$WARP"
    fi
  else
    cp "$REG" "$WARP"
  fi

  WARP_PEER="$(jq -r '.config.peers[0].public_key'               "$WARP")"
  WARP_V4="$(jq -r '.config.interface.addresses.v4'               "$WARP")"
  WARP_V6="$(jq -r '.config.interface.addresses.v6 // ""'         "$WARP")"
  [ -n "$WARP_PEER" ] && [ "$WARP_PEER" != "null" ] || err "WARP: нет peer public_key в ответе."
  [ -n "$WARP_V4" ]   && [ "$WARP_V4"   != "null" ] || err "WARP: нет client IPv4 в ответе."

  # WARP addresses come WITHOUT a prefix length (e.g. "172.16.0.2") — WireGuard
  # needs CIDR. Append /32 for IPv4 and /128 for IPv6 if none is present.
  case "$WARP_V4" in
    */*) : ;;
    *)   WARP_V4="$WARP_V4/32" ;;
  esac
  if [ -n "$WARP_V6" ]; then
    case "$WARP_V6" in
      */*) : ;;
      *)   WARP_V6="$WARP_V6/128" ;;
    esac
  fi

  say "WARP зарегистрирован: $WARP_V4${WARP_V6:+, $WARP_V6}"
}

# ──────────────────────────── 5. create warp0 interface ─────────────────────
# Writes the WARP tunnel into UCI as an AmneziaWG interface, with the AWG
# obfuscation knobs. Peer section naming follows splify-ctl's wg-import format:
# amneziawg_<iface>. awg_* options are lowercase (as the parser emits them).
create_warp_iface() {
  if [ -n "$(uci -q get "network.$WARP_IFACE")" ]; then
    say "Интерфейс $WARP_IFACE уже существует — перенастраиваю."
    ifdown "$WARP_IFACE" >/dev/null 2>&1 || true
  fi

  say "Создаю интерфейс $WARP_IFACE (AmneziaWG + WARP)…"
  uci -q set "network.$WARP_IFACE=interface"
  uci set "network.$WARP_IFACE.proto=amneziawg"
  uci set "network.$WARP_IFACE.private_key=$PRIV"
  uci -q delete "network.$WARP_IFACE.addresses" || true
  uci add_list "network.$WARP_IFACE.addresses=$WARP_V4"
  [ -n "$WARP_V6" ] && uci add_list "network.$WARP_IFACE.addresses=$WARP_V6"
  uci -q delete "network.$WARP_IFACE.dns" || true
  uci add_list "network.$WARP_IFACE.dns=1.1.1.1"
  uci set "network.$WARP_IFACE.mtu=1280"
  # splify owns routing (marks + table 200); never let netifd pull AllowedIPs
  # into the main table — matches the wg-import default.
  uci set "network.$WARP_IFACE.route_allowed_ips=0"

  # ── AWG obfuscation knobs (lowercase option names, as splify-ctl emits) ──
  uci set "network.$WARP_IFACE.awg_jc=$AWG_JC"
  uci set "network.$WARP_IFACE.awg_jmin=$AWG_JMIN"
  uci set "network.$WARP_IFACE.awg_jmax=$AWG_JMAX"
  uci set "network.$WARP_IFACE.awg_h1=$AWG_H1"
  uci set "network.$WARP_IFACE.awg_h2=$AWG_H2"
  uci set "network.$WARP_IFACE.awg_h3=$AWG_H3"
  uci set "network.$WARP_IFACE.awg_h4=$AWG_H4"
  uci set "network.$WARP_IFACE.awg_s1=$AWG_S1"
  uci set "network.$WARP_IFACE.awg_s2=$AWG_S2"
  uci set "network.$WARP_IFACE.awg_i1=$AWG_I1"

  # ── peer (the WARP server) — single section, replace any prior ──
  _pt="amneziawg_$WARP_IFACE"
  while [ -n "$(uci -q get "network.@${_pt}[0]")" ]; do uci -q delete "network.@${_pt}[0]" || true; done
  uci add network "$_pt" >/dev/null
  uci set "network.@${_pt}[-1].public_key=$WARP_PEER"
  uci -q delete "network.@${_pt}[-1].allowed_ips" || true
  uci add_list "network.@${_pt}[-1].allowed_ips=0.0.0.0/0"
  uci add_list "network.@${_pt}[-1].allowed_ips=::/0"
  uci set "network.@${_pt}[-1].endpoint_host=${WARP_EP%:*}"
  uci set "network.@${_pt}[-1].endpoint_port=${WARP_EP##*:}"
  uci set "network.@${_pt}[-1].persistent_keepalive=25"

  uci commit network
  /etc/init.d/network restart
  
  ifup "$WARP_IFACE" >/dev/null 2>&1 || warn "ifup $WARP_IFACE не удался — проверьте в LuCI."
}

# ──────────────────────────── 6. register endpoint in splify ────────────────
register_in_splify() {
  # Drop phantom endpoints: any endpoint section whose iface does NOT exist in
  # /etc/config/network. The package's default config used to ship a live
  # `config endpoint iface wg0` example, so a fresh install paired it with the
  # warp0 this script adds — two endpoints in the list, but wg0 has no real
  # interface (failover keeps probing a device that never comes up). Re-running
  # this also cleans up already-broken installs. Iterate with a manual counter
  # because deleting @endpoint[i] shifts the rest down (don't advance i on delete).
  _ei=0
  while [ -n "$(uci -q get "splify.@endpoint[$_ei]" 2>/dev/null)" ]; do
    _ei_if="$(uci -q get "splify.@endpoint[$_ei].iface" 2>/dev/null)"
    if [ -n "$_ei_if" ] && [ -z "$(uci -q get "network.$_ei_if" 2>/dev/null)" ]; then
      say "Удаляю фантомный endpoint $_ei_if (нет такого интерфейса в network)."
      uci -q delete "splify.@endpoint[$_ei]" || true
    else
      _ei=$((_ei + 1))
    fi
  done
  uci commit splify

  # Add a `config endpoint` section pointing at warp0, if none exists yet.
  if grep -q "option iface '$WARP_IFACE'" /etc/config/splify 2>/dev/null; then
    say "endpoint $WARP_IFACE уже зарегистрирован в splify."
  else
    say "Регистрирую $WARP_IFACE как endpoint splify (приоритет 1)…"
    # Append via a heredoc to /etc/config/splify — a fresh endpoint section
    # (the package's default example is commented out now, so warp0 is the only one).
    cat >>/etc/config/splify <<EOF

config endpoint
	option iface '$WARP_IFACE'
	option priority '1'
	option type 'wg'
EOF
  fi
  # Apply the routing rules now so traffic flows through warp0 immediately.
  if command -v splify-apply >/dev/null 2>&1; then
    splify-apply >/dev/null 2>&1 || warn "splify-apply завершился с ошибкой — см. Сервисы → splify."
  fi
  # Make sure the splify service is enabled+running.
  [ -x /etc/init.d/splify ] && { /etc/init.d/splify enabled 2>/dev/null || /etc/init.d/splify enable; }
  /etc/init.d/splify restart 2>/dev/null || true
}

# ──────────────────────────── 7. firewall zone ──────────────────────────────
# splify owns routing (marks + table 200) but NOT the firewall — yet fw4 still
# runs every LAN->tunnel packet through the firewall and REJECTs it unless the
# tunnel iface is in a zone (with masq + lan<->zone + zone->wan forwarding).
# Without this the tunnel "looks dead". splify-firewall fix creates that zone
# idempotently, modelling it on a known-good AmneziaWG zone (accept + masq +
# mtu_fix). It refuses to touch shared WAN/LAN zones, so it's safe.
setup_firewall() {
  if [ ! -x /usr/local/sbin/splify-firewall ]; then
    warn "splify-firewall не найден — создайте зону для $WARP_IFACE вручную (masq + lan→зона)."
    return 0
  fi
  say "Создаю firewall-зону для $WARP_IFACE…"
  if /usr/local/sbin/splify-firewall check "$WARP_IFACE" >/dev/null 2>&1; then
    say "Firewall-зона для $WARP_IFACE уже настроена."
  else
    /usr/local/sbin/splify-firewall fix "$WARP_IFACE" \
      || warn "splify-firewall fix не удался — проверьте зону для $WARP_IFACE в Сеть → Firewall."
  fi
}

# ──────────────────────────── main ──────────────────────────────────────────
install_splify
sleep 3
install_awg
sleep 3
register_warp
sleep 3
create_warp_iface
sleep 3
register_in_splify
sleep 3
setup_firewall
sleep 3
/etc/init.d/splify restart; /etc/init.d/splify-agent restart
sleep 5
say "Готово! Настроен обфусцированный WARP-туннель $WARP_IFACE + splify routing."
printf '  • Туннель:   %s (AmneziaWG + WARP, endpoint %s)\n' "$WARP_IFACE" "$WARP_EP"
printf '  • Адрес:     %s%s\n' "$WARP_V4" "${WARP_V6:+, $WARP_V6}"
printf '  • Endpoint:  Сервисы → splify → Главная (нажмите «Включить», если ещё не включён)\n'
printf '  • Тюнинг:    Сервисы → splify → Дополнительно (режим, kill switch, списки)\n'
