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
if ! $SUDO modprobe snd-aloop 2>/dev/null; then
    # Classic trap: unattended-upgrades installs a new kernel but NOT
    # linux-modules-extra (where snd-aloop lives) for it. The VM then boots
    # fine and everything looks up, but the loopback card simply doesn't
    # exist and audio dies with only a WARN in the app log. Self-heal:
    # install the extra-modules package matching the RUNNING kernel.
    if [ -d "/lib/modules/$(uname -r)" ]; then
        echo "snd-aloop missing for kernel $(uname -r); installing linux-modules-extra ..." >&2
        $SUDO apt-get update -qq >/dev/null 2>&1 || true
        $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            "linux-modules-extra-$(uname -r)" >/dev/null 2>&1 || true
        $SUDO modprobe snd-aloop 2>/dev/null || true
    fi
fi
# /proc/asound/cards says "Loopback"; the module name is what to check
grep -q snd_aloop /proc/modules || { echo "snd-aloop failed to load" >&2; exit 1; }
if ! grep -q "^[[:space:]]*1 \[Loopback" /proc/asound/cards; then
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
# Device choice is load-bearing, and aloop's cable map is NOT what the docs
# suggest: an empirical matrix (tone on each playback x capture on each
# device, both start orders) proves that on this card device 0's PLAYBACK is
# looped to device 1's CAPTURE (D0p -> D1c), and same-numbered pairs carry
# nothing. So: apps write default -> device 0; the Mac reads hw:Loopback,1,0
# — that is the live cable. Device 0's capture (what a hardcoded hw:1,0
# "mic" opens) is fed by device 1's playback, which nothing writes: a silent
# mic, like a device with no mic input, instead of a feedback echo of the
# app's own output. Moving default to device 1 plugs the app into a dead
# cable: full-rate clock-locked digital silence.
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
echo "alsa default -> loopback (card Loopback,1) in $R/etc/asound.conf"
