#!/bin/sh
# Tests the display program without a screen or a second machine: it runs in a container,
# drawing to nothing, while Tandem's own encoder (built from Tandem's Swift source into a small
# test sender) streams a moving pattern at it. Passes if both ends finish with the same pixels,
# once with everything sent losslessly and once with moving parts sent as BC7.
#
#   test/headless.sh [width]x[height]        default 5120x2880
#
# TANDEM_SOURCE is Tandem's source folder (default .., this repository).
set -eu
cd "$(dirname "$0")/.."
SIZE=${1:-5120x2880}
TANDEM_SOURCE=${TANDEM_SOURCE:-..}
mkdir -p out/test out/rx-native out/dockercfg
[ -f out/dockercfg/config.json ] || echo '{}' > out/dockercfg/config.json
export DOCKER_CONFIG="$PWD/out/dockercfg"
if [ -z "${DOCKER_HOST:-}" ] && [ -S "$HOME/.colima/default/docker.sock" ]; then
    export DOCKER_HOST="unix://$HOME/.colima/default/docker.sock"
fi

if ! docker image inspect tandem-rx > /dev/null 2>&1; then
    docker rm -f tandem-rx-build > /dev/null 2>&1 || true
    docker run --name tandem-rx-build alpine:3.24 apk add --no-cache --quiet build-base pkgconf mesa-dev libdrm-dev \
        lz4-dev linux-headers mesa-dri-gallium mesa-egl mesa-gles mesa-gbm font-terminus
    docker commit tandem-rx-build tandem-rx > /dev/null
    docker rm tandem-rx-build > /dev/null
fi
docker run --rm -v "$PWD/receiver":/src:ro -v "$PWD/out/rx-native":/out tandem-rx sh -c \
    'cp -r /src /build && cd /build && make -s clean && make -s -j8 && cp tandem-display /out/ && gunzip -c /usr/share/consolefonts/ter-132n.psf.gz > /out/font.psf'

if [ ! -x out/test/tandem-test-sender ] || [ test/sender/main.swift -nt out/test/tandem-test-sender ]; then
    swiftc -O -o out/test/tandem-test-sender test/sender/main.swift "$TANDEM_SOURCE/Shared/Wire.swift" \
        "$TANDEM_SOURCE/Shared/Machine.swift" "$TANDEM_SOURCE/Sender/TileEncoder.swift" \
        "$TANDEM_SOURCE/Sender/BC7Encoder.swift" "$TANDEM_SOURCE/Sender/TileDiffer.swift" 2>&1 | grep -E 'error' || true
fi

failed=0
for mode in lossless bc7; do
    docker rm -f tandem-rx-test > /dev/null 2>&1 || true
    docker run -d --name tandem-rx-test -p 127.0.0.1:51600:51600 -v "$PWD/out/rx-native":/rx:ro tandem-rx \
        /rx/tandem-display --headless "$SIZE" --port 51600 --any-interface --hash-all --font /rx/font.psf > /dev/null
    sleep 3
    sender=$(out/test/tandem-test-sender 127.0.0.1 51600 60 $mode 2>/dev/null | grep -E '^(hello|sent|final|FAIL)' || true)
    sleep 1
    receiver=$(docker logs tandem-rx-test 2>&1)
    docker rm -f tandem-rx-test > /dev/null 2>&1
    want=$(echo "$sender" | sed -n 's/^final frame [0-9]* hash //p')
    frame=$(echo "$sender" | sed -n 's/^final frame \([0-9]*\) hash .*/\1/p')
    picture=$(echo "$receiver" | sed -n "s/.* frame $frame picture //p" | tail -n 1)
    lossless=$(echo "$receiver" | sed -n "s/.* frame $frame hash \([0-9a-f]*\) .*/\1/p" | tail -n 1)
    as_bc7=$(echo "$sender" | sed -n 's/.* picture, \([0-9.]*\) MB of it as BC7.*/\1/p')
    if [ -n "$want" ] && [ "$want" = "$picture" ] && [ "$want" = "$lossless" ]; then
        result=PASS
        # The BC7 run only counts if something really went as BC7.
        [ $mode = bc7 ] && [ "${as_bc7:-0.0}" = 0.0 ] && result="FAIL (nothing was sent as BC7)"
    else
        result="FAIL (sender $want, receiver's picture $picture, its lossless copy $lossless)"
    fi
    case "$result" in FAIL*) failed=1; echo "$sender"; echo "$receiver" | tail -n 5 ;; esac
    echo "$mode at $SIZE: $result  (frame $frame, hash $want, ${as_bc7:-0} MB as BC7)"
done
rm -f "$HOME/Library/Logs/tandem-test-sender.log" "$HOME/Library/Logs/tandem-test-sender.previous.log"
exit $failed
