#!/bin/sh
# Build the pinned assembler into fdd3000/tools/bin/sjasmplus.
# The ZX-UX sources use sjasmplus syntax (DEVICE, ASSERT, SAVEBIN, local
# .labels); v1.21.0 reproduces the shipped ZX-UX.tzx kernel byte for byte.
set -e
VER=v1.21.0
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
git clone -q --depth 1 --branch "$VER" --recurse-submodules \
    https://github.com/z00m128/sjasmplus.git "$WORK/sjasmplus"
make -C "$WORK/sjasmplus" -j4 >/dev/null
mkdir -p "$HERE/bin"
cp "$WORK/sjasmplus/sjasmplus" "$HERE/bin/sjasmplus"
"$HERE/bin/sjasmplus" --version
