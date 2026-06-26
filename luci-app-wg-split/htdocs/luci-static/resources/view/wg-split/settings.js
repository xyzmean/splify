'use strict';
'require view';
'require form';
'require network';

// wg-split 2.0 settings form. Status/diagnostics moved to the sibling dashboard
// (view/wg-split/status.js); this view is just the UCI form.Map.

// Defensively pull IPv4 host hints (DHCP leases / neighbours) into a datalist for
// the per-device override IP, so operators pick a known host instead of typing.
// Shape-tolerant: any unexpected hint structure simply yields an empty list
// rather than breaking the form.
function ipHints(hints) {
	var out = [];
	if (!hints || typeof hints !== 'object') return out;
	var obj = (hints.hosts && typeof hints.hosts === 'object') ? hints.hosts : hints;
	Object.keys(obj).forEach(function (mac) {
		var h = obj[mac] || {}, ips = [];
		if (typeof h.ipv4 === 'string') ips.push(h.ipv4);
		if (Array.isArray(h.ipaddrs)) ips = ips.concat(h.ipaddrs);
		if (Array.isArray(h.ipv4addrs)) ips = ips.concat(h.ipv4addrs);
		ips.forEach(function (ip) {
			if (typeof ip === 'string' && /^\d+\.\d+\.\d+\.\d+/.test(ip)) {
				var bare = ip.split('/')[0];
				out.push([ bare, h.name ? (h.name + ' (' + bare + ')') : bare ]);
			}
		});
	});
	return out;
}

return view.extend({
	load: function () {
		return Promise.all([
			network.getNetworks(),
			L.resolveDefault(network.getHostHints(), {})
		]);
	},

	render: function (data) {
		var networks = data[0] || [];
		var hostHints = data[1] || {};
		var wgIfaces = networks.filter(function (n) {
			var p = n.getProtocol();
			return p === 'amneziawg' || p === 'wireguard';
		}).map(function (n) { return n.getName(); });

		var m, s, o;

		m = new form.Map('wg-split', _('wg-split'),
			_('Local split-tunnel: policy-route LAN traffic over priority-ordered ' +
			  'WireGuard/AmneziaWG tunnels, with downloaded IP/domain lists and optional ' +
			  'zapret DPI-bypass. Create the tunnel interfaces normally under ' +
			  'Network → Interfaces, then list them below by priority. See the Status tab ' +
			  'for live diagnostics.'));

		// ---- global options, grouped into native LuCI tabs ----
		s = m.section(form.NamedSection, 'global', 'wg-split');
		s.addremove = false;
		s.tab('general', _('General'));
		s.tab('lists',   _('Lists'));
		s.tab('manual',  _('Manual entries'));

		o = s.taboption('general', form.ListValue, 'mode', _('Routing mode'));
		o.value('blocklist', _('blocklist — only listed/ipsum IPs ride the VPN'));
		o.value('full', _('full — default via VPN, direct list = exceptions'));
		o.value('split', _('split — only explicit VPN lists ride the VPN'));
		o.default = 'blocklist';

		o = s.taboption('general', form.Value, 'interval', _('Failover interval'),
			_('Seconds between health/failover checks.'));
		o.datatype = 'uinteger';
		o.placeholder = '180';

		o = s.taboption('general', form.Flag, 'killswitch', _('Kill switch'),
			_('Drop policy-VPN traffic when every tunnel is down instead of leaking to WAN.'));

		o = s.taboption('general', form.Value, 'lan_iface', _('LAN interface'));
		o.placeholder = 'br-lan';
		o = s.taboption('general', form.Value, 'lan_cidr', _('LAN subnet (CIDR)'));
		o.datatype = 'cidr4';
		o.placeholder = '192.168.1.0/24';

		o = s.taboption('general', form.DynamicList, 'health_target', _('Health ping targets'),
			_('Pinged through each tunnel to test it (any reply = healthy).'));
		o.datatype = 'ipaddr';
		o = s.taboption('general', form.Value, 'health_url', _('WAN health URL'),
			_('curled over WAN to decide the zapret vs plain-WAN fallback rung.'));
		o.placeholder = 'https://1.1.1.1/cdn-cgi/trace';

		o = s.taboption('lists', form.Flag, 'ipsum_enabled', _('Enable ipsum (VPN IP list)'));
		o.default = '1';
		o = s.taboption('lists', form.Value, 'ipsum_url', _('ipsum list URL'));
		o.depends('ipsum_enabled', '1');

		o = s.taboption('lists', form.Flag, 'ru_enabled', _('Enable ru/cn direct list'));
		o.default = '1';
		o = s.taboption('lists', form.Value, 'ru_url', _('ru/cn list URL'));
		o.depends('ru_enabled', '1');

		o = s.taboption('lists', form.Value, 'vpn_domains_url', _('VPN domains list URL'),
			_('Downloaded domains tagged to the VPN at dnsmasq resolve time.'));
		o = s.taboption('lists', form.Value, 'ignore_domains_url', _('Ignore/direct domains list URL'));

		o = s.taboption('lists', form.Flag, 'zapret_enabled', _('Use zapret DPI-bypass'),
			_('Auto-skipped if zapret is not installed.'));
		o.default = '1';

		o = s.taboption('manual', form.DynamicList, 'vpn_cidr', _('VPN subnets'),
			_('Remote subnets that must ride the tunnel — typically a peer router’s LAN ' +
			  'for site-to-site (e.g. 10.8.2.0/24). The Status tab flags any that are not ' +
			  'actually routed into the tunnel.'));
		o.datatype = 'cidr4';
		o = s.taboption('manual', form.DynamicList, 'direct_cidr', _('Direct subnets'),
			_('Subnets kept off the tunnel (always exit via WAN).'));
		o.datatype = 'cidr4';
		o = s.taboption('manual', form.DynamicList, 'vpn_domain', _('VPN domains'));
		o = s.taboption('manual', form.DynamicList, 'direct_domain', _('Direct domains'));

		// ---- failover tunnels ----
		s = m.section(form.GridSection, 'endpoint', _('Failover tunnels'),
			_('Lowest priority number wins. Pick interfaces you created under ' +
			  'Network → Interfaces.'));
		s.addremove = true;
		s.anonymous = true;
		s.sortable = true;

		o = s.option(form.ListValue, 'iface', _('Interface'));
		if (wgIfaces.length) {
			wgIfaces.forEach(function (i) { o.value(i); });
		} else {
			o.value('', _('(no wireguard/amneziawg interfaces found)'));
		}

		o = s.option(form.Value, 'priority', _('Priority'));
		o.datatype = 'uinteger';
		o.placeholder = '1';

		// Transport type seam (design §2.2): only `wg` is implemented in 2.0.0; a
		// future sing-box (vless/hysteria) backend adds choices here. Kept as a
		// defaulted, read-mostly field so the config carries an explicit type.
		o = s.option(form.ListValue, 'type', _('Type'));
		o.value('wg', _('WireGuard / AmneziaWG'));
		o.default = 'wg';
		o.modalonly = true;

		// ---- per-device overrides ----
		s = m.section(form.GridSection, 'device', _('Per-device overrides'),
			_('Pin a LAN host to vpn or direct by its IP.'));
		s.addremove = true;
		s.anonymous = true;

		o = s.option(form.Value, 'ip', _('Device IP'));
		o.datatype = 'ip4addr';
		ipHints(hostHints).forEach(function (p) { o.value(p[0], p[1]); });
		o = s.option(form.ListValue, 'mode', _('Route via'));
		o.value('vpn', _('VPN'));
		o.value('direct', _('Direct'));

		return m.render();
	}
});
