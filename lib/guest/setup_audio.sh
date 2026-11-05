#!/bin/bash
# In-guest: build the sound system the app expects, out of loopback cards.
#   usage: setup_audio.sh <rootfs-dir>
#
# Three snd-aloop cards, indices pinned — every number here is load-bearing:
#
#   card 0  Codec     The device's built-in audio codec. GrainBrick's
#                     BUILT-IN MIC preset is a hardcoded hw:0,0 (48k/16/MONO,
#                     read out of the binary), so index 0 must be a real
#                     capture device — snd-dummy sat here before and could only
#                     ever hand the app silence.
#   card 1  USBAudio  The emulated USB audio interface GrainBrick records from.
#                     Index 1 is not arbitrary: GrainBrick 1.0 hardcodes its USB
#                     record device as hw:1,0 (that IS the device's convention —
#                     codec on 0, USB stick on 1), while 1.0.1 and later resolve
#                     it by name. Sitting on index 1 satisfies both, so one
#                     layout serves every build.
#                     Named without a hyphen on purpose: 1.0.1 validates the
#                     [name] field of /proc/asound/cards against
#                     [A-Za-z0-9_]+ and skips anything else. The "it's a USB
#                     card" claim lives in asound_overlay.sh, because the
#                     kernel's driver field is not a tunable.
#   card 2  Loopback  The app's OUTPUT path. Its asound.conf "default" points
#                     here by NAME and the Mac captures the far end by name
#                     (audio_capture.sh), so this one moved without touching
#                     either script — but nothing else may assume it is card 1.
set -euo pipefail
R="${1:?usage: setup_audio.sh <rootfs-dir>}"
SUDO=sudo
HERE="$(cd "$(dirname "$0")" && pwd)"
WANT=(Codec USBAudio Loopback)

# Module parameters cannot change on a live module, so the conf is written
# first and (re)loading below is what actually applies it. Overwrite whenever
# the layout isn't ours — the old file pinned dummy+one aloop, and an
# "only if missing" guard would keep that layout forever on upgrades.
# enable=Y,Y,Y is not decoration: the slots this driver probes are gated by
# enable[], whose default leaves only the first one on, so a three-card request
# can silently come back as one card.
# pcms=2,2,2 is load-bearing, not tidiness: every cable in this design is
# cross-DEVICE (D0p<->D1c), so a card with ONE pcm device has no far end at
# all — the output would have nowhere to be captured and a feed nothing to
# write. The module's default for pcms has differed between kernel eras, so
# never inherit it: say 2 on every card, every boot. (The running VM here has
# 2 per card; this makes a fresh install GUARANTEE it rather than get lucky.)
DESIRED='options snd-aloop index=0,1,2 id=Codec,USBAudio,Loopback enable=Y,Y,Y pcms=2,2,2'
if ! $SUDO grep -qxF "$DESIRED" /etc/modprobe.d/knulli-vm.conf 2>/dev/null; then
    printf '%s\n' "$DESIRED" | $SUDO tee /etc/modprobe.d/knulli-vm.conf >/dev/null
fi

have_all() {
    local i
    for i in 0 1 2; do
        [ "$(cat "/proc/asound/card$i/id" 2>/dev/null)" = "${WANT[$i]}" ] || return 1
    done
    return 0
}

load_cards() {
    # snd-dummy must go, not merely "not be loaded": it claims card index 0,
    # and aloop then refuses to probe at all —
    #   cannot find the slot for index 0 (range 0-1), error: -16
    # which reads like a missing module and sent the self-heal below hunting
    # for linux-modules-extra that was there all along.
    $SUDO rmmod snd_dummy 2>/dev/null || true
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
}

have_all || {
    load_cards
    have_all || {
        # Wrong layout already loaded (dummy on 0, single aloop on 1): module
        # params are fixed at load time, so the only fix is a reload — which
        # needs nothing to be holding a stream. Stop the app and the Mac audio
        # pipe first (knulli-vm stop does both).
        $SUDO rmmod snd-aloop 2>/dev/null || true
        $SUDO rmmod snd_dummy 2>/dev/null || true
        load_cards
    }
}
grep -q snd_aloop /proc/modules || { echo "snd-aloop failed to load" >&2; exit 1; }
have_all || {
    echo "WARNING: sound cards are not Codec/USBAudio/Loopback on 0/1/2 — something holds a stream." >&2
    echo "         stop the app and the audio pipe, then re-run; if it persists: knulli-vm down && knulli-vm up" >&2
    grep -E "Loopback|Dummy|Codec|USBAudio" /proc/asound/cards >&2 || true
}
# GrainBrick 1.0's hardcoded USB record device IS the index, so this is the one
# card number an app (not a script) depends on.
if ! grep -q "^[[:space:]]*1 \[USBAudio" /proc/asound/cards; then
    echo "WARNING: USBAudio is not card 1 — GrainBrick 1.0 (which opens hw:1,0 for USB capture) will record the wrong card" >&2
    grep -E "Codec|USBAudio|Loopback" /proc/asound/cards >&2 || true
fi
printf 'snd-aloop\n' | $SUDO tee /etc/modules-load.d/knulli-vm.conf >/dev/null

if $SUDO test -f "$R/etc/asound.conf" && ! $SUDO grep -q "knulli-vm" "$R/etc/asound.conf"; then
    $SUDO cp "$R/etc/asound.conf" "$R/etc/asound.conf.knulli-vm-orig"
    echo "backed up image asound.conf -> etc/asound.conf.knulli-vm-orig"
fi
$SUDO tee "$R/etc/asound.conf" > /dev/null <<'EOF'
# knulli-vm: send all audio to the loopback card; the Mac host captures
# hw:Loopback,1,0 (same rate/format) and plays it. Do not edit the rate or
# format without matching the host-side arecord invocation.
# Device choice is load-bearing, and aloop's cable map is NOT what the docs
# suggest: a matrix measured by RMS (noise on each playback sub x capture on
# each device/sub, both start orders) proves the cable is CROSS-DEVICE and
# same-substream — D0p subN -> D1c subN and D1p subN -> D0c subN — while
# same-numbered pairs carry nothing. (Byte counts cannot show this: arecord
# returns full-length buffers of zeros from a dead cable.) So: apps write
# default -> device 0; the Mac reads hw:Loopback,1,0 — that is the live cable.
# Device 0's capture is fed by device 1's playback, which nothing writes, so an
# idle mic reads silence like a device with no mic input instead of echoing the
# app's own output back at it; audio_feed.sh writes that device 1 playback to
# put real signal on a capture the app has open. Moving default to device 1
# plugs the app into a dead cable: full-rate clock-locked digital silence.
#
# WHY PLAYBACK IS MIXED, NOT DIRECT. snd-aloop hands out a NEW substream for
# every stream a client opens, so an app with two output streams — GrainBrick
# keeps an always-on monitor stream next to its audio worker — lands on sub0 and
# sub1, and a capture pinned to one of them hears only that one. That is how
# "the app outputs pure silence" happened while it was playing on the other
# sub: the silent stream was the one being read. dmix is ALSA's software mixer:
# every client shares ONE hardware substream, so there is exactly one cable to
# read, it exists from the moment the card does, and nothing has to be
# discovered, followed or re-selected while music is playing. `plug` in front
# converts whatever a client asks for (mono, 44.1k, whatever) into that mix.
#
# WHY default IS `asym` AND NOT JUST THE MIXER: dmix is playback-only, so making
# it `default` outright would make `arecord -D default` fail to open at all.
# asym keeps capture exactly as it has always been here (device 0's capture —
# the cable nothing writes, i.e. the mic) and mixes only the playback direction.
pcm.knulli-vm-out {
    type dmix
    # Every client must land in the SAME mixer: per-uid key derivation would
    # hand root and the app separate mixers writing the same hardware substream,
    # which is worse than useless — one silently wins and the other is silence.
    ipc_key 4249001
    ipc_key_add_uid false
    slave {
        pcm { type hw; card Loopback; device 0; subdevice 0 }
        format S16_LE
        rate 48000
        channels 2
        # 1024/4096 = 21ms/85ms at 48k. This ring is the price of static
        # wiring: it is REAL added latency (a few tens of ms) in front of the
        # arecord/ssh/audioplay chain, and it is the first knob to turn if the
        # instrument feels late. No XRUNs were seen at this size with the app's
        # monitor stream plus two mixing clients (tools/audio_static_mix_test.sh
        # prints any), but lower it honestly: the ring belongs to whoever opens
        # the mixer first (the app's monitor stream), so a new size only takes
        # effect when the app restarts, and it needs another no-XRUN run after.
        period_size 1024
        buffer_size 4096
    }
}
pcm.!default {
    type asym
    playback.pcm {
        type plug
        slave.pcm "knulli-vm-out"
    }
    capture.pcm {
        type plug
        slave {
            pcm { type hw; card Loopback; device 0 }
            format S16_LE
            rate 48000
            channels 2
        }
    }
    hint { show true description "knulli-vm out to Mac (dmix)" }
}
ctl.!default { type hw; card Loopback }
EOF
echo "alsa default -> dmix mix on card 'Loopback' device 0 (one cable) in $R/etc/asound.conf"

# --- the built-in mic's mixer ------------------------------------------------
# configure_builtin_mic() shells amixer for three Allwinner codec elements
# before it will record from hw:0,0, and reports AMIXER FAILED if any call
# fails. The VM has no codec (an aloop card exposes no mixer elements at all),
# so a shim answers those elements and forwards everything else untouched.
# It goes in /usr/local/bin, which is ahead of /usr/bin on the chroot's PATH,
# so the real /usr/bin/amixer stays exactly where it is.
if [ -f "$HERE/brick_amixer.sh" ]; then
    # KNULLI's image has no /usr/local at all, so create the dir rather than
    # assume install can write into it.
    $SUDO mkdir -p "$R/usr/local/bin"
    $SUDO install -m 755 "$HERE/brick_amixer.sh" "$R/usr/local/bin/amixer"
    echo "amixer shim -> $R/usr/local/bin/amixer (real one still at usr/bin/amixer)"
else
    echo "WARNING: brick_amixer.sh not found next to setup_audio.sh — the mic path will report AMIXER FAILED" >&2
fi

# --- describe the emulated USB card -----------------------------------------
if [ -f "$HERE/asound_overlay.sh" ]; then
    "$HERE/asound_overlay.sh" "$R" --generate-only \
        || echo "WARNING: could not generate the USB-Audio card table" >&2
fi
echo "sound cards: $(tr -d '\n' < /proc/asound/cards | cut -c1-120)"
