# CLI и файлы

← [Назад на главную](Home.md)

## Команды

| Команда | Назначение |
|---------|-----------|
| `wg-split-doctor` | структурированная диагностика (текст; `--json` для LuCI; `--events` — JSON-журнал failover) |
| `wg-split-firewall {check\|fix} <iface>` | проверить/починить firewall-зону туннеля (зона + masq + forwarding lan↔туннель↔wan) |
| `wg-split-status` | компактный снимок рантайма |
| `wg-split-apply` | регенерировать nft/dnsmasq-слой из UCI и переустановить маршруты |
| `wg-split-failover` | один проход failover (`--daemon` — цикл, это и есть служба) |
| `wg-split-disable` | аварийно: только WAN |
| `wg-split-uninstall` | полный демонтаж (правила/маршруты/сеты) |
| `wg-split-update-ipsum` | скачать/применить список ipsum (VPN) |
| `wg-split-update-ru` | скачать/применить список ru/cn (direct) |
| `wg-split-update-domains` | скачать/применить доменные списки |
| `wg-split-sync-nozapret` | пересобрать bypass-сет zapret |
| `/etc/init.d/wg-split {start\|stop\|restart\|enable}` | управление службой procd |
| `logread -e wg-split` | журнал службы/failover |

## Файлы

| Путь | Роль |
|------|------|
| `/etc/config/wg-split` | UCI-конфиг (global + endpoint + device) |
| `/usr/local/sbin/wg-split-failover` | машина состояний failover + демон procd |
| `/usr/local/sbin/wg-split-doctor` | диагностика (текст + `--json`) |
| `/usr/local/sbin/wg-split-apply` | регенерация nft/dnsmasq-слоя из UCI |
| `/usr/local/sbin/wg-split-firewall` | создание/починка firewall-зоны туннеля |
| `/usr/libexec/rpcd/wg-split` | ubus-объект `wg-split` (status/events/action) для LuCI |
| `/var/run/wg-split-events` | RAM-журнал событий failover (таймлайн) |
| `/usr/local/sbin/wg-split-update-{ipsum,ru,domains}` | загрузчики списков |
| `/usr/local/sbin/wg-split-sync-nozapret` | пересборка bypass-сета zapret |
| `/usr/local/lib/wg-split/common.sh` | общие хелперы (загружают UCI) |
| `/etc/nftables.d/30-wg-split.nft` | канонический ruleset (регенерируется apply) |
| `/var/run/wg-split-state` | активный путь (`vpn:<if>`/`zapret`/`wan`/`killswitch`) |
| `/var/run/wg-split-failcount` | счётчик сбоев |
| `/etc/wg-split/*.lst` | скачанные списки |
| `luci-app-wg-split/` | страница настроек LuCI |

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
config wg-split 'global'   # все глобальные опции (mode, interval, killswitch, …)
config endpoint            # один туннель: option iface, option priority
config device              # пин хоста: option ip, option mode (vpn|direct)
```

Правка через LuCI или `uci set wg-split.global.<opt>=...; uci commit; wg-split-apply`.
