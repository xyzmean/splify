include $(TOPDIR)/rules.mk

PKG_VERSION:=$(strip $(shell cat $(CURDIR)/../VERSION 2>/dev/null || echo 1.0.0))
PKG_RELEASE:=1
PKG_MAINTAINER:=xyzmean
PKG_LICENSE:=MIT

LUCI_TITLE:=splify — веб-интерфейс
LUCI_DEPENDS:=+luci-base +splify
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature to be used
