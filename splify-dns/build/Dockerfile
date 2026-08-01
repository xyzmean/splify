# Cross-compiles splify-dnsd against musl for every OpenWrt target we ship.
#
# Why a container at all: the daemon has to be a static musl binary. OpenWrt has
# musl, so a Debian cross-gcc (glibc) binary must be linked statically to run
# there — and static glibc is ~800KB for a 35KB program, on routers that can have
# under 7MB of free flash. Worse, Debian's mipsel-linux-gnu targets HARD FLOAT
# while OpenWrt's mipsel_24kc is soft-float: that binary dies with SIGILL on a
# Mi Router 4C, i.e. the package installed and the daemon could never start.
#
# zig ships musl plus every target we need in one 45MB download, so one x86
# container builds all four architectures with no per-target toolchains:
#
#   target                        glibc static -> musl static
#   aarch64_cortex-a53            848 024      ->  92 520
#   mipsel_24kc                   825 588 (!)  -> 135 128   (broken -> works)
#   arm_cortex-a7                 ~848 000     ->  92 468
#   x86_64                        ~705 000     ->  88 056
#
# It also removes the need for a per-architecture toolchain download (the usual
# approach is one ~100MB musl-cross tarball per target), which is what makes it
# practical to cover every ISA OpenWrt runs on from a single image: 11 of them
# compile in parallel here in about a minute and a half.
FROM alpine:3.20

ARG ZIG_VERSION=0.13.0
ARG ZIG_SHA256=d45312e61ebcc48032b77bc4cf7fd6915c11fa16e4aad116b66c9468211230ea

RUN apk add --no-cache curl xz \
 && curl -fsSL -o /tmp/zig.tar.xz \
      "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz" \
 && echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - \
 && mkdir -p /opt && tar xf /tmp/zig.tar.xz -C /opt \
 && ln -s "/opt/zig-linux-x86_64-${ZIG_VERSION}/zig" /usr/local/bin/zig \
 && rm /tmp/zig.tar.xz \
 && zig version

WORKDIR /src
ENTRYPOINT ["/usr/local/bin/zig"]
