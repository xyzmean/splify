'use strict';
'require view';
'require rpc';
'require ui';

// Reference/template copy of the shipped host view (the packaged one lives at
// htdocs/luci-static/resources/view/splify/home.js). Keep them in sync.
return view.extend({
	render: function () {
		window.luci_rpc = rpc;
		window.ui = ui;

		// Stylesheet: inject once with a STABLE href. A per-visit ?v=Date.now()
		// re-parses the sheet on every navigation for no benefit.
		if (!document.getElementById('splify-app-css')) {
			var link = document.createElement('link');
			link.id = 'splify-app-css';
			link.rel = 'stylesheet';
			link.href = L.resource('splify/splify-index.css');
			document.head.appendChild(link);
		}

		var container = E('div', { id: 'splify-root', 'class': 'splify-react-root' });

		// Load the React module ONCE with a stable URL. A unique ?v= URL per visit
		// is a fresh ES module the browser's registry never frees, leaking the
		// whole React bundle each navigation until the tab froze. The module
		// registers window.__splifyMount; later visits just re-mount.
		if (window.__splifyMount) {
			window.__splifyMount(container);
		} else if (!document.getElementById('splify-app-js')) {
			var script = document.createElement('script');
			script.id = 'splify-app-js';
			script.src = L.resource('splify/splify-index.js');
			script.type = 'module';
			document.head.appendChild(script);
		}

		return container;
	},
	handleSave: null, handleSaveApply: null, handleReset: null
});
