'use strict';
'require view';
'require network';
'require uci';
'require rpc';
'require ui';
'require poll';
'require splify.dashboard as dashboard';

var callStatus = rpc.declare({ object: 'splify', method: 'status' });
var callAction = rpc.declare({ object: 'splify', method: 'action', params: [ 'name', 'iface' ] });

// Plain-language status from doctor's summary.state.
function statusLine(d) {
    var s = (d && d.summary) || {}, st = s.state || '';
    if (/^vpn:/.test(st)) return { ok: true,  text: _('Защищено — трафик идёт через VPN (%s)').format(st.replace(/^vpn:/, '')) };
    if (st === 'zapret')  return { ok: false, text: _('Нет туннеля — работает обход DPI на прямом канале') };
    if (st === 'killswitch') return { ok: false, text: _('Защита включена, но туннель недоступен — трафик заблокирован') };
    if (st === 'wan')     return { ok: false, text: _('Прямое подключение — VPN не активен') };
    return { ok: false, text: _('Состояние неизвестно') };
}
function isOn(d) { var st = ((d && d.summary) || {}).state || ''; return /^vpn:/.test(st) || st === 'zapret' || st === 'killswitch'; }

// First firewall problem doctor can auto-fix (message starts "<iface>: …").
function firewallFix(d) {
    var c = (d && d.checks || []).filter(function (x) {
        return x.category === 'firewall' && x.severity !== 'OK' &&
               !/in the shared |device wildcard|non-tunnel networks/.test(x.message || '');
    })[0];
    if (!c) return null;
    var m = /^([A-Za-z0-9_.-]+):/.exec(c.message || '');
    return m ? m[1] : null;
}

return view.extend({
    load: function () {
        return Promise.all([ network.getNetworks(), uci.load('splify') ]);
    },
    render: function (data) {
        dashboard.injectStyle();
        var networks = data[0] || [];
        var wgIfaces = networks.filter(function (n) {
            var p = n.getProtocol(); return p === 'amneziawg' || p === 'wireguard';
        }).map(function (n) { return n.getName(); });

        var body = E('div', {}, E('em', {}, _('Загрузка…')));
        var detailsBox = E('div', { 'style': 'display:none;margin-top:1em' });
        var detailsBuilt = false;

        function busy(node, fn) {
            node.disabled = true;
            return Promise.resolve().then(fn).finally(function () { node.disabled = false; });
        }

        function setTunnel(iface) {
            // Write iface onto the priority-1 endpoint (create one if none).
            var secs = uci.sections('splify', 'endpoint');
            var sid = secs.length ? secs[0]['.name'] : uci.add('splify', 'endpoint');
            uci.set('splify', sid, 'iface', iface);
            if (!uci.get('splify', sid, 'priority')) uci.set('splify', sid, 'priority', '1');
            if (!uci.get('splify', sid, 'type')) uci.set('splify', sid, 'type', 'wg');
            return uci.save().then(function () { return callAction('apply', ''); });
        }

        function refresh() {
            return callStatus().then(function (d) {
                d = d || {};
                var sl = statusLine(d), on = isOn(d), fwIface = firewallFix(d);

                var toggle = E('button', {
                    'class': 'btn cbi-button ' + (on ? 'cbi-button-reset' : 'cbi-button-save'),
                    'style': 'font-size:1.1em;padding:.5em 1.4em',
                    'click': ui.createHandlerFn(this, function (ev) {
                        return busy(ev.target, function () {
                            return callAction(on ? 'off' : 'on', '').then(function () {
                                ui.addNotification(null, E('p', {}, on ? _('VPN выключен') : _('VPN включён')), 'info');
                                return refresh();
                            });
                        });
                    })
                }, on ? _('Выключить') : _('Включить'));

                var picker;
                if (wgIfaces.length) {
                    var cur = (uci.sections('splify', 'endpoint')[0] || {}).iface || '';
                    var sel = E('select', { 'class': 'cbi-input-select' },
                        wgIfaces.map(function (i) {
                            return E('option', Object.assign({ 'value': i }, i === cur ? { 'selected': 'selected' } : {}), i);
                        }));
                    sel.addEventListener('change', ui.createHandlerFn(this, function () {
                        return busy(sel, function () {
                            return setTunnel(sel.value).then(function () {
                                ui.addNotification(null, E('p', {}, _('Туннель переключён на %s').format(sel.value)), 'info');
                                return refresh();
                            });
                        });
                    }));
                    picker = E('div', { 'style': 'margin:.6em 0' }, [
                        E('label', { 'style': 'margin-right:.5em' }, _('Подключаться через:')), sel ]);
                } else {
                    picker = E('div', { 'class': 'alert-message warning', 'style': 'margin:.6em 0' }, [
                        _('Сначала создайте VPN-туннель в '),
                        E('a', { 'href': L.url('admin/network/network') }, _('Сеть → Интерфейсы')),
                        _(' (WireGuard или AmneziaWG).') ]);
                }

                var tools = [
                    E('button', { 'class': 'btn cbi-button cbi-button-neutral',
                        'click': ui.createHandlerFn(this, function (ev) {
                            return busy(ev.target, function () {
                                return Promise.all([ callAction('update_ipsum',''), callAction('update_ru',''), callAction('update_domains','') ])
                                    .then(function () { ui.addNotification(null, E('p', {}, _('Списки обновлены')), 'info'); return refresh(); });
                            });
                        }) }, _('Обновить списки'))
                ];
                if (fwIface) tools.push(E('button', { 'class': 'btn cbi-button cbi-button-action',
                    'click': ui.createHandlerFn(this, function (ev) {
                        return busy(ev.target, function () {
                            return callAction('fw_fix', fwIface).then(function (r) {
                                r = r || {};
                                ui.addNotification(null, E('p', {}, r.code === 0 ? _('Брандмауэр настроен') : _('Не удалось настроить брандмауэр: ') + (r.stdout||'')), r.code === 0 ? 'info' : 'warning');
                                return refresh();
                            });
                        });
                    }) }, _('Починить автоматически')));

                var detailsToggle = E('a', { 'href': '#', 'style': 'display:inline-block;margin-top:1em',
                    'click': function (e) {
                        e.preventDefault();
                        var open = detailsBox.style.display === 'none';
                        detailsBox.style.display = open ? 'block' : 'none';
                        if (open && !detailsBuilt) { detailsBuilt = true; detailsBox.appendChild(dashboard.buildPanel(wgIfaces)); }
                        e.target.textContent = open ? _('Скрыть подробное состояние') : _('Подробное состояние');
                    } }, _('Подробное состояние'));

                body.replaceChildren(E('div', { 'class': 'cbi-section' }, [
                    E('div', { 'class': 'wgs-hero', 'style': 'border-left:5px solid ' + (sl.ok ? '#3c763d' : '#a94442') }, [
                        E('div', { 'class': 'wgs-hero-icon', 'style': 'color:' + (sl.ok ? '#3c763d' : '#a94442') }, sl.ok ? '✓' : '!'),
                        E('div', { 'class': 'wgs-hero-main' }, [ E('div', { 'class': 'wgs-hero-path' }, sl.text) ]),
                        E('div', { 'style': 'flex:0 0 auto' }, toggle)
                    ]),
                    picker,
                    E('div', { 'class': 'wgs-toolbar' }, tools),
                    detailsToggle
                ]));
            }).catch(function (e) {
                body.replaceChildren(E('em', { 'style': 'color:#a94442' }, _('Не удалось получить состояние (служба splify запущена?): ') + e));
            });
        }

        refresh();
        poll.add(refresh, 8);
        return E('div', {}, [ E('h2', {}, 'splify'), body, detailsBox ]);
    },
    handleSave: null, handleSaveApply: null, handleReset: null
});
