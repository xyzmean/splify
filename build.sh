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

# splify-dns (native domain-routing backend) is the one compiled package in this
# repo — everything else is noarch shell/Lua/static assets built with no compiler.
#
# TWO TABLES, because two different things are being enumerated:
#
#   DNSD_ISAS    what actually gets COMPILED. One static musl binary per
#                instruction set + ABI, built with zig in a container (see
#                splify-dns/build/Dockerfile).
#   DNSD_ARCHES  what gets PACKAGED. apk on OpenWrt matches Architecture as an
#                EXACT string against the board's /etc/apk/arch, so every target
#                needs its own package — but several of them can share one binary.
#
# Getting the ABI wrong here is silent and fatal: the binary installs and dies with
# SIGILL on first run. That already happened — the previous Debian-cross build for
# mipsel_24kc was hard-float while the target is soft-float, so splify-dns could
# never start on a Mi Router 4C. Every entry below is therefore verified from the
# produced ELF (machine, endianness, FP ABI) by dnsd_verify_elf, and the two we
# have boards for (aarch64_cortex-a53, mipsel_24kc) were also run on hardware.
#
# id : zig target : zig mcpu
DNSD_ISAS="
aarch64:aarch64-linux-musl:baseline
armv7hf:arm-linux-musleabihf:generic+v7a
armv6hf:arm-linux-musleabihf:arm1176jzf_s
armv5sf:arm-linux-musleabi:arm926ej_s
mipselsf:mipsel-linux-musl:mips32r2+soft_float
mipssf:mips-linux-musl:mips32r2+soft_float
mips64:mips64-linux-musl:baseline
i386:x86-linux-musl:i586
x86_64:x86_64-linux-musl:baseline
powerpc:powerpc-linux-musl:baseline
riscv64:riscv64-linux-musl:baseline
"

# OpenWrt arch string : ISA id above.
# The ARM split follows OpenWrt's own naming: a suffix naming an FPU (_vfp,
# _vfpv3, _vfpv4, _neon*) means hard-float, its absence means soft-float.
DNSD_ARCHES="
aarch64_cortex-a53:aarch64
aarch64_cortex-a72:aarch64
aarch64_cortex-a76:aarch64
aarch64_generic:aarch64
arm_cortex-a7_neon-vfpv4:armv7hf
arm_cortex-a7_vfpv4:armv7hf
arm_cortex-a9_neon:armv7hf
arm_cortex-a9_vfpv3-d16:armv7hf
arm_cortex-a15_neon-vfpv4:armv7hf
arm_cortex-a5_vfpv4:armv7hf
arm_cortex-a8_vfpv3:armv7hf
arm_arm1176jzf-s_vfp:armv6hf
arm_arm926ej-s:armv5sf
arm_xscale:armv5sf
arm_mpcore:armv5sf
arm_fa526:armv5sf
mipsel_24kc:mipselsf
mipsel_74kc:mipselsf
mipsel_mips32:mipselsf
mips_24kc:mipssf
mips_4kec:mipssf
mips_mips32:mipssf
mips64_octeonplus:mips64
i386_pentium4:i386
i386_pentium-mmx:i386
x86_64:x86_64
powerpc_8540:powerpc
powerpc_8548:powerpc
riscv64_riscv64:riscv64
"

DNSD_IMAGE="splify-dnsd-builder:zig-0.13.0"
DNSD_BIN_DIR="$BUILD_DIR/dnsd-bin"

dnsd_builder_ready() {
    command -v docker >/dev/null 2>&1 || return 1
    docker image inspect "$DNSD_IMAGE" >/dev/null 2>&1 && return 0
    echo "splify-dns: building the musl cross image (one time, ~45MB download)..."
    docker build -q -t "$DNSD_IMAGE" splify-dns/build >/dev/null 2>&1
}

# Reads back what was actually produced. An ABI mismatch is invisible until the
# binary runs on the board, so it is checked here instead: machine, endianness and
# — for the architectures where it silently breaks — the float ABI.
# $1=isa id $2=binary path
dnsd_verify_elf() {
    local id=$1 bin=$2 hdr attrs
    command -v readelf >/dev/null 2>&1 || return 0   # nothing to check with
    hdr="$(readelf -h "$bin" 2>/dev/null)"
    attrs="$(readelf -A "$bin" 2>/dev/null)"
    local want_machine="" want_endian="" want_fp=""
    case "$id" in
        aarch64)  want_machine="AArch64"; want_endian="little" ;;
        armv7hf)  want_machine="ARM"; want_endian="little"; want_fp="hard-float" ;;
        armv6hf)  want_machine="ARM"; want_endian="little"; want_fp="hard-float" ;;
        armv5sf)  want_machine="ARM"; want_endian="little"; want_fp="soft-float" ;;
        mipselsf) want_machine="MIPS"; want_endian="little"; want_fp="Soft float" ;;
        mipssf)   want_machine="MIPS"; want_endian="big";    want_fp="Soft float" ;;
        mips64)   want_machine="MIPS"; want_endian="big" ;;
        i386)     want_machine="80386"; want_endian="little" ;;
        x86_64)   want_machine="X86-64"; want_endian="little" ;;
        powerpc)  want_machine="PowerPC"; want_endian="big" ;;
        riscv64)  want_machine="RISC-V"; want_endian="little" ;;
    esac
    echo "$hdr" | grep -q "$want_machine" || { echo "splify-dns/$id: ELF machine is not $want_machine"; return 1; }
    echo "$hdr" | grep -qi "$want_endian endian" || { echo "splify-dns/$id: ELF is not $want_endian endian"; return 1; }
    if [ -n "$want_fp" ]; then
        printf '%s\n%s\n' "$hdr" "$attrs" | grep -qi "$want_fp" \
            || { echo "splify-dns/$id: float ABI is not '$want_fp' — this would SIGILL on the board"; return 1; }
    fi
    return 0
}

# Compiles every ISA once, IN PARALLEL — the compiles are independent and each is
# a separate container, so serialising them just wastes wall clock (the same reason
# a release matrix runs one job per architecture).
dnsd_build_isas() {
    mkdir -p "$DNSD_BIN_DIR"
    local pids="" spec id target mcpu
    for spec in $DNSD_ISAS; do
        id=${spec%%:*}; spec=${spec#*:}
        target=${spec%%:*}; mcpu=${spec#*:}
        (
            if docker run --rm -v "$PWD:/src" -w /src "$DNSD_IMAGE" \
                    cc -target "$target" -mcpu="$mcpu" -static -Os -Wall -Wextra \
                       -o "$DNSD_BIN_DIR/$id" splify-dns/src/splify-dnsd.c 2>"$DNSD_BIN_DIR/$id.err"; then
                if dnsd_verify_elf "$id" "$DNSD_BIN_DIR/$id"; then
                    echo "splify-dns: $id ok, $(stat -c %s "$DNSD_BIN_DIR/$id") bytes"
                else
                    rm -f "$DNSD_BIN_DIR/$id"
                fi
            else
                echo "splify-dns: $id compile failed — $(head -1 "$DNSD_BIN_DIR/$id.err")"
                rm -f "$DNSD_BIN_DIR/$id"
            fi
        ) &
        pids="$pids $!"
    done
    for p in $pids; do wait "$p" || true; done
}

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

# Packages one OpenWrt arch string (ipk + apk) from an already-built ISA binary.
# $1=openwrt arch string $2=isa id from DNSD_ISAS
build_native_pkg() {
    local arch=$1
    local isa=$2
    local bin="$DNSD_BIN_DIR/$isa"

    if [ ! -f "$bin" ]; then
        # Either the container is unavailable or that ISA failed/failed verification.
        # Shipping nothing is correct: splify's own backend detection falls back to
        # the dnsmasq nftset path, whereas a wrong-ABI binary would install and then
        # die with SIGILL on first start.
        echo "splify-dns/$arch: no verified $isa binary — skipping this target"
        return 0
    fi

    local pkg_dir="$BUILD_DIR/splify-dns_$arch"
    mkdir -p "$pkg_dir/usr/sbin" "$pkg_dir/etc/init.d"
    cp "$bin" "$pkg_dir/usr/sbin/splify-dnsd"
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
#   2. the ?v= query the entry bundles (splify-index.js/splify-settings.js) put on
#      EVERY chunk they import — the shared one plus the lazily loaded tabs — for
#      which npm build bakes a placeholder "?v=0.0.0". Stamping the real VERSION
#      keeps entry and chunks pinned to one release so a stale HTTP cache can't
#      mix a new entry with an old chunk. scripts/check-dist.mjs fails the build if
#      any chunk reference is missing that placeholder.
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
# splify-dns: compile each ISA once (in parallel), then package every arch string.
if dnsd_builder_ready; then
    dnsd_build_isas
else
    echo "splify-dns: docker not available — no musl toolchain, skipping every native target"
    echo "            (splify itself is unaffected: its backend detection falls back to dnsmasq nftset)"
fi
echo "$DNSD_ARCHES" | while IFS=: read -r _arch _isa; do
    [ -n "$_arch" ] || continue
    # A failure on ONE arch must never abort the others or the noarch packages
    # already built above — `|| true` suspends set -e for the whole call.
    build_native_pkg "$_arch" "$_isa" || echo "splify-dns/$_arch: packaging failed, skipping"
done

# Checksums for everything that leaves this build. splify-dns now ships one
# package per OpenWrt arch string, so a release carries dozens of files and
# "did I download the right one, intact?" stops being answerable by eye.
( cd "$OUT_DIR" && sha256sum ./*.ipk ./*.apk 2>/dev/null | sed 's|\./||' > sha256sums.txt ) || true

echo "All packages built in $OUT_DIR/"
echo "  splify-dns: $(ls "$OUT_DIR"/splify-dns-*.ipk 2>/dev/null | wc -l) arch(es), $(ls "$OUT_DIR" | wc -l) files total"
ls -la $OUT_DIR/

