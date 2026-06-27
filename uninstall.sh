#!/bin/sh
# splify — удаление.
#   wget -O - https://raw.githubusercontent.com/xyzmean/splify/main/uninstall.sh | sh
set -eu
[ "$(id -u)" = "0" ] || { echo "запустите от root." >&2; exit 1; }
command -v apk >/dev/null 2>&1 || { echo "apk не найден." >&2; exit 1; }
echo "==> Удаляю splify…"
apk del luci-i18n-splify-ru luci-app-splify splify 2>/dev/null || apk del luci-app-splify splify
echo "Готово. Конфигурация /etc/config/splify сохранена (удалите вручную при желании)."
