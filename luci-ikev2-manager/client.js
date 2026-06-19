'use strict';
'require view';
'require fs';
'require ui';
'require ikev2-manager.shared as common';

var helper = '/usr/libexec/ikev2-manager';

function input(type, value, attrs) {
	return E('input', Object.assign({
		'type': type,
		'class': type === 'checkbox' ? 'cbi-input-checkbox' : 'cbi-input-text',
		'value': type === 'checkbox' ? null : (value || ''),
		'checked': type === 'checkbox' && value === '1' ? '' : null
	}, attrs || {}));
}

function findOutbound(sas) {
	for (var i = 0; i < sas.length; i++) {
		if (sas[i]['proxy-out'])
			return sas[i]['proxy-out'];
	}
	return null;
}

function encodeBase64(value) {
	return window.btoa(unescape(encodeURIComponent(value)));
}

function runManagerJob(button, result, args, busy, success, failure, timeout, onSuccess) {
	return common.runJob({
		button: button,
		result: result,
		busy: busy,
		success: success,
		failure: failure,
		startPath: helper,
		startArgs: args,
		statusPath: helper,
		statusArgs: [ 'action-status' ],
		timeout: timeout || 120000,
		allowImmediate: true,
		timeoutMessage: _('The operation continues in the background. You can use the button again.'),
		onSuccess: onSuccess
	});
}

return view.extend({
	load: function() {
		return L.resolveDefault(fs.stat('/usr/sbin/swanmon'), null).then(function(ready) {
			if (!ready)
				return { ready: false };
			return Promise.all([
				fs.exec(helper, [ 'client-get' ]),
				L.resolveDefault(fs.exec('/usr/sbin/swanmon', [ 'list-sas' ]), { stdout: '' }),
				fs.exec(helper, [ 'advanced-mode', 'outbound' ]),
				fs.exec(helper, [ 'advanced-read', 'outbound' ])
			]).then(function(d) { d.ready = true; return d; });
		});
	},

	render: function(data) {
		if (!data.ready)
			return E([ common.styles(), common.gate(_('Outbound IKEv2 Tunnel'),
				_('The router uses this IPv4 IKEv2 tunnel for domains and devices selected on the Policy Routing page.')) ]);
		var value = common.parseKeyValues(data[0].stdout);
		var customMode = (data[2].stdout || '').trim() === '1';
		var outbound = findOutbound(common.parseSwanmon(data[1]));
		var child = outbound && Object.values(outbound['child-sas'] || {})
			.find(function(item) { return item.name === 'proxy4'; });
		var statusPill = common.pill('', 'neutral');

		function updateStatusPill() {
			common.setPill(statusPill,
				customMode ? _('Custom config') : (child ? _('Connected') : _('Disconnected')),
				customMode ? 'warn' : (child ? 'good' : 'bad'));
		}

		function refreshClientState() {
			return Promise.all([
				L.resolveDefault(fs.exec(helper, [ 'client-get' ]), { stdout: '' }),
				L.resolveDefault(fs.exec('/usr/sbin/swanmon', [ 'list-sas' ]), { stdout: '' })
			]).then(function(results) {
				value = common.parseKeyValues(results[0].stdout || '');
				outbound = findOutbound(common.parseSwanmon(results[1]));
				child = outbound && Object.values(outbound['child-sas'] || {})
					.find(function(item) { return item.name === 'proxy4'; });
				updateStatusPill();
			});
		}
		updateStatusPill();
		var enabled = input('checkbox', value.enabled);
		var address = input('text', value.remote_address, {
			'placeholder': _('IPv4 address or hostname')
		});
		var remoteId = input('text', value.remote_id);
		var username = input('text', value.username, { 'autocomplete': 'off' });
		var password = input('text', '', {
			'placeholder': _('Leave blank to keep the current password'),
			'autocomplete': 'off'
		});
		var dpd = input('number', value.dpd, { 'min': '10', 'max': '300' });
		var mtu = input('number', value.mtu, { 'min': '1280', 'max': '1500' });
		var save = E('button', { 'class': 'cbi-button cbi-button-apply' }, [
			_('Save and connect')
		]);
		var saveOnly = E('button', { 'class': 'cbi-button' }, [
			_('Save')
		]);
		var reconnect = E('button', { 'class': 'cbi-button cbi-button-neutral' }, [
			_('Reconnect')
		]);
		var connectResult = common.inlineResult();
		var rawResult = common.inlineResult();
		var rawToggle = E('button', { 'class': 'cbi-button' }, [ _('Edit raw config') ]);
		var rawText = E('textarea', { 'class': 'ikev2-domain-editor' }, [
			data[3].stdout || ''
		]);
		var rawSave = E('button', { 'class': 'cbi-button cbi-button-apply' }, [
			_('Save custom config')
		]);
		var rawReset = E('button', { 'class': 'cbi-button cbi-button-reset' }, [
			_('Reset to generated')
		]);
		var rawPanel = E('div', {
			'style': 'display:none;margin-top:1rem'
		}, [
			E('div', { 'class': 'ikev2-note warn' }, [
				_('Custom mode replaces the generated outbound connection. Credentials remain managed separately by the EAP fields above.')
			]),
			rawText,
			E('div', { 'class': 'ikev2-actions end', 'style': 'margin-top:.7rem' }, [
				rawResult.node,
				rawReset,
				rawSave
			])
		]);

		rawToggle.addEventListener('click', function() {
			rawPanel.style.display = rawPanel.style.display === 'none' ? '' : 'none';
		});

		rawSave.addEventListener('click', function() {
			return runManagerJob(rawSave, rawResult,
				[ 'advanced-start', 'outbound', encodeBase64(rawText.value) ],
				_('Validating and reconnecting...'), _('Loaded'),
				_('Custom configuration was rejected'), 120000, function(st) {
					if (st && st.state !== 'timeout') {
						customMode = true;
						return refreshClientState();
					}
				});
		});

		rawReset.addEventListener('click', function() {
			return runManagerJob(rawReset, rawResult,
				[ 'advanced-reset-start', 'outbound' ],
				_('Restoring and reconnecting...'), _('Restored'), _('Reset failed'), 120000,
				function(st) {
					if (st && st.state !== 'timeout') {
						customMode = false;
						return refreshClientState();
					}
				});
		});

		function collectArgs(cmd) {
			var args = [
				cmd,
				enabled.checked ? '1' : '0',
				address.value.trim(),
				remoteId.value.trim(),
				username.value.trim(),
				dpd.value,
				mtu.value
			];
			if (password.value)
				args.push(password.value);
			return args;
		}

		saveOnly.addEventListener('click', function() {
			return runManagerJob(saveOnly, connectResult, collectArgs('client-save'),
				_('Saving...'), _('Saved'), _('Save failed'), 120000, refreshClientState);
		});

		save.addEventListener('click', function() {
			return runManagerJob(save, connectResult, collectArgs('client-set'),
				enabled.checked ? _('Saving and connecting...') : _('Saving and stopping...'),
				enabled.checked ? _('Saved and connected') : _('Saved and disabled'),
				_('Apply failed'), 150000, refreshClientState);
		});

		// Reconnect the existing tunnel without changing saved settings.
		reconnect.addEventListener('click', function() {
			return runManagerJob(reconnect, connectResult, [ 'reconnect-client' ],
				_('Reconnecting...'), _('Reconnected'), _('Reconnect failed'), 90000,
				refreshClientState);
		});

		var traffic = child ? _('Down %s, up %s').format(
			common.formatBytes(child['bytes-in']),
			common.formatBytes(child['bytes-out'])) : _('No active traffic SA');

		return E([
			common.styles(),
			E('div', { 'class': 'ikev2-page' }, [
				common.header(_('Outbound IKEv2 Tunnel'),
					_('The router uses this IPv4 IKEv2 tunnel for domains and devices selected on the Policy Routing page.'),
					statusPill),
				E('div', { 'class': 'ikev2-grid' }, [
					common.card(_('Remote gateway'),
						outbound ? outbound['remote-host'] : (value.remote_address || '-'),
						outbound ? outbound['remote-id'] : value.remote_id, 'third'),
					common.card(_('Virtual IPv4'),
						outbound && (outbound['local-vips'] || [])[0] || '-',
						child ? common.formatDuration(child['install-time']) + ' ' + _('online') : '', 'third'),
					common.card(_('Current session traffic'),
						child ? common.formatBytes(
							Number(child['bytes-in'] || 0) + Number(child['bytes-out'] || 0)) : '0 B',
						traffic, 'third')
				]),
				common.section(_('Connection'),
					_('Changing these values reloads the tunnel profile and reconnects it. The PBR policy remains loaded.'),
					E('div', {}, [
						E('div', { 'class': 'ikev2-form-grid' }, [
							common.fieldLabel(_('Enable client')),
							common.switchLabel(enabled),
							common.fieldLabel(_('Remote address'),
								_('IPv4 address or hostname of the IKEv2 gateway.')),
							address,
							common.fieldLabel(_('Remote identity'),
								_('Certificate identity expected from the VPS.')),
							remoteId,
							common.fieldLabel(_('EAP username')),
							username,
							common.fieldLabel(_('New EAP password'),
								_('Visible while editing; leave blank to preserve the saved secret.')),
							password
						]),
						E('details', { 'class': 'ikev2-advanced' }, [
							E('summary', {}, [ _('Advanced connectivity') ]),
							E('div', { 'class': 'ikev2-form-grid' }, [
								common.fieldLabel(_('DPD interval'),
									_('Dead peer detection in seconds.')),
								dpd,
								common.fieldLabel(_('XFRM MTU'),
									_('Keep 1400 unless PMTU diagnostics show a problem.')),
								mtu
							])
						]),
						E('div', { 'class': 'ikev2-actions bar' }, [ connectResult.node, reconnect, saveOnly, save ])
					])),
				common.section(_('Advanced strongSwan configuration'),
					_('Inspect the generated swanctl connection or replace it with a manually maintained profile.'),
					E('div', {}, [
						rawPanel,
						E('div', { 'class': 'ikev2-actions end', 'style': 'margin-top:1rem' }, [ rawToggle ])
					]),
					customMode ? common.pill(_('Override active'), 'warn') :
						common.pill(_('Generated'), 'good')),
				E('div', { 'class': 'ikev2-note warn' }, [
					_('Disabling this client intentionally blocks selected domains. The kill-switch does not fall back to the home WAN.')
				])
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
