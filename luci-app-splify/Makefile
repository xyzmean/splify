include $(TOPDIR)/rules.mk

PKG_VERSION:=$(strip $(shell cat $(CURDIR)/../VERSION 2>/dev/null || echo 1.0.0))
PKG_RELEASE:=1
PKG_MAINTAINER:=xyzmean
PKG_LICENSE:=MIT

LUCI_TITLE:=splify — веб-интерфейс
LUCI_DEPENDS:=+luci-base +splify
LUCI_PKGARCH:=all

# htdocs ships PRE-minified ES2020 bundles (built by the ui/ toolchain). luci.mk
# would otherwise pipe every .js through Crockford's jsmin, which predates
# template literals: it treats the `//` of an `http://…` INSIDE a backtick
# string as a comment and, on a single-line bundle, silently discards the whole
# rest of the file — the LuCI page then dies with "Unexpected end of input".
# Same story for csstidy vs the modern (already-minified) stylesheet.
LUCI_MINIFY_JS:=0
LUCI_MINIFY_CSS:=0

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature to be used
