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

# splify-dns (native domain-routing backend) is the one compiled package in
# this repo — everything else is noarch shell/Lua/static assets built with no
# compiler at all. apk's arch check on OpenWrt is an EXACT string match
# against the board's own /etc/apk/arch (confirmed empirically: a real
# aarch64_cortex-a53 board's /etc/apk/arch contains ONLY that string, no
# generic-ISA fallback) — so this ships a few common, EXACT OpenWrt target
# arch strings rather than one generic-per-ISA build. Not every board is
# covered (see docs); `apk add splify-dns` simply fails cleanly on an
# unlisted arch, and splify's DOMAIN_BACKEND auto-detection (common.sh)
# falls back to the dnsmasq nftset path with zero behavior change.
#
# Fields: arch : fallback-cc : fallback-apt-pkg : zig-target : zig-mcpu
#
# The zig fields are the PRIMARY build path (musl, in a container — see
# splify-dns/build/Dockerfile). The cc fields are a fallback for a machine with
# no docker; it produces a static GLIBC binary, ~9x larger, and for mipsel_24kc
# it produces one that does not run at all: Debian's mipsel-linux-gnu is
# hard-float while this OpenWrt target is soft-float, so the daemon dies with
# SIGILL on the board (verified on a Mi Router 4C). That target is therefore
# skipped rather than shipped broken when the container path is unavailable.
NATIVE_TARGETS="
aarch64_cortex-a53:aarch64-linux-gnu-gcc:gcc-aarch64-linux-gnu:aarch64-linux-musl:baseline
arm_cortex-a7:arm-linux-gnueabihf-gcc:gcc-arm-linux-gnueabihf:arm-linux-musleabihf:cortex_a7
mipsel_24kc:mipsel-linux-gnu-gcc-10:gcc-10-mipsel-linux-gnu:mipsel-linux-musl:mips32r2+soft_float
x86_64:gcc::x86_64-linux-musl:baseline
"

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

# ---- splify-dnsd: musl cross build in a container ---------------------------
# The image is built once and cached; see splify-dns/build/Dockerfile for why the
# binary must be static musl and what the alternative costs.
DNSD_IMAGE="splify-dnsd-builder:zig-0.13.0"

dnsd_builder_ready() {
    command -v docker >/dev/null 2>&1 || return 1
    docker image inspect "$DNSD_IMAGE" >/dev/null 2>&1 && return 0
    echo "splify-dns: building the musl cross image (one time, ~45MB download)..."
    docker build -q -t "$DNSD_IMAGE" splify-dns/build >/dev/null 2>&1
}

# $1=output path (repo-relative) $2=zig target triple $3=zig mcpu
dnsd_compile_musl() {
    docker run --rm -v "$PWD:/src" -w /src "$DNSD_IMAGE" \
        cc -target "$2" -mcpu="$3" -static -Os -Wall -Wextra \
           -o "$1" splify-dns/src/splify-dnsd.c
}

# Cross-compiles the splify-dnsd binary for one OpenWrt target arch and packages
# it (ipk + apk), Architecture-tagged with that exact arch string — mirrors
# build_pkg's shape but with a real compiled binary instead of noarch files.
# $1=arch $2=fallback-cc $3=apt-package-providing-cc $4=zig target $5=zig mcpu
build_native_pkg() {
    local arch=$1
    local cc=$2
    local cc_apt_pkg=$3
    local ztarget=$4
    local zmcpu=$5

    local pkg_dir="$BUILD_DIR/splify-dns_$arch"
    mkdir -p "$pkg_dir/usr/sbin" "$pkg_dir/etc/init.d"
    local out="$pkg_dir/usr/sbin/splify-dnsd"

    if [ -n "$ztarget" ] && dnsd_builder_ready; then
        if ! dnsd_compile_musl "$out" "$ztarget" "$zmcpu"; then
            echo "splify-dns/$arch: musl compile failed — skipping this target"
            return 0
        fi
        echo "splify-dns/$arch: musl static, $(stat -c %s "$out") bytes"
    else
        # No container available. Static glibc instead: ~9x larger, and for
        # mipsel_24kc simply wrong — Debian's mipsel-linux-gnu is hard-float while
        # this target is soft-float, so the binary dies with SIGILL on the board
        # (verified on a Mi Router 4C). Shipping nothing beats shipping that:
        # splify falls back to the dnsmasq nftset backend on its own.
        case "$arch" in
            mipsel_*)
                echo "splify-dns/$arch: needs the musl container (docker); the glibc cross builds a soft-float-incompatible binary — skipping"
                return 0 ;;
        esac
        if ! command -v "$cc" >/dev/null 2>&1; then
            if [ -n "$cc_apt_pkg" ] && command -v apt-get >/dev/null 2>&1; then
                echo "splify-dns/$arch: installing $cc_apt_pkg..."
                apt-get install -y "$cc_apt_pkg" >/dev/null 2>&1 || true
            fi
        fi
        if ! command -v "$cc" >/dev/null 2>&1; then
            echo "splify-dns/$arch: '$cc' not available — skipping this target (other packages are unaffected)"
            return 0
        fi
        if ! "$cc" -static -Os -Wall -Wextra \
                -ffunction-sections -fdata-sections -Wl,--gc-sections -s \
                -o "$out" splify-dns/src/splify-dnsd.c; then
            echo "splify-dns/$arch: compile failed — skipping this target"
            return 0
        fi
        echo "splify-dns/$arch: static glibc fallback, $(stat -c %s "$out") bytes"
    fi
    chmod 0755 "$pkg_dir/usr/sbin/splify-dnsd"
    cp splify-dns/files/etc/init.d/splify-dns "$pkg_dir/etc/init.d/splify-dns"
    chmod 0755 "$pkg_dir/etc/init.d/splify-dns"

    local pkg_name="splify-dns"
    local ctrl_dir="$pkg_dir/CONTROL"
    mkdir -p "$ctrl_dir"
    cat <<EOF4 > "$ctrl_dir/control"
Package: $pkg_name
Version: $VERSION-1
Depends: splify, nftables
Architecture: $arch
Maintainer: xyzmean
Section: net
Description: Native domain-routing backend for splify (replaces dnsmasq nftset tagging)
EOF4

    read -r -d '' _DNS_POSTINST << 'EOF_DNS_POSTINST' || true
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
[ -x /usr/local/sbin/splify-apply ] && /usr/local/sbin/splify-apply >/dev/null 2>&1 || true
exit 0
EOF_DNS_POSTINST
    read -r -d '' _DNS_PRERM << 'EOF_DNS_PRERM' || true
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/splify-dns stop    >/dev/null 2>&1 || true
/etc/init.d/splify-dns disable >/dev/null 2>&1 || true
exit 0
EOF_DNS_PRERM
    echo "$_DNS_POSTINST" > "$ctrl_dir/postinst"; chmod +x "$ctrl_dir/postinst"
    echo "$_DNS_PRERM"    > "$ctrl_dir/prerm";    chmod +x "$ctrl_dir/prerm"

    ./ipkg-build "$pkg_dir" "$PWD/$OUT_DIR"
    mv "$PWD/$OUT_DIR/${pkg_name}_${VERSION}-1_${arch}.ipk" "$PWD/$OUT_DIR/${pkg_name}-${VERSION}-1_${arch}.ipk" 2>/dev/null || true

    echo "$_DNS_POSTINST" > "$pkg_dir/.post-install"; chmod +x "$pkg_dir/.post-install"
    echo "$_DNS_PRERM"    > "$pkg_dir/.pre-deinstall"; chmod +x "$pkg_dir/.pre-deinstall"
    local out_apk="$OUT_DIR/${pkg_name}-${VERSION}-1_${arch}.apk"
    docker run --rm -v "$PWD":/workspace -w /workspace alpine:latest sh -c \
        "apk update && apk add apk-tools && apk mkpkg --info name:$pkg_name --info version:$VERSION-r1 --info description:'native domain-routing backend for splify' --info arch:$arch --info depends:'splify nftables' --script post-install:$pkg_dir/.post-install --script pre-deinstall:$pkg_dir/.pre-deinstall -F $pkg_dir -o $out_apk"
    rm -f "$pkg_dir/.post-install" "$pkg_dir/.pre-deinstall"
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

# 4. splify-dns (native domain-routing backend; one .ipk/.apk per target arch)
echo "Building splify-dns (native domain-routing backend)..."
echo "$NATIVE_TARGETS" | while IFS=: read -r _arch _cc _apt _ztarget _zmcpu; do
    [ -n "$_arch" ] || continue
    # A failure building ONE target (missing toolchain, a docker hiccup, ...)
    # must never abort the other 3 native targets or the noarch packages
    # already built above — `|| true` suspends set -e for the whole call.
    build_native_pkg "$_arch" "$_cc" "$_apt" "$_ztarget" "$_zmcpu" || echo "splify-dns/$_arch: build step failed, skipping"
done

echo "All packages built in $OUT_DIR/"
ls -la $OUT_DIR/

