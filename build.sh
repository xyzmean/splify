#!/bin/bash
set -e

VERSION=$(cat VERSION | tr -d '\n')
BUILD_DIR="build_dir"
OUT_DIR="out"

mkdir -p $OUT_DIR
rm -rf $BUILD_DIR
mkdir -p $BUILD_DIR

# Build UI
echo "Building UI..."
cd luci-app-splify/ui
npm ci
npm run build
cd ../..

# po2lmo.py is checked into the repo root (a faithful port of OpenWrt LuCI's
# real po2lmo/sfh_hash — see that file's docstring for why: an earlier
# from-scratch reimplementation here produced files LuCI's i18n loader can't
# actually parse, corrupting the WHOLE Russian catalog since it aggregates
# every *.ru.lmo file it finds into one shared search list). Do NOT
# regenerate/overwrite it here — that previously clobbered the fixed copy on
# every build.

# Prepare ipkg-build
if [ ! -f ipkg-build ]; then
    wget https://raw.githubusercontent.com/openwrt/openwrt/master/scripts/ipkg-build -O ipkg-build
    chmod +x ipkg-build
fi

build_pkg() {
    local pkg_name=$1
    local version=$2
    local depends=$3
    local description=$4
    local src_dir=$5
    local postinst=$6
    local prerm=$7
    local conffiles=$8

    local pkg_dir="$BUILD_DIR/$pkg_name"
    mkdir -p "$pkg_dir/CONTROL"
    
    cat <<EOF3 > "$pkg_dir/CONTROL/control"
Package: $pkg_name
Version: $version-1
Depends: $depends
Architecture: all
Maintainer: xyzmean
Section: net
Description: $description
EOF3

    if [ -n "$postinst" ]; then
        echo "$postinst" > "$pkg_dir/CONTROL/postinst"
        chmod +x "$pkg_dir/CONTROL/postinst"
    fi
    
    if [ -n "$prerm" ]; then
        echo "$prerm" > "$pkg_dir/CONTROL/prerm"
        chmod +x "$pkg_dir/CONTROL/prerm"
    fi

    if [ -n "$conffiles" ]; then
        echo "$conffiles" > "$pkg_dir/CONTROL/conffiles"
    fi

    if [ -d "$src_dir" ]; then
        cp -r "$src_dir"/* "$pkg_dir/" || true
    fi
    
    ./ipkg-build "$pkg_dir" "$PWD/$OUT_DIR"
    
    # Rename ipk to use hyphen instead of underscore
    mv "$PWD/$OUT_DIR/${pkg_name}_${version}-1_all.ipk" "$PWD/$OUT_DIR/${pkg_name}-${version}-1_all.ipk" 2>/dev/null || true

    # Build APK
    local clean_deps=$(echo "$depends" | sed 's/,//g')
    local apk_script_args=""
    if [ -n "$postinst" ]; then
        echo "$postinst" > "$pkg_dir/.post-install"
        chmod +x "$pkg_dir/.post-install"
        apk_script_args="$apk_script_args --script post-install:$pkg_dir/.post-install"
    fi
    if [ -n "$prerm" ]; then
        echo "$prerm" > "$pkg_dir/.pre-deinstall"
        chmod +x "$pkg_dir/.pre-deinstall"
        apk_script_args="$apk_script_args --script pre-deinstall:$pkg_dir/.pre-deinstall"
    fi

    local out_apk="$OUT_DIR/${pkg_name}-${version}-1_noarch.apk"

    docker run --rm -v "$PWD":/workspace -w /workspace alpine:latest sh -c "apk update && apk add apk-tools && apk mkpkg --info name:$pkg_name --info version:$version-r1 --info description:'$description' --info arch:noarch --info depends:'$clean_deps' $apk_script_args -F $src_dir -o $out_apk"
    
    rm -f "$src_dir/.post-install" "$src_dir/.pre-deinstall"
}

# 1. splify
echo "Building splify..."
mkdir -p "$BUILD_DIR/splify_src"
cp -r splify/files/* "$BUILD_DIR/splify_src/"
chmod 0755 "$BUILD_DIR/splify_src/usr/local/sbin/"splify-* "$BUILD_DIR/splify_src/etc/init.d/splify"* "$BUILD_DIR/splify_src/usr/libexec/rpcd/splify" "$BUILD_DIR/splify_src/www/cgi-bin/splify-api"

read -r -d '' SPLIFY_POSTINST << 'EOF_POSTINST' || true
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
CRON=/etc/crontabs/root; touch "$CRON"
grep -q 'splify-update-ipsum'   "$CRON" || echo '30 4 * * * /usr/local/sbin/splify-update-ipsum'   >> "$CRON"
grep -q 'splify-update-ru'      "$CRON" || echo '45 4 * * * /usr/local/sbin/splify-update-ru'      >> "$CRON"
grep -q 'splify-update-domains' "$CRON" || echo '50 4 * * * /usr/local/sbin/splify-update-domains' >> "$CRON"
grep -q 'splify-telemetry'      "$CRON" || echo '0 */6 * * * /usr/local/sbin/splify-telemetry'     >> "$CRON"
/etc/init.d/cron enable; /etc/init.d/cron restart
/etc/init.d/splify enable
/etc/init.d/splify restart
/etc/init.d/splify-singbox enable
/etc/init.d/splify-singbox start
/etc/init.d/splify-agent enable
/etc/init.d/splify-agent start
/etc/init.d/rpcd reload
( /usr/local/sbin/splify-telemetry ) </dev/null >/dev/null 2>&1 &
( /usr/local/sbin/splify-update-ipsum; /usr/local/sbin/splify-update-ru; /usr/local/sbin/splify-update-domains ) </dev/null >/dev/null 2>&1 &
exit 0
EOF_POSTINST

read -r -d '' SPLIFY_PRERM << 'EOF_PRERM' || true
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/splify-agent stop
/etc/init.d/splify-agent disable
/usr/local/sbin/splify-uninstall || true
exit 0
EOF_PRERM

build_pkg "splify" "$VERSION" "nftables, curl, ip-full, kmod-nft-core" "splify VPN gateway" "$BUILD_DIR/splify_src" "$SPLIFY_POSTINST" "$SPLIFY_PRERM" "/etc/config/splify"

# 2. luci-app-splify
echo "Building luci-app-splify..."
mkdir -p "$BUILD_DIR/luci_src"
[ -d luci-app-splify/luasrc ] && cp -r luci-app-splify/luasrc/* "$BUILD_DIR/luci_src/" || true
[ -d luci-app-splify/root ] && cp -r luci-app-splify/root/* "$BUILD_DIR/luci_src/" || true
# LuCI view modules (the loader shims) + tracked static assets live under
# htdocs/. The old OpenWrt luci.mk installed htdocs/* to /www/ automatically;
# without the SDK that step is gone, so it MUST be done explicitly. Skipping it
# was what broke the dashboard with a "NetworkError": LuCI requests
# view/splify/main (action { type: view, path: "splify/main" }) and 404s the
# module because it never shipped in the package.
#
# NOTE: the destination www/ must exist BEFORE the copy. With a single-element
# glob (htdocs/luci-static) `cp -r <one> dest/` where dest is missing renames
# the source INTO dest — collapsing the luci-static path level so views land at
# www/resources/view/... instead of www/luci-static/resources/view/... (a 404).
mkdir -p "$BUILD_DIR/luci_src/www"
[ -d luci-app-splify/htdocs ] && cp -r luci-app-splify/htdocs/* "$BUILD_DIR/luci_src/www/" || true
mkdir -p "$BUILD_DIR/luci_src/www/luci-static/resources/splify"
cp -r luci-app-splify/ui/dist/* "$BUILD_DIR/luci_src/www/luci-static/resources/splify/"

# Cache-busting for the React bundles. Two things carry the release identity:
#   1. build-id.txt — fetched by the loader shims (main.js/advanced.js) with
#      cache:'no-store' and appended as ?v= to every bundle URL.
#   2. the ?v= query the entry bundles (splify-index.js/splify-settings.js) use
#      to import their shared chunk (splify-x.js) — npm build bakes a placeholder
#      "?v=0.0.0"; stamping the real VERSION keeps the entry+chunk pair pinned to
#      one release so a stale HTTP cache can't mix a new entry with an old chunk.
printf '%s\n' "$VERSION" > "$BUILD_DIR/luci_src/www/luci-static/resources/splify/build-id.txt"
sed -i -E "s/\?v=[0-9]+\.[0-9]+\.[0-9]+/?v=$VERSION/g" \
    "$BUILD_DIR/luci_src/www/luci-static/resources/splify/splify-index.js" \
    "$BUILD_DIR/luci_src/www/luci-static/resources/splify/splify-settings.js"

read -r -d '' LUCI_POSTINST << 'EOF_LUCI_POSTINST' || true
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
	exit 0
}
EOF_LUCI_POSTINST

build_pkg "luci-app-splify" "$VERSION" "luci-base, splify" "LuCI support for splify" "$BUILD_DIR/luci_src" "$LUCI_POSTINST" "" ""

# 3. luci-i18n-splify-ru
echo "Building luci-i18n-splify-ru..."
mkdir -p "$BUILD_DIR/i18n_src/usr/lib/lua/luci/i18n"
mkdir -p "$BUILD_DIR/i18n_src/etc/uci-defaults"

python3 po2lmo.py luci-app-splify/po/ru/splify.po "$BUILD_DIR/i18n_src/usr/lib/lua/luci/i18n/splify.ru.lmo"

cat << 'EOF_I18N_DEFAULTS' > "$BUILD_DIR/i18n_src/etc/uci-defaults/luci-i18n-splify-ru"
uci set luci.languages.ru='Русский (Russian)'; uci commit luci
EOF_I18N_DEFAULTS
chmod +x "$BUILD_DIR/i18n_src/etc/uci-defaults/luci-i18n-splify-ru"

build_pkg "luci-i18n-splify-ru" "$VERSION" "luci-app-splify" "Russian translation for splify" "$BUILD_DIR/i18n_src" "" "" ""

echo "All packages built in $OUT_DIR/"
ls -la $OUT_DIR/

