#!/bin/bash
# In-guest: bring up the virtual hardware (sound card, joypad, display, VNC)
# and launch an app inside the KNULLI chroot the way knulli's
# EmulationStation would (exec /usr/bin/pygame <script> with the app dir as
# cwd; configgen/generators/pygame is the reference).
#   usage: run_app.sh <app-dir-in-rootfs> <launch-cmd> [vnc-pass]
set -u
DIR="$1"; CMD="$2"; VNC_PASS="${3:-knulli}"
G="$HOME/knulli-vm"
PIDF=/tmp/knulli-app.pid
# the app registry stores host paths; the chroot sees them without the prefix
if [ -n "${KNULLI_ROOT:-}" ]; then
    case "$DIR" in "$KNULLI_ROOT"/*) DIR="${DIR#"$KNULLI_ROOT"}";; esac
fi

# route the chroot's ALSA default into the loopback card the Mac captures
# (setup_audio.sh also pins the card indices the apps hardcode)
if [ -n "${KNULLI_ROOT:-}" ] && [ -x "$G/setup_audio.sh" ]; then
    "$G/setup_audio.sh" "$KNULLI_ROOT" || echo "WARN: audio routing setup failed (silent)" >&2
fi

pgrep -f "virtual_joypad[.]py" >/dev/null 2>&1 || {
    sudo nohup python3 "$G/virtual_joypad.py" retrogame_joypad > /tmp/joypad.log 2>&1 &
    sleep 1
}
# NO apt on this path, ever: a package install here (dpkg lock held by a
# fresh VM's boot-time apt activity, or a network stall) can block for
# minutes silently, and the display/app sit behind it. All display/input
# packages are ensured by install.sh / the lima template instead; the
# optional input helpers below degrade to a WARN when a dep is missing.
# Display + VNC: prefer TigerVNC's Xvnc (X server and VNC server in one,
# modern input pipeline) over Xvfb+x11vnc. x11vnc starves its client input
# queue while diffing the framebuffer (Recv-Q grew unboundedly under
# animation — 742KB->1.6MB measured — so keyboard/mouse arrive seconds
# late); Xvnc processes input on its own event loop, no second server,
# no diff loop. Ubuntu's tigervnc package has no x0vncserver (serve-existing
# -display mode is not built), so we move the display to Xvnc instead of
# mirroring Xvfb.
# AcceptSetDesktopSize must be OFF: macOS Screen Sharing otherwise sends a
# set-desktop-size request sized to its window, shrinking the framebuffer
# under the app (1280x720 UI on a 1024x768 desktop = right/bottom of the
# UI clipped away, "VNC cuts parts of the screen off"). The mark hashes the
# password AND the Xvnc config version, so changing launch options below
# forces a restart of a running-but-stale Xvnc.
MARK=/tmp/knulli-vnc.passwd-md5
want=$(printf '%s|v4-nosetsize' "$VNC_PASS" | md5sum | cut -d' ' -f1)
if command -v Xvnc >/dev/null 2>&1; then
    if pgrep -x Xvnc >/dev/null 2>&1 && [ "$(cat "$MARK" 2>/dev/null)" = "$want" ]; then
        :
    else
        # pkill Xvnc too: without it the replacement server dies with
        # "Cannot establish any listening sockets" while the marker got
        # written anyway — leaving the STALE server (old geometry/flags)
        # masquerading as configured on every later start.
        pkill -x x11vnc 2>/dev/null; pkill -x Xvfb 2>/dev/null
        pkill -x Xvnc 2>/dev/null; sleep 1
        rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null
        printf '%s\n%s\n' "$VNC_PASS" "$VNC_PASS" | vncpasswd -f > /tmp/knulli-vnc.pass
        chmod 600 /tmp/knulli-vnc.pass
        (setsid nohup Xvnc :1 -geometry 1280x720 -depth 24 -rfbport 5901 \
            -SecurityTypes VncAuth -PasswordFile /tmp/knulli-vnc.pass \
            -AlwaysShared -localhost yes -AcceptSetDesktopSize=0 \
            > /tmp/xvnc.log 2>&1 &)
        sleep 2
        [ "$(pgrep -cx Xvnc)" = 1 ] && echo "$want" > "$MARK"
    fi
else
    # fallback: Xvfb + x11vnc (laggy input, see comment above)
    pgrep -x Xvfb >/dev/null 2>&1 || (Xvfb :1 -screen 0 1280x720x24 >/tmp/xvfb.log 2>&1 & sleep 1)
    if pgrep -x x11vnc >/dev/null 2>&1 && [ "$(cat "$MARK" 2>/dev/null)" = "$want" ]; then
        x_ok=1
    else
        x_ok=0
    fi
    if [ "$x_ok" = 0 ]; then
        pkill -x x11vnc 2>/dev/null; sleep 1
        x11vnc -display :1 -forever -shared -passwd "$VNC_PASS" \
            -rfbport 5901 -bg -o /tmp/x11vnc.log >/dev/null 2>&1; sleep 1
        echo "$want" > "$MARK"
    fi
fi

# Optional input helpers, AFTER the display is up (they need :1). Missing
# deps only cost keyboard/focus convenience, never the app or VNC.
pgrep -f "focusd[.]sh" >/dev/null 2>&1 || {
    if command -v xdotool >/dev/null 2>&1; then
        nohup "$G/focusd.sh" > /tmp/focusd.log 2>&1 &
        sleep 1
    else
        echo "WARN: xdotool missing — window-focus helper off (re-run install.sh to fix)" >&2
    fi
}
# keyboard -> joypad on the VM display (needs python3-xlib)
pgrep -f "keymapd[.]py" >/dev/null 2>&1 || {
    if python3 -c "import Xlib" 2>/dev/null; then
        sudo DISPLAY=:1 nohup python3 "$G/keymapd.py" > /tmp/keymap.log 2>&1 &
        sleep 1
    else
        echo "WARN: python3-xlib missing — VNC keyboard mapping off (re-run install.sh to fix)" >&2
    fi
}

# Stop a previously launched app — the WHOLE tree. A wrapper-only kill
# orphans the app UI + audio pump + aplay at ppid=1, where they keep an
# aloop substream and keep respawning their aplay, poisoning audio
# capture for the new instance (see audio_capture.sh). Tree runs as
# root inside the chroot, so kill with sudo.
if [ -f "$PIDF" ]; then
    OLD=$(cat "$PIDF" 2>/dev/null)
    if [ -n "$OLD" ]; then
        killtree() { for c in $(pgrep -P "$1" 2>/dev/null); do killtree "$c"; done; sudo kill "$1" 2>/dev/null; }
        killtree "$OLD"
        sleep 1
        # the app installs signal handlers and IGNORES SIGTERM — escalate
        killtree() { for c in $(pgrep -P "$1" 2>/dev/null); do killtree "$c"; done; sudo kill -9 "$1" 2>/dev/null; }
        killtree "$OLD"
        # (no name sweep here: our own cmdline carries the launch CMD
        # argument "gb_launch.py", so a pkill pattern would match us)
    fi
fi

echo $$ > "$PIDF"
# SDL_VIDEO_X11_XRANDR=0: SDL's RandR fullscreen mode-switching reprograms
# the Xvnc screen and leaves the desktop at 1024x768 (its built-in default)
# — the app's 1280-wide fullscreen UI then hangs off the shrunken desktop,
# clipped ("VNC cuts parts of the screen off"). With RandR switching off,
# SDL fullscreen just uses the desktop size as-is.
exec "$G/knulli-chroot.sh" "cd '$DIR' && exec env SDL_VIDEO_X11_XRANDR=0 $CMD"
