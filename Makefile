include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-ikev2-manager
# Source of truth for package identity is ../release.env, consumed by the
# canonical build (scripts/build-ipk.sh). These SDK literals are kept in sync
# manually because OpenWrt's relative include path is unreliable;
# scripts/check-version-sync.sh fails the canonical build if they drift (B3).
PKG_VERSION:=1.0.0
PKG_RELEASE:=6
PKG_LICENSE:=MIT
PKG_MAINTAINER:=nikitid
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-ikev2-manager
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=IKEv2 Manager for OpenWrt
  URL:=https://github.com/nikitid/ikev2-manager-openwrt
  DEPENDS:= \
	+luci-base \
	+rpcd-mod-file \
	+jsonfilter
endef

define Package/luci-app-ikev2-manager/description
 LuCI application and runtime for an IPv4 IKEv2 client, an optional
 road-warrior IKEv2 server, domain-based PBR, device overrides and
 fail-closed routing on OpenWrt 24.10.
endef

define Package/luci-app-ikev2-manager/conffiles
/etc/config/ikev2-manager
/etc/pbr-ikev2-domains.txt
/etc/pbr-ikev2-domains.manual.txt
/etc/pbr-ikev2-addresses.manual.txt
/etc/pbr-ikev2-community-selected.txt
endef

define Build/Compile
endef

define Package/luci-app-ikev2-manager/preinst
#!/bin/sh
set -eu
[ -n "$${IPKG_INSTROOT:-}" ] && exit 0
[ -r /etc/openwrt_release ] || {
	echo "IKEv2 Manager for OpenWrt: OpenWrt is required" >&2
	exit 1
}
. /etc/openwrt_release
[ "$${DISTRIB_ID:-}" = OpenWrt ] || {
	echo "IKEv2 Manager for OpenWrt: official OpenWrt is required" >&2
	exit 1
}
case "$${DISTRIB_RELEASE:-}" in
	24.10.*) ;;
	25.12.*)
		echo "IKEv2 Manager for OpenWrt: OpenWrt 25.12/apk is not supported yet" >&2
		exit 1
		;;
	*)
		echo "IKEv2 Manager for OpenWrt: OpenWrt 24.10.x is required" >&2
		exit 1
		;;
esac
grep -qE 'downloads\.openwrt\.org/releases/24\.10\.' /etc/opkg/distfeeds.conf 2>/dev/null || {
	echo "IKEv2 Manager for OpenWrt: official OpenWrt 24.10 release feeds are required" >&2
	exit 1
}
opkg status luci-app-ikev2-pbr 2>/dev/null | grep -q '^Status: .* installed' && {
	echo "IKEv2 Manager for OpenWrt: migrate the legacy package with scripts/install.sh" >&2
	exit 1
}
exit 0
endef

define Package/luci-app-ikev2-manager/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./openwrt/files/etc/config/ikev2-manager $(1)/etc/config/ikev2-manager

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./ikev2-manager-runtime/ikev2-xfrm.init $(1)/etc/init.d/ikev2-xfrm
	$(INSTALL_BIN) ./ikev2-manager-runtime/ikev2-health.init $(1)/etc/init.d/ikev2-health
	$(INSTALL_BIN) ./ikev2-manager-runtime/ikev2-domain-router.init $(1)/etc/init.d/ikev2-domain-router

	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface $(1)/etc/hotplug.d/acme
	$(INSTALL_BIN) ./ikev2-manager-runtime/90-ikev2-wan $(1)/etc/hotplug.d/iface/90-ikev2-pbr
	$(INSTALL_BIN) ./ikev2-manager-runtime/90-ikev2-acme $(1)/etc/hotplug.d/acme/90-ikev2-pbr

	$(INSTALL_DIR) $(1)/etc/strongswan.d/charon
	$(INSTALL_CONF) ./ikev2-manager-runtime/20-router-xfrm.conf $(1)/etc/strongswan.d/charon/20-ikev2-pbr.conf

	$(INSTALL_DIR) $(1)/etc/ikev2-manager
	$(INSTALL_DATA) ./openwrt/files/etc/ikev2-manager/README $(1)/etc/ikev2-manager/README
	$(INSTALL_CONF) ./openwrt/files/etc/pbr-ikev2-domains.manual.txt $(1)/etc/pbr-ikev2-domains.manual.txt
	$(INSTALL_CONF) ./openwrt/files/etc/pbr-ikev2-addresses.manual.txt $(1)/etc/pbr-ikev2-addresses.manual.txt
	touch $(1)/etc/pbr-ikev2-domains.txt
	touch $(1)/etc/pbr-ikev2-community-selected.txt
	chmod 600 $(1)/etc/pbr-ikev2-domains.txt
	chmod 600 $(1)/etc/pbr-ikev2-community-selected.txt

	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./openwrt/files/lib/upgrade/keep.d/ikev2-manager $(1)/lib/upgrade/keep.d/ikev2-manager

	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./luci-ikev2-manager/ikev2-manager.sh $(1)/usr/libexec/ikev2-manager
	$(INSTALL_BIN) ./ikev2-manager-runtime/ikev2-manager-system.sh $(1)/usr/libexec/ikev2-manager-system
	$(INSTALL_DIR) $(1)/usr/libexec/ikev2-manager.d
	$(INSTALL_DATA) ./ikev2-manager-runtime/lib/actions.sh $(1)/usr/libexec/ikev2-manager.d/actions.sh
	$(INSTALL_DATA) ./ikev2-manager-runtime/lib/routing.sh $(1)/usr/libexec/ikev2-manager.d/routing.sh
	$(INSTALL_BIN) ./ikev2-manager-runtime/ikev2-health.sh $(1)/usr/libexec/ikev2-health
	$(INSTALL_BIN) ./ikev2-manager-runtime/ikev2-sync-vips.sh $(1)/usr/libexec/ikev2-sync-vips
	$(INSTALL_BIN) ./ikev2-manager-runtime/ikev2-domain-router.sh $(1)/usr/libexec/ikev2-domain-router
	$(INSTALL_BIN) ./luci-ikev2-domains/community-domains.sh $(1)/usr/libexec/ikev2-domains-community
	$(INSTALL_BIN) ./luci-ikev2-domains/restart-pbr.sh $(1)/usr/libexec/ikev2-domains-restart
	$(INSTALL_BIN) ./luci-ikev2-domains/ikev2-devices.sh $(1)/usr/libexec/ikev2-devices

	$(INSTALL_DIR) $(1)/usr/share/pbr
	$(INSTALL_BIN) ./ikev2-manager-runtime/pbr.user.ikev2out $(1)/usr/share/pbr/pbr.user.ikev2out

	$(INSTALL_DIR) $(1)/usr/share/ikev2-manager/ca
	$(INSTALL_DATA) ./ikev2-manager-runtime/ca/isrg-root-x1.pem $(1)/usr/share/ikev2-manager/ca/isrg-root-x1.pem
	$(INSTALL_DATA) ./ikev2-manager-runtime/ca/isrg-root-x2.pem $(1)/usr/share/ikev2-manager/ca/isrg-root-x2.pem

	$(INSTALL_DIR) $(1)/usr/share/licenses/luci-app-ikev2-manager
	$(INSTALL_DATA) ./LICENSE $(1)/usr/share/licenses/luci-app-ikev2-manager/LICENSE
	$(INSTALL_DATA) ./NOTICE $(1)/usr/share/licenses/luci-app-ikev2-manager/NOTICE

	$(INSTALL_DIR) $(1)/usr/share/ikev2-domains/local-services
	$(INSTALL_DATA) ./luci-ikev2-domains/community-services.txt $(1)/usr/share/ikev2-domains/community-services
	$(INSTALL_DATA) ./luci-ikev2-domains/local-services/*.lst $(1)/usr/share/ikev2-domains/local-services/
	$(INSTALL_DATA) ./luci-ikev2-domains/local-services/*.cidrs $(1)/usr/share/ikev2-domains/local-services/

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./luci-ikev2-manager/menu.json $(1)/usr/share/luci/menu.d/luci-app-ikev2-manager.json
	$(INSTALL_DATA) ./luci-ikev2-manager/acl.json $(1)/usr/share/rpcd/acl.d/luci-app-ikev2-manager.json

	$(INSTALL_DIR) $(1)/www/luci-static/resources/ikev2-manager
	$(INSTALL_DATA) ./luci-ikev2-manager/shared.js $(1)/www/luci-static/resources/ikev2-manager/shared.js

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/ikev2-manager
	$(INSTALL_DATA) ./luci-ikev2-manager/setup.js $(1)/www/luci-static/resources/view/ikev2-manager/setup.js
	$(INSTALL_DATA) ./luci-ikev2-manager/users.js $(1)/www/luci-static/resources/view/ikev2-manager/users.js
	$(INSTALL_DATA) ./luci-ikev2-manager/settings.js $(1)/www/luci-static/resources/view/ikev2-manager/settings.js
	$(INSTALL_DATA) ./luci-ikev2-manager/client.js $(1)/www/luci-static/resources/view/ikev2-manager/client.js

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/ikev2-domains
	$(INSTALL_DATA) ./luci-ikev2-domains/editor.js $(1)/www/luci-static/resources/view/ikev2-domains/editor.js
endef

define Package/luci-app-ikev2-manager/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
rm -f /usr/share/nftables.d/chain-pre/forward/20-ikev2-pbr-killswitch.nft
rm -f /usr/share/nftables.d/chain-pre/forward/20-ikev2-killswitch.nft
if [ "$$(uci -q get ikev2-manager.globals.configured)" = 1 ]; then
	fw4 -q reload >/dev/null 2>&1 || true
fi
if [ "$$(uci -q get ikev2-manager.globals.configured)" = 1 ] || \
   [ "$$(uci -q get ikev2-manager.client.enabled)" = 1 ] || \
   [ "$$(uci -q get ikev2-manager.server.enabled)" = 1 ]; then
	echo "Existing configuration detected; runtime was not started automatically."
fi
echo "IKEv2 Manager for OpenWrt installed."
echo "Open LuCI -> Services -> IKEv2 Manager for OpenWrt."
exit 0
endef

define Package/luci-app-ikev2-manager/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
# Overview owns runtime cleanup. Keeping prerm non-destructive prevents
# opkg upgrades from briefly deleting live XFRM interfaces.
exit 0
endef

$(eval $(call BuildPackage,luci-app-ikev2-manager))
