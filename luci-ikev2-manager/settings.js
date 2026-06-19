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

function encodeBase64(value) {
	return window.btoa(unescape(encodeURIComponent(value)));
}

function updateAcmeLine(st) {
	var pre = document.getElementById('ikev2-acme-status');
	if (!pre)
		return;
	var msg = st ? _(st.message || st.state || '') : '';
	pre.textContent = msg;
	pre.style.display = msg ? '' : 'none';
}

function disclosure(title, description, content, badges) {
	return E('details', { 'class': 'ikev2-disclosure' }, [
		E('summary', {}, [
			E('span', { 'class': 'ikev2-disclosure-copy' }, [
				E('strong', {}, [ title ]),
				description ? E('span', {}, [ description ]) : ''
			]),
			badges ? E('span', { 'class': 'ikev2-disclosure-badges' }, badges) : ''
		]),
		E('div', { 'class': 'ikev2-disclosure-body' }, [ content ])
	]);
}

return view.extend({
	load: function() {
		return L.resolveDefault(fs.stat('/usr/sbin/swanmon'), null).then(function(ready) {
			if (!ready)
				return { ready: false };
			return Promise.all([
				fs.exec(helper, [ 'server-get' ]),
				fs.exec(helper, [ 'server-access-get' ]),
				fs.exec(helper, [ 'advanced-mode', 'inbound' ]),
				fs.exec(helper, [ 'advanced-read', 'inbound' ]),
				L.resolveDefault(fs.exec(helper, [ 'acme-get' ]), { stdout: '' })
			]).then(function(d) { d.ready = true; return d; });
		});
	},

	render: function(data) {
		if (!data.ready)
			return E([ common.styles(), common.gate(_('Inbound VPN Server'),
				_('Remote devices connect to the router over IKEv2. Routes advertised by strongSwan and firewall permissions are controlled independently.')) ]);
		var value = common.parseKeyValues(data[0].stdout);
		var access = common.parseKeyValues(data[1].stdout);
		var acme = common.parseKeyValues((data[4] && data[4].stdout) || '');
		var customMode = (data[2].stdout || '').trim() === '1';
		var enabled = input('checkbox', value.enabled);
		var identity = input('text', value.identity, {
			'placeholder': 'vpn.example.com'
		});
		var pool4 = input('text', value.pool4, {
			'placeholder': '10.20.30.10-10.20.30.100'
		});
		var gateway4 = input('text', value.gateway4, {
			'placeholder': '10.20.30.1/24'
		});
		var dns4 = input('text', value.dns4, { 'placeholder': '10.20.30.1' });
		var localTs = input('text', access.local_ts, {
			'placeholder': '0.0.0.0/0'
		});
		var allowInternet = input('checkbox', access.allow_internet);
		var allowLan = input('checkbox', access.allow_lan);
		var allowRouter = input('checkbox', access.allow_router);
		var routerPorts = input('text', access.router_ports, {
			'placeholder': _('Empty means all router services')
		});
		var lanZones = input('text', access.lan_zones, { 'placeholder': 'lan' });
		var firewallZone = input('text', access.firewall_zone, { 'placeholder': 'ikev2in' });
		var outboundZone = input('text', access.outbound_zone, { 'placeholder': 'ikev2out' });
		var certSource = input('text', value.cert_source, {
			'placeholder': '/etc/ssl/acme'
		});
		var certFile = input('text', value.cert_file, {
			'placeholder': _('Automatic from identity')
		});
		var keyFile = input('text', value.key_file, {
			'placeholder': _('Automatic from identity')
		});
		var mtu = input('number', value.mtu, { 'min': '1280', 'max': '1500' });
		var dpd = input('number', value.dpd, { 'min': '10', 'max': '300' });
		var ikeRekey = input('number', value.ike_rekey, { 'min': '3600', 'max': '86400' });
		var childRekey = input('number', value.child_rekey, { 'min': '900', 'max': '86400' });
		var mobike = input('checkbox', value.mobike);
		var fragmentation = input('checkbox', value.fragmentation);
		var save = E('button', { 'class': 'cbi-button cbi-button-apply' }, [
			_('Save server')
		]);
		var serverResult = common.inlineResult();
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
		var rawResult = common.inlineResult();
		var rawPanel = E('div', {
			'style': 'display:none;margin-top:1rem'
		}, [
			E('div', { 'class': 'ikev2-note warn' }, [
				_('Custom mode replaces the generated inbound connection and pool blocks. Normal form values remain stored but do not change the active strongSwan profile until generated mode is restored.')
			]),
			rawText,
			E('div', { 'class': 'ikev2-actions', 'style': 'margin-top:.7rem' }, [
				rawSave,
				rawReset,
				rawResult.node
			])
		]);

		rawToggle.addEventListener('click', function() {
			rawPanel.style.display = rawPanel.style.display === 'none' ? '' : 'none';
		});

		rawSave.addEventListener('click', function() {
			return common.runJob({
				button: rawSave,
				result: rawResult,
				busy: _('Validating and loading...'),
				success: _('Loaded'),
				failure: _('Custom configuration was rejected'),
				startPath: helper,
				startArgs: [ 'advanced-start', 'inbound', encodeBase64(rawText.value) ],
				statusPath: helper,
				statusArgs: [ 'action-status' ],
				timeout: 90000,
				timeoutMessage: _('The operation continues in the background. You can use the button again.'),
				onSuccess: function(st) {
					if (st && st.state !== 'timeout') {
						customMode = true;
						updateServerPills();
					}
				}
			});
		});

		rawReset.addEventListener('click', function() {
			return common.runJob({
				button: rawReset,
				result: rawResult,
				busy: _('Restoring generator...'),
				success: _('Restored'),
				failure: _('Reset failed'),
				startPath: helper,
				startArgs: [ 'advanced-reset-start', 'inbound' ],
				statusPath: helper,
				statusArgs: [ 'action-status' ],
				timeout: 90000,
				timeoutMessage: _('The operation continues in the background. You can use the button again.'),
				onSuccess: function(st) {
					if (st && st.state !== 'timeout') {
						customMode = false;
						return refreshServerState();
					}
				}
			});
		});

		save.addEventListener('click', function() {
			var serverArgs = [
				'server-set',
				enabled.checked ? '1' : '0',
				identity.value.trim(),
				pool4.value.trim(),
				gateway4.value.trim(),
				dns4.value.trim(),
				certSource.value.trim(),
				certFile.value.trim(),
				keyFile.value.trim(),
				dpd.value,
				ikeRekey.value,
				childRekey.value,
				mtu.value,
				mobike.checked ? '1' : '0',
				fragmentation.checked ? '1' : '0'
			];
			var accessArgs = [
				'server-access-set',
				localTs.value.trim(),
				allowInternet.checked ? '1' : '0',
				allowLan.checked ? '1' : '0',
				allowRouter.checked ? '1' : '0',
				routerPorts.value.trim(),
				lanZones.value.trim(),
				firewallZone.value.trim(),
				outboundZone.value.trim(),
				'1' /* defer apply: the server save runs one detached apply for both */
			];
			return common.runAction({
				button: save,
				result: serverResult,
				busy: _('Saving...'),
				failure: _('Server settings rejected'),
				run: function() {
					common.setPill(serverStatusPill, _('Applying...'), 'info');
					return common.execChecked(helper, accessArgs, _('Access policy rejected'))
						.then(function() {
							return common.execChecked(helper, serverArgs, _('Server settings rejected'));
						}).then(function(response) {
							var started = common.parseKeyValues(response.stdout || '');
							if (!started.action_id) {
								serverResult.ok(_('Saved'));
								return;
							}
							return common.pollAction(helper,
								[ 'action-status', started.action_id ], started.action_id, {
								timeout: 120000,
								interval: 1500,
								onProgress: function(st) {
									if (st.action_id === started.action_id && st.message)
										serverResult.busy(_(st.message));
								}
							}).then(function(st) {
								if (!st) {
									serverResult.warn(_('The operation continues in the background. You can use the button again.'));
								}
								else if (st.state === 'error') {
									throw new Error(st.message ? _(st.message) : _('Apply failed'));
								}
								else {
									serverResult.ok(_('Saved'));
								}
							});
						});
				},
				onSuccess: refreshServerState,
				onError: refreshServerState
			});
		});

		// ── ACME certificate ─────────────────────────────────────────────
		var acmeEmail = input('text', acme.email, { 'placeholder': 'you@example.com' });
		var acmeMethod = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'dns', 'selected': acme.method !== 'http' ? '' : null },
				[ _('DNS-01 (DNS provider API)') ]),
			E('option', { 'value': 'http', 'selected': acme.method === 'http' ? '' : null },
				[ _('HTTP-01 (standalone, needs inbound port 80)') ])
		]);
		var providerList = (acme.providers || '').trim().split(/\s+/).filter(Boolean);
		if (!providerList.length)
			providerList = [ 'dns_timeweb' ];
		var acmeProvider = E('select', { 'class': 'cbi-input-select' },
			providerList.map(function(p) {
				return E('option', {
					'value': p,
					'selected': p === acme.dns_provider ? '' :
						(!acme.dns_provider && p === 'dns_timeweb' ? '' : null)
				}, [ p ]);
			}));
		var acmeCreds = E('textarea', {
			'class': 'ikev2-domain-editor',
			'style': 'min-height:4rem',
			'placeholder': acme.has_credentials === '1' ?
				_('Stored — leave empty to keep, or paste to replace') :
				_('Paste your API token here')
		}, []);
		var acmeStaging = input('checkbox', acme.staging);
		var acmeSave = E('button', { 'class': 'cbi-button cbi-button-apply' }, [
			_('Save ACME settings') ]);
		var acmeRequest = E('button', { 'class': 'cbi-button cbi-button-action' }, [
			_('Request certificate') ]);

		var dnsRows = E('div', { 'class': 'ikev2-form-grid ikev2-form-grid-compact' }, [
			common.fieldLabel(_('DNS provider'),
				_('acme.sh dns_* plugin. Timeweb needs TW_Token.')),
			acmeProvider,
			common.fieldLabel(_('Provider credentials'),
				_('For Timeweb just paste the API token. Multi-field providers: one VAR="value" per line.')),
			acmeCreds
		]);
		function syncAcmeMethod() {
			dnsRows.style.display = acmeMethod.value === 'dns' ? '' : 'none';
		}
		acmeMethod.addEventListener('change', syncAcmeMethod);
		syncAcmeMethod();

		// Hand the settings to the backend through a file, not a command
		// argument. The token is large and secret; passing it on the exec
		// command line is brittle (rpcd's file-exec ACL globs the arguments and
		// arbitrary base64 broke the match) and leaks it into the process list.
		// fs.write keeps acme-set argument-free.
		function writeAcmeInput() {
			var payload = [
				acmeEmail.value.trim(),
				acmeMethod.value,
				acmeProvider.value,
				acmeStaging.checked ? '1' : '0'
			].join('\n') + '\n' + acmeCreds.value + '\n';
			return fs.write('/tmp/ikev2-acme.in', payload, 384 /* 0600 */);
		}

		acmeSave.addEventListener('click', function() {
			return common.runAction({
				button: acmeSave,
				busy: _('Saving...'),
				failure: _('ACME settings rejected'),
				run: function() {
					updateAcmeLine({ message: _('Saving...') });
					return writeAcmeInput().then(function() {
						return common.execChecked(helper, [ 'acme-set' ], _('ACME settings rejected'));
					}).then(function() {
						updateAcmeLine({ message: _('ACME settings saved.') });
					});
				},
				onError: function(message) { updateAcmeLine({ message: message }); }
			});
		});

		acmeRequest.addEventListener('click', function() {
			return common.runAction({
				button: acmeRequest,
				busy: _('Requesting...'),
				failure: _('Certificate request failed.'),
				run: function() {
					updateAcmeLine({ message: _('Saving settings...') });
					return writeAcmeInput().then(function() {
						return common.execChecked(helper, [ 'acme-set' ], _('ACME settings rejected'));
					}).then(function() {
						return common.execChecked(helper, [ 'acme-issue' ], _('Certificate request failed.'));
					}).then(function(response) {
						var started = common.parseKeyValues(response.stdout || '');
						if (!started.action_id)
							throw new Error(_('Certificate request did not start.'));
						return common.pollAction(helper, [ 'acme-status' ], started.action_id, {
							timeout: 300000,
							interval: 2500,
							onProgress: updateAcmeLine
						});
					}).then(function(st) {
						if (!st) {
							updateAcmeLine({ message:
								_('The certificate request continues in the background. You can use the button again.') });
						}
						else if (st.state === 'error') {
							throw new Error(st.message || _('Certificate request failed.'));
						}
						else {
							updateAcmeLine({ message: st.message || _('Certificate issued.') });
							return refreshServerState();
						}
					});
				},
				onError: function(message) { updateAcmeLine({ message: message }); }
			});
		});

		var acmeStatusPill = acme.cert_present === '1' ?
			common.pill(_('Certificate present') +
				(acme.cert_expiry ? ' · ' + common.formatDate(acme.cert_expiry) : ''), 'good') :
			common.pill(_('No certificate'), 'bad');

		// Reflect runtime reality, not just the UCI flag: an enabled server with no
		// usable certificate is not actually serving, so warn instead of "Enabled".
		var serverStatusPill = common.pill('', 'neutral');

		function updateServerPills() {
			if (acme.cert_present === '1') {
				common.setPill(acmeStatusPill,
					_('Certificate present') +
						(acme.cert_expiry ? ' · ' + common.formatDate(acme.cert_expiry) : ''),
					'good');
			}
			else {
				common.setPill(acmeStatusPill, _('No certificate'), 'bad');
			}

			if (customMode) {
				common.setPill(serverStatusPill, _('Custom config'), 'warn');
			}
			else if (value.enabled !== '1') {
				common.setPill(serverStatusPill, _('Disabled'), 'neutral');
			}
			else if (acme.cert_present !== '1') {
				common.setPill(serverStatusPill, _('Enabled — no certificate'), 'warn');
			}
			else if (acme.conn_loaded === '1') {
				common.setPill(serverStatusPill, _('Enabled'), 'good');
			}
			else {
				common.setPill(serverStatusPill, _('Enabled — not loaded'), 'warn');
			}
		}

		function refreshServerState() {
			return Promise.all([
				L.resolveDefault(fs.exec(helper, [ 'server-get' ]), { stdout: '' }),
				L.resolveDefault(fs.exec(helper, [ 'acme-get' ]), { stdout: '' })
			]).then(function(results) {
				value = common.parseKeyValues(results[0].stdout || '');
				acme = common.parseKeyValues(results[1].stdout || '');
				updateServerPills();
			});
		}
		updateServerPills();

		var accessPanel = disclosure(
			_('Client routes and access'),
			_('Choose what clients send through IKEv2 and where that traffic may go.'),
			E('div', {}, [
				E('div', { 'class': 'ikev2-form-grid ikev2-form-grid-compact' }, [
					common.fieldLabel(_('Advertised IPv4 destinations'),
						_('Space-separated CIDRs. Use 0.0.0.0/0 for a full-tunnel client route.')),
					localTs,
					common.fieldLabel(_('Allow Internet'),
						_('Permit forwarding to home WAN and the outbound IKEv2 policy path.')),
					common.switchLabel(allowInternet),
					common.fieldLabel(_('Allow internal networks'),
						_('Permit forwarding to the LAN firewall zones listed below.')),
					common.switchLabel(allowLan),
					common.fieldLabel(_('Internal firewall zones')),
					lanZones,
					common.fieldLabel(_('Allow router itself'),
						_('Allows router services on its LAN, VPN and public addresses. This also enables same-router public-IP loopback.')),
					common.switchLabel(allowRouter),
					common.fieldLabel(_('Allowed router ports'),
						_('Optional TCP/UDP ports or ranges. Leave empty to allow all protocols and services.')),
					routerPorts
				]),
				E('details', { 'class': 'ikev2-advanced' }, [
					E('summary', {}, [ _('Firewall zone integration') ]),
					E('div', { 'class': 'ikev2-form-grid ikev2-form-grid-compact' }, [
						common.fieldLabel(_('Inbound VPN zone')), firewallZone,
						common.fieldLabel(_('Outbound IKEv2 zone')), outboundZone
					])
				])
			])
		);

		var acmePanel = disclosure(
			_('ACME certificate'),
			_('Issue and renew the public certificate used by VPN clients.'),
			E('div', {}, [
				E('p', { 'class': 'ikev2-panel-note' }, [
					_('The public identity above must be a DNS name pointing to this router.')
				]),
				E('div', { 'class': 'ikev2-form-grid ikev2-form-grid-compact' }, [
					common.fieldLabel(_('Account email'),
						_('Used for the Let\'s Encrypt account and expiry notices.')),
					acmeEmail,
					common.fieldLabel(_('Challenge method'),
						_('DNS-01 works behind NAT and without port 80. HTTP-01 needs inbound TCP 80 to this router.')),
					acmeMethod
				]),
				dnsRows,
				E('div', { 'class': 'ikev2-form-grid ikev2-form-grid-compact' }, [
					common.fieldLabel(_('Staging'),
						_('Use the Let\'s Encrypt staging CA for testing (untrusted certs, no rate limits).')),
					common.switchLabel(acmeStaging)
				]),
				E('pre', { 'id': 'ikev2-acme-status', 'class': 'ikev2-status-box', 'style': 'display:none' }, []),
				E('div', { 'class': 'ikev2-actions end', 'style': 'margin-top:1rem' }, [
					acmeSave,
					acmeRequest
				])
			]),
			[
				acmeStatusPill,
				acme.cert_subject ? common.pill(acme.cert_subject, 'neutral') : ''
			]
		);

		var behaviorPanel = disclosure(
			_('Connection and advanced settings'),
			_('Roaming behavior, timers, certificate paths and raw strongSwan configuration.'),
			E('div', {}, [
				E('div', { 'class': 'ikev2-form-grid ikev2-form-grid-compact' }, [
					common.fieldLabel(_('MOBIKE'),
						_('Keeps the VPN session when a phone moves between Wi-Fi and mobile data.')),
					common.switchLabel(mobike),
					common.fieldLabel(_('IKE fragmentation'),
						_('Avoids oversized IKE packets on constrained networks.')),
					common.switchLabel(fragmentation),
					common.fieldLabel(_('XFRM MTU')), mtu
				]),
				E('details', { 'class': 'ikev2-advanced' }, [
					E('summary', {}, [ _('Advanced timers') ]),
					E('div', { 'class': 'ikev2-form-grid ikev2-form-grid-compact' }, [
						common.fieldLabel(_('DPD interval')), dpd,
						common.fieldLabel(_('IKE rekey')), ikeRekey,
						common.fieldLabel(_('CHILD rekey')), childRekey
					])
				]),
				E('details', { 'class': 'ikev2-advanced' }, [
					E('summary', {}, [ _('Certificate paths') ]),
					E('div', { 'class': 'ikev2-form-grid ikev2-form-grid-compact' }, [
						common.fieldLabel(_('ACME certificate directory')), certSource,
						common.fieldLabel(_('Certificate file override')), certFile,
						common.fieldLabel(_('Private key override')), keyFile
					])
				]),
				E('details', { 'class': 'ikev2-advanced' }, [
					E('summary', {}, [ _('Advanced strongSwan configuration') ]),
					E('p', { 'class': 'ikev2-panel-note' }, [
						_('Inspect the generated swanctl connection or replace it with a manually maintained profile.')
					]),
					rawPanel,
					E('div', { 'class': 'ikev2-actions spread', 'style': 'margin-top:1rem' }, [
						customMode ? common.pill(_('Override active'), 'warn') :
							common.pill(_('Generated'), 'good'),
						rawToggle
					])
				])
			])
		);

		return E([
			common.styles(),
			E('div', { 'class': 'ikev2-page' }, [
				common.header(_('Inbound VPN Server'),
					_('Remote devices connect to the router over IKEv2. Routes advertised by strongSwan and firewall permissions are controlled independently.')),
				common.section(_('Service'),
					_('Configure the server identity and client address pool. Less common settings are grouped below.'),
					E('div', {}, [
						E('div', { 'class': 'ikev2-form-grid ikev2-form-grid-compact' }, [
							common.fieldLabel(_('Enable server'),
								_('Listen on WAN UDP 500 and 4500.')),
							common.switchLabel(enabled),
							common.fieldLabel(_('Public identity')), identity,
							common.fieldLabel(_('Client IPv4 pool')), pool4,
							common.fieldLabel(_('Pool gateway'),
								_('Router address and prefix assigned to ipsec-in.')),
							gateway4,
							common.fieldLabel(_('DNS for VPN clients')), dns4
						]),
						E('div', { 'class': 'ikev2-disclosure-stack' }, [
							accessPanel,
							acmePanel,
							behaviorPanel
						])
					]),
					serverStatusPill),
				E('div', { 'class': 'ikev2-actions end ikev2-save-bar' }, [
					serverResult.node,
					save
				])
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
