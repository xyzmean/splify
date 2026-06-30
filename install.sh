#!/bin/sh
# splify installer — качает последний релиз и ставит пакеты.
# Использование на роутере OpenWrt:
#   wget -O - https://raw.githubusercontent.com/xyzmean/splify/main/install.sh | sh
set -eu

REPO="xyzmean/splify"
API="https://api.github.com/repos/$REPO/releases/latest"
TMP="$(mktemp -d /tmp/splify.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31mОшибка:\033[0m %s\n' "$*" >&2; exit 1; }

# 1) проверки окружения
[ "$(id -u)" = "0" ] || err "запустите от root."
command -v apk  >/dev/null 2>&1 || err "нужен OpenWrt 24.10+/25.12+ с менеджером apk."
command -v wget >/dev/null 2>&1 || err "не найден wget."

# 2) узнать ссылки на .apk из последнего релиза
say "Ищу последний релиз splify…"
META="$TMP/meta.json"
wget -qO "$META" "$API" || err "не удалось получить данные релиза (нет интернета?)."
URLS="$(sed -n 's/.*"browser_download_url": *"\([^"]*\.apk\)".*/\1/p' "$META")"
[ -n "$URLS" ] || err "в последнем релизе нет .apk. Возможно, релиз ещё не собран."

# 3) скачать пакеты
say "Скачиваю пакеты…"
for u in $URLS; do
  case "$u" in
    # Force the output name with -O (not -P): GitHub redirects release assets to
    # objects.githubusercontent.com/...?X-Amz-… and busybox wget would otherwise
    # save the file under that query-laden name, so `ls *.apk` finds nothing.
    *splify*) wget -qO "$TMP/${u##*/}" "$u" || err "не удалось скачать $u" ;;
  esac
done
ls "$TMP"/*.apk >/dev/null 2>&1 || err "пакеты не скачались."

# 4) установить (зависимости подтянутся из фидов)
say "Устанавливаю…"
apk add --allow-untrusted "$TMP"/*.apk || err "apk add не выполнился."

say "Готово! Дальше:"
printf '  1. Создайте VPN-туннель: Сеть → Интерфейсы (WireGuard/AmneziaWG).\n'
printf '  2. Откройте Сервисы → splify → Главная и нажмите «Включить».\n'
