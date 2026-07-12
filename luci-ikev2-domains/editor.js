'use strict';
'require view';
'require fs';
'require ui';
'require ikev2-manager.shared as common';

var domainFile    = '/etc/pbr-ikev2-domains.txt';
var manualFile    = '/etc/pbr-ikev2-domains.manual.txt';
var manualAddressFile = '/etc/pbr-ikev2-addresses.manual.txt';
var selectedFile  = '/etc/pbr-ikev2-community-selected.txt';
var statusFile    = '/tmp/ikev2-domains-community.status';
var communityHelper = '/usr/libexec/ikev2-domains-community';
var devicesHelper   = '/usr/libexec/ikev2-devices';
var systemHelper    = '/usr/libexec/ikev2-manager-system';
var domainRouterHelper = '/usr/libexec/ikev2-domain-router';
var serviceSelection = {};

function normalizeDomains(value) {
	var lines = (value || '').replace(/\r/g, '').split('\n');
	var domains = [];
	var seen = {};

	for (var i = 0; i < lines.length; i++) {
		var domain = lines[i].trim().toLowerCase();

		if (!domain || domain.charAt(0) === '#')
			continue;

		if (/\s/.test(domain) || domain.indexOf('@') !== -1 ||
		    domain.indexOf('/') !== -1 ||
		    domain.indexOf('full:') === 0 ||
		    domain.indexOf('regexp:') === 0 ||
		    !/^[a-z0-9._-]+$/.test(domain)) {
			throw new Error(
				_('Invalid entry on line %d: %s').format(i + 1, domain));
		}

		if (!seen[domain]) {
			seen[domain] = true;
			domains.push(domain);
		}
	}

	return domains;
}

function normalizeAddresses(value) {
	var lines = (value || '').replace(/\r/g, '').split('\n');
	var addresses = [];
	var seen = {};

	for (var i = 0; i < lines.length; i++) {
		var entry = lines[i].trim();
		if (!entry || entry.charAt(0) === '#')
			continue;

		var parts = entry.split('/');
		if (parts.length > 2 || (parts.length === 2 &&
		    (!/^\d+$/.test(parts[1]) || +parts[1] > 32)))
			throw new Error(
				_('Invalid IPv4 address or network on line %d: %s').format(i + 1, entry));

		var octets = parts[0].split('.');
		if (octets.length !== 4 || octets.some(function(octet) {
			return !/^\d+$/.test(octet) || +octet > 255;
		}))
			throw new Error(
				_('Invalid IPv4 address or network on line %d: %s').format(i + 1, entry));

		var normalized = parts[0] + '/' + (parts.length === 2 ? +parts[1] : 32);
		if (!seen[normalized]) {
			seen[normalized] = true;
			addresses.push(normalized);
		}
	}

	return addresses;
}

function serviceLabel(name) {
	var labels = {
		openai: 'OpenAI',
		anthropic_ai: 'Anthropic',
		google_ai: 'Google AI',
		x_ai: 'xAI',
		hdrezka: 'HDRezka',
		google_play: 'Google Play',
		google_meet: 'Google Meet',
		digitalocean: 'DigitalOcean',
		cloudfront: 'CloudFront'
	};
	if (labels[name])
		return labels[name];
	return name.replace(/_/g, ' ').replace(/\b\w/g, function(letter) {
		return letter.toUpperCase();
	});
}

// Ordered service categories. Any catalog name not listed here falls into the
// trailing "Other" group, so adding a new service still shows up.
var SERVICE_CATEGORIES = [
	{ title: 'AI',
	  names: [ 'openai', 'anthropic_ai', 'google_ai', 'midjourney',
	           'perplexity', 'mistral', 'huggingface', 'stability_ai', 'x_ai' ] },
	{ title: 'Social & messaging',
	  names: [ 'telegram', 'discord', 'twitter', 'meta', 'linkedin' ] },
	{ title: 'Video & music',
	  names: [ 'youtube', 'tiktok', 'hdrezka', 'spotify', 'google_meet' ] },
	{ title: 'Games & stores',
	  names: [ 'roblox', 'google_play' ] },
	{ title: 'Infrastructure (broad — use with care)',
	  names: [ 'cloudflare', 'cloudfront', 'digitalocean', 'hetzner', 'ovh' ] }
];

var BROAD_SERVICES = /^(cloudflare|cloudfront|digitalocean|hetzner|ovh)$/;
// Compact selectable chip (replaces the bulky per-service checkbox card).
function serviceChip(name, selected, ipServices) {
	var broad = BROAD_SERVICES.test(name);
	var ipNetworks = !!ipServices[name];
	var input = E('input', {
		'type': 'checkbox',
		'class': 'ikev2-community-service',
		'value': name,
		'checked': selected[name] ? '' : null
	});
	var chip = E('label', {
		'class': 'ikev2-chip' + (broad ? ' broad' : '') + (selected[name] ? ' selected' : '')
	}, [
		input,
		E('span', {}, [ serviceLabel(name) ]),
		broad ? E('span', {
			'class': 'ikev2-chip-mark',
			'title': _('Broad — may also route unrelated sites')
		}, [ '⚠' ]) : '',
		ipNetworks ? E('span', {
			'class': 'ikev2-chip-mark',
			'title': _('Includes direct service IP networks')
		}, [ 'IP' ]) : ''
	]);
	input.addEventListener('change', function() {
		chip.classList.toggle('selected', input.checked);
		if (input.checked)
			serviceSelection[name] = true;
		else
			delete serviceSelection[name];
	});
	return chip;
}

// Group a flat catalog list into ordered category blocks. Unmatched names
// collect into a trailing "Other" group.
function renderServiceGroups(services, selected, ipServices) {
	var available = {};
	services.forEach(function(n) { available[n] = true; });

	var used   = {};
	var blocks = [];

	function block(title, names) {
		var items = names.filter(function(n) { return available[n]; })
			.map(function(n) {
				used[n] = true;
				return serviceChip(n, selected, ipServices);
			});
		if (!items.length)
			return;
		blocks.push(E('div', { 'class': 'ikev2-chip-group' }, [
			E('h4', {}, [ _(title) ]),
			E('div', { 'class': 'ikev2-chips' }, items)
		]));
	}

	SERVICE_CATEGORIES.forEach(function(cat) { block(cat.title, cat.names); });

	var others = services.filter(function(n) { return !used[n]; }).sort();
	block('Other', others);

	return blocks;
}

function parseStatus(text) {
	var out = {};
	var lines = (text || '').replace(/\r/g, '').split('\n');
	for (var i = 0; i < lines.length; i++) {
		var eq = lines[i].indexOf('=');
		if (eq > 0)
			out[lines[i].slice(0, eq)] = lines[i].slice(eq + 1);
	}
	return out;
}

// Poll the status file until its `updated` timestamp differs from `prev`
// (meaning our apply run finished) or the deadline passes. Resolves with the
// parsed status object, or null on timeout.
function pollStatus(actionId, deadline) {
	return L.resolveDefault(fs.read(statusFile), '').then(function(txt) {
		var st = parseStatus(txt);
		if (st.action_id === actionId && (st.state === 'ok' || st.state === 'error'))
			return st;
		if (Date.now() >= deadline)
			return null;
		return new Promise(function(resolve) {
			window.setTimeout(resolve, 1500);
		}).then(function() {
			return pollStatus(actionId, deadline);
		});
	});
}

function pollDomainRouter(actionId, deadline) {
	return L.resolveDefault(fs.exec(domainRouterHelper, [ 'status' ]), {
		code: 1, stdout: ''
	}).then(function(response) {
		var st = parseStatus((response || {}).stdout || '');
		if (st.action_id === actionId &&
		    (st.state === 'active' || st.state === 'disabled' || st.state === 'error'))
			return st;
		if (Date.now() >= deadline)
			return null;
		return new Promise(function(resolve) {
			window.setTimeout(resolve, 1000);
		}).then(function() {
			return pollDomainRouter(actionId, deadline);
		});
	});
}

// Refresh the on-page status block without a full reload.
function updateStatusLine(st) {
	var pre = document.querySelector('#ikev2-status-line');
	if (!pre)
		return;
	if (!st) {
		return;
	}
	var lines = [];
	if (st.state)    lines.push('state=' + st.state);
	if (st.updated)  lines.push('updated=' + st.updated);
	if (st.services != null) lines.push('services=' + st.services);
	if (st.domains  != null) lines.push('domains=' + st.domains);
	if (st.cidrs != null) lines.push('cidrs=' + st.cidrs);
	if (st.custom_cidrs != null) lines.push('custom_cidrs=' + st.custom_cidrs);
	if (st.selected) lines.push('selected=' + st.selected);
	if (st.cached_services) lines.push('cached_services=' + st.cached_services);
	if (st.message)  lines.push('message=' + st.message);
	pre.textContent = lines.join('\n');
	pre.style.display = lines.length ? '' : 'none';
}

function parseDeviceDump(stdout) {
	var entries = [];
	var lines = (stdout || '').replace(/\r/g, '').split('\n');
	for (var i = 0; i < lines.length; i++) {
		var line = lines[i].trim();
		if (!line) continue;
		var entry = {};
		var parts = line.split(' ');
		for (var j = 0; j < parts.length; j++) {
			if (!parts[j]) continue;
			var eqIdx = parts[j].indexOf('=');
			if (eqIdx > 0)
				entry[parts[j].slice(0, eqIdx)] = parts[j].slice(eqIdx + 1);
		}
		if (entry.addr && entry.mode)
			entries.push(entry);
	}
	return entries;
}

function validateAddr(addr) {
	return addr.length > 0 && addr.length < 50 &&
		/^[0-9.]+(\/[0-9]{1,2})?$/.test(addr);
}

return view.extend({
	load: function() {
		return Promise.all([
			// Textarea is bound to the manual file only — never fall back to the
			// combined list, or clearing/editing would silently reappear.
			L.resolveDefault(fs.read(manualFile), ''),
			L.resolveDefault(fs.read(selectedFile), ''),
			L.resolveDefault(fs.read(statusFile), ''),
			L.resolveDefault(fs.exec(communityHelper, [ 'catalog' ]), {
				code: 1, stdout: ''
			}),
			L.resolveDefault(fs.exec(devicesHelper, [ 'dump' ]), {
				code: 0, stdout: ''
			}),
			L.resolveDefault(fs.read(domainFile), '')
			,
			L.resolveDefault(fs.exec(systemHelper, [ 'get' ]), {
				code: 0, stdout: ''
			}),
			L.resolveDefault(fs.exec(devicesHelper, [ 'networks' ]), {
				code: 0, stdout: ''
			}),
			L.resolveDefault(fs.exec(domainRouterHelper, [ 'status' ]), {
				code: 0, stdout: ''
			}),
			L.resolveDefault(fs.exec(communityHelper, [ 'ip-services' ]), {
				code: 0, stdout: ''
			}),
			L.resolveDefault(fs.read(manualAddressFile), '')
		]);
	},

	doSave: function(result) {
		var textarea   = document.querySelector('#ikev2-domain-list');
		var addressTextarea = document.querySelector('#ikev2-address-list');
		var domains;
		var addresses;
		var selected = Object.keys(serviceSelection).sort();

		if (!textarea || !addressTextarea) {
			result.err(_('Editor not ready — please reload the page.'));
			return Promise.reject(new Error('textarea-missing'));
		}

		try {
			domains = normalizeDomains(textarea.value);
			addresses = normalizeAddresses(addressTextarea.value);
		}
		catch (error) {
			result.err(error.message);
			return Promise.reject(error);
		}

		var manualValue   = domains.join('\n') + (domains.length ? '\n' : '');
		var addressValue = addresses.join('\n') + (addresses.length ? '\n' : '');
		var selectedValue = selected.join('\n') + (selected.length ? '\n' : '');

		return Promise.all([
			fs.write(manualFile, manualValue),
			fs.write(manualAddressFile, addressValue),
			fs.write(selectedFile, selectedValue)
		])
				.then(function() {
					textarea.value = manualValue;
					addressTextarea.value = addressValue;
					result.busy(_('Rebuilding the PBR list…'));
					return common.execChecked(communityHelper, [ 'schedule' ],
						_('Unable to start the PBR rebuild')).then(function(response) {
						var actionId = parseStatus(response.stdout || '').action_id;
						if (!actionId)
							throw new Error(_('Action did not start'));
						return pollStatus(actionId, Date.now() + 60000);
					});
				})
				.then(function(st) {
					updateStatusLine(st);

					if (!st) {
						result.warn(_('Saved; rebuild continues in the background.'));
						return;
					}
					if (st.state === 'ok') {
						result.ok(_('%s domains active').format(st.domains != null ? st.domains : '?'));
					}
					else {
						result.err(_('Rebuild failed: %s').format(st.message || _('unknown error')));
					}
				})
			.catch(function(error) {
				if (error.message !== 'textarea-missing')
					result.err(_('Unable to save: %s').format(error.message));
			});
	},

	renderDevicesTab: function(initialDump, systemConfig, networksDump) {
		var entries  = parseDeviceDump((initialDump || {}).stdout || '');
		var tableWrap = E('div', {});
		var protectedNetworks = (systemConfig.source_interfaces || '').trim()
			.split(/\s+/).filter(Boolean);
		function coverageAction(button, action, name) {
			return common.runJob({
				button: button,
				busy: _('Applying...'),
				failure: _('Operation failed'),
				startPath: systemHelper,
				startArgs: [ 'coverage-async', action, name ],
				statusPath: systemHelper,
				statusArgs: [ 'action-status' ],
				timeout: 120000,
				timeoutMessage: _('The operation continues in the background. You can use the button again.'),
				onSuccess: function(st) {
					ui.addNotification(null, E('p', {}, [
						st && st.state === 'timeout' ?
							_('The operation continues in the background. You can use the button again.') :
							_('Saved.') ]), st && st.state === 'timeout' ? 'warning' : 'info');
					if (!st || st.state !== 'timeout')
						window.dispatchEvent(new Event('ikev2-coverage-updated'));
				},
				onError: function(message) {
					ui.addNotification(null, E('p', {}, [ message ]), 'danger');
				}
			});
		}

		var coverageTags = protectedNetworks.map(function(name) {
			return E('span', { 'class': 'ikev2-tag' }, [
				name,
				E('button', {
					'class': 'ikev2-tag-x',
					'title': _('Remove'),
					'aria-label': _('Remove'),
					'click': function(ev) {
						coverageAction(ev.currentTarget, 'remove', name);
					}
				}, [ '\u00d7' ])
			]);
		});

		function doAction(button, cmd, addr, extra, onSuccess) {
			var args = extra != null ? [ cmd, addr, extra ] : [ cmd, addr ];
			return common.runAction({
				button: button,
				busy: _('Saving...'),
				run: function() {
					return common.execChecked(devicesHelper, args, _('Operation failed'))
						.then(function() {
							ui.addNotification(null, E('p', {}, [
								_('Saved. Domain routing is updating in the background.')
							]), 'info');
							return fs.exec(devicesHelper, [ 'dump' ]);
						}).then(function(r) {
							showTable(parseDeviceDump((r || {}).stdout || ''));
						});
				},
				onError: function(message) {
					ui.addNotification(null, E('p', {}, [ message ]), 'danger');
				},
				onSuccess: onSuccess
			});
		}

		function showTable(ents) {
			while (tableWrap.firstChild)
				tableWrap.removeChild(tableWrap.firstChild);

			var domains   = ents.filter(function(e) { return e.mode === 'domain'; });
			var overrides = ents.filter(function(e) { return e.mode !== 'domain'; });

			if (!ents.length) {
				tableWrap.appendChild(E('div', { 'class': 'ikev2-empty' }, [
					E('strong', {}, [ _('No custom device rules') ]),
					E('div', { 'class': 'cbi-section-descr' }, [
						_('All default network segments still use domain routing. Add a rule below only when a device needs different behavior.')
					])
				]));
				return;
			}

			if (domains.length) {
				tableWrap.appendChild(E('h4', {}, [ _('Domain routing') ]));
				tableWrap.appendChild(
					E('p', { 'class': 'cbi-section-descr' }, [
						_('Traffic to VPN only for domains in the list.')
					])
				);

				var dRows = domains.map(function(e) {
					var btn = E('button', {
						'class': 'cbi-button cbi-button-remove',
						'click': function(ev) {
							doAction(ev.currentTarget, 'remove-subnet', e.addr, null);
						}
					}, [ _('Remove') ]);
					return E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, [ E('code', {}, [ e.addr ]) ]),
						E('td', { 'class': 'td cbi-section-actions' }, [ btn ])
					]);
				});

				tableWrap.appendChild(E('table', { 'class': 'table' }, [
					E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th' }, [ _('Address / subnet') ]),
						E('th', { 'class': 'th cbi-section-actions' }, [ _('Actions') ])
					])
				].concat(dRows)));
			}

			if (overrides.length) {
				tableWrap.appendChild(E('h4', {}, [ _('Device overrides') ]));

				var oRows = overrides.map(function(e) {
					var label = e.mode === 'fullroute' ? _('Full route') : _('Exclude');

					var rmBtn = E('button', {
						'class': 'cbi-button cbi-button-remove',
						'click': function(ev) {
							doAction(ev.currentTarget, 'remove-override', e.addr, null);
						}
					}, [ _('Remove') ]);

					return E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, [ E('code', {}, [ e.addr ]) ]),
						E('td', { 'class': 'td' }, [
							common.pill(label, e.mode === 'fullroute' ? 'good' : 'warn')
						]),
						E('td', { 'class': 'td cbi-section-actions' }, [ rmBtn ])
					]);
				});

				tableWrap.appendChild(E('table', { 'class': 'table' }, [
					E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th' }, [ _('Device / IP') ]),
						E('th', { 'class': 'th' }, [ _('Mode') ]),
						E('th', { 'class': 'th cbi-section-actions' }, [ _('Actions') ])
					])
				].concat(oRows)));
			}
		}

		showTable(entries);

		/* ── Network pick-list (add a router subnet to domain routing) ──── */
		var netOptions = ((networksDump || {}).stdout || '').replace(/\r/g, '').split('\n')
			.map(function(line) {
				var eq = line.indexOf('=');
				return eq > 0 ? { name: line.slice(0, eq), cidr: line.slice(eq + 1) } : null;
			}).filter(Boolean)
			.filter(function(o) { return protectedNetworks.indexOf(o.name) === -1; });

		var networkSelect = E('select', { 'class': 'cbi-input-select' },
			netOptions.length
				? netOptions.map(function(o) {
					return E('option', { 'value': o.name }, [ o.name + ' — ' + o.cidr ]);
				})
				: [ E('option', { 'value': '' }, [ _('No networks available') ]) ]);

		var addNetworkBtn = E('button', {
			'class': 'cbi-button cbi-button-add',
			'click': function() {
				var name = networkSelect.value;
				if (!name) return;
				coverageAction(addNetworkBtn, 'add', name);
			}
		}, [ _('Add') ]);

		/* ── Add-override form ─────────────────────────────────────────── */
		var overrideInput = E('input', {
			'type': 'text',
			'class': 'cbi-input-text',
			'placeholder': '192.168.1.55'
		});

		var modeSelect = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'fullroute' }, [ _('Full route — all traffic via VPN') ]),
			E('option', { 'value': 'exclude'   }, [ _('Exclude — always use WAN')          ])
		]);

		var addOverrideBtn = E('button', {
			'class': 'cbi-button cbi-button-add',
			'click': function() {
				var addr = overrideInput.value.trim();
				if (!validateAddr(addr)) {
					ui.addNotification(null, E('p', {}, [ _('Invalid address') ]), 'warning');
					return;
				}
				doAction(addOverrideBtn, 'add-override', addr, modeSelect.value,
					function() { overrideInput.value = ''; });
			}
		}, [ _('Add') ]);

		return E('div', {}, [
			E('div', { 'class': 'ikev2-note' }, [
				_('Domain routing sends only listed destinations through the VPS. Full route sends all IPv4 traffic for a device through the VPS. Exclude always uses the home WAN.')
			]),
			E('div', { 'class': 'ikev2-section', 'style': 'margin-top:1rem;' }, [
				E('div', { 'class': 'ikev2-section-head' }, [
					E('div', {}, [
						E('h4', { 'style': 'margin:.2em 0 .25em;' },
							[ _('Default coverage') ]),
						E('p', { 'class': 'cbi-section-descr' }, [
							_('These networks participate in domain-based VPN routing. Add another router network from the list.')
						])
					]),
					common.pill(_('Active'), 'good')
				]),
				coverageTags.length
					? E('div', { 'class': 'ikev2-tags', 'style': 'margin-bottom:.9rem;' }, coverageTags)
					: '',
				E('div', { 'class': 'ikev2-inline-form' }, [ networkSelect, addNetworkBtn ])
			]),
			E('h4', { 'style': 'margin:1.2rem 0 .5rem;' },
				[ _('Custom device rules') ]),
			tableWrap,
			E('div', { 'class': 'ikev2-section', 'style': 'margin-top:1rem;' }, [
				E('h4', { 'style': 'margin:.2em 0 .5em;' },
					[ _('Add device override') ]),
				E('p', { 'class': 'cbi-section-descr' },
					[ _('Per-device exception inserted before the base PBR rule.') ]),
				E('div', { 'class': 'ikev2-inline-form' },
					[ overrideInput, modeSelect, addOverrideBtn ])
			])
		]);
	},

	render: function(data) {
		var self = this;
		var systemConfig = common.parseKeyValues((data[6] || {}).stdout || '');

		/* ── Domains tab ────────────────────────────────────────────────── */
		var manual = data[0] || '';
		var manualAddresses = data[10] || '';
		var selected = {};
		var selectedLines = (data[1] || '').trim().split(/\s+/).filter(Boolean);
		var status = (data[2] || '').trim();
		var statusData = parseStatus(status);
		var routerStatus = parseStatus(((data[8] || {}).stdout || ''));
		var fakeipActive = routerStatus.engine === 'fakeip' &&
			routerStatus.service === 'running' &&
			routerStatus.nft === 'active' &&
			routerStatus.rule === 'active';
		var activeDomains = (data[5] || '').split('\n').filter(function(line) {
			return line.trim() && line.trim().charAt(0) !== '#';
		}).length;
		var catalogResult = data[3] || {};
		var services = (catalogResult.stdout || '').trim().split(/\s+/)
			.filter(function(name) {
				return /^[a-z0-9_]+$/.test(name);
			});
		var ipServices = {};
		((data[9] || {}).stdout || '').trim().split(/\s+/)
			.filter(function(name) {
				return /^[a-z0-9_]+$/.test(name);
			})
			.forEach(function(name) {
				ipServices[name] = true;
			});

		for (var i = 0; i < selectedLines.length; i++)
			selected[selectedLines[i]] = true;
		serviceSelection = Object.assign({}, selected);

		var serviceNodes = renderServiceGroups(services, selected, ipServices);

		if (!serviceNodes.length) {
			serviceNodes.push(E('p', { 'class': 'alert-message warning' }, [
				_('The community catalog is temporarily unavailable. Saved selections and cached lists are preserved.')
			]));
		}

		var engineResult = common.inlineResult();
		var enginePill = common.pill(
			fakeipActive ? _('Reliable mode active') : _('Legacy mode active'),
			fakeipActive ? 'good' : 'warn');
		var engineSummary = E('p', {
			'class': 'ikev2-engine-summary'
		}, [ fakeipActive ?
			_('Selected domains receive stable FakeIP addresses. Only connections to those addresses from covered networks enter the IKEv2 path.') :
			_('dnsmasq currently classifies domains by their public IP addresses. Existing connections may keep an earlier WAN route after an address changes.') ]);
		var engineButton = E('button', {
			'class': 'cbi-button ' + (fakeipActive ? 'cbi-button-reset' : 'cbi-button-apply')
		}, [ fakeipActive ? _('Use legacy mode') : _('Enable reliable mode') ]);
		function updateEngineState(active, message) {
			fakeipActive = active;
			common.setPill(enginePill,
				active ? _('Reliable mode active') : _('Legacy mode active'),
				active ? 'good' : 'warn');
			engineSummary.textContent = active ?
				_('Selected domains receive stable FakeIP addresses. Only connections to those addresses from covered networks enter the IKEv2 path.') :
				_('dnsmasq currently classifies domains by their public IP addresses. Existing connections may keep an earlier WAN route after an address changes.');
			engineButton.className = 'cbi-button ' +
				(active ? 'cbi-button-reset' : 'cbi-button-apply');
			engineButton.textContent = active ?
				_('Use legacy mode') : _('Enable reliable mode');
			if (message)
				engineResult.ok(message);
		}
		engineButton.addEventListener('click', function() {
			var command = fakeipActive ? 'deactivate-async' : 'activate-async';
			var targetActive = !fakeipActive;
			return common.runAction({
				button: engineButton,
				result: engineResult,
				busy: fakeipActive ? _('Disabling...') : _('Enabling...'),
				run: function() {
					return common.execChecked(domainRouterHelper, [ command ],
						_('Unable to start routing-engine change')).then(function(response) {
						var actionId = parseStatus(response.stdout || '').action_id;
						if (!actionId)
							throw new Error(_('Action did not start'));
						return pollDomainRouter(actionId, Date.now() + 60000);
					}).then(function(st) {
						if (!st)
							throw new Error(_('The operation continues in the background.'));
						if (st.state === 'error')
							throw new Error(st.message || _('Operation failed'));
						updateEngineState(targetActive, st.message || _('Saved.'));
					});
				}
			});
		});

		var domainsContent = E('div', {}, [
			common.section(_('Domain routing engine'),
				_('Reliable mode keeps selected domains on the IKEv2 route even when their public addresses change. Other traffic continues through the normal WAN.'),
				E('div', { 'class': 'ikev2-engine' }, [
					E('div', { 'class': 'ikev2-engine-head' }, [
						E('div', { 'class': 'ikev2-engine-state' }, [
							enginePill,
							engineSummary
						]),
						E('div', { 'class': 'ikev2-engine-action' }, [
							engineResult.node,
							engineButton
						])
					])
				])),
			common.section(_('Community services'),
				_('Curated targets are cached locally and merged atomically. Services marked IP also include their direct protocol networks. Broad infrastructure groups may route unrelated sites.'),
				E('div', {}, [
					E('div', {}, serviceNodes),
					E('pre', {
						'id': 'ikev2-status-line',
						'class': 'ikev2-status-box',
						'style': status ? '' : 'display:none;'
					}, [ status ])
				])),
			common.section(_('Custom domains'),
				_('One plain domain per line. Custom entries are never overwritten by service updates.'),
				E('textarea', {
					'id': 'ikev2-domain-list',
					'class': 'cbi-input-textarea ikev2-domain-editor',
					'spellcheck': 'false'
				}, [ manual ])),
			common.section(_('Custom IP addresses and networks'),
				_('One IPv4 address or CIDR network per line. A single address is stored as /32.'),
				E('textarea', {
					'id': 'ikev2-address-list',
					'class': 'cbi-input-textarea ikev2-domain-editor',
					'spellcheck': 'false',
					'placeholder': '203.0.113.10\n198.51.100.0/24'
				}, [ manualAddresses ]))
		]);

		var saveResult = common.inlineResult();
		var saveBtn = E('button', { 'class': 'cbi-button cbi-button-apply' }, [ _('Save') ]);
		saveBtn.addEventListener('click', function() {
			return common.runAction({
				button: saveBtn,
				result: saveResult,
				busy: _('Saving...'),
				run: function() {
					return self.doSave(saveResult);
				}
			});
		});

		return E([
			common.styles(),
			E('div', { 'class': 'ikev2-page' }, [
				common.header(_('Policy Routing'),
					_('Build the IPv4 VPN policy from curated services, custom destinations and per-device modes.'),
					common.pill(statusData.state === 'ok' || activeDomains > 0 ?
						_('Policy active') : _('Policy empty'),
						statusData.state === 'ok' || activeDomains > 0 ? 'good' : 'warn')),
				domainsContent,
				E('div', { 'class': 'ikev2-note warn' }, [
					_('Clients must use router DNS. Plain DNS is redirected and DoT is blocked, but browser DoH and Apple Private Relay must still be disabled for deterministic domain routing.')
				]),
				E('div', { 'class': 'ikev2-actions end', 'style': 'margin-top:1.1rem' }, [
					saveResult.node,
					saveBtn
				])
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
