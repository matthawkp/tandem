#!/bin/sh
# Runs inside the kernel build container. /work is a Linux filesystem (a Docker volume: the
# kernel tree can't live on a case-insensitive Mac folder), /src is this folder, /out the results.
set -eu
VERSIONS="${KERNEL_VERSIONS:-7.3.4 7.3}"
JOBS="${JOBS:-$(nproc)}"
cd /work

for V in $VERSIONS; do
    TARBALL="linux-$V.tar.xz"
    if [ ! -f "$TARBALL.ok" ]; then
        echo "== downloading $TARBALL"
        curl -fL --retry 3 -o "$TARBALL" "https://cdn.kernel.org/pub/linux/kernel/v7.x/$TARBALL"
        curl -fsL --retry 3 -o sha256sums.asc https://cdn.kernel.org/pub/linux/kernel/v7.x/sha256sums.asc
        WANT=$(grep " $TARBALL\$" sha256sums.asc | cut -d' ' -f1)
        GOT=$(sha256sum "$TARBALL" | cut -d' ' -f1)
        [ -n "$WANT" ] && [ "$WANT" = "$GOT" ] || { echo "checksum mismatch for $TARBALL: $GOT, expected $WANT"; exit 1; }
        touch "$TARBALL.ok"
    fi
    if [ ! -d "linux-$V" ]; then
        echo "== extracting"
        tar xf "$TARBALL"
    fi
    cd "linux-$V"
    if [ ! -f .tandem-patched ]; then
        if patch -p1 --dry-run -s < /src/patches/iMac5K-7.3.0.patch; then
            patch -p1 < /src/patches/iMac5K-7.3.0.patch
            touch .tandem-patched
        else
            echo "== the 5K patch doesn't apply to $V, trying the next version"
            cd /work
            continue
        fi
    fi
    echo "== building Linux $V with $JOBS jobs"
    export ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu-
    make -s x86_64_defconfig
    ./scripts/kconfig/merge_config.sh -m .config /src/tandem.config > /out/merge.log 2>&1
    make -s olddefconfig
    # Anything asked for that didn't survive: wrong name, or something it depends on is missing.
    : > /out/config-missing.txt
    grep -E '^CONFIG_[A-Z0-9_x]+=' /src/tandem.config | while IFS= read -r line; do
        grep -qxF "$line" .config || echo "$line" >> /out/config-missing.txt
    done
    make -j"$JOBS" bzImage modules 2>&1 | tail -n 40
    rm -rf /out/modules && mkdir -p /out/modules
    make -s INSTALL_MOD_PATH=/out/modules INSTALL_MOD_STRIP=1 modules_install
    rm -f /out/modules/lib/modules/*/build /out/modules/lib/modules/*/source
    cp arch/x86/boot/bzImage /out/vmlinuz

    # The same graphics driver without the 5K patch, for the image's fallback entry: the patch
    # can't be switched off at boot, so the unpatched driver is kept beside the patched one.
    echo "== building the unpatched graphics driver"
    patch -s -R -p1 < /src/patches/iMac5K-7.3.0.patch
    make -j"$JOBS" modules 2>&1 | tail -n 3
    x86_64-linux-gnu-strip --strip-debug -o /out/amdgpu-stock.ko drivers/gpu/drm/amd/amdgpu/amdgpu.ko
    patch -s -p1 < /src/patches/iMac5K-7.3.0.patch
    make -j"$JOBS" modules 2>&1 | tail -n 3
    cmp -s drivers/gpu/drm/amd/amdgpu/amdgpu.ko /out/amdgpu-stock.ko && { echo "the patched and unpatched drivers are the same"; exit 1; }
    cp .config /out/kernel.config
    make -s kernelrelease > /out/kernel.release
    echo "== done: Linux $(cat /out/kernel.release)"
    exit 0
done
echo "no kernel version took the patch"; exit 1
