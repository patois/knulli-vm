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

lsmod | grep -q snd_dummy || sudo modprobe snd-dummy

pgrep -f "virtual_joypad[.]py" >/dev/null 2>&1 || {
    sudo nohup python3 "$G/virtual_joypad.py" retrogame_joypad > /tmp/joypad.log 2>&1 &
    sleep 1
}
pgrep -x Xvfb >/dev/null 2>&1 || (Xvfb :1 -screen 0 1280x720x24 >/tmp/xvfb.log 2>&1 & sleep 1)
pgrep -x x11vnc >/dev/null 2>&1 || (x11vnc -display :1 -forever -shared -passwd "$VNC_PASS" \
    -rfbport 5901 -bg -o /tmp/x11vnc.log >/dev/null 2>&1; sleep 1)

# stop a previously launched app (sudo forwards SIGTERM into the chroot)
if [ -f "$PIDF" ]; then
    OLD=$(cat "$PIDF" 2>/dev/null)
    [ -n "$OLD" ] && kill "$OLD" 2>/dev/null
    sleep 1
fi

echo $$ > "$PIDF"
exec "$G/knulli-chroot.sh" "cd '$DIR' && exec $CMD"
