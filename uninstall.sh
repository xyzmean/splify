#!/bin/sh
# splify — ПОЛНОЕ удаление. Возвращает роутер к виду «как до установки»:
#   - пакеты splify (apk ИЛИ opkg, в зависимости от того, что есть)
#   - пакеты AmneziaWG (kmod-amneziawg, amneziawg-tools, luci-proto-amneziawg,
#     локализация) — тоже apk/opkg
#   - интерфейс warp0 (+ peer-секции amneziawg_warp0), созданный easyinstall
#   - firewall-зону для туннелей, которую создал splify-firewall fix
#   - конфиг /etc/config/splify и runtime-состояние splify
#   - любой другой splify-эндпоинт, оказавшийся в /etc/config/network без ссылки
#
# Безопасность: каждое действие best-effort (никогда не падает посередине из-за
# одной отсутствующей детали). splify-эндпоинты-НЕ-warp0 (которые вы создали
# вручную в Сеть → Интерфейсы) НЕ трогаются — это ваши собственные туннели.
#
#   wget -O - https://raw.githubusercontent.com/xyzmean/splify/main/uninstall.sh | sh
set -eu

WARP_IFACE="warp0"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mВнимание:\033[0m %s\n' "$*" >&2; }

[ "$(id -u)" = "0" ] || { printf '\033[1;31mОшибка:\033[0m запустите от root.\n' >&2; exit 1; }

# Какой пакетный менеджер доступен. apk = OpenWrt 24.10+/25.12+; opkg = 23.x/24.x.
PKG_MANAGER=""
if command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
elif command -v opkg >/dev/null 2>&1; then
    PKG_MANAGER="opkg"
else
    warn "не найден ни apk, ни opkg — пакетный менеджер недоступен. Продолжу очистку UCI/runtime, но пакеты удалите вручную."
fi

# uci -q get, пусто если не задано (не роняет скрипт).
uget() { uci -q get "$1" 2>/dev/null; }

# Удалить пакет(ы) через доступный менеджер. Молча, ошибки не фатальны:
# пакета может уже не быть (частичный uninstall ранее) — это норма.
del_pkgs() {
    [ -n "$PKG_MANAGER" ] || return 0
    if [ "$PKG_MANAGER" = "apk" ]; then
        # apk del принимает сразу несколько имён и сам игнорирует отсутствующие.
        apk del "$@" >/dev/null 2>&1 || true
    else
        # opkg тоже игнорирует отсутствующие по одному; перебираем на случай,
        # если одна ошибка не должна маскировать остальные.
        for _p in "$@"; do
            opkg remove "$_p" >/dev/null 2>&1 || true
        done
    fi
}

# ──────────────────────────── 1. stop splify services ───────────────────────
# Сначала глушим демонов, чтобы они не пересоздавали ip rules / nft прямо в
# процессе удаления. splify-uninstall (pre-remove хук) тоже это делает, но мы
# хотим детерминированности ПЕРЕД правкой network/firewall.
say "Останавливаю службы splify…"
for s in splify splify-agent; do
    if [ -x "/etc/init.d/$s" ]; then
        "/etc/init.d/$s" stop    >/dev/null 2>&1 || true
        "/etc/init.d/$s" disable >/dev/null 2>&1 || true
    fi
done
# sing-box тоже может крутиться отдельным procd-инстансом.
if [ -x /etc/init.d/splify-singbox ]; then
    /etc/init.d/splify-singbox stop    >/dev/null 2>&1 || true
    /etc/init.d/splify-singbox disable >/dev/null 2>&1 || true
fi

# ──────────────────────────── 2. warp0 interface + peers ────────────────────
# Удаляем интерфейс warp0 (созданный easyinstall) И его peer-секции
# amneziawg_warp0 из /etc/config/network. Глушим линк до правки UCI.
if [ -n "$(uget "network.$WARP_IFACE")" ]; then
    say "Удаляю интерфейс $WARP_IFACE…"
    ifdown "$WARP_IFACE" >/dev/null 2>&1 || true
    uci -q delete "network.$WARP_IFACE" || true
fi
# peer-секции: amneziawg_warp0 (и, на всякий случай, wireguard_warp0 — если
# кто-то переключал протокол вручную). Удаляем по индексу от [0] вниз.
for _pt in amneziawg_"$WARP_IFACE" wireguard_"$WARP_IFACE"; do
    while [ -n "$(uget "network.@${_pt}[0]")" ]; do
        uci -q delete "network.@${_pt}[0]" || true
    done
done

# ──────────────────────────── 3. firewall zone + forwardings ────────────────
# splify-firewall fix создаёт зону с name = <iface> (для warp0 это «warp0») и
# forwardings lan<->zone, zone->wan. Чистим ВСЕ зоны/forwardings, ссылающиеся
# на splify-эндпоинты, — не только warp0, чтобы не осталось висячих зон после
# удаления пакетов (эндпоинты читаются из /etc/config/splify, пока он ещё есть).
# Дополнительно гарантированно трогаем warp0 (зону могли создать, а эндпоинт в
# splify — уже стёрли).
_ep_ifaces="$(uci show splify 2>/dev/null | sed -n "s/^splify\.[^=]*\.iface='\([^']*\)'\$/\1/p" | sort -u)"
_ep_ifaces="$WARP_IFACE $_ep_ifaces"

say "Чищу firewall-зоны для туннелей…"
# Зоны: удаляем те, чьё name ∈ {эндпоинты} ИЛИ чья network/device = эндпоинт
# (зона для sing-box создаётся через device=, не network=).
_zi=0
while [ -n "$(uget "firewall.@zone[$_zi]")" ]; do
    _zn="$(uget "firewall.@zone[$_zi].name")"
    _znet="$(uget "firewall.@zone[$_zi].network")"
    _zdev="$(uget "firewall.@zone[$_zi].device")"
    _match=""
    for _ep in $_ep_ifaces; do
        [ -n "$_ep" ] || continue
        { [ "$_zn" = "$_ep" ] || \
          case " $_znet " in *" $_ep "*) :;; *) false;; esac || \
          case " $_zdev " in *" $_ep "*) :;; *) false;; esac; } && { _match=1; break; }
    done
    if [ -n "$_match" ]; then
        uci -q delete "firewall.@zone[$_zi]" || true
        # не увеличиваем _zi: удаление сдвигает остальные секции вниз
    else
        _zi=$((_zi + 1))
    fi
done
# Forwardings: удаляем те, чьи src ИЛИ dest ссылаются на splify-эндпоинт.
# (lan->warp0, warp0->lan, warp0->wan — все три содержат имя зоны-эндпоинта.)
_fi=0
while [ -n "$(uget "firewall.@forwarding[$_fi]")" ]; do
    _fsrc="$(uget "firewall.@forwarding[$_fi].src")"
    _fdest="$(uget "firewall.@forwarding[$_fi].dest")"
    _match=""
    for _ep in $_ep_ifaces; do
        [ -n "$_ep" ] || continue
        { [ "$_fsrc" = "$_ep" ] || [ "$_fdest" = "$_ep" ]; } && { _match=1; break; }
    done
    if [ -n "$_match" ]; then
        uci -q delete "firewall.@forwarding[$_fi]" || true
    else
        _fi=$((_fi + 1))
    fi
done

# ──────────────────────────── 4. commit UCI + reload ────────────────────────
# Коммитим network/firewall ДО удаления пакетов, чтобы демоны при остановке
# уже видели чистую конфигурацию.
uci -q commit network  2>/dev/null || true
uci -q commit firewall 2>/dev/null || true
/etc/init.d/network reload   >/dev/null 2>&1 || true
/etc/init.d/firewall reload  >/dev/null 2>&1 || true

# ──────────────────────────── 5. splify runtime (ip rules, nft, cron) ───────
# splify-uninstall (pre-remove хук пакета) сносит ip rules/routes, сгенерированный
# nft-дропин, cron-записи и runtime-состояние. Запустим его руками, если он есть,
# чтобы state ушёл даже если пакеты ещё стоят (порядок не важен — он idempotent).
if [ -x /usr/local/sbin/splify-uninstall ]; then
    say "Чищу runtime-состояние splify (ip rules, nft, cron)…"
    /usr/local/sbin/splify-uninstall >/dev/null 2>&1 || true
else
    # Пакета ещё/уже нет — почистим минимум вручную, чтобы не осталось висячих
    # ip rules и nft-цепочек. Зеркалирует splify-uninstall без заимствования его
    # переменных (этот скрипт не source'ит common.sh — он должен работать до
    # установки пакета и после).
    say "Чищу runtime-состояние splify вручную…"
    while ip -4 rule del priority 999   >/dev/null 2>&1; do :; done
    while ip -4 rule del priority 1000  >/dev/null 2>&1; do :; done
    ip -4 route flush table 200 >/dev/null 2>&1 || true
    rm -f /etc/nftables.d/30-splify.nft
    rm -f /tmp/dnsmasq.d/splify-*.conf /tmp/dnsmasq.cfg*.d/splify-*.conf
    if [ -f /etc/crontabs/root ]; then
        grep -v 'splify-' /etc/crontabs/root > /tmp/splify-cron.uninst || true
        cat /tmp/splify-cron.uninst > /etc/crontabs/root
        rm -f /tmp/splify-cron.uninst
        /etc/init.d/cron restart >/dev/null 2>&1 || true
    fi
    rm -f /var/run/splify-state /var/run/splify-failcount /var/run/splify-events
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    /etc/init.d/dnsmasq reload  >/dev/null 2>&1 || true
fi

# ──────────────────────────── 6. remove splify packages ─────────────────────
if [ -n "$PKG_MANAGER" ]; then
    say "Удаляю пакеты splify ($PKG_MANAGER)…"
    del_pkgs luci-i18n-splify-ru luci-app-splify splify
fi

# ──────────────────────────── 7. remove AmneziaWG packages ──────────────────
# kmod-amneziawg, amneziawg-tools, luci-proto-amneziawg + локализация. Это ровно
# то, что ставит install.sh/easyinstall через awg-openwrt. НЕ трогаем luci-proto-
# wireguard (обычный WG мог быть нужен и до splify). del_pkgs игнорирует отсутствие.
if [ -n "$PKG_MANAGER" ]; then
    say "Удаляю пакеты AmneziaWG ($PKG_MANAGER)…"
    del_pkgs luci-i18n-amneziawg-ru luci-proto-amneziawg amneziawg-tools kmod-amneziawg
    # Выгружаем kmod, если ещё загружен (init.d/kmod грузит модули только на boot;
    # как и в easyinstall, modprobe/insmod — иначе интерфейс останется в ядре).
    if lsmod 2>/dev/null | grep -q '^amneziawg '; then
        rmmod amneziawg 2>/dev/null || warn "не удалось выгрузить модуль amneziawg — он уйдёт после перезагрузки."
    fi
fi

# ──────────────────────────── 8. splify config + leftover data ──────────────
say "Удаляю конфигурацию и данные splify…"
rm -f /etc/config/splify
# Списки/снапшоты/состояние агента (флеш-часть — не tmpfs).
rm -rf /etc/splify
# /var/run живёт в tmpfs (уйдёт при ребуте), но приберём и его для чистоты.
rm -f /var/run/splify-state /var/run/splify-failcount /var/run/splify-events \
      /var/run/splify-agent.last /var/run/splify-agent.status

# Чтобы исчезли пункты меню LuCI и закешированные rpcd-методы.
rm -f /tmp/luci-indexcache* /tmp/luci-modulecache* 2>/dev/null || true
/etc/init.d/rpcd reload 2>/dev/null || /etc/init.d/rpcd restart 2>/dev/null || true

say "Готово! Роутер чист: splify, AmneziaWG, интерфейс $WARP_IFACE и firewall-зона удалены."
printf '  • Если вы редактировали Сеть → Интерфейсы вручную — проверьте, что ничего лишнего не осталось.\n'
printf '  • Перезагрузка не требуется, но не повредит «добить» выгрузку kmod.\n'
