#!/bin/bash
# In-guest: build a stock SDL2 (X11 video backend) and install it into the
# knulli rootfs as /opt/sdl2-x11 — the one substitution knulli needs to run
# in a VM: its own SDL2 only knows the Allwinner "mali" GPU driver, and the
# image ships no X11 at all. Knulli's pygame refuses any SDL2 older than the
# 2.32.8 it was compiled against ("Dynamic linking causes SDL downgrade"),
# so we build the same minor, and copy its X-side dependency closure from
# Ubuntu's packages (glibc-compatible; libasound deliberately excluded so
# SDL uses knulli's own ALSA).
#   usage: build_sdl2_x11.sh <rootfs-dir>
set -euo pipefail
R="$1"
SDL_VER=2.32.10
D="$R/opt/sdl2-x11"
SUDO=sudo

if $SUDO test -e "$D/libSDL2-2.0.so.0"; then
    echo "SDL2 x11-compat already present at $D — skipping"
    exit 0
fi

sudo apt-get update -qq
sudo apt-get install -y -qq --no-install-recommends build-essential cmake pkg-config \
  libx11-dev libxext-dev libxi-dev libxrandr-dev libxcursor-dev libxfixes-dev \
  libxss-dev libxrender-dev libasound2-dev libxkbcommon-dev wget >/dev/null

B="$HOME/sdl2-build"
mkdir -p "$B" && cd "$B"
[ -f "SDL2-$SDL_VER.tar.gz" ] || wget -q \
  "https://github.com/libsdl-org/SDL/releases/download/release-$SDL_VER/SDL2-$SDL_VER.tar.gz"
tar xf "SDL2-$SDL_VER.tar.gz"
cd "SDL2-$SDL_VER"
cmake -B build -DCMAKE_BUILD_TYPE=Release \
  -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TESTS=OFF \
  -DSDL_WAYLAND=OFF -DSDL_KMSDRM=OFF >/dev/null
cmake --build build -j"$(nproc)" >/dev/null
LIB=$(ls build/libSDL2-2.0.so.0.* | grep -v '\.so\.0$' | head -1)

$SUDO mkdir -p "$D"
$SUDO cp "$LIB" "$D/libSDL2-2.0.so.0"

# Copy the X-side dependency closure, iterating until ldd (run with the
# chroot's own loader) resolves everything. glibc core and libasound are
# excluded: the chroot's newer glibc must stay authoritative, and SDL should
# use knulli's ALSA.
EXCLUDE="ld-linux|/libc\.so|/libm\.so|/libdl\.so|/librt\.so|/libpthread\.so|/libutil\.so|libasound|libSDL2"
for _ in 1 2 3 4 5 6; do
    MISS=$($SUDO chroot "$R" env LD_LIBRARY_PATH=/opt/sdl2-x11 \
        ldd /opt/sdl2-x11/libSDL2-2.0.so.0 2>/dev/null \
        | awk '/not found/{print $1}')
    [ -z "$MISS" ] && break
    for n in $MISS; do
        f=$(ls "/usr/lib/aarch64-linux-gnu/$n" 2>/dev/null | head -1)
        [ -n "$f" ] && ! echo "$f" | grep -qE "$EXCLUDE" && $SUDO cp "$f" "$D/"
    done
done
if $SUDO chroot "$R" env LD_LIBRARY_PATH=/opt/sdl2-x11 \
        ldd /opt/sdl2-x11/libSDL2-2.0.so.0 2>/dev/null | grep -q "not found"; then
    echo "SDL2 dependency closure incomplete" >&2; exit 1
fi
echo "SDL $SDL_VER (x11) installed at $D"
