#!/bin/bash
# Enter (or run a command in) the extracted KNULLI rootfs as a chroot.
#
# The KNULLI image cannot boot in a VM (device SoC firmware), but its
# userspace — CPython 3.12 + pygame + ALSA — runs natively on the shared
# aarch64 kernel. Usage:
#   knulli-chroot.sh                     # interactive shell
#   knulli-chroot.sh 'python3 -V'        # one command
# Env: KNULLI_ROOT (default /home/user.guest/knulli-root — installer sets it)
set -u
R="${KNULLI_ROOT:-/home/user.guest/knulli-root}"
[ -d "$R" ] || { echo "no knulli rootfs at $R (run install.sh first)" >&2; exit 1; }
S="sudo"

$S mkdir -p "$R/proc" "$R/sys" "$R/dev" "$R/run" "$R/tmp/.X11-unix"
# The mountpoint guards are LOAD-BEARING: stacking repeated identical
# bind-mounts makes util-linux `mountpoint`/`df` spin forever in-kernel.
$S mountpoint -q "$R/proc" || $S mount -t proc proc "$R/proc"
$S mountpoint -q "$R/sys"  || $S mount -t sysfs sys "$R/sys"
$S mountpoint -q "$R/dev"  || $S mount --rbind /dev "$R/dev"
$S mountpoint -q "$R/run"  || $S mount -t tmpfs run "$R/run"
$S mountpoint -q "$R/tmp/.X11-unix" || $S mount --bind /tmp/.X11-unix "$R/tmp/.X11-unix"
$S cp /etc/resolv.conf "$R/etc/resolv.conf" 2>/dev/null || true

# KNULLI's SDL2 has exactly one video driver: "mali" (the device's GPU blob).
# /opt/sdl2-x11 (created by build_sdl2_x11.sh) holds a stock SDL 2.32.x built
# with X11 plus its X-side dependency closure, shadowing only the video
# backend. KNULLI keeps its own glibc, libasound, SDL2_ttf/image/mixer, and
# satisfies the >= 2.32.8 floor that knulli's pygame enforces.
CMD="${*:-exec /bin/sh -l}"
exec $S chroot "$R" env -i \
    HOME=/root TERM="${TERM:-linux}" USER=root \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LD_LIBRARY_PATH=/opt/sdl2-x11 \
    DISPLAY="${DISPLAY:-:1}" \
    SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-x11}" \
    ${SDL_AUDIODRIVER:+SDL_AUDIODRIVER=$SDL_AUDIODRIVER} \
    ${LD_PRELOAD:+LD_PRELOAD=$LD_PRELOAD} \
    ${PYTHONPATH:+PYTHONPATH=$PYTHONPATH} \
    KNULLI=1 \
    /bin/sh -c "$CMD"
