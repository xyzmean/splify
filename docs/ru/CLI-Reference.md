# CLI и файлы

← [Назад на главную](Home.md)

## Команды

| Команда | Назначение |
|---------|-----------|
| `splify-doctor` | структурированная диагностика (текст; `--json` для LuCI; `--events` — JSON-журнал failover) |
| `splify-firewall {check\|fix} <iface>` | проверить/починить firewall-зону туннеля (зона + masq + forwarding lan↔туннель↔wan) |
| `splify-status` | компактный снимок рантайма |
| `splify-apply` | регенерировать nft/dnsmasq-слой из UCI и переустановить маршруты |
| `splify-failover` | один проход failover (`--daemon` — цикл, это и есть служба) |
| `splify-disable` | аварийно: только WAN |
| `splify-uninstall` | полный демонтаж (правила/маршруты/сеты) |
| `splify-update-ipsum` | скачать/применить список ipsum (VPN) |
| `splify-update-ru` | скачать/применить список ru/cn (direct) |
| `splify-update-domains` | скачать/применить доменные списки |
| `splify-sync-nozapret` | пересобрать bypass-сет zapret |
| `/etc/init.d/splify {start\|stop\|restart\|enable}` | управление службой procd |
| `logread -e splify` | журнал службы/failover |

## Файлы

| Путь | Роль |
|------|------|
| `/etc/config/splify` | UCI-конфиг (global + endpoint + device) |
| `/usr/local/sbin/splify-failover` | машина состояний failover + демон procd |
| `/usr/local/sbin/splify-doctor` | диагностика (текст + `--json`) |
| `/usr/local/sbin/splify-apply` | регенерация nft/dnsmasq-слоя из UCI |
| `/usr/local/sbin/splify-firewall` | создание/починка firewall-зоны туннеля |
| `/usr/libexec/rpcd/splify` | ubus-объект `splify` (status/events/action) для LuCI |
| `/var/run/splify-events` | RAM-журнал событий failover (таймлайн) |
| `/usr/local/sbin/splify-update-{ipsum,ru,domains}` | загрузчики списков |
| `/usr/local/sbin/splify-sync-nozapret` | пересборка bypass-сета zapret |
| `/usr/local/lib/splify/common.sh` | общие хелперы (загружают UCI) |
| `/etc/nftables.d/30-splify.nft` | канонический ruleset (регенерируется apply) |
| `/var/run/splify-state` | активный путь (`vpn:<if>`/`zapret`/`wan`/`killswitch`) |
| `/var/run/splify-failcount` | счётчик сбоев |
| `/etc/splify/*.lst` | скачанные списки |
| `luci-app-splify/` | страница настроек LuCI |

## Внутренние константы (не настраиваются)

| Имя | Значение | Что это |
|-----|----------|---------|
| Таблица маршрутов | `200` | таблица политики VPN |
| VPN-марка | `0x40000`, prio правила `999` | пакет → таблица 200 |
| Анти-loop марка | `0x10000`, prio `1000` | пакет → main (напрямую) |
| Таблица проб | `201`, prio `998` | изолированный маршрут для health-пробы |
| Мин. ipsum / ru | `5000` / `5000` | порог «сет просел» |
| Мин. nozapret | `1000` | порог bypass-сета zapret |
| Порог «устаревания» | `172800` с (2 дня) | возраст списка → WARN |

## UCI-секции

```
config splify 'global'   # все глобальные опции (mode, interval, killswitch, …)
config endpoint            # один туннель: option iface, option priority
config device              # пин хоста: option ip, option mode (vpn|direct)
```

Правка через LuCI или `uci set splify.global.<opt>=...; uci commit; splify-apply`.
