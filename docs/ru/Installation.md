# Установка

← [Назад на главную](Home.md)

Требуется **OpenWrt 24.10+ / 25.12+ (менеджер пакетов apk)**.

## 1. Получить пакеты

Собираются два (плюс языковой) пакета:

- `wg-split` — ядро (скрипты, служба, nftables/dnsmasq-слой);
- `luci-app-wg-split` — страница настроек LuCI;
- `luci-i18n-wg-split-ru` — русский перевод интерфейса (опционально).

Способы получить `.apk`:

### Релизы GitHub
Готовые `.apk` прикладываются к каждому релизу (workflow `release.yml` /
`auto-version.yml`). Скачайте все три файла.

### Сборка в CI
Открыть **Actions → Build packages → Run workflow**. Артефакт `packages` будет
содержать `wg-split-*.apk`, `luci-app-wg-split-*.apk` и
`luci-i18n-wg-split-*.apk`.

### Локальная сборка через Docker (OpenWrt SDK)
```sh
docker build -f Dockerfile-apk --build-arg VERSION=1.7.2 -t wg-split:local .
id=$(docker create wg-split:local)
docker cp "$id:/builder/bin/packages/." ./out/
docker rm "$id"
find ./out -name '*wg-split*.apk'
```
Тяжёлый слой зависимостей (ядро + nftables/curl/dnsmasq/ip-full/luci-base)
кэшируется один раз; пересборка наших пакетов занимает секунды.

## 2. Установить на роутер

Скопируйте `.apk` на роутер и установите:

```sh
apk add ./wg-split-*.apk ./luci-app-wg-split-*.apk ./luci-i18n-wg-split-*.apk
```

`luci-i18n-wg-split-*` — пакет перевода; без него интерфейс будет на английском
(английский встроен). zapret ставится **отдельно** и определяется в рантайме — он
не является зависимостью.

## 3. Что произойдёт при установке

`postinst` пакета `wg-split`:

- добавит в `cron` ежедневное обновление списков (04:30 ipsum, 04:45 ru/cn,
  04:50 домены);
- включит и запустит службу `wg-split`;
- перезагрузит `rpcd`, чтобы зарегистрировать ubus-объект `wg-split`
  (`/usr/libexec/rpcd/wg-split`), через который ходит панель LuCI;
- в фоне скачает списки первый раз (установка возвращается сразу).

При обновлении с 1.7.x `uci-defaults`-миграция аддитивно проставляет новые
значения по умолчанию (например `type=wg` на существующих эндпоинтах) —
существующий `/etc/config/wg-split` не ломается.

## 4. Дальше

Перейдите к [настройке и панели LuCI](Configuration.md). До создания туннельного
интерфейса и добавления его в wg-split весь трафик безопасно идёт через WAN.

## Удаление

```sh
apk del luci-app-wg-split wg-split
```
`prerm` вызывает `wg-split-uninstall` (снимает правила/маршруты/сеты). Ручной
полный демонтаж — командой `wg-split-uninstall`.
