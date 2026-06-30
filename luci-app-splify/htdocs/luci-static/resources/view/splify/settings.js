'use strict';
'require view';
'require rpc';
'require ui';
'require uci';
'require network';

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

		// 1. Inject React App CSS
		if (!document.getElementById('splify-settings-css')) {
			var link = document.createElement('link');
			link.id = 'splify-settings-css';
			link.rel = 'stylesheet';
			link.href = L.resource('splify/splify-index.css') + '?v=' + Date.now();
			document.head.appendChild(link);
		} else {
			var oldLink = document.getElementById('splify-settings-css');
			oldLink.parentNode.removeChild(oldLink);
			var newLink = document.createElement('link');
			newLink.id = 'splify-settings-css';
			newLink.rel = 'stylesheet';
			newLink.href = L.resource('splify/splify-index.css') + '?v=' + Date.now();
			document.head.appendChild(newLink);
		}

		// 2. Create Root Div
		var container = E('div', { id: 'splify-root', 'class': 'splify-react-root' });

		// 3. Inject React App JS
		if (!document.getElementById('splify-settings-js')) {
			var script = document.createElement('script');
			script.id = 'splify-settings-js';
			script.src = L.resource('splify/splify-settings.js') + '?v=' + Date.now();
			script.type = 'module';
			document.head.appendChild(script);
		} else {
			// LuCI re-renders the whole view when navigating back without
			// re-fetching the module, so force re-evaluation (same approach
			// as home.js).
			var oldScript = document.getElementById('splify-settings-js');
			oldScript.parentNode.removeChild(oldScript);
			var newScript = document.createElement('script');
			newScript.id = 'splify-settings-js';
			newScript.src = L.resource('splify/splify-settings.js') + '?v=' + Date.now();
			newScript.type = 'module';
			document.head.appendChild(newScript);
		}

		return container;
	},
	handleSave: null, handleSaveApply: null, handleReset: null
});
