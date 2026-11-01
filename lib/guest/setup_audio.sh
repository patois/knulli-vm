#!/bin/bash
# In-guest: route the KNULLI chroot's ALSA "default" into a snd-aloop
# loopback card. The Mac host captures the other end (hw:Loopback,1,0) and
# plays it locally — the VM has no audio device, this is the way out.
#   usage: setup_audio.sh <rootfs-dir>
set -euo pipefail
R="${1:?usage: setup_audio.sh <rootfs-dir>}"
SUDO=sudo

$SUDO modprobe snd-aloop 2>/dev/null || true
# /proc/asound/cards says "Loopback"; the module name is what to check
grep -q snd_aloop /proc/modules || { echo "snd-aloop failed to load" >&2; exit 1; }
echo snd-aloop | $SUDO tee /etc/modules-load.d/knulli-vm.conf >/dev/null

if $SUDO test -f "$R/etc/asound.conf" && ! $SUDO grep -q "knulli-vm" "$R/etc/asound.conf"; then
    $SUDO cp "$R/etc/asound.conf" "$R/etc/asound.conf.knulli-vm-orig"
    echo "backed up image asound.conf -> etc/asound.conf.knulli-vm-orig"
fi
$SUDO tee "$R/etc/asound.conf" > /dev/null <<'EOF'
# knulli-vm: send all audio to the loopback card; the Mac host captures
# hw:Loopback,1,0 (same rate/format) and plays it. Do not edit the rate or
# format without matching the host-side arecord invocation.
pcm.!default {
    type plug
    slave {
        pcm { type hw; card Loopback; device 0 }
        format S16_LE
        rate 48000
        channels 2
    }
    hint { show true description "knulli-vm out to Mac" }
}
ctl.!default { type hw; card Loopback }
EOF
echo "alsa default -> loopback (card Loopback,0) in $R/etc/asound.conf"
