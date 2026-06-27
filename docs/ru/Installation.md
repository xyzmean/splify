# Установка

← [Назад на главную](Home.md)

Требуется **OpenWrt 24.10+ / 25.12+ (менеджер пакетов apk)**.

## 1. Получить пакеты

Собираются два (плюс языковой) пакета:

- `splify` — ядро (скрипты, служба, nftables/dnsmasq-слой);
- `luci-app-splify` — страница настроек LuCI;
- `luci-i18n-splify-ru` — русский перевод интерфейса (опционально).

Способы получить `.apk`:

### Релизы GitHub
Готовые `.apk` прикладываются к каждому релизу (workflow `release.yml` /
`auto-version.yml`). Скачайте все три файла.

### Сборка в CI
Открыть **Actions → Build packages → Run workflow**. Артефакт `packages` будет
содержать `splify-*.apk`, `luci-app-splify-*.apk` и
`luci-i18n-splify-*.apk`.

### Локальная сборка через Docker (OpenWrt SDK)
```sh
docker build -f Dockerfile-apk --build-arg VERSION=1.7.2 -t splify:local .
id=$(docker create splify:local)
docker cp "$id:/builder/bin/packages/." ./out/
docker rm "$id"
find ./out -name '*splify*.apk'
```
Тяжёлый слой зависимостей (ядро + nftables/curl/dnsmasq/ip-full/luci-base)
кэшируется один раз; пересборка наших пакетов занимает секунды.

## 2. Установить на роутер

Скопируйте `.apk` на роутер и установите:

```sh
apk add ./splify-*.apk ./luci-app-splify-*.apk ./luci-i18n-splify-*.apk
```

`luci-i18n-splify-*` — пакет перевода; без него интерфейс будет на английском
(английский встроен). zapret ставится **отдельно** и определяется в рантайме — он
не является зависимостью.

## 3. Что произойдёт при установке

`postinst` пакета `splify`:

- добавит в `cron` ежедневное обновление списков (04:30 ipsum, 04:45 ru/cn,
  04:50 домены);
- включит и запустит службу `splify`;
- перезагрузит `rpcd`, чтобы зарегистрировать ubus-объект `splify`
  (`/usr/libexec/rpcd/splify`), через который ходит панель LuCI;
- в фоне скачает списки первый раз (установка возвращается сразу).

При обновлении с 1.7.x `uci-defaults`-миграция аддитивно проставляет новые
значения по умолчанию (например `type=wg` на существующих эндпоинтах) —
существующий `/etc/config/splify` не ломается.

## 4. Дальше

Перейдите к [настройке и панели LuCI](Configuration.md). До создания туннельного
интерфейса и добавления его в splify весь трафик безопасно идёт через WAN.

## Удаление

```sh
apk del luci-app-splify splify
```
`prerm` вызывает `splify-uninstall` (снимает правила/маршруты/сеты). Ручной
полный демонтаж — командой `splify-uninstall`.
