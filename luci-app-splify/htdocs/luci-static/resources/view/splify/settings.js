'use strict';
'require view';
'require rpc';
'require ui';
'require uci';
'require network';

// Cache-buster for the bundled assets — see the note in home.js. Bump together
// with the VERSION file.
var ASSET_V = '?v=0.2.1';

return view.extend({
	load: function () {
		return Promise.all([
			uci.load('splify'),
			L.resolveDefault(rpc.declare({ object: 'luci-rpc', method: 'getHostHints' })(), {})
		]);
	},
	render: function (data) {
		// Expose LuCI modules to React the same way home.js does for the
		// dashboard bundle, plus uci/network for reading & writing config and
		// the host-hints snapshot for the device-rules IP suggestions.
		window.luci_rpc = rpc;
		window.luci_uci = uci;
		window.luci_network = network;
		window.ui = ui;
		window.__splifyHostHints = data[1] || {};

		// Stylesheet: inject once with a stable href (see home.js for why the old
		// per-visit ?v=Date.now() was dropped).
		if (!document.getElementById('splify-settings-css')) {
			var link = document.createElement('link');
			link.id = 'splify-settings-css';
			link.rel = 'stylesheet';
			link.href = L.resource('splify/splify-index.css') + ASSET_V;
			document.head.appendChild(link);
		}

		var container = E('div', { id: 'splify-root', 'class': 'splify-react-root' });

		// Load the settings module ONCE with a stable URL; re-mount on later visits
		// via the global it registers. The old code re-injected a cache-busted
		// <script> on every navigation, permanently leaking a module each time
		// (see the detailed note in home.js).
		if (window.__splifySettingsMount) {
			window.__splifySettingsMount(container);
		} else if (!document.getElementById('splify-settings-js')) {
			var script = document.createElement('script');
			script.id = 'splify-settings-js';
			script.src = L.resource('splify/splify-settings.js') + ASSET_V;
			script.type = 'module';
			document.head.appendChild(script);
		}

		return container;
	},
	handleSave: null, handleSaveApply: null, handleReset: null
});
