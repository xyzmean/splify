'use strict';
'require view';
'require rpc';
'require ui';
'require uci';
'require network';

// STABLE loader shim — see the detailed note in main.js: no baked-in version,
// the current build id is fetched with cache:'no-store' so a browser-cached
// copy of THIS file still loads the newest bundles after every release.

function fetchBuildId() {
	return fetch(L.resource('splify/build-id.txt'), { cache: 'no-store' })
		.then(function (r) { return r.ok ? r.text() : ''; })
		.then(function (t) { return (t || '').trim(); })
		.catch(function () { return ''; });
}

return view.extend({
	load: function () {
		return Promise.all([
			uci.load('splify'),
			L.resolveDefault(rpc.declare({ object: 'luci-rpc', method: 'getHostHints' })(), {}),
			fetchBuildId()
		]);
	},
	render: function (data) {
		var v = '?v=' + (data[2] || Date.now());

		// Expose LuCI modules to React the same way main.js does for the
		// dashboard bundle, plus uci/network for reading & writing config and
		// the host-hints snapshot for the device-rules IP suggestions.
		window.luci_rpc = rpc;
		window.luci_uci = uci;
		window.luci_network = network;
		window.ui = ui;
		window.__splifyHostHints = data[1] || {};

		// Stylesheet: inject once with an href that is stable within a release.
		if (!document.getElementById('splify-settings-css')) {
			var link = document.createElement('link');
			link.id = 'splify-settings-css';
			link.rel = 'stylesheet';
			link.href = L.resource('splify/splify-index.css') + v;
			document.head.appendChild(link);
		}

		var container = E('div', { id: 'splify-root', 'class': 'splify-react-root' });

		// Load the settings module ONCE per document; re-mount on later visits
		// via the global it registers (no per-visit module leak — see main.js).
		if (window.__splifySettingsMount) {
			window.__splifySettingsMount(container);
		} else if (!document.getElementById('splify-settings-js')) {
			var script = document.createElement('script');
			script.id = 'splify-settings-js';
			script.src = L.resource('splify/splify-settings.js') + v;
			script.type = 'module';
			document.head.appendChild(script);
		}

		return container;
	},
	handleSave: null, handleSaveApply: null, handleReset: null
});
