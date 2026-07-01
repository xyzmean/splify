'use strict';
'require view';
'require rpc';
'require ui';

// Cache-buster for the bundled assets: L.resource() returns a bare URL (LuCI
// versions only its own require()-loaded views), so without a query string the
// browser heuristic-caches the bundle and can keep serving a stale copy after
// an upgrade. Stable within a release — bump together with the VERSION file.
var ASSET_V = '?v=0.2.1';

return view.extend({
	render: function () {
		// Expose LuCI modules to React (rpc bridge + ui for toast notifications;
		// L is already a global). The React bundle reads window.luci_rpc / window.ui.
		window.luci_rpc = rpc;
		window.ui = ui;

		// Stylesheet: inject once with an href that is stable within a release.
		// A per-visit ?v=Date.now() forced the browser to re-parse the sheet on
		// every navigation for no benefit.
		if (!document.getElementById('splify-app-css')) {
			var link = document.createElement('link');
			link.id = 'splify-app-css';
			link.rel = 'stylesheet';
			link.href = L.resource('splify/splify-index.css') + ASSET_V;
			document.head.appendChild(link);
		}

		// Root the React app mounts into.
		var container = E('div', { id: 'splify-root', 'class': 'splify-react-root' });

		// Load the React module ONCE, with a URL that is stable within a release.
		// The previous code appended ?v=Date.now() and re-injected the <script> on
		// every visit; each unique URL is a fresh ES module that the browser's
		// module registry keeps for the document's lifetime, so revisiting the
		// dashboard leaked a whole React bundle each time until the tab froze.
		// Now the module self-registers window.__splifyMount on first load; later
		// visits just re-mount into the new container without re-evaluating it.
		if (window.__splifyMount) {
			window.__splifyMount(container);
		} else if (!document.getElementById('splify-app-js')) {
			var script = document.createElement('script');
			script.id = 'splify-app-js';
			script.src = L.resource('splify/splify-index.js') + ASSET_V;
			script.type = 'module';
			document.head.appendChild(script);
		}

		return container;
	},
	handleSave: null, handleSaveApply: null, handleReset: null
});
