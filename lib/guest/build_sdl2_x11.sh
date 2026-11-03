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

if $SUDO test -e "$D/libSDL2-2.0.so.0" && $SUDO test -e "$D/libX11.so.6"; then
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

# A cmake that lost the X dev packages (or reused a stale build/ cache from
# such an attempt) silently builds WITHOUT the X11 backend — and the result
# passes every ldd check because SDL dlopens X at runtime. Verify the
# backend is actually in the binary: SDL's dynamic loader references the
# SONAME string it will dlopen.
# grep WITHOUT -q: -q exits at first match, strings then dies of SIGPIPE,
# and `set -o pipefail` turns that matched-and-happy pipeline into exit 141.
if ! strings "$D/libSDL2-2.0.so.0" | grep "libX11.so.6" >/dev/null; then
    echo "built SDL2 has NO X11 backend (stale cmake cache? missing libx11-dev)" >&2
    echo "fix: rm -rf $B/SDL2-$SDL_VER/build && re-run install.sh" >&2
    exit 1
fi

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

# The ldd loop above CANNOT see the X runtime libs: SDL2 dlopen()s
# libX11/libXext/... at runtime, so they never show as ldd "not found" —
# a fresh chroot (the image ships no X11) got a "complete" closure of just
# libSDL2 and pygame died at "x11 not available". Copy the runtime set
# explicitly (the set a working VM's closure contains), then gate on an
# actual dlopen through SDL's own load path, not on ldd.
XRUNTIME="libX11.so.6 libXau.so.6 libXcursor.so.1 libXdmcp.so.6 libXext.so.6
libXfixes.so.3 libXi.so.6 libXrandr.so.2 libXrender.so.1 libXss.so.1
libbsd.so.0 libdecor-0.so.0 libdrm.so.2 libgbm.so.1 libmd.so.0
libwayland-client.so.0 libwayland-cursor.so.0 libwayland-egl.so.1
libxcb.so.1 libxkbcommon.so.0"
for n in $XRUNTIME; do
    f=$(ls "/usr/lib/aarch64-linux-gnu/$n" 2>/dev/null | head -1)
    [ -n "$f" ] && $SUDO cp -f "$f" "$D/$n"
done
if ! $SUDO chroot "$R" env -i LD_LIBRARY_PATH=/opt/sdl2-x11 /usr/bin/python3 \
        -c 'import ctypes; ctypes.CDLL("libX11.so.6")' 2>/dev/null; then
    echo "SDL2 X runtime libs not dlopen-able inside the chroot" >&2; exit 1
fi
echo "SDL $SDL_VER (x11) installed at $D"
