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
WORKER_URL="${WORKER_URL:-}"
# WARP UDP endpoint for the tunnel itself. AWG obfuscation on the handshake is
# what makes it reachable where plain WireGuard is DPI-blocked. 162.159.195.1 is
# a stable anycast WARP ingress; :500 is a widely-open port.
WARP_EP="162.159.195.1:500"
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
cat >"$TMP/i1" <<'AWG_I1_EOF'
0xc10000000114367096bb0fb3f58f3a3fb8aaacd61d63a1c8a40e14f7374b8a62dccba6431716c3abf6f5afbcfb39bd008000047c32e268567c652e6f4db58bff759bc8c5aaca183b87cb4d22938fe7d8dca22a679a79e4d9ee62e4bbb3a380dd78d4e8e48f26b38a1d42d76b371a5a9a0444827a69d1ab5872a85749f65a4104e931740b4dc1e2dd77733fc7fac4f93011cd622f2bb47e85f71992e2d585f8dc765a7a12ddeb879746a267393ad023d267c4bd79f258703e27345155268bd3cc0506ebd72e2e3c6b5b0f005299cd94b67ddabe30389c4f9b5c2d512dcc298c14f14e9b7f931e1dc397926c31fbb7cebfc668349c218672501031ecce151d4cb03c4c660b6c6fe7754e75446cd7de09a8c81030c5f6fb377203f551864f3d83e27de7b86499736cbbb549b2f37f436db1cae0a4ea39930f0534aacdd1e3534bc87877e2afabe959ced261f228d6362e6fd277c88c312d966c8b9f67e4a92e757773db0b0862fb8108d1d8fa262a40a1b4171961f0704c8ba314da2482ac8ed9bd28d4b50f7432d89fd800c25a50c5e2f5c0710544fef5273401116aa0572366d8e49ad758fcb29e6a92912e644dbe227c247cb3417eabfab2db16796b2fba420de3b1dc94e8361f1f324a331ddaf1e626553138860757fd0bf687566108b77b70fb9f8f8962eca599c4a70ed373666961a8cb506b96756d9e28b94122b20f16b54f118c0e603ce0b831efea614ad836df6cf9affbdd09596412547496967da758cec9080295d853b0861670b71d9abde0d562b1a6de82782a5b0c14d297f27283a895abc889a5f6703f0e6eb95f67b2da45f150d0d8ab805612d570c2d5cb6997ac3a7756226c2f5c8982ffbd480c5004b0660a3c9468945efde90864019a2b519458724b55d766e16b0da25c0557c01f3c11ddeb024b62e303640e17fdd57dedb3aeb4a2c1b7c93059f9c1d7118d77caac1cd0f6556e46cbc991c1bb16970273dea833d01e5090d061a0c6d25af2415cd2878af97f6d0e7f1f936247b394ecb9bd484da6be936dee9b0b92dc90101a1b4295e97a9772f2263eb09431995aa173df4ca2abd687d87706f0f93eaa5e13cbe3b574fa3cfe94502ace25265778da6960d561381769c24e0cbd7aac73c16f95ae74ff7ec38124f7c722b9cb151d4b6841343f29be8f35145e1b27021056820fed77003df8554b4155716c8cf6049ef5e318481460a8ce3be7c7bfac695255be84dc491c19e9dedc449dd3471728cd2a3ee51324ccb3eef121e3e08f8e18f0006ea8957371d9f2f739f0b89e4db11e5c6430ada61572e589519fbad4498b460ce6e4407fc2d8f2dd4293a50a0cb8fcaaf35cd9a8cc097e3603fbfa08d9036f52b3e7fcce11b83ad28a4ac12dba0395a0cc871cefd1a2856fffb3f28d82ce35cf80579974778bab13d9b3578d8c75a2d196087a2cd439aff2bb33f2db24ac175fff4ed91d36a4cdbfaf3f83074f03894ea40f17034629890da3efdbb41141b38368ab532209b69f057ddc559c19bc8ae62bf3fd564c9a35d9a83d14a95834a92bae6d9a29ae5e8ece07910d16433e4c6230c9bd7d68b47de0de9843988af6dc88b5301820443bd4d0537778bf6b4c1dd067fcf14b81015f2a67c7f2a28f9cb7e0684d3cb4b1c24d9b343122a086611b489532f1c3a26779da1706c6759d96d8ab
AWG_I1_EOF

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
      apk add luci-i18n-amneziawg-ru >/dev/null 2>&1 \
        || warn "luci-i18n-amneziawg-ru недоступен — пропускаю."
    else
      err "Не удалось скачать установщик AmneziaWG (нет WARP без него)."
    fi
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

  REG_ID="$(jq -r '.result.id'    "$REG")"
  REG_TOK="$(jq -r '.result.token' "$REG")"
  [ -n "$REG_ID" ] && [ "$REG_ID" != "null" ] || err "WARP: нет result.id в ответе."
  [ -n "$REG_TOK" ] && [ "$REG_TOK" != "null" ] || err "WARP: нет result.token в ответе."

  # The Register response already carries the peer pubkey + addresses. wgcf does
  # not send a separate PATCH warp_enabled. Re-fetch the full device record via
  # GET /reg/{id} to be sure we have config.* (some API versions omit it from
  # the POST response) — authenticated with the registration token.
  WARP="$TMP/warp.json"
  if ! curl -fsSL --max-time 30 -X GET "$(reg_url "reg/$REG_ID")" \
        -H "User-Agent: $CF_UA" \
        -H "CF-Client-Version: $CF_CLIENT_VER" \
        -H "Accept: application/json" \
        -H "Authorization: Bearer $REG_TOK" \
        -o "$WARP" 2>/dev/null; then
    # GET failed — fall back to whatever the POST returned (it may have config).
    cp "$REG" "$WARP"
  fi

  WARP_PEER="$(jq -r '.result.config.peers[0].public_key'        "$WARP")"
  WARP_V4="$(jq -r '.result.config.interface.addresses.v4'        "$WARP")"
  WARP_V6="$(jq -r '.result.config.interface.addresses.v6 // ""'  "$WARP")"
  [ -n "$WARP_PEER" ] && [ "$WARP_PEER" != "null" ] || err "WARP: нет peer public_key в ответе."
  [ -n "$WARP_V4" ]   && [ "$WARP_V4"   != "null" ] || err "WARP: нет client IPv4 в ответе."

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
  uci set "network.$WARP_IFACE.proto='amneziawg'"
  uci set "network.$WARP_IFACE.private_key='$PRIV'"
  uci -q delete "network.$WARP_IFACE.addresses"
  uci add_list "network.$WARP_IFACE.addresses='$WARP_V4'"
  [ -n "$WARP_V6" ] && uci add_list "network.$WARP_IFACE.addresses='$WARP_V6'"
  uci -q delete "network.$WARP_IFACE.dns"
  uci add_list "network.$WARP_IFACE.dns='1.1.1.1'"
  uci set "network.$WARP_IFACE.mtu='1280'"
  # splify owns routing (marks + table 200); never let netifd pull AllowedIPs
  # into the main table — matches the wg-import default.
  uci set "network.$WARP_IFACE.route_allowed_ips='0'"

  # ── AWG obfuscation knobs (lowercase option names, as splify-ctl emits) ──
  uci set "network.$WARP_IFACE.awg_jc='$AWG_JC'"
  uci set "network.$WARP_IFACE.awg_jmin='$AWG_JMIN'"
  uci set "network.$WARP_IFACE.awg_jmax='$AWG_JMAX'"
  uci set "network.$WARP_IFACE.awg_h1='$AWG_H1'"
  uci set "network.$WARP_IFACE.awg_h2='$AWG_H2'"
  uci set "network.$WARP_IFACE.awg_h3='$AWG_H3'"
  uci set "network.$WARP_IFACE.awg_h4='$AWG_H4'"
  uci set "network.$WARP_IFACE.awg_s1='$AWG_S1'"
  uci set "network.$WARP_IFACE.awg_s2='$AWG_S2'"
  # I1 is huge — read from the staging file, not a heredoc-in-uci.
  uci set "network.$WARP_IFACE.awg_i1='$(cat "$TMP/i1")'"

  # ── peer (the WARP server) — single section, replace any prior ──
  _pt="amneziawg_$WARP_IFACE"
  while [ -n "$(uci -q get "network.@${_pt}[0]")" ]; do uci -q delete "network.@${_pt}[0]"; done
  uci add network "$_pt" >/dev/null
  uci set "network.@${_pt}[-1].public_key='$WARP_PEER'"
  uci -q delete "network.@${_pt}[-1].allowed_ips"
  uci add_list "network.@${_pt}[-1].allowed_ips='0.0.0.0/0'"
  uci add_list "network.@${_pt}[-1].allowed_ips='::/0'"
  uci set "network.@${_pt}[-1].endpoint_host='${WARP_EP%:*}'"
  uci set "network.@${_pt}[-1].endpoint_port='${WARP_EP##*:}'"
  uci set "network.@${_pt}[-1].persistent_keepalive='25'"

  uci commit network
  ifup "$WARP_IFACE" >/dev/null 2>&1 || warn "ifup $WARP_IFACE не удался — проверьте в LuCI."
}

# ──────────────────────────── 6. register endpoint in splify ────────────────
register_in_splify() {
  # Add a `config endpoint` section pointing at warp0, if none exists yet.
  if grep -q "option iface '$WARP_IFACE'" /etc/config/splify 2>/dev/null; then
    say "endpoint $WARP_IFACE уже зарегистрирован в splify."
  else
    say "Регистрирую $WARP_IFACE как endpoint splify (приоритет 1)…"
    # Append via a heredoc to /etc/config/splify — same shape as the default wg0.
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

# ──────────────────────────── main ──────────────────────────────────────────
install_splify
install_awg
register_warp
create_warp_iface
register_in_splify

say "Готово! Настроен обфусцированный WARP-туннель $WARP_IFACE + splify routing."
printf '  • Туннель:   %s (AmneziaWG + WARP, endpoint %s)\n' "$WARP_IFACE" "$WARP_EP"
printf '  • Адрес:     %s%s\n' "$WARP_V4" "${WARP_V6:+, $WARP_V6}"
printf '  • Endpoint:  Сервисы → splify → Главная (нажмите «Включить», если ещё не включён)\n'
printf '  • Тюнинг:    Сервисы → splify → Дополнительно (режим, kill switch, списки)\n'
