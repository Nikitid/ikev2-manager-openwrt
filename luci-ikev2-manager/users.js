'use strict';
'require view';
'require fs';
'require ui';
'require ikev2-manager.shared as common';

var helper = '/usr/libexec/ikev2-manager';

function sessionsByUser(sas) {
	var result = {};
	sas.forEach(function(item) {
		var sa = item['ikev2-in'];
		if (!sa)
			return;
		var user = sa['remote-eap-id'] || sa['remote-id'] || _('Unknown');
		var children = Object.values(sa['child-sas'] || {});
		var bytesIn = 0, bytesOut = 0;
		children.forEach(function(child) {
			bytesIn += Number(child['bytes-in'] || 0);
			bytesOut += Number(child['bytes-out'] || 0);
		});
		if (!result[user])
			result[user] = [];
		result[user].push({
			id: sa.uniqueid,
			host: sa['remote-host'],
			vips: sa['remote-vips'] || [],
			established: sa.established,
			// strongSwan reports traffic relative to the router. For a remote
			// VPN user, router bytes-out are downloaded by the client and
			// router bytes-in are uploaded by the client.
			bytesReceived: bytesOut,
			bytesSent: bytesIn
		});
	});
	return result;
}

function runUserAction(button, args, success, opts) {
	opts = opts || {};
	return common.runAction({
		button: button,
		busy: opts.busy || _('Saving...'),
		run: function() {
			return common.execChecked(helper, args, _('Operation failed')).then(function() {
				ui.hideModal();
				ui.addNotification(null, E('p', {}, [ success ]), 'info');
				window.setTimeout(function() { window.location.reload(); }, 350);
			});
		},
		onError: function(message) {
			ui.addNotification(null, E('p', {}, [
				(opts.errMessage || _('Unable to save the VPN user: %s')).format(message)
			]), 'danger');
		}
	});
}

function passwordDialog(title, username, action, includeUsername) {
	var name = E('input', {
		'type': 'text',
		'class': 'cbi-input-text',
		'value': username || '',
		'placeholder': 'new-user',
		'autocomplete': 'off'
	});
	var password = E('input', {
		'type': 'text',
		'class': 'cbi-input-text',
		'placeholder': _('Password'),
		'autocomplete': 'off'
	});
	var fields = [];

	if (includeUsername) {
		fields.push(common.fieldLabel(_('Username'), _('Letters, digits, dot, dash and underscore.')));
		fields.push(name);
	}
	fields.push(common.fieldLabel(_('Password'), _('Visible by design to LuCI administrators.')));
	fields.push(password);

	ui.showModal(title, [
		E('div', { 'class': 'ikev2-page' }, [
			common.styles(),
			E('div', { 'class': 'ikev2-form-grid' }, fields),
			E('div', { 'class': 'right', 'style': 'margin-top:1.2rem;' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]),
				' ',
				E('button', {
					'class': 'btn cbi-button-positive',
					'click': function(ev) {
						var button = ev.currentTarget;
						var user = includeUsername ? name.value.trim() : username;
						if (!/^[A-Za-z0-9_.@-]{1,64}$/.test(user)) {
							ui.addNotification(null, E('p', {}, [ _('Invalid username.') ]), 'warning');
							return;
						}
						if (!password.value) {
							ui.addNotification(null, E('p', {}, [ _('Password is required.') ]), 'warning');
							return;
						}
						return runUserAction(button, [ action, user, password.value ],
							includeUsername ? _('VPN user added.') : _('Password changed.'));
					}
				}, [ _('Save') ])
			])
		])
	]);
	(includeUsername ? name : password).focus();
}

return view.extend({
	load: function() {
		return L.resolveDefault(fs.stat('/usr/sbin/swanmon'), null).then(function(ready) {
			if (!ready)
				return { ready: false };
			return Promise.all([
				fs.exec(helper, [ 'users-show' ]),
				L.resolveDefault(fs.exec('/usr/sbin/swanmon', [ 'list-sas' ]), { stdout: '' })
			]).then(function(d) { d.ready = true; return d; });
		});
	},

	render: function(data) {
		if (!data.ready)
			return E([ common.styles(), common.gate(_('VPN Users'),
				_('Manage inbound IKEv2 credentials and current sessions. Traffic counters reset when a session reconnects.')) ]);
		var users = (data[0].stdout || '').replace(/\r/g, '').split('\n')
			.filter(Boolean)
			.map(function(line) { return { name: line }; });
		var sessions = sessionsByUser(common.parseSwanmon(data[1]));
		var online = Object.keys(sessions).reduce(function(total, user) {
			return total + sessions[user].length;
		}, 0);
		var userCards = [];

		function actionButton(icon, label, className, handler) {
			return E('button', {
				'class': 'cbi-button ikev2-icon-button ' + className,
				'type': 'button',
				'title': label,
				'aria-label': label,
				'click': handler
			}, [ common.icon(icon), E('span', {}, [ label ]) ]);
		}

		users.forEach(function(entry) {
			var active = sessions[entry.name] || [];
			var sessionNode = active.length ? E('div', { 'class': 'ikev2-session-list' },
				active.map(function(session) {
					var disconnectLabel = _('Disconnect');
					return E('div', { 'class': 'ikev2-session' }, [
						E('div', { 'class': 'ikev2-session-main' }, [
							E('span', { 'class': 'ikev2-session-address' }, [
								(session.vips || []).join(', ') || session.host || '-'
							]),
							E('div', { 'class': 'ikev2-session-meta' }, [
								E('span', {}, [
									_('Online for %s').format(common.formatDuration(session.established))
								]),
								E('span', {
									'class': 'ikev2-traffic received',
									'title': _('Received'),
									'aria-label': _('Received %s').format(common.formatBytes(session.bytesReceived))
								}, [
									common.icon('down'),
									E('span', {}, [ common.formatBytes(session.bytesReceived) ])
								]),
								E('span', {
									'class': 'ikev2-traffic sent',
									'title': _('Sent'),
									'aria-label': _('Sent %s').format(common.formatBytes(session.bytesSent))
								}, [
									common.icon('up'),
									E('span', {}, [ common.formatBytes(session.bytesSent) ])
								])
							])
						]),
						actionButton('disconnect', disconnectLabel, 'cbi-button-neutral', function(ev) {
							runUserAction(ev.currentTarget,
								[ 'disconnect', String(session.id) ],
								_('Session disconnected.'),
								{ busy: _('Disconnecting...'),
								  errMessage: _('Unable to disconnect the session: %s') });
						})
					]);
				})) : E('div', { 'class': 'ikev2-session-meta' }, [ _('No active sessions') ]);

			var changeLabel = _('Change password');
			var deleteLabel = _('Delete');
			userCards.push(E('div', { 'class': 'ikev2-user-card' }, [
				E('div', { 'class': 'ikev2-user-identity' }, [
					E('span', { 'class': 'ikev2-user-avatar' }, [ entry.name.slice(0, 1) || '?' ]),
					E('div', { 'style': 'min-width:0' }, [
						E('strong', { 'class': 'ikev2-user-name' }, [ entry.name ]),
						active.length ?
							common.pill(active.length > 1 ?
								_('%d active sessions').format(active.length) : _('Online'), 'good') :
							common.pill(_('Offline'), 'neutral')
					])
				]),
				sessionNode,
				E('div', { 'class': 'ikev2-user-actions' }, [
					actionButton('key', changeLabel, 'cbi-button-edit', function() {
							passwordDialog(_('Change password'), entry.name,
								'user-password', false);
						}),
					actionButton('trash', deleteLabel, 'cbi-button-remove', function(ev) {
							if (!window.confirm(_('Delete user %s?').format(entry.name)))
								return;
							runUserAction(ev.currentTarget,
								[ 'user-delete', entry.name ],
								_('VPN user deleted.'),
								{ busy: _('Deleting...'),
								  errMessage: _('Unable to delete the VPN user: %s') });
						})
				])
			]));
		});

		var add = actionButton('addUser', _('Add user'), 'cbi-button-add', function() {
				passwordDialog(_('Add VPN user'), '', 'user-add', true);
			});
		var disconnectAll = actionButton('disconnectAll', _('Disconnect all'),
			'cbi-button-negative', function(ev) {
				if (!window.confirm(_('Disconnect all active VPN sessions?')))
					return;
				runUserAction(ev.currentTarget, [ 'disconnect-all' ],
					_('All sessions disconnected.'),
					{ busy: _('Disconnecting...'),
					  errMessage: _('Unable to disconnect sessions: %s') });
			});
		disconnectAll.disabled = !online;

		return E([
			common.styles(),
			E('div', { 'class': 'ikev2-page' }, [
				common.header(_('VPN Users'),
					_('Manage inbound IKEv2 credentials and current sessions. Traffic counters reset when a session reconnects.')),
				common.section(_('Access list'),
					_('Passwords are write-only. Set a new password if one is lost; router backups still contain secrets.'),
					E('div', {}, [
						E('div', { 'class': 'ikev2-note', 'style': 'margin-bottom:1rem' }, [
							_('Online shows only IKEv2 sessions terminating on this router. A device connected to the outbound VPS tunnel is shown on the Outbound Tunnel page and is not counted here.')
						]),
						users.length ? E('div', { 'class': 'ikev2-user-list' }, userCards) :
						E('div', { 'class': 'ikev2-empty' }, [
							_('No VPN users configured.')
						]),
						E('div', { 'class': 'ikev2-actions end ikev2-save-bar' }, [
							disconnectAll,
							add
						])
					]),
					E('div', { 'class': 'ikev2-actions' }, [
						common.pill(_('%d users').format(users.length), 'info'),
						common.pill(_('%d online').format(online), online ? 'good' : 'neutral')
					]))
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
