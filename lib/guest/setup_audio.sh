#!/bin/bash
# In-guest: route the KNULLI chroot's ALSA "default" into a snd-aloop
# loopback card. The Mac host captures the other end (hw:Loopback,1,0) and
# plays it locally — the VM has no audio device, this is the way out.
#   usage: setup_audio.sh <rootfs-dir>
set -euo pipefail
R="${1:?usage: setup_audio.sh <rootfs-dir>}"
SUDO=sudo

# Card indices are load-bearing, not cosmetic: apps like GrainBrick open the
# mic as a hardcoded hw:1,0, so the loopback card MUST be card 1. We pin
# snd-dummy to 0 and snd-aloop to 1 (dummy exists solely to occupy index 0).
if ! $SUDO test -f /etc/modprobe.d/knulli-vm.conf; then
    printf 'options snd-dummy index=0\noptions snd-aloop index=1 id=Loopback\n' \
        | $SUDO tee /etc/modprobe.d/knulli-vm.conf >/dev/null
fi
$SUDO modprobe snd-dummy 2>/dev/null || true
$SUDO modprobe snd-aloop 2>/dev/null || true
# /proc/asound/cards says "Loopback"; the module name is what to check
grep -q snd_aloop /proc/modules || { echo "snd-aloop failed to load" >&2; exit 1; }
if ! grep -q "^Loopback$" /proc/asound/cards 2>/dev/null || ! grep -q "1 \[Loopback" /proc/asound/cards; then
    echo "WARNING: Loopback is not card 1 — apps with hardcoded hw:1,0 will mis-open" >&2
    grep -E "Loopback|Dummy" /proc/asound/cards >&2 || true
fi
printf 'snd-dummy\nsnd-aloop\n' | $SUDO tee /etc/modules-load.d/knulli-vm.conf >/dev/null

if $SUDO test -f "$R/etc/asound.conf" && ! $SUDO grep -q "knulli-vm" "$R/etc/asound.conf"; then
    $SUDO cp "$R/etc/asound.conf" "$R/etc/asound.conf.knulli-vm-orig"
    echo "backed up image asound.conf -> etc/asound.conf.knulli-vm-orig"
fi
$SUDO tee "$R/etc/asound.conf" > /dev/null <<'EOF'
# knulli-vm: send all audio to the loopback card; the Mac host captures
# hw:Loopback,1,0 (same rate/format) and plays it. Do not edit the rate or
# format without matching the host-side arecord invocation.
# Note: with two aloop devices the cables are CROSS-wired — writes to device
# 0's playback are readable at device 1's capture. That is intended: it also
# leaves device 0's capture (what a hardcoded hw:1,0 "mic" opens) hearing
# device 1's playback, which nothing writes to — a silent mic, like a device
# with no mic input, instead of a feedback echo of the app's own output.
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
