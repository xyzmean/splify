'use strict';
'require view';
'require network';
'require rpc';
'require ui';
'require poll';

// wg-split 2.0 dashboard. Pure status/diagnostics view — settings live on the
// sibling "Settings" tab (view/wg-split/settings.js). Talks to the wg-split rpcd
// object over ubus (least-privilege; design §4.3) — no broad file:exec ACL.
var callStatus = rpc.declare({ object: 'wg-split', method: 'status' });
var callEvents = rpc.declare({ object: 'wg-split', method: 'events' });
var callAction = rpc.declare({
	object: 'wg-split', method: 'action',
	params: [ 'name', 'iface' ]
});

// Severity -> CSS color (matches wg-split-doctor's OK/WARN/FIXABLE/FAIL).
var SEV = {
	OK:      '#3c763d',
	WARN:    '#8a6d3b',
	FIXABLE: '#a0522d',
	FAIL:    '#a94442'
};

var STYLE_ID = 'wg-split-style';
function injectStyle() {
	if (document.getElementById(STYLE_ID)) return;
	// Theme-aware surfaces with translucent-grey fallbacks so the panel renders
	// identically on stock Bootstrap/material and on Argon's card theme.
	var BORDER = 'var(--border-color, rgba(127,127,127,.35))';
	var SURFACE = 'var(--off-color, rgba(127,127,127,.07))';
	var css = '' +
		'.wgs-hero{display:flex;align-items:center;gap:1em;padding:1em 1.2em;border-radius:.5em;margin:.4em 0 1em;border:1px solid ' + BORDER + '}' +
		'.wgs-hero-icon{font-size:2.2em;line-height:1;width:1.4em;text-align:center;flex:0 0 auto}' +
		'.wgs-hero-main{flex:1 1 auto;min-width:0}' +
		'.wgs-hero-path{font-size:1.25em;font-weight:bold;margin-bottom:.15em}' +
		'.wgs-hero-meta{font-size:.9em;opacity:.85}' +
		'.wgs-hero-meta span{margin-right:1em;white-space:nowrap}' +
		'.wgs-chain{display:flex;flex-wrap:wrap;align-items:stretch;gap:.35em;margin:.2em 0 1em}' +
		'.wgs-node{display:flex;flex-direction:column;justify-content:center;padding:.45em .7em;border-radius:.45em;' +
			'border:1px solid ' + BORDER + ';background:' + SURFACE + ';text-align:center;min-width:78px}' +
		'.wgs-node-title{font-weight:600;font-size:.95em}' +
		'.wgs-node-sub{font-size:.78em;opacity:.75;margin-top:.1em}' +
		'.wgs-node-active{border-color:' + SEV.OK + ';background:rgba(60,118,61,.14);box-shadow:0 0 0 2px rgba(60,118,61,.3)}' +
		'.wgs-node-dead{border-color:' + SEV.FAIL + ';color:' + SEV.FAIL + ';opacity:.85}' +
		'.wgs-node-block{border-color:' + SEV.FAIL + ';background:rgba(169,68,66,.14);box-shadow:0 0 0 2px rgba(169,68,66,.3)}' +
		'.wgs-arrow{align-self:center;opacity:.5;font-size:1.1em;padding:0 .1em}' +
		'.wgs-check{display:flex;flex-wrap:wrap;align-items:center;gap:.5em;margin:.4em 0;padding:.5em .7em;' +
			'border-radius:.35em;border-left:4px solid #777;background:' + SURFACE + '}' +
		'.wgs-check-body{flex:1 1 240px;min-width:0}' +
		'.wgs-check-fix{opacity:.8;font-size:.88em;margin-top:.15em}' +
		'.wgs-firstrun{padding:1em 1.2em;border-radius:.5em;border:1px dashed ' + BORDER + ';' +
			'background:rgba(138,109,59,.1);margin:.4em 0 1em}' +
		'.wgs-firstrun h4{margin:.2em 0 .5em}' +
		'.wgs-firstrun ol{margin:.3em 0 .6em 1.2em}' +
		'.wgs-firstrun li{margin:.25em 0}' +
		'.wgs-badge{display:inline-block;padding:.1em .5em;border-radius:.25em;color:#fff;font-weight:bold;font-size:.85em}' +
		'.wgs-toolbar{margin:.2em 0 .8em;display:flex;flex-wrap:wrap;gap:.4em;align-items:center}' +
		'.wgs-spacer{flex:1 1 auto}' +
		'.wgs-live{font-size:.82em;opacity:.7;display:inline-flex;align-items:center;gap:.35em}' +
		'.wgs-dot{width:.6em;height:.6em;border-radius:50%;background:' + SEV.OK + ';display:inline-block}' +
		'.wgs-dot-off{background:#999}' +
		'.wgs-rate{font-size:.78em;opacity:.8;white-space:nowrap}' +
		'.wgs-rate-rx{color:' + SEV.OK + '}.wgs-rate-tx{color:#3b6ea5}';
	var el = document.createElement('style');
	el.id = STYLE_ID;
	el.textContent = css;
	document.head.appendChild(el);
}

function badge(sev) {
	return E('span', { 'class': 'wgs-badge', 'style': 'background:' + (SEV[sev] || '#777') }, sev);
}

function yn(v) {
	return E('span', { 'style': 'color:' + (v ? SEV.OK : SEV.FAIL) + ';font-weight:600' }, v ? '✓' : '✗');
}

// Doctor is passive: per-endpoint health is liveness-derived — 'ok' (fresh) /
// 'idle' (stale, not probed). The daemon-confirmed live path is the hero above.
function healthCell(h) {
	if (h === 'OK' || h === 'ok') return E('span', { 'style': 'color:' + SEV.OK }, _('ok'));
	if (h === 'FAIL') return E('span', { 'style': 'color:' + SEV.FAIL }, 'FAIL');
	if (h === 'idle') return E('span', { 'style': 'color:#888' }, _('idle'));
	return '—';
}

function fmtAge(s) {
	if (s == null || s < 0) return '—';
	if (s < 120) return s + 's';
	if (s < 7200) return Math.round(s / 60) + 'm';
	return Math.round(s / 3600) + 'h';
}

// Humanize a byte/s rate (IEC-ish, base 1000 to match nft/wg counters' feel).
function fmtRate(bps) {
	if (bps == null || !isFinite(bps) || bps < 1) return '0';
	var u = [ 'B/s', 'K/s', 'M/s', 'G/s' ], i = 0;
	while (bps >= 1000 && i < u.length - 1) { bps /= 1000; i++; }
	return (bps < 10 && i > 0 ? bps.toFixed(1) : Math.round(bps)) + ' ' + u[i];
}

// Per-iface previous transfer sample, for speed = Δbytes / Δt between polls.
var prevTx = {};
function ratesFor(e, now) {
	var k = e.iface, p = prevTx[k], rxr = 0, txr = 0;
	if (p && now > p.t && e.rx >= p.rx && e.tx >= p.tx) {
		var dt = (now - p.t) / 1000;
		rxr = (e.rx - p.rx) / dt;
		txr = (e.tx - p.tx) / dt;
	}
	prevTx[k] = { rx: e.rx || 0, tx: e.tx || 0, t: now };
	return { rx: rxr, tx: txr };
}
function rateLabel(r) {
	return E('span', { 'class': 'wgs-rate' }, [
		E('span', { 'class': 'wgs-rate-rx' }, '↓' + fmtRate(r.rx)), ' ',
		E('span', { 'class': 'wgs-rate-tx' }, '↑' + fmtRate(r.tx))
	]);
}

function pathInfo(state, overall) {
	var icon = '✓', sev = overall || 'FAIL', label;
	if (/^vpn:/.test(state)) {
		label = _('VPN active via %s').format(state.replace(/^vpn:/, ''));
	} else if (state === 'zapret') {
		label = _('No tunnel — WAN with zapret DPI-bypass');
	} else if (state === 'killswitch') {
		label = _('Kill switch — policy traffic blocked'); icon = '⛔';
	} else if (state === 'wan') {
		label = _('No tunnel — direct WAN (traffic exposed)');
	} else {
		label = _('Unknown'); icon = '?';
	}
	if (sev === 'OK') icon = (state && /^vpn:/.test(state)) ? '✓' : icon;
	else if (sev === 'WARN') icon = (icon === '✓' ? '⚠' : icon);
	else if (sev === 'FAIL' || sev === 'FIXABLE') icon = (icon === '✓' ? '✕' : icon);
	return { icon: icon, label: label, sev: sev };
}

function heroCard(d) {
	var s = d.summary || {};
	var pi = pathInfo(s.state || '', d.overall);
	var color = SEV[pi.sev] || '#777';
	var meta = E('div', { 'class': 'wgs-hero-meta' }, [
		E('span', {}, [ E('strong', {}, _('Mode') + ': '), (s.mode || '?') ]),
		E('span', {}, [ E('strong', {}, _('Kill switch') + ': '),
			(String(s.killswitch) === '1' ? _('on') : _('off')) ]),
		E('span', {}, [ E('strong', {}, _('Failures') + ': '),
			(s.fail_count != null ? String(s.fail_count) : '?') ]),
		E('span', {}, [ E('strong', {}, _('LAN') + ': '),
			(s.lan_iface || '?') + ' → ' + (s.lan_cidr || _('(none detected)')) ])
	]);
	return E('div', { 'class': 'wgs-hero', 'style': 'border-left:5px solid ' + color },[
		E('div', { 'class': 'wgs-hero-icon', 'style': 'color:' + color }, pi.icon),
		E('div', { 'class': 'wgs-hero-main' }, [
			E('div', { 'class': 'wgs-hero-path' }, pi.label),
			meta
		]),
		E('div', { 'style': 'flex:0 0 auto' }, badge(d.overall || 'FAIL'))
	]);
}

// Routing chain LAN → [endpoint #1..#N] → (zapret) → WAN, live hop highlighted,
// live rate shown on the active endpoint. Generic "endpoint" labels (no hardcoded
// "WireGuard"/"handshake") so a future sing-box transport reads the same.
function chainViz(d, rates) {
	var s = d.summary || {};
	var state = s.state || '';
	var nodes = [];

	function node(title, sub, cls) {
		return E('div', { 'class': 'wgs-node' + (cls ? ' ' + cls : '') }, [
			E('div', { 'class': 'wgs-node-title' }, title),
			sub != null && sub !== '' ? E('div', { 'class': 'wgs-node-sub' }, sub) : ''
		]);
	}
	function arrow() { return E('div', { 'class': 'wgs-arrow' }, '→'); }

	nodes.push(node(_('LAN'), s.lan_iface || '', ''));

	(d.endpoints || []).forEach(function (e) {
		var active = (state === 'vpn:' + e.iface);
		var cls = active ? 'wgs-node-active' : (e.present ? '' : 'wgs-node-dead');
		var sub;
		if (!e.present) sub = _('down');
		else if (active) sub = rateLabel(rates[e.iface] || { rx: 0, tx: 0 });
		else sub = (e.handshake_age >= 0 ? '⇄ ' + fmtAge(e.handshake_age) : '');
		nodes.push(arrow());
		nodes.push(node('#' + (e.priority || '?') + ' ' + e.iface, sub, cls));
	});

	var hasZapret = (d.lists || []).some(function (l) { return l.name === 'nozapret'; }) || state === 'zapret';
	if (hasZapret) {
		nodes.push(arrow());
		nodes.push(node(_('zapret'), _('DPI-bypass'), state === 'zapret' ? 'wgs-node-active' : ''));
	}

	nodes.push(arrow());
	if (state === 'killswitch') {
		nodes.push(node(_('blocked'), _('kill switch'), 'wgs-node-block'));
	} else {
		nodes.push(node(_('WAN'), _('direct'), state === 'wan' ? 'wgs-node-active' : ''));
	}

	return E('div', { 'class': 'wgs-chain' }, nodes);
}

function checkLink(c) {
	if (c.category === 'firewall')
		return E('a', { 'class': 'btn cbi-button cbi-button-neutral', 'href': L.url('admin/network/firewall') },
			_('Firewall settings'));
	if (c.category === 'endpoint' && /does not exist|configured but down/.test(c.message || ''))
		return E('a', { 'class': 'btn cbi-button cbi-button-neutral', 'href': L.url('admin/network/network') },
			_('Network interfaces'));
	return null;
}

function statusPanel(wgIfaces) {
	injectStyle();
	var body = E('div', {}, E('em', _('Loading diagnostics…')));
	var liveOn = true;

	function firstRun(d) {
		if ((d.endpoints || []).length) return null;
		var steps = [];
		if (!wgIfaces || !wgIfaces.length) {
			steps.push(E('li', {}, [
				_('Create a WireGuard/AmneziaWG interface under '),
				E('a', { 'href': L.url('admin/network/network') }, _('Network → Interfaces')),
				_(' (wg-split does not manage keys/peers).')
			]));
		} else {
			steps.push(E('li', {}, _('You have %d WireGuard/AmneziaWG interface(s) — good.').format(wgIfaces.length)));
		}
		steps.push(E('li', {}, [
			_('Add it on the '),
			E('a', { 'href': L.url('admin/services/wg-split/settings') }, _('Settings')),
			_(' tab under “Failover tunnels” with a priority, then Save & Apply.')
		]));
		steps.push(E('li', {}, _('Put the tunnel interface in a firewall zone (masq on) and allow forwarding lan → that zone — or use “Fix automatically” on any firewall finding below.')));
		return E('div', { 'class': 'wgs-firstrun' }, [
			E('h4', {}, '👋 ' + _('Let’s get the first tunnel routing')),
			E('p', {}, _('No failover tunnels are configured yet, so all LAN traffic currently exits over plain WAN.')),
			E('ol', {}, steps)
		]);
	}

	// kind -> {icon, color} for the failover timeline (matches journal() kinds).
	var EVK = {
		switch:          { i: '⇄', c: SEV.WARN },
		recover:         { i: '✓', c: SEV.OK },
		restart:         { i: '↻', c: SEV.WARN },
		killswitch:      { i: '⛔', c: SEV.FAIL },
		zapret_fallback: { i: '⚠', c: SEV.FIXABLE },
		wan_fallback:    { i: '✕', c: SEV.FAIL }
	};
	function fmtWhen(ts) {
		var d = (Date.now() / 1000) - ts;
		if (d < 0) d = 0;
		if (d < 60) return Math.round(d) + 's ago';
		if (d < 3600) return Math.round(d / 60) + 'm ago';
		if (d < 86400) return Math.round(d / 3600) + 'h ago';
		return new Date(ts * 1000).toLocaleString();
	}
	function timeline(events) {
		if (!events || !events.length)
			return E('p', { 'style': 'opacity:.7' }, _('No failover events recorded yet.'));
		return E('table', { 'class': 'table' }, events.slice(0, 50).map(function (ev) {
			var k = EVK[ev.kind] || { i: '•', c: '#777' };
			var path = (ev.from && ev.to) ? (ev.from + ' → ' + ev.to) : (ev.to || ev.from || '');
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'style': 'color:' + k.c + ';font-weight:600;white-space:nowrap' }, k.i + ' ' + ev.kind),
				E('td', { 'class': 'td', 'style': 'white-space:nowrap' }, path),
				E('td', { 'class': 'td' }, ev.reason || ''),
				E('td', { 'class': 'td', 'style': 'opacity:.7;white-space:nowrap' }, fmtWhen(ev.ts))
			]);
		}));
	}

	function render(d, events) {
		var now = Date.now();
		// Sample each endpoint's rate ONCE per refresh: ratesFor() advances prevTx as
		// a side effect, so calling it again in the same render (table + chain) would
		// see Δt=0 and report 0. Cache here and reuse for both views.
		var rates = {};
		(d.endpoints || []).forEach(function (e) { rates[e.iface] = ratesFor(e, now); });
		var fr = firstRun(d);

		var epRows = [ E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, _('Endpoint')), E('th', { 'class': 'th' }, _('Prio')),
			E('th', { 'class': 'th' }, _('Last seen')), E('th', { 'class': 'th' }, _('Traffic')),
			E('th', { 'class': 'th' }, _('Health')), E('th', { 'class': 'th' }, _('Zone')),
			E('th', { 'class': 'th' }, _('Masq')), E('th', { 'class': 'th' }, _('LAN fwd'))
		]) ];
		(d.endpoints || []).forEach(function (e) {
			var r = rates[e.iface] || { rx: 0, tx: 0 };
			epRows.push(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, e.present ? e.iface : E('span', { 'style': 'color:' + SEV.FAIL }, e.iface + ' ' + _('(missing)'))),
				E('td', { 'class': 'td' }, e.priority || '—'),
				E('td', { 'class': 'td' }, e.present ? fmtAge(e.handshake_age) : '—'),
				E('td', { 'class': 'td' }, e.present ? rateLabel(r) : '—'),
				E('td', { 'class': 'td' }, healthCell(e.health)),
				E('td', { 'class': 'td' }, e.zone || E('span', { 'style': 'color:' + SEV.FAIL }, _('none'))),
				E('td', { 'class': 'td' }, yn(e.masq)),
				E('td', { 'class': 'td' }, yn(e.forwarding))
			]));
		});

		var listRows = [ E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, _('List')), E('th', { 'class': 'th' }, _('Entries')),
			E('th', { 'class': 'th' }, _('Min')), E('th', { 'class': 'th' }, _('Age')),
			E('th', { 'class': 'th' }, _('State'))
		]) ];
		(d.lists || []).forEach(function (l) {
			listRows.push(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, l.name),
				E('td', { 'class': 'td' }, l.enabled ? l.count : _('(disabled)')),
				E('td', { 'class': 'td' }, l.min),
				E('td', { 'class': 'td' }, fmtAge(l.age)),
				E('td', { 'class': 'td' }, l.enabled ? yn(l.ok) : '—')
			]));
		});

		var checks = (d.checks || []).filter(function (c) { return c.severity !== 'OK'; });
		var checkNodes;
		if (!checks.length) {
			checkNodes = E('p', { 'style': 'color:' + SEV.OK + ';font-weight:600' }, '✓ ' + _('No problems detected.'));
		} else {
			checkNodes = E('div', {}, checks.map(function (c) {
				var link = checkLink(c);
				var extra = fixButton(c);
				return E('div', { 'class': 'wgs-check', 'style': 'border-left-color:' + (SEV[c.severity] || '#777') }, [
					badge(c.severity),
					E('div', { 'class': 'wgs-check-body' }, [
						E('div', {}, c.message),
						c.fix ? E('div', { 'class': 'wgs-check-fix' }, '→ ' + c.fix) : ''
					]),
					extra || '',
					link || ''
				]);
			}));
		}

		body.replaceChildren(
			heroCard(d),
			fr || '',
			chainViz(d, rates),
			E('h4', _('Failover tunnels')), E('table', { 'class': 'table' }, epRows),
			E('h4', _('Lists')), E('table', { 'class': 'table' }, listRows),
			E('h4', _('Diagnostics')), checkNodes,
			E('h4', _('Recent failover events')), timeline(events)
		);
	}

	// A "Fix automatically" button on firewall findings — runs wg-split-firewall
	// for the named endpoint (design §4.2). The iface is parsed from the message
	// ("<iface>: …") which doctor always emits for firewall checks.
	function fixButton(c) {
		if (c.category !== 'firewall') return null;
		// Some firewall findings are NOT auto-fixable: a shared WAN/LAN zone, or an
			// iface already covered by a device-wildcard zone — wg-split-firewall refuses
			// both. Don't offer a button that can only fail; the "Firewall settings" link
			// guides manual remediation instead.
			if (/in the shared |device wildcard|non-tunnel networks/.test(c.message || '')) return null;
			var m = /^([A-Za-z0-9_.-]+):/.exec(c.message || '');
		if (!m) return null;
		var iface = m[1];
		return E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(this, function () {
				if (!confirm(_('Create/repair the firewall zone for “%s” (accept-all + masquerading + lan↔tunnel↔wan forwarding) and reload the firewall?').format(iface)))
					return;
				return callAction('fw_fix', iface).then(function (res) {
					res = res || {};
					ui.addNotification(null, E('p', (res.code === 0 ? _('Firewall fixed for %s') : _('Firewall fix failed for %s')).format(iface) + (res.stdout ? ': ' + res.stdout : '')), (res.code === 0 ? 'info' : 'warning'));
					return refresh();
				}).catch(function (e) {
					ui.addNotification(null, E('p', _('Firewall fix failed: ') + e), 'error');
				});
			})
		}, _('Fix automatically'));
	}

	function refresh() {
		return Promise.all([
			callStatus(),
			L.resolveDefault(callEvents(), { events: [] })
		]).then(function (res) {
			var d = res[0] || {};
			var events = (res[1] && res[1].events) || [];
			if (!d || !d.summary) {
				body.replaceChildren(E('em', { 'style': 'color:' + SEV.FAIL },
					_('Diagnostics unavailable (is the wg-split service installed and running?)')));
				return;
			}
			render(d, events);
		}).catch(function (e) {
			body.replaceChildren(E('em', { 'style': 'color:' + SEV.FAIL }, _('Diagnostics failed: ') + e));
		});
	}

	// Run one allow-listed maintenance action over ubus, toast the result, refresh.
	function actionBtn(label, cls, actionName, confirmMsg, toast) {
		return E('button', {
			'class': 'btn cbi-button ' + cls,
			'click': ui.createHandlerFn(this, function () {
				if (confirmMsg && !confirm(confirmMsg)) return;
				return callAction(actionName, '').then(function (res) {
					res = res || {};
					ui.addNotification(null, E('p', (toast || label) + (res.code !== 0 && res.stdout ? ': ' + res.stdout : '')), (res.code === 0 ? 'info' : 'warning'));
					return refresh();
				}).catch(function (e) {
					ui.addNotification(null, E('p', label + ': ' + e), 'error');
				});
			})
		}, label);
	}

	var POLL_S = 8;
	var liveLabel = E('span', {}, _('Live'));
	var liveDot = E('span', { 'class': 'wgs-dot' });
	function setLive(on) {
		liveOn = on;
		liveDot.className = 'wgs-dot' + (on ? '' : ' wgs-dot-off');
		liveLabel.textContent = on ? _('Live (every %ds)').format(POLL_S) : _('Paused');
		if (on) { poll.add(refresh, POLL_S); poll.start(); } else poll.remove(refresh);
	}
	var liveToggle = E('span', {
		'class': 'wgs-live', 'style': 'cursor:pointer',
		'click': function () { setLive(!liveOn); }
	}, [ liveDot, liveLabel ]);

	var diagBtn = E('button', {
		'class': 'btn cbi-button cbi-button-action',
		'click': ui.createHandlerFn(this, function () { return refresh(); })
	}, _('Refresh now'));

	var actions = E('div', { 'class': 'wgs-toolbar' }, [
		diagBtn,
		actionBtn(_('Apply'), 'cbi-button-apply', 'apply', null, _('Configuration applied')),
		actionBtn(_('Restart service'), 'cbi-button-reset', 'restart', null, _('Service restarted')),
		actionBtn(_('Refresh ipsum'), 'cbi-button-neutral', 'update_ipsum', null, _('ipsum refreshed')),
		actionBtn(_('Refresh ru/cn'), 'cbi-button-neutral', 'update_ru', null, _('ru/cn refreshed')),
		actionBtn(_('Refresh domains'), 'cbi-button-neutral', 'update_domains', null, _('domains refreshed')),
		actionBtn(_('Emergency disable'), 'cbi-button-remove', 'disable',
			_('Disable split routing now? All LAN traffic will exit via WAN until the service re-enables it (or you stop it).'),
			_('Split routing disabled')),
		E('span', { 'class': 'wgs-spacer' }),
		liveToggle
	]);

	refresh();
	setLive(true);

	return E('div', { 'class': 'cbi-section' }, [
		E('h3', _('Status & diagnostics')),
		actions,
		body
	]);
}

return view.extend({
	load: function () {
		return network.getNetworks();
	},

	render: function (networks) {
		var wgIfaces = (networks || []).filter(function (n) {
			var p = n.getProtocol();
			return p === 'amneziawg' || p === 'wireguard';
		}).map(function (n) { return n.getName(); });

		return statusPanel(wgIfaces);
	},

	// status-only view: no Save/Reset footer
	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
