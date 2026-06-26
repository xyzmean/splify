# Устранение неполадок

← [Назад на главную](Home.md)

`wg-split-doctor` называет каждую из этих проблем напрямую; исправление — в его
строке `→ fix`. В панели LuCI они же показаны в блоке «Диагностика» (с кнопками
перехода в firewall/интерфейсы).

| Симптом (сообщение doctor) | Исправление |
|---|---|
| `no failover tunnels configured` | Добавьте туннель в Services → wg-split (Туннели отказоустойчивости). |
| `LAN subnet not set or not detected` | Задайте подсеть/интерфейс LAN; до этого весь трафик идёт через WAN. |
| `<if>: interface does not exist` | Создайте WG/AWG-интерфейс в Network → Interfaces или уберите его из wg-split. |
| `<if>: not in any firewall zone` | Добавьте туннель в зону firewall (иначе fw4 отбрасывает LAN→туннель — **гоча №1 после перепрошивки**). |
| `<if>: zone '…' has masquerading disabled` | Включите masq на этой зоне, иначе ответы VPN не маршрутизируются обратно. |
| `<if>: no forwarding '…' -> '…'` | Добавьте форвардинг firewall из зоны LAN в зону туннеля. |
| `<addr> not routed into tunnel` (site-to-site) | Подсеть пира в `vpn_cidr`, но не маршрутизируется — запустите `wg-split-apply` (на хабе подсеть спицы должна быть делегирована). |
| `<if>: route_allowed_ips not 0` | `wg-split-apply` — он принудительно ставит `route_allowed_ips=0`, чтобы туннель не перехватывал маршруты main. |
| `<if>: health probe failed` | Проверьте endpoint/ключи пира; failover пока выберет другой туннель. |
| `ipsum/ru set has N (<min)` | `wg-split-update-ipsum` / `-ru`; также перезаливается на след. тике. |
| `… list is stale` / `not yet downloaded` | Проверьте URL списка; запустите нужный `wg-split-update-*`. |
| `zapret is installed but not running` | Цикл failover его запустит; или `/etc/init.d/zapret start`. |
| `zapret is enabled … but not installed` | Установите zapret или снимите галку в Services → wg-split. |
| `dnsmasq nftset drop-in is missing` | `wg-split-apply` — регенерирует дроп-ин и перезагружает dnsmasq. |
| `killswitch is ON but active path is 'wan'/'zapret'` | Ни один туннель не здоров; под kill switch трафик должен блэкхолиться — проверьте туннели. |

## Главная причина: firewall

> wg-split управляет **маршрутизацией**, но **не трогает межсетевой экран**.

Даже при поднятом туннеле ядро прогоняет форвардинг LAN→туннель через fw4. Чтобы
он не был отброшен, туннельному интерфейсу нужно:

1. быть в **зоне firewall**;
2. на этой зоне — **`masq=1`** (иначе сервер VPN не вернёт ответ);
3. **форвардинг** `lan → эта зона`.

Без этого туннель выглядит «мёртвым», хотя рукопожатие свежее. В панели LuCI это
видно сразу: столбцы **Зона / Masq / LAN fwd** в таблице туннелей. Чинить вручную
не нужно — у каждого firewall-замечания есть кнопка **«Починить автоматически»**
(создаёт/чинит зону туннеля: accept-all + masq + mtu_fix, форвардинг
lan↔туннель↔wan). Из CLI: `wg-split-firewall fix <iface>` (проверить, не меняя:
`wg-split-firewall check <iface>`). Рядом — прямая ссылка **«Настройки
межсетевого экрана»**.

## Аварийные команды

```sh
wg-split-disable     # немедленно: весь LAN в WAN (служба может вернуть обратно)
wg-split-doctor      # полный отчёт
wg-split-status      # компактный снимок рантайма
logread -e wg-split  # журнал службы/failover
wg-split-apply       # регенерировать nft/dnsmasq из UCI и переустановить маршруты
```

## Диагностический чек-лист

1. `wg-split-doctor` — посмотреть `overall` и FAIL/FIXABLE.
2. Все FAIL обычно про firewall — починить зону/masq/форвардинг.
3. FIXABLE — выполнить названную команду или подождать тик failover.
4. Проверить активный путь: должен быть `vpn:<iface>`.
5. Проверить количества списков относительно минимумов.
6. Свериться с панелью LuCI (она показывает тот же JSON).
