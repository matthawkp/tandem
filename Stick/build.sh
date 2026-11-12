#!/bin/sh
# Builds Tandem Display's USB image: out/tandem-display.img, and the same files in out/stick/.
#
#   ./build.sh           the image, building whatever isn't built yet
#   ./build.sh kernel    the kernel again as well (ten minutes or so)
#   ./build.sh release   for anyone to download: no SSH key built in (see image/make-image.sh)
#
# Needs Docker (colima is enough). Everything is built in containers; the kernel is
# cross-compiled, and the rest is put together in an emulated x86-64 Alpine.
set -eu
cd "$(dirname "$0")"
mkdir -p out/kernel out/ssh out/dockercfg

# A Docker config of our own: pulling public images needs no login, and a config that names a
# credentials helper which isn't installed would stop them.
[ -f out/dockercfg/config.json ] || echo '{}' > out/dockercfg/config.json
export DOCKER_CONFIG="$PWD/out/dockercfg"
if [ -z "${DOCKER_HOST:-}" ] && [ -S "$HOME/.colima/default/docker.sock" ]; then
    export DOCKER_HOST="unix://$HOME/.colima/default/docker.sock"
fi
docker info > /dev/null 2>&1 || { echo "Docker isn't running (with colima: colima start)"; exit 1; }

have_image() { docker image inspect "$1" > /dev/null 2>&1; }

if [ "${1:-}" = kernel ] || [ ! -f out/kernel/vmlinuz ] || [ ! -f out/kernel/amdgpu-stock.ko ]; then
    echo "== kernel"
    have_image tandem-kbuild || docker build -q -t tandem-kbuild kernel > /dev/null
    # The kernel's source tree lives in a Docker volume: it can't be kept on a Mac's
    # case-insensitive disk.
    docker volume create tandem-kbuild > /dev/null
    docker run --rm -v tandem-kbuild:/work -v "$PWD/kernel":/src:ro -v "$PWD/out/kernel":/out tandem-kbuild /src/build-kernel.sh
fi

# The key that's allowed into the running system over SSH. It never leaves this folder.
[ -f out/ssh/tandem_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -C tandem-display -f out/ssh/tandem_ed25519

if ! have_image tandem-image; then
    echo "== tools"
    # Made by running x86-64 Alpine and keeping the result: plain "docker build" can't be told
    # which architecture to build for.
    docker rm -f tandem-image-build > /dev/null 2>&1 || true
    docker run --platform linux/amd64 --name tandem-image-build alpine:3.24 apk add --no-cache --quiet \
        build-base pkgconf mesa-dev libdrm-dev lz4-dev linux-headers font-terminus kmod zstd cpio dropbear \
        grub grub-efi mtools dosfstools sfdisk xorriso
    docker commit -c 'WORKDIR /build' tandem-image-build tandem-image > /dev/null
    docker rm tandem-image-build > /dev/null
fi

[ "${1:-}" = release ] && release=1 || release=
docker run --rm --platform linux/amd64 --privileged -e TANDEM_RELEASE=$release -v "$PWD":/src:ro -v "$PWD/out":/out tandem-image /src/image/make-image.sh
