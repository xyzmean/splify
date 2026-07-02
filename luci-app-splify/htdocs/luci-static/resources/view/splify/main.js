'use strict';
'require view';
'require rpc';
'require ui';

// STABLE loader shim — deliberately version-agnostic, must never need to change
// between releases. LuCI serves this file as home?v=<LuCI revision>, which only
// changes when luci-base itself is upgraded, so browsers cache it for a long
// time (this is exactly how stale UIs survived upgrades and even reboots).
// Instead of baking an asset version in here, the CURRENT build id is fetched
// at page load with cache:'no-store' (a ~10-byte request that bypasses the HTTP
// cache) and appended to the bundle URLs — every release ships a new build id,
// so new bundles are picked up even by clients holding this shim from cache.

function fetchBuildId() {
	return fetch(L.resource('splify/build-id.txt'), { cache: 'no-store' })
		.then(function (r) { return r.ok ? r.text() : ''; })
		.then(function (t) { return (t || '').trim(); })
		.catch(function () { return ''; });
}

return view.extend({
	load: function () {
		return fetchBuildId();
	},
	render: function (buildId) {
		// A missing build id (older package without the file) degrades to a
		// per-visit buster — correctness over cacheability.
		var v = '?v=' + (buildId || Date.now());

		// Expose LuCI modules to React (rpc bridge + ui for toast notifications;
		// L is already a global). The React bundle reads window.luci_rpc / window.ui.
		window.luci_rpc = rpc;
		window.ui = ui;

		// Stylesheet: inject once with an href that is stable within a release.
		if (!document.getElementById('splify-app-css')) {
			var link = document.createElement('link');
			link.id = 'splify-app-css';
			link.rel = 'stylesheet';
			link.href = L.resource('splify/splify-index.css') + v;
			document.head.appendChild(link);
		}

		// Root the React app mounts into.
		var container = E('div', { id: 'splify-root', 'class': 'splify-react-root' });

		// Load the React module ONCE per document. Each unique URL is a fresh ES
		// module kept for the document's lifetime, so the bundle self-registers
		// window.__splifyMount on first load and later visits just re-mount into
		// the new container without re-evaluating it (no per-visit module leak).
		if (window.__splifyMount) {
			window.__splifyMount(container);
		} else if (!document.getElementById('splify-app-js')) {
			var script = document.createElement('script');
			script.id = 'splify-app-js';
			script.src = L.resource('splify/splify-index.js') + v;
			script.type = 'module';
			document.head.appendChild(script);
		}

		return container;
	},
	handleSave: null, handleSaveApply: null, handleReset: null
});
