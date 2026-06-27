'use strict';
'require view';
'require network';
'require splify.dashboard as dashboard';

// Thin wrapper: the full live dashboard now lives in the shared splify.dashboard
// module (also embedded under "Подробное состояние" on the Главная view).
return view.extend({
	load: function () { return network.getNetworks(); },
	render: function (networks) {
		var wgIfaces = (networks || []).filter(function (n) {
			var p = n.getProtocol();
			return p === 'amneziawg' || p === 'wireguard';
		}).map(function (n) { return n.getName(); });
		return dashboard.buildPanel(wgIfaces);
	},
	handleSave: null, handleSaveApply: null, handleReset: null
});
