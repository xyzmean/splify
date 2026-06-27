include $(TOPDIR)/rules.mk

PKG_NAME:=splify
PKG_VERSION:=$(strip $(shell cat $(CURDIR)/../VERSION 2>/dev/null || echo 1.0.0))
PKG_RELEASE:=1
PKG_MAINTAINER:=xyzmean
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/splify
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Local WireGuard/AmneziaWG split-tunnel with priority failover + zapret
  URL:=https://github.com/xyzmean/splify
  DEPENDS:=+nftables +curl +dnsmasq-full +ip-full +kmod-nft-core
  PKGARCH:=all
endef

define Package/splify/description
 Policy-routes LAN traffic over one of several WireGuard/AmneziaWG tunnels.
 Downloads IP lists (blocked/foreign -> VPN, ru/cn -> direct) and optional domain
 lists, builds a zapret nozapret bypass set, and runs a priority failover loop
 across the configured tunnels: restart a stuck tunnel first, fall over to the
 next priority, then degrade to zapret DPI-bypass on WAN, then plain WAN, always
 recovering toward priority #1. Fully local — configured via UCI/LuCI, no API.
 zapret is optional and detected at runtime.
endef

define Package/splify/conffiles
/etc/config/splify
endef

Build/Compile:=

define Package/splify/install
	$(INSTALL_DIR) $(1)
	$(CP) ./files/* $(1)/
	chmod 0755 $(1)/usr/local/sbin/splify-* $(1)/etc/init.d/splify $(1)/usr/libexec/rpcd/splify
endef

define Package/splify/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
# daily list refresh (idempotent)
CRON=/etc/crontabs/root; touch "$$CRON"
grep -q 'splify-update-ipsum'   "$$CRON" || echo '30 4 * * * /usr/local/sbin/splify-update-ipsum >/dev/null 2>&1'   >> "$$CRON"
grep -q 'splify-update-ru'      "$$CRON" || echo '45 4 * * * /usr/local/sbin/splify-update-ru >/dev/null 2>&1'      >> "$$CRON"
grep -q 'splify-update-domains' "$$CRON" || echo '50 4 * * * /usr/local/sbin/splify-update-domains >/dev/null 2>&1' >> "$$CRON"
/etc/init.d/cron enable >/dev/null 2>&1; /etc/init.d/cron restart >/dev/null 2>&1
/etc/init.d/splify enable >/dev/null 2>&1
/etc/init.d/splify restart >/dev/null 2>&1
# register the splify ubus object (rpcd plugin) so LuCI can call it
/etc/init.d/rpcd reload >/dev/null 2>&1
# first list fetch in the background so the install returns promptly
( /usr/local/sbin/splify-update-ipsum; /usr/local/sbin/splify-update-ru; /usr/local/sbin/splify-update-domains ) >/dev/null 2>&1 &
exit 0
endef

define Package/splify/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/usr/local/sbin/splify-uninstall >/dev/null 2>&1 || true
exit 0
endef

$(eval $(call BuildPackage,splify))
