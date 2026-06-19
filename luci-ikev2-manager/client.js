'use strict';
'require view';
'require fs';
'require ui';
'require ikev2-manager.shared as common';

var helper = '/usr/libexec/ikev2-manager';
var systemHelper = '/usr/libexec/ikev2-manager-system';

var dnsProtocols = [
	{ id: 'udp', label: 'DNS over UDP' },
	{ id: 'tcp', label: 'DNS over TCP' },
	{ id: 'dot', label: 'DNS over TLS (DoT)' },
	{ id: 'doh', label: 'DNS over HTTPS (DoH)' },
	{ id: 'doh3', label: 'DoH with HTTP/3 preferred' },
	{ id: 'h3', label: 'DoH over HTTP/3 only' },
	{ id: 'doq', label: 'DNS over QUIC (DoQ)' },
	{ id: 'dnscrypt', label: 'DNSCrypt' }
];

var dnsProviders = [
	{
		id: 'cloudflare', label: 'Cloudflare',
		udp: 'udp://1.1.1.1:53 udp://1.0.0.1:53',
		tcp: 'tcp://1.1.1.1:53 tcp://1.0.0.1:53',
		dot: 'tls://one.one.one.one',
		doh: 'https://dns.cloudflare.com/dns-query',
		doh3: 'https://dns.cloudflare.com/dns-query',
		bootstrap: '1.1.1.1:53 1.0.0.1:53'
	},
	{
		id: 'google', label: 'Google Public DNS',
		udp: 'udp://8.8.8.8:53 udp://8.8.4.4:53',
		tcp: 'tcp://8.8.8.8:53 tcp://8.8.4.4:53',
		dot: 'tls://dns.google',
		doh: 'https://dns.google/dns-query',
		doh3: 'https://dns.google/dns-query',
		h3: 'h3://dns.google/dns-query',
		bootstrap: '8.8.8.8:53 8.8.4.4:53'
	},
	{
		id: 'quad9', label: 'Quad9 Security',
		udp: 'udp://9.9.9.9:53 udp://149.112.112.112:53',
		tcp: 'tcp://9.9.9.9:53 tcp://149.112.112.112:53',
		dot: 'tls://dns.quad9.net',
		doh: 'https://dns.quad9.net/dns-query',
		bootstrap: '9.9.9.9:53 149.112.112.112:53'
	},
	{
		id: 'adguard', label: 'AdGuard DNS',
		udp: 'udp://94.140.14.14:53 udp://94.140.15.15:53',
		tcp: 'tcp://94.140.14.14:53 tcp://94.140.15.15:53',
		dot: 'tls://dns.adguard-dns.com',
		doh: 'https://dns.adguard-dns.com/dns-query',
		doh3: 'https://dns.adguard-dns.com/dns-query',
		doq: 'quic://dns.adguard-dns.com',
		dnscrypt: 'sdns://AQMAAAAAAAAAETk0LjE0MC4xNC4xNDo1NDQzINErR_JS3PLCu_iZEIbq95zkSV2LFsigxDIuUso_OQhzIjIuZG5zY3J5cHQuZGVmYXVsdC5uczEuYWRndWFyZC5jb20',
		bootstrap: '94.140.14.14:53 94.140.15.15:53'
	},
	{
		id: 'adguard_unfiltered', label: 'AdGuard DNS — unfiltered',
		udp: 'udp://94.140.14.140:53 udp://94.140.14.141:53',
		tcp: 'tcp://94.140.14.140:53 tcp://94.140.14.141:53',
		dot: 'tls://unfiltered.adguard-dns.com',
		doh: 'https://unfiltered.adguard-dns.com/dns-query',
		doh3: 'https://unfiltered.adguard-dns.com/dns-query',
		doq: 'quic://unfiltered.adguard-dns.com',
		bootstrap: '94.140.14.140:53 94.140.14.141:53'
	},
	{
		id: 'controld', label: 'Control D — unfiltered',
		udp: 'udp://76.76.2.0:53 udp://76.76.10.0:53',
		tcp: 'tcp://76.76.2.0:53 tcp://76.76.10.0:53',
		dot: 'tls://p0.freedns.controld.com',
		doh: 'https://freedns.controld.com/p0',
		bootstrap: '76.76.2.0:53 76.76.10.0:53'
	},
	{
		id: 'alidns', label: 'AliDNS',
		udp: 'udp://223.5.5.5:53 udp://223.6.6.6:53',
		tcp: 'tcp://223.5.5.5:53 tcp://223.6.6.6:53',
		dot: 'tls://dns.alidns.com',
		doh: 'https://dns.alidns.com/dns-query',
		doq: 'quic://dns.alidns.com:853',
		bootstrap: '223.5.5.5:53 223.6.6.6:53'
	}
];

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
				fs.exec(helper, [ 'advanced-read', 'outbound' ]),
				L.resolveDefault(fs.exec(systemHelper, [ 'dns-get' ]), { stdout: '' })
			]).then(function(d) { d.ready = true; return d; });
		});
	},

	render: function(data) {
		if (!data.ready)
			return E([ common.styles(), common.gate(_('Outbound IKEv2 Tunnel'),
				_('The router uses this IPv4 IKEv2 tunnel for domains and devices selected on the Policy Routing page.')) ]);
		var value = common.parseKeyValues(data[0].stdout);
		var dnsValue = common.parseKeyValues((data[4] && data[4].stdout) || '');
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

		var dnsManaged = E('select', { 'class': 'cbi-input-select' }, [
			E('option', {
				'value': '0',
				'selected': dnsValue.managed !== '1' ? '' : null
			}, [ _('Keep existing router DNS') ]),
			E('option', {
				'value': '1',
				'selected': dnsValue.managed === '1' ? '' : null
			}, [ _('Manage DNS upstream') ])
		]);
		var initialProtocol = dnsValue.protocol || dnsValue.current_protocol || 'doh';
		if (!dnsProtocols.some(function(item) { return item.id === initialProtocol; }))
			initialProtocol = 'doh';
		var dnsProtocol = E('select', { 'class': 'cbi-input-select' },
			dnsProtocols.map(function(item) {
				return E('option', {
					'value': item.id,
					'selected': item.id === initialProtocol ? '' : null
				}, [ _(item.label) ]);
			}));
		var dnsProvider = E('select', { 'class': 'cbi-input-select' });
		var dnsUpstream = E('textarea', {
			'class': 'ikev2-domain-editor',
			'style': 'min-height:4.4rem',
			'placeholder': 'https://dns.example/dns-query'
		}, [ dnsValue.upstream || dnsValue.current_upstream || '' ]);
		var dnsBootstrap = input('text',
			dnsValue.bootstrap || dnsValue.current_bootstrap || '1.1.1.1:53 1.0.0.1:53', {
				'placeholder': '1.1.1.1:53 1.0.0.1:53'
			});
		var dnsFallback = input('text',
			dnsValue.fallback || dnsValue.current_fallback || '', {
				'placeholder': _('Optional; use the same protocol')
			});
		var dnsResult = common.inlineResult();
		var dnsSave = E('button', {
			'class': 'cbi-button cbi-button-apply',
			'type': 'button'
		}, [ _('Apply DNS') ]);
		var dnsRows = E('div', { 'class': 'ikev2-form-grid' }, [
			common.fieldLabel(_('Protocol'),
				_('dnsproxy supports plain DNS, DoT, DoH, HTTP/3, DoQ and DNSCrypt.')),
			dnsProtocol,
			common.fieldLabel(_('Provider')),
			dnsProvider,
			common.fieldLabel(_('Upstream endpoints'),
				_('Space-separated dnsproxy upstream URLs. Select Custom to edit them manually.')),
			dnsUpstream
		]);
		var dnsAdvanced = E('details', { 'class': 'ikev2-advanced' }, [
			E('summary', {}, [ _('Bootstrap and fallback') ]),
			E('div', { 'class': 'ikev2-form-grid' }, [
				common.fieldLabel(_('Bootstrap DNS'),
					_('Plain IPv4 resolvers used only to locate encrypted DNS hostnames.')),
				dnsBootstrap,
				common.fieldLabel(_('Fallback endpoints'),
					_('Optional endpoints used when the primary resolver is unavailable.')),
				dnsFallback
			])
		]);
		var dnsManagedRows = E('div', {}, [ dnsRows, dnsAdvanced ]);

		function presetFor(protocol, provider) {
			for (var i = 0; i < dnsProviders.length; i++)
				if (dnsProviders[i].id === provider && dnsProviders[i][protocol])
					return dnsProviders[i];
			return null;
		}

		function rebuildDnsProviders(preferred, updateEndpoint) {
			while (dnsProvider.firstChild)
				dnsProvider.removeChild(dnsProvider.firstChild);
			dnsProviders.forEach(function(provider) {
				if (!provider[dnsProtocol.value])
					return;
				dnsProvider.appendChild(E('option', {
					'value': provider.id,
					'selected': provider.id === preferred ? '' : null
				}, [ provider.label ]));
			});
			dnsProvider.appendChild(E('option', {
				'value': 'custom',
				'selected': preferred === 'custom' ? '' : null
			}, [ _('Custom') ]));
			if (!dnsProvider.value)
				dnsProvider.value = dnsProvider.options[0].value;
			if (updateEndpoint) {
				var preset = presetFor(dnsProtocol.value, dnsProvider.value);
				if (preset) {
					dnsUpstream.value = preset[dnsProtocol.value];
					dnsBootstrap.value = preset.bootstrap || dnsBootstrap.value;
					dnsFallback.value = '';
				}
			}
		}

		function syncDnsVisibility() {
			dnsManagedRows.style.display = dnsManaged.value === '1' ? '' : 'none';
		}

		rebuildDnsProviders(dnsValue.provider || 'cloudflare', false);
		if (!presetFor(dnsProtocol.value, dnsProvider.value))
			dnsProvider.value = 'custom';
		syncDnsVisibility();
		dnsManaged.addEventListener('change', syncDnsVisibility);
		dnsProtocol.addEventListener('change', function() {
			rebuildDnsProviders(dnsProvider.value, true);
		});
		dnsProvider.addEventListener('change', function() {
			var preset = presetFor(dnsProtocol.value, dnsProvider.value);
			if (!preset)
				return;
			dnsUpstream.value = preset[dnsProtocol.value];
			dnsBootstrap.value = preset.bootstrap || dnsBootstrap.value;
			dnsFallback.value = '';
		});

		dnsSave.addEventListener('click', function() {
			var normalize = function(text) {
				return (text || '').trim().split(/\s+/).filter(Boolean).join(' ');
			};
			var payload = [
				dnsManaged.value,
				dnsProtocol.value,
				dnsProvider.value,
				normalize(dnsUpstream.value),
				normalize(dnsBootstrap.value),
				normalize(dnsFallback.value)
			].join('\n') + '\n';
			return common.runAction({
				button: dnsSave,
				result: dnsResult,
				busy: _('Applying and testing DNS...'),
				failure: _('DNS apply failed'),
				run: function() {
					return fs.write('/tmp/ikev2-manager-dns.in', payload, 384)
						.then(function() {
							return common.execChecked(systemHelper, [ 'dns-set-async' ],
								_('DNS settings rejected'));
						})
						.then(function(response) {
							var started = common.parseKeyValues(response.stdout || '');
							if (!started.action_id)
								throw new Error(_('DNS apply did not start'));
							return common.pollAction(systemHelper,
								[ 'action-status', started.action_id ], started.action_id, {
									timeout: 90000,
									interval: 1000,
									onProgress: function(st) {
										if (st.message)
											dnsResult.busy(_(st.message));
									}
								});
						})
						.then(function(st) {
							if (!st)
								throw new Error(_('DNS apply timed out'));
							if (st.state === 'error')
								throw new Error(st.message || _('DNS apply failed'));
							dnsResult.ok(_('DNS is working'));
							window.setTimeout(function() { window.location.reload(); }, 500);
						});
				}
			});
		});

		var dnsCurrent = dnsValue.current_upstream || _('WAN-provided resolvers');
		var dnsStatus = dnsValue.managed === '1' ?
			common.pill(dnsValue.running === '1' ? _('Managed') : _('Stopped'),
				dnsValue.running === '1' ? 'good' : 'bad') :
			common.pill(_('Existing settings'), 'neutral');

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
				common.section(_('DNS upstream'),
					_('Choose how the router resolves public DNS names. dnsmasq-full remains the local resolver and continues populating PBR nftsets.'),
					E('div', {}, [
						E('div', { 'class': 'ikev2-note', 'style': 'margin-bottom:1rem' }, [
							_('Current upstream: %s').format(dnsCurrent),
							E('br'),
							_('This is a router-wide resolver setting. Upstream DNS connections use the router default route.')
						]),
						E('div', { 'class': 'ikev2-form-grid' }, [
							common.fieldLabel(_('DNS management'),
								_('Existing settings are preserved until managed DNS is enabled.')),
							dnsManaged
						]),
						dnsManagedRows,
						E('div', { 'class': 'ikev2-actions bar' }, [ dnsResult.node, dnsSave ])
					]),
					dnsStatus),
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
