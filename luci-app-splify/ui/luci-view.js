'use strict';
'require view';
'require rpc';

return view.extend({
	render: function () {
		// Expose LuCI modules to React
		window.luci_rpc = rpc;

		// 1. Inject React App CSS
		if (!document.getElementById('splify-app-css')) {
			var link = document.createElement('link');
			link.id = 'splify-app-css';
			link.rel = 'stylesheet';
			link.href = L.resource('splify/splify-index.css') + '?v=' + Date.now();
			document.head.appendChild(link);
		} else {
            var oldLink = document.getElementById('splify-app-css');
			oldLink.parentNode.removeChild(oldLink);
			var newLink = document.createElement('link');
			newLink.id = 'splify-app-css';
			newLink.rel = 'stylesheet';
			newLink.href = L.resource('splify/splify-index.css') + '?v=' + Date.now();
			document.head.appendChild(newLink);
        }

		// 2. Create Root Div
		var container = E('div', { id: 'splify-root', 'class': 'splify-react-root' });

		// 3. Inject React App JS
		if (!document.getElementById('splify-app-js')) {
			var script = document.createElement('script');
			script.id = 'splify-app-js';
			script.src = L.resource('splify/splify-index.js') + '?v=' + Date.now();
			script.type = 'module';
			document.head.appendChild(script);
		} else {
			// If already loaded, we might need to trigger a re-mount event
			// But for now, we just rely on Vite's module execution.
			// Actually, LuCI re-renders the whole view when navigating back, 
			// so the script might not re-execute. Let's force re-evaluation:
			var oldScript = document.getElementById('splify-app-js');
			oldScript.parentNode.removeChild(oldScript);
			var newScript = document.createElement('script');
			newScript.id = 'splify-app-js';
			newScript.src = L.resource('splify/splify-index.js') + '?v=' + Date.now();
			newScript.type = 'module';
			document.head.appendChild(newScript);
		}

		return container;
	},
	handleSave: null, handleSaveApply: null, handleReset: null
});
