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
# GitHub prettifies JSON only for curl; for wget the answer is ONE line, and a
# greedy line-wise sed would then capture only the LAST asset URL. Split on
# commas first so each URL lands on its own line regardless of formatting.
URLS="$(tr ',' '\n' <"$META" | sed -n 's/.*"browser_download_url": *"\([^"]*\.apk\)".*/\1/p')"
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
# Релиз состоит из трёх пакетов — убедимся, что скачались все, иначе ставится
# только демон без веб-интерфейса и перевода.
for pkg in splify- luci-app-splify- luci-i18n-splify-ru-; do
  ls "$TMP/$pkg"*.apk >/dev/null 2>&1 || err "в релизе не хватает пакета $pkg*.apk"
done

# 4) установить (зависимости подтянутся из фидов)
say "Устанавливаю…"
apk add --allow-untrusted "$TMP"/*.apk || err "apk add не выполнился."

# 5) чтобы меню и страницы splify появились сразу, без ручного рестарта
rm -f /tmp/luci-indexcache* /tmp/luci-modulecache* 2>/dev/null || true
/etc/init.d/rpcd reload 2>/dev/null || /etc/init.d/rpcd restart 2>/dev/null || true

# 6) перезапустить работающие демоны: при обновлении пакета старые процессы
# (splify-failover, splify-agent) продолжают крутить КОД ПРЕЖНЕЙ версии до
# ребута — новые скрипты на диске сами по себе ничего не меняют.
for s in splify splify-agent; do
  if [ -x "/etc/init.d/$s" ] && "/etc/init.d/$s" enabled 2>/dev/null; then
    "/etc/init.d/$s" restart 2>/dev/null || true
  fi
done

# 7) AmneziaWG — без него splify не сможет поднять WG/AWG-туннели. Внешний
# установщик awg-openwrt ставит kmod-amneziawg + amneziawg-tools + LuCI.
# Запускаем ТИХО: -n (не создавать авто-интерфейс awg1 — splify сам ведёт
# туннели через Сеть → Интерфейсы) и -e (пропустить интерактивный запрос про
# ru-локализацию, который повис бы на `wget … | sh`, где stdin — не терминал).
# Сбои не фатальны: splify работает и без AWG (просто туннели не поднимутся).
if apk info -e kmod-amneziawg >/dev/null 2>&1; then
  say "AmneziaWG уже установлен."
else
  say "AmneziaWG не найден — устанавливаю поддержку…"
  if wget -qO "$TMP/awg-install.sh" \
      "https://raw.githubusercontent.com/Slava-Shchipunov/awg-openwrt/refs/heads/master/amneziawg-install.sh"; then
    sh "$TMP/awg-install.sh" -n -e \
      || say "AmneziaWG: установка не удалась (не критично, splify работает)."
    # Русская локализация для LuCI-страниц AmneziaWG ставится отдельно: она
    # есть не во всех версиях OpenWrt, поэтому мягко — отсутствие пакета
    # не должно рвать установку.
    say "AmneziaWG: русская локализация…"
    apk add luci-i18n-amneziawg-ru >/dev/null 2>&1 \
      || say "luci-i18n-amneziawg-ru недоступен для этой версии OpenWrt — пропускаю."
  else
    say "Не удалось скачать установщик AmneziaWG — пропускаю."
  fi
fi

say "Готово! Дальше:"
printf '  1. Создайте VPN-туннель: Сеть → Интерфейсы (WireGuard/AmneziaWG).\n'
printf '  2. Откройте Сервисы → splify → Главная и нажмите «Включить».\n'
printf '     (поддержка AmneziaWG с русским переводом установлена автоматически)\n'
