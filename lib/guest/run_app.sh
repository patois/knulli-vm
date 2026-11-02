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
command -v xdotool >/dev/null 2>&1 || sudo apt-get install -y -qq xdotool >/dev/null 2>&1
pgrep -f "focusd[.]sh" >/dev/null 2>&1 || {
    nohup "$G/focusd.sh" > /tmp/focusd.log 2>&1 &
    sleep 1
}
# keyboard -> joypad on the VM display (needs python3-xlib)
pgrep -f "keymapd[.]py" >/dev/null 2>&1 || {
    python3 -c "import Xlib" 2>/dev/null || sudo apt-get install -y -qq python3-xlib >/dev/null 2>&1
    sudo DISPLAY=:1 nohup python3 "$G/keymapd.py" > /tmp/keymap.log 2>&1 &
    sleep 1
}
# Display + VNC: prefer TigerVNC's Xvnc (X server and VNC server in one,
# modern input pipeline) over Xvfb+x11vnc. x11vnc starves its client input
# queue while diffing the framebuffer (Recv-Q grew unboundedly under
# animation — 742KB->1.6MB measured — so keyboard/mouse arrive seconds
# late); Xvnc processes input on its own event loop, no second server,
# no diff loop. Ubuntu's tigervnc package has no x0vncserver (serve-existing
# -display mode is not built), so we move the display to Xvnc instead of
# mirroring Xvfb.
MARK=/tmp/knulli-vnc.passwd-md5
want=$(printf '%s' "$VNC_PASS" | md5sum | cut -d' ' -f1)
if command -v Xvnc >/dev/null 2>&1; then
    if pgrep -x Xvnc >/dev/null 2>&1 && [ "$(cat "$MARK" 2>/dev/null)" = "$want" ]; then
        :
    else
        pkill -x x11vnc 2>/dev/null; pkill -x Xvfb 2>/dev/null; sleep 1
        rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null
        printf '%s\n%s\n' "$VNC_PASS" "$VNC_PASS" | vncpasswd -f > /tmp/knulli-vnc.pass
        chmod 600 /tmp/knulli-vnc.pass
        (setsid nohup Xvnc :1 -geometry 1280x720 -depth 24 -rfbport 5901 \
            -SecurityTypes VncAuth -PasswordFile /tmp/knulli-vnc.pass \
            -AlwaysShared -localhost yes > /tmp/xvnc.log 2>&1 &)
        sleep 2
        echo "$want" > "$MARK"
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

# stop a previously launched app (sudo forwards SIGTERM into the chroot)
if [ -f "$PIDF" ]; then
    OLD=$(cat "$PIDF" 2>/dev/null)
    [ -n "$OLD" ] && kill "$OLD" 2>/dev/null
    sleep 1
fi

echo $$ > "$PIDF"
exec "$G/knulli-chroot.sh" "cd '$DIR' && exec $CMD"
