# Списки и zapret

← [Назад на главную](Home.md)

wg-split тянет IP- и доменные списки по URL и обновляет их ежедневно (cron). Сеты
nftables живут внутри `table inet fw4`.

## IP-списки

| Список | Файл | nft-сет | Куда | Мин. записей |
|--------|------|---------|------|:------------:|
| **ipsum** | `/etc/wg-split/ipsum.lst` | `wg_split_ipsum_v4` | VPN | 5000 |
| **ru/cn** | `/etc/wg-split/ru_subnets.lst` | `wg_split_ru_subnets_v4` | direct (+ feed nozapret) | 5000 |

- **ipsum** — заблокированные/зарубежные IP, которые должны ехать через VPN
  (используется в режиме `blocklist`).
- **ru/cn** — отечественные подсети, которые держим напрямую; они же кормят
  bypass-сет zapret. Живой nft-сет существует только в режиме `full` (там это
  явное direct-исключение).

Списки скачиваются по `ipsum_url` / `ru_url`, проходят валидацию/очистку
(только корректные IPv4/CIDR, дедуп) и заливаются в сет **одним компактным
блоком** `flush set; add element { … }` — это парсится в ~10 МБ вместо OOM на
38k+ записей на роутерах с 240 МБ RAM.

## Доменные списки

Скачиваемые `vpn_domains_url` / `ignore_domains_url` (плюс ручные `vpn_domain` /
`direct_domain`) превращаются в директивы `nftset=` для dnsmasq и помечают домен
**в момент DNS-резолва**: имя резолвится → его IP попадает в VPN- или direct-сет.

Файлы: `/etc/wg-split/vpn-domains.lst`, `/etc/wg-split/ignore-domains.lst`,
дроп-ин dnsmasq генерируется в живой conf-dir dnsmasq.

## zapret (обход DPI на WAN)

zapret — **опционален** и определяется в рантайме (по `/etc/init.d/zapret`,
`/opt/zapret/nfq/nfqws`, бинарю `nfqws` или работающему процессу). Если включён
(`zapret_enabled=1`) и доступен:

- сет **`nozapret`** (`inet zapret`, мин. 1000) — это «не трогать zapret».
  - Когда VPN активен: VPN-IP **остаются** в `nozapret` (они и так в туннеле).
  - При WAN-фолбэке: VPN-IP **вынимаются** из `nozapret`, чтобы zapret обошёл их
    DPI прямо на WAN.
- ступень `zapret` в failover берётся, только если синк удался, `nfqws` работает
  и WAN отвечает.

Если zapret выключен или не установлен — ступень просто пропускается (обычный
WAN), предупреждение об этом не критично.

## Обновление

Ежедневный cron (добавляется в `postinst`):

```
30 4 * * *  wg-split-update-ipsum
45 4 * * *  wg-split-update-ru
50 4 * * *  wg-split-update-domains
```

Вручную/из LuCI: `wg-split-update-ipsum`, `-ru`, `-domains`. Апдейтеры
сериализуются на `flock`, чтобы параллельные запуски (cron + Save&Apply) не
спамили ошибками. После успешного скачивания список переприменяется.

«Возраст» списка старше 2 дней `doctor` помечает как `WARN` (пропущенный ночной
запуск или битый URL).
