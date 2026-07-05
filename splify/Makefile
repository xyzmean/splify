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
  TITLE:=splify — простой split-tunnel VPN-шлюз для OpenWrt
  URL:=https://github.com/xyzmean/splify
  DEPENDS:=+nftables +curl +dnsmasq-full +ip-full +kmod-nft-core
  PKGARCH:=all
endef

define Package/splify/description
 splify маршрутизирует трафик локальной сети через WireGuard/AmneziaWG-туннель:
 заблокированное идёт через VPN, остальное — напрямую. Приоритетный failover между
 туннелями, автообновляемые списки, опциональный обход DPI (zapret). Управление —
 через простую страницу в LuCI. zapret опционален и определяется в рантайме.
 Также поддерживаются sing-box туннели (VLESS/Hysteria2) как опциональный
 транспорт failover — требует отдельно установленного пакета sing-box
 (opkg install sing-box), определяется в рантайме, как и zapret.
endef

define Package/splify/conffiles
/etc/config/splify
endef

Build/Compile:=

define Package/splify/install
	$(INSTALL_DIR) $(1)
	$(CP) ./files/* $(1)/
	chmod 0755 $(1)/usr/local/sbin/splify-* $(1)/etc/init.d/splify* $(1)/usr/libexec/rpcd/splify $(1)/www/cgi-bin/splify-api
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
# sing-box (VLESS/Hysteria2) endpoints: register the service (it self-gates on
# the sing-box package actually being installed, same runtime-detected
# convention as zapret, so enabling the init script is always safe).
/etc/init.d/splify-singbox enable >/dev/null 2>&1
/etc/init.d/splify-singbox start >/dev/null 2>&1
# remote-management agent: register the service (it self-gates on
# splify.api.agent_enabled, so enabling the init script is safe even when the
# agent is configured off — it simply won't open an instance).
/etc/init.d/splify-agent enable >/dev/null 2>&1
/etc/init.d/splify-agent start >/dev/null 2>&1
# register the splify ubus object (rpcd plugin) so LuCI can call it
/etc/init.d/rpcd reload >/dev/null 2>&1
# first list fetch in the background so the install returns promptly
( /usr/local/sbin/splify-update-ipsum; /usr/local/sbin/splify-update-ru; /usr/local/sbin/splify-update-domains ) >/dev/null 2>&1 &
exit 0
endef

define Package/splify/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/splify-agent stop >/dev/null 2>&1
/etc/init.d/splify-agent disable >/dev/null 2>&1
/usr/local/sbin/splify-uninstall >/dev/null 2>&1 || true
exit 0
endef

$(eval $(call BuildPackage,splify))
