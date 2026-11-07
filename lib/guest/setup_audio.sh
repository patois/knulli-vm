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
# knulli-vm: send all audio to the loopback card; the Mac host captures the far
# end by NAME (audio_capture.sh, same rate/format) and plays it. Do not edit the
# rate or format without matching that reader.
# Device choice is load-bearing, and aloop's cable map is NOT what the docs
# suggest: a matrix measured by RMS (noise on each playback sub x capture on
# each device/sub, both start orders) proves the cable is CROSS-DEVICE and
# same-substream — D0p subN -> D1c subN and D1p subN -> D0c subN — while
# same-numbered pairs carry nothing. (Byte counts cannot show this: arecord
# returns full-length buffers of zeros from a dead cable.) So: apps write
# default -> device 0, and the Mac reads device 1 at whatever sub the writer
# landed on — which is why the reader takes them all. Re-measured per-sub after
# the change below: a click written on hw:Loopback,0,1 came back on
# hw:Loopback,1,1 bit-exact, peak 30000 of a 30000-sample impulse.
# Device 0's capture is fed by device 1's playback, which nothing writes, so an
# idle mic reads silence like a device with no mic input instead of echoing the
# app's own output back at it; audio_feed.sh writes that device 1 playback to
# put real signal on a capture the app has open. Moving default to device 1
# plugs the app into a dead cable: full-rate clock-locked digital silence.
#
# WHY PLAYBACK IS NOT MIXED. It was dmix here, deliberately, to get one static
# cable instead of hunting substreams at runtime — and measured, dmix was the
# whole of the "enormous delay that will not clear" report. GrainBrick opens
# ALSA twice: the audible worker pipes into `aplay`, and pygame/SDL2 holds a
# second stream that it opens at startup and never writes a frame to. dmix puts
# every client on one hardware substream and refuses to mix past the SLOWEST
# client's position, so that idle stream pins the mix where it started. After 35
# hours the shared slave's hw_ptr had run 6.0e9 frames ahead while its appl_ptr
# was still 0 — the mixer had mixed nothing since before the app started — and a
# click written through `default` reached the cable as nine seconds of exact
# zeros: accepted, buffered, never mixed out. The backlog sits in the guest's
# mixer ring, where the Mac-side drop cannot reach it, so the delay never comes
# back on its own. A direct stream has no shared position to wait for:
# each client owns a substream, and a client that never writes can only stall
# its own silence.
#
# Dropping the mixer costs the single cable — snd-aloop gives every client its
# own sub again — and audio_capture.sh pays for it by holding the capture end of
# every substream it can, permanently, and summing them. Static wiring, as
# before, one wire per sub instead of one shared mixer.
#
# WHY default IS `asym`: capture stays exactly as it has always been here
# (device 0's capture — the cable nothing writes, i.e. the mic) and only the
# playback direction is routed to the loopback.
pcm.!default {
    type asym
    playback.pcm {
        # No subdevice: ALSA hands the client the next free substream and the
        # reader takes whatever sub that was.
        #
        # No period_size/buffer_size here either — `snd_pcm_slave_conf` rejects
        # them outright ("Unknown field period_size", audio open error: Invalid
        # argument, for every client), and unlike a dmix slave there is no ring
        # of ours to size: the buffer now belongs to whoever opens the stream, so
        # the latency knob is the client's own -B/-F (GrainBrick's aplay asks, and
        # the reader asks too). What the writer actually negotiated is visible at
        # /proc/asound/card2/pcm0p/subN/hw_params if the instrument ever feels
        # late — and left to itself aplay asks for 24000 frames (500 ms), which is
        # why usr/local/bin/aplay (brick_aplay.sh) exists: it gives a caller that
        # named no size a 20 ms buffer. Measured on one clock at both ends, a click
        # 2 s into a file reached the Mac-side reader 627 ms late with aplay's
        # default and 202 ms with a 20 ms buffer.
        type plug
        slave {
            pcm { type hw; card Loopback; device 0 }
            format S16_LE
            rate 48000
            channels 2
        }
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
    hint { show true description "knulli-vm out to Mac (one substream per client)" }
}
ctl.!default { type hw; card Loopback }
EOF
echo "alsa default -> card 'Loopback' device 0, one substream per client, in $R/etc/asound.conf"

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

# --- the output buffer's size -------------------------------------------------
# Same trick for the same reason as above: the app's audible path is `aplay`, and
# an aplay that names no buffer size gets its own 500 ms default, which on a
# direct hardware stream IS the output latency. See brick_aplay.sh for numbers.
if [ -f "$HERE/brick_aplay.sh" ]; then
    $SUDO mkdir -p "$R/usr/local/bin"
    $SUDO install -m 755 "$HERE/brick_aplay.sh" "$R/usr/local/bin/aplay"
    echo "aplay shim -> $R/usr/local/bin/aplay (real one still at usr/bin/aplay)"
else
    echo "WARNING: brick_aplay.sh not found next to setup_audio.sh — output keeps aplay's 500 ms buffer" >&2
fi

# --- describe the emulated USB card -----------------------------------------
if [ -f "$HERE/asound_overlay.sh" ]; then
    "$HERE/asound_overlay.sh" "$R" --generate-only \
        || echo "WARNING: could not generate the USB-Audio card table" >&2
fi
echo "sound cards: $(tr -d '\n' < /proc/asound/cards | cut -c1-120)"
