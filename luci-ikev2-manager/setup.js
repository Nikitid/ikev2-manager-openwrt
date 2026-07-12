'use strict';
'require view';
'require fs';
'require ui';
'require ikev2-manager.shared as common';

var helper = '/usr/libexec/ikev2-manager-system';
var devicesHelper = '/usr/libexec/ikev2-devices';
var depsStatusFile = '/tmp/ikev2-manager-deps.status';

function parseStatus(text) {
	var out = {};
	(text || '').replace(/\r/g, '').split('\n').forEach(function(line) {
		var eq = line.indexOf('=');
		if (eq > 0) out[line.slice(0, eq)] = line.slice(eq + 1);
	});
	return out;
}

function updateDepsLine(st) {
	var pre = document.getElementById('ikev2-deps-status');
	if (!pre)
		return;
	var msg = st ? _(st.message || st.state || '') : '';
	pre.textContent = msg;
	pre.style.display = msg ? '' : 'none';
}

// install-deps detaches and reports through depsStatusFile; poll until the
// run after `prev` finishes (state ok/error) or the deadline passes.
function pollDeps(actionId, deadline) {
	return L.resolveDefault(fs.read(depsStatusFile), '').then(function(txt) {
		var st = parseStatus(txt);
		updateDepsLine(st);
		if ((st.state === 'ok' || st.state === 'error') && st.action_id === actionId)
			return st;
		if (Date.now() >= deadline)
			return null;
		return new Promise(function(r) { window.setTimeout(r, 2000); }).then(function() {
			return pollDeps(actionId, deadline);
		});
	});
}

function runDepsJob(button, cmd, doneMsg) {
	return common.runAction({
		button: button,
		busy: _('Working...'),
		run: function() {
			return common.execChecked(helper, [ cmd ], _('Operation failed')).then(function(response) {
				var actionId = parseStatus(response.stdout || '').action_id;
				if (!actionId)
					throw new Error(_('Action did not start'));
				return pollDeps(actionId, Date.now() + 300000);
			}).then(function(st) {
				if (!st) {
					ui.addNotification(null, E('p', {}, [
						_('The operation continues in the background. You can use the button again.') ]), 'warning');
				}
				else if (st.state === 'error') {
					throw new Error(st.message ? _(st.message) : _('Operation failed'));
				}
				else {
				}
			});
		},
		onError: function(message) {
			ui.addNotification(null, E('p', {}, [ message ]), 'danger');
		}
	});
}

function input(type, value, attrs) {
	return E('input', Object.assign({
		'type': type,
		'class': type === 'checkbox' ? 'cbi-input-checkbox' : 'cbi-input-text',
		'value': type === 'checkbox' ? null : (value || ''),
		'checked': type === 'checkbox' && value === '1' ? '' : null
	}, attrs || {}));
}

// "name=192.168.2.0/24" lines from `ikev2-devices networks`
function parseNetworks(stdout) {
	return (stdout || '').replace(/\r/g, '').split('\n').map(function(line) {
		var eq = line.indexOf('=');
		return eq > 0 ? { name: line.slice(0, eq), cidr: line.slice(eq + 1) } : null;
	}).filter(Boolean);
}

function parseDeviceDump(stdout) {
	var entries = [];
	(stdout || '').replace(/\r/g, '').split('\n').forEach(function(line) {
		line = line.trim();
		if (!line) return;
		var entry = {};
		line.split(' ').forEach(function(part) {
			var eq = part.indexOf('=');
			if (eq > 0) entry[part.slice(0, eq)] = part.slice(eq + 1);
		});
		if (entry.addr && entry.mode) entries.push(entry);
	});
	return entries;
}

function validateAddr(addr) {
	return addr.length > 0 && addr.length < 50 &&
		/^[0-9.]+(\/[0-9]{1,2})?$/.test(addr);
}

function domainRuntimeStatus(value) {
	if (value.domain_engine !== 'fakeip') {
		return {
			label: _('Legacy mode active'),
			tone: 'neutral',
			detail: _('PBR currently classifies selected services by their resolved public IP addresses. Configure the engine on the Policy Routing page.')
		};
	}
	if (value.domain_healthy === 'yes') {
		return {
			label: _('Reliable mode active'), tone: 'good',
			detail: _('sing-box FakeIP and nftables TProxy classify selected services. Configure the engine on the Policy Routing page.')
		};
	}
	var detail;
	if (value.domain_state === 'running')
		detail = _('Reliable domain routing is still updating.');
	else if (value.domain_service !== 'running')
		detail = _('The reliable domain-router service is stopped.');
	else if (value.domain_dnsmasq_upstream !== '127.0.0.42')
		detail = _('dnsmasq is not using the FakeIP resolver.');
	else if (value.domain_dnsmasq_cache !== '0')
		detail = _('dnsmasq caching is still enabled in reliable mode.');
	else if (value.domain_nft !== 'active')
		detail = _('Reliable-mode nftables rules are missing.');
	else if (value.domain_rule !== 'active')
		detail = _('Reliable-mode policy routing rule is missing.');
	else
		detail = value.domain_message ? _(value.domain_message) :
			_('Reliable domain routing failed a runtime health check.');
	return { label: _('Reliable mode degraded'), tone: 'bad', detail: detail };
}

function checkRows(doctor) {
	var labels = {
		firmware_source: _('Firmware source'),
		openwrt: _('OpenWrt release'),
		board_model: _('Router model'),
		target: _('OpenWrt target'),
		architecture: _('Architecture'),
		kernel: _('Kernel'),
		package_manager: _('Package manager'),
		package_feeds: _('Package feeds'),
		storage_free: _('Persistent storage free'),
		tmp_free: _('Temporary storage free'),
		memory_available: _('Available memory'),
		system_clock: _('System clock'),
		crypto_acceleration: _('Crypto acceleration'),
		flow_offloading: _('Flow offloading'),
		resource_conflict: _('Reserved resource conflicts'),
		firewall4: _('firewall4'),
		dnsmasq_nftset: _('dnsmasq nftset support'),
		dnsproxy: _('Encrypted DNS proxy'),
		sing_box: _('sing-box domain router'),
		nft_tproxy: _('nftables TProxy support'),
		pbr_service: _('PBR service'),
		pbr_version: _('PBR version'),
		failclosed_route: _('Fail-closed route'),
		xfrm_module: _('XFRM interface module'),
		xfrm_ifid_conflict: _('XFRM if_id conflict'),
		xfrm_name_conflict: _('XFRM name conflict'),
		swanctl: _('strongSwan swanctl'),
		swanmon: _('strongSwan monitoring'),
		strongswan_kernel_netlink: _('strongSwan kernel-netlink'),
		strongswan_vici: _('strongSwan VICI'),
		strongswan_openssl: _('strongSwan OpenSSL'),
		strongswan_eap_mschapv2: _('strongSwan EAP-MSCHAPv2'),
		strongswan_x509: _('strongSwan X.509')
	};
	var rows = [];
	Object.keys(labels).forEach(function(key) {
		if (doctor[key] == null)
			return;
		var value = doctor[key];
		var good = value === 'ok' || value === 'none' || value.indexOf('ok:') === 0;
		var warn = value.indexOf('warn:') === 0;
		var shown = value.replace(/^(ok|warn):/, '');
		if ((key === 'storage_free' || key === 'tmp_free' || key === 'memory_available') &&
		    /^\d+KiB$/.test(shown)) {
			shown = common.formatBytes(Number(shown.slice(0, -3)) * 1024);
		}
		else if (key === 'system_clock') {
			var clock = new Date(shown);
			if (!isNaN(clock.getTime()))
				shown = clock.toLocaleString();
		}
		rows.push({
			key: key,
			label: labels[key],
			value: common.pill(_(shown), good ? 'good' : (warn ? 'warn' : 'bad')),
			tone: good ? 'good' : (warn ? 'warn' : 'bad')
		});
	});
	return rows;
}

function rowPairs(rows) {
	return rows.map(function(row) { return [ row.label, row.value ]; });
}

function dependencyGroups(rows) {
	var preferred = [ 'openwrt', 'pbr_service', 'swanctl', 'sing_box' ];
	var summary = [];

	rows.filter(function(row) { return row.tone !== 'good'; }).forEach(function(row) {
		if (summary.length < 4)
			summary.push(row);
	});
	preferred.forEach(function(key) {
		if (summary.length >= 4 || summary.some(function(row) { return row.key === key; }))
			return;
		var found = rows.find(function(row) { return row.key === key; });
		if (found)
			summary.push(found);
	});
	rows.forEach(function(row) {
		if (summary.length < 4 && !summary.some(function(item) { return item.key === row.key; }))
			summary.push(row);
	});

	return {
		summary: summary,
		details: rows.filter(function(row) {
			return !summary.some(function(item) { return item.key === row.key; });
		})
	};
}

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(fs.exec(helper, [ 'get' ]), { stdout: '' }),
			L.resolveDefault(fs.exec(helper, [ 'doctor' ]), { stdout: '' }),
			L.resolveDefault(fs.exec(devicesHelper, [ 'networks' ]), { stdout: '' }),
			L.resolveDefault(fs.exec(devicesHelper, [ 'dump' ]), { stdout: '' })
		]);
	},

	// Add/remove a device override and refresh only this table. The helper
	// persists the rule before returning; routing services may finish updating in the
	// background without forcing a page reload or losing the user's scroll.
	deviceAction: function(args, busyBtn, onSaved) {
		return common.runAction({
			button: busyBtn,
			busy: _('Saving...'),
			run: function() {
				return common.execChecked(devicesHelper, args, _('Operation failed')).then(function() {
					return common.execChecked(devicesHelper, [ 'dump' ], _('Could not refresh device rules'));
				}).then(function(response) {
					if (onSaved)
						onSaved(response.stdout || '');
					ui.addNotification(null, E('p', {}, [
						_('Saved. Domain routing is updating in the background.') ]), 'info');
				});
			},
			onError: function(message) {
				ui.addNotification(null, E('p', {}, [ message ]), 'danger');
			}
		});
	},

	renderExceptions: function(dumpStdout) {
		var self = this;
		var list = E('div', {}, []);

		function refreshList(stdout) {
			var overrides = parseDeviceDump(stdout).filter(function(e) {
				return e.mode === 'fullroute' || e.mode === 'exclude';
			});
			var content;
			if (!overrides.length) {
				content = E('div', { 'class': 'ikev2-empty' }, [
					E('strong', {}, [ _('No device exceptions') ]),
					E('div', { 'class': 'cbi-section-descr' }, [
						_('Every protected network follows the domain policy. Add a rule only for a device that needs a different mode.') ])
				]);
			}
			else {
				content = E('table', { 'class': 'table' }, [
					E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th' }, [ _('Device / IP') ]),
						E('th', { 'class': 'th' }, [ _('Mode') ]),
						E('th', { 'class': 'th cbi-section-actions' }, [ _('Actions') ])
					])
				].concat(overrides.map(function(e) {
					var rm = E('button', {
						'class': 'cbi-button cbi-button-remove',
						'type': 'button'
					}, [ _('Remove') ]);
					rm.addEventListener('click', function() {
						self.deviceAction([ 'remove-override', e.addr ], rm, refreshList);
					});
					return E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, [ E('code', {}, [ e.addr ]) ]),
						E('td', { 'class': 'td' }, [
							common.pill(e.mode === 'fullroute' ? _('Full route') : _('Exclude'),
								e.mode === 'fullroute' ? 'good' : 'warn') ]),
						E('td', { 'class': 'td cbi-section-actions' }, [ rm ])
					]);
				})));
			}
			list.replaceChildren(content);
		}
		refreshList(dumpStdout);

		var addr = input('text', '', { 'placeholder': '192.168.2.55' });
		var mode = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'exclude' }, [ _('Exclude — always use WAN') ]),
			E('option', { 'value': 'fullroute' }, [ _('Full route — all traffic via VPN') ])
		]);
		var add = E('button', {
			'class': 'cbi-button cbi-button-add',
			'type': 'button'
		}, [ _('Add') ]);
		add.addEventListener('click', function() {
			var v = addr.value.trim();
			if (!validateAddr(v)) {
				ui.addNotification(null, E('p', {}, [ _('Invalid address') ]), 'warning');
				return;
			}
			self.deviceAction([ 'add-override', v, mode.value ], add, function(stdout) {
				addr.value = '';
				refreshList(stdout);
			});
		});

		return E('div', {}, [
			list,
			E('div', { 'class': 'ikev2-inline-form', 'style': 'margin-top:1rem' }, [ addr, mode, add ])
		]);
	},

	render: function(data) {
		var self = this;
		var value = common.parseKeyValues(data[0].stdout);
		var doctor = common.parseKeyValues(data[1].stdout);
		var netList = parseNetworks(data[2].stdout);
		var depRows = checkRows(doctor);
		var depGroups = dependencyGroups(depRows);
		var detailHalf = Math.ceil(depGroups.details.length / 2);
		var ready = doctor.doctor_ok === '1';

		var enabled = input('checkbox', value.configured);
		var dnsEnforce = input('checkbox', value.dns_enforce);
		var blockDot = input('checkbox', value.block_dot);
		var save = E('button', { 'class': 'cbi-button cbi-button-apply' }, [ _('Apply') ]);
		var applyResult = common.inlineResult();
		var installDeps = E('button', { 'class': 'cbi-button cbi-button-action' }, [
			_('Install runtime dependencies') ]);
		var removeDeps = E('button', { 'class': 'cbi-button cbi-button-remove' }, [
			_('Remove runtime dependencies') ]);
		var domainRuntime = domainRuntimeStatus(value);

		// ── Network selectors ────────────────────────────────────────────
		var protectedSet = {};
		(value.source_interfaces || '').trim().split(/\s+/).filter(Boolean)
			.forEach(function(n) { protectedSet[n] = true; });

		var haveNets = netList.length > 0;
		var wanField, protectedField, netCheckboxes = [];

		// The inbound VPN server is a selectable "network": when on, its clients
		// (ipsec-in) follow the same domain policy as local networks.
		var vpnPick = value.server_enabled === '1'
			? common.netPick('__vpn__', _('VPN server'), _('Inbound clients (ipsec-in)'),
				value.source_include_vpn !== '0')
			: null;

		if (haveNets) {
			wanField = E('select', { 'class': 'cbi-input-select' }, netList.map(function(o) {
				return E('option', {
					'value': o.name,
					'selected': o.name === value.wan_interface ? '' : null
				}, [ o.name + ' — ' + o.cidr ]);
			}));
			protectedField = E('div', { 'class': 'ikev2-netpick-grid' },
				netList.filter(function(o) { return o.name !== value.wan_interface; })
					.map(function(o) {
						var pick = common.netPick(o.name, o.name, o.cidr, !!protectedSet[o.name]);
						netCheckboxes.push(pick.input);
						return pick.node;
					}).concat(vpnPick ? [ vpnPick.node ] : []));
		}
		else {
			// Fallback when the network list is unavailable (e.g. ubus issue).
			wanField = input('text', value.wan_interface, { 'placeholder': 'wan' });
			protectedField = input('text', value.source_interfaces, { 'placeholder': 'lan iot' });
		}

		save.addEventListener('click', function() {
			var protectedVal = haveNets
				? netCheckboxes.filter(function(c) { return c.checked; })
					.map(function(c) { return c.value; }).join(' ')
				: protectedField.value.trim();
			var args = [
				'set',
				enabled.checked ? '1' : '0',
				wanField.value.trim ? wanField.value.trim() : wanField.value,
				protectedVal,
				dnsEnforce.checked ? '1' : '0',
				blockDot.checked ? '1' : '0',
				vpnPick ? (vpnPick.input.checked ? '1' : '0') : (value.source_include_vpn || '1')
			];
			args[0] = 'set-async';
			return common.runJob({
				button: save,
				result: applyResult,
				busy: enabled.checked ? _('Applying configuration...') : _('Disabling...'),
				success: enabled.checked ? _('Applied') : _('Disabled'),
				failure: _('Apply failed'),
				startPath: helper,
				startArgs: args,
				statusPath: helper,
				statusArgs: [ 'action-status' ],
				timeout: 150000,
				timeoutMessage: _('The operation continues in the background. You can use the button again.')
			});
		});

		installDeps.addEventListener('click', function() {
			if (!window.confirm(_('Install missing runtime packages now? DNS/DHCP may restart briefly while dnsmasq-full replaces dnsmasq.')))
				return;
			runDepsJob(installDeps, 'install-deps', _('Dependencies installed. Rechecking...'));
		});

		removeDeps.addEventListener('click', function() {
			if (!window.confirm(_('Restore the router state from before dependency installation? The VPN and managed routing stop. Only packages recorded as installed by this app are removed, and the previous DNS/DHCP state is restored.')))
				return;
			runDepsJob(removeDeps, 'remove-deps', _('Runtime dependencies removed.'));
		});

		if (!ready) {
			enabled.disabled = true;
			save.disabled = true;
		}

		return E([
			common.styles(),
			E('div', { 'class': 'ikev2-page' }, [
				common.header(_('IKEv2 Manager Overview'),
					_('Install the app safely, prepare dependencies, then enable the managed routing configuration only when the checks are green.'),
					common.pill(value.configured === '1' ? _('Configured') : _('Not configured'),
						value.configured === '1' ? 'good' : 'warn')),
				E('section', { 'class': 'ikev2-section' }, [
					E('div', { 'class': 'ikev2-section-head' }, [
						E('div', {}, [
							E('h3', {}, [ _('Managed mode') ]),
							E('p', {}, [ ready ?
								_('Master switch: lets the app create and own the router routing, firewall and PBR. Off = the app only watches.') :
								_('Install the runtime dependencies below first — then this switch becomes available.') ])
						])
					]),
					common.toggleRow(enabled, _('Let the app manage the router'),
						ready ? _('Creates and owns routing, firewall and PBR on the router.') :
							_('Available after runtime dependencies are installed.')),
					E('div', { 'class': 'ikev2-actions end', 'style': 'margin-top:.9rem' }, [
						applyResult.node,
						save
					]),
					E('div', { 'class': 'ikev2-health-row', 'style': 'margin-top:1rem' }, [
						E('span', { 'class': 'ikev2-health-copy' }, [
							E('strong', {}, [ _('Domain routing engine') ]),
							E('span', { 'class': 'ikev2-toggle-sub' }, [
								domainRuntime.detail
							])
						]),
						common.pill(domainRuntime.label, domainRuntime.tone)
					])
				]),
				common.section(_('Runtime dependencies'),
					_('This installs PBR, strongSwan, sing-box, dnsmasq-full, dnsproxy and XFRM/TProxy packages. Remove restores the DNS/DHCP configuration and deletes only packages this app recorded as newly installed. VPN and routing stay disabled until managed mode is enabled.'),
					E('div', {}, [
						E('div', { 'class': 'ikev2-deps-summary' }, [
							E('h4', {}, [ _('Key checks') ]),
							E('div', { 'class': 'ikev2-two-col' }, [
								common.keyValueTable(rowPairs(depGroups.summary.slice(0, 2))),
								common.keyValueTable(rowPairs(depGroups.summary.slice(2)))
							])
						]),
						E('details', { 'class': 'ikev2-diagnostics' }, [
							E('summary', {}, [
								_('Show %d more diagnostic checks').format(depGroups.details.length)
							]),
							E('div', { 'class': 'ikev2-diagnostics-body' }, [
								E('div', { 'class': 'ikev2-two-col' }, [
									common.keyValueTable(rowPairs(depGroups.details.slice(0, detailHalf))),
									common.keyValueTable(rowPairs(depGroups.details.slice(detailHalf)))
								])
							])
						]),
						E('pre', { 'id': 'ikev2-deps-status', 'class': 'ikev2-status-box', 'style': 'display:none' }, []),
						E('div', { 'class': 'ikev2-actions end', 'style': 'margin-top:1rem' }, [
							ready ? removeDeps : installDeps
						])
					]),
					common.pill(ready ? _('Ready') : _('Dependencies missing'),
						ready ? 'good' : 'bad')),
				common.section(_('Network integration'),
					_('Choose the WAN uplink and the networks this app protects. Firewall zones are detected automatically.'),
					E('div', {}, [
						E('div', { 'class': 'ikev2-form-grid' }, [
							common.fieldLabel(_('WAN network'),
								_('The internet uplink. Receives UDP 500/4500 when the inbound server is enabled.')),
							wanField
						]),
						E('div', { 'style': 'margin-top:1.15rem' }, [
							common.fieldLabel(_('Protected networks'),
								_('Networks whose selected domains use the outbound tunnel.')),
							E('div', { 'style': 'margin-top:.6rem' }, [ protectedField ])
						])
					])),
				common.section(_('Device exceptions'),
					_('Force a device fully through the VPN (Full route) or fully past it (Exclude), regardless of the domain list.'),
					self.renderExceptions(data[3].stdout)),
				common.section(_('DNS policy'),
					_('Domain routing is deterministic only when clients use the router resolver.'),
					E('div', {}, [
						E('div', { 'class': 'ikev2-two-col' }, [
							common.toggleRow(dnsEnforce, _('Redirect plain DNS'),
								_('Redirect TCP/UDP port 53 from protected zones to the router.')),
							common.toggleRow(blockDot, _('Block DNS-over-TLS'),
								_('Reject TCP/UDP port 853 from protected zones to WAN.'))
						]),
						E('div', { 'class': 'ikev2-health-row', 'style': 'margin-top:.85rem' }, [
							E('span', { 'class': 'ikev2-health-copy' }, [
								E('strong', {}, [ _('IPv6 fail-fast') ]),
								E('span', { 'class': 'ikev2-toggle-sub' }, [
									_('Dual-stack clients drop to IPv4 instead of hanging when there is no IPv6 WAN.') ])
							]),
							common.pill(
								value.ipv6_failfast === 'active' ? _('active') :
									(value.ipv6_failfast === 'na' ? _('IPv6 WAN present') : _('off')),
								value.ipv6_failfast === 'active' ? 'good' : 'neutral')
						])
					])),
				E('div', { 'class': 'ikev2-note warn' }, [
					_('Browser DoH, Android Private DNS and Apple Private Relay cannot be transparently classified by a DNS-based domain policy.')
				])
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
