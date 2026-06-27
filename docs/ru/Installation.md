# Установка

← [На главную](Home.md)

## Одной командой (рекомендуется)

На роутере с OpenWrt **24.10+ / 25.12+** (менеджер пакетов `apk`), от root:

    wget -O - https://raw.githubusercontent.com/xyzmean/splify/main/install.sh | sh

Установщик сам:

- находит последний релиз splify на GitHub;
- скачивает пакеты `splify`, `luci-app-splify`, `luci-i18n-splify-ru`;
- ставит их (`apk add`), зависимости подтягиваются из фидов OpenWrt;
- поднимает службу и ежедневное обновление списков.

После установки откройте **Сервисы → splify → Главная**.

## Требования

- OpenWrt **24.10+** или **25.12+** с менеджером `apk`.
- Доступ в интернет на роутере (для скачивания пакетов и списков).
- Права root.

## Вручную (из файлов релиза)

Если нужно поставить из заранее скачанных файлов:

    apk add --allow-untrusted ./splify-*.apk ./luci-app-splify-*.apk ./luci-i18n-splify-ru-*.apk

`zapret` опционален — поставьте отдельно, если нужен обход DPI; splify определит
его в рантайме.

## Удаление

    wget -O - https://raw.githubusercontent.com/xyzmean/splify/main/uninstall.sh | sh

Конфигурация `/etc/config/splify` при удалении сохраняется — удалите вручную,
если она больше не нужна.
