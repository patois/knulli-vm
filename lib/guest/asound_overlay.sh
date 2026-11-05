#!/bin/bash
# In-guest: make the emulated USB sound card LOOK like a USB sound card to
# GrainBrick's capture discovery, without touching the app.
#
# Why this exists. GrainBrick's available_usb_captures() (engine/audio_inputs.py,
# read out of the 1.0.1 binary) parses /proc/asound/cards with
#     (?m)^\s*(\d+)\s+\[([^]]+)\]\s*:\s*([^\n]+)
# and keeps a card only when the DRIVER field (group 3, up to the first " - ")
# lowercases to "usb-audio" or "usb audio". That field is card->driver in the
# kernel — snd-usb-audio sets it to "USB-Audio" and NOTHING else does; aloop
# always reports "Loopback" and it is not a tunable. So no module parameter can
# produce a card the app will accept.
#
# The same function takes an `asound_root` argument (default /proc/asound) and
# only ever READS from it: `cards`, then `card<N>/pcm<M>c` directories. The
# device it hands back is a NAME — plughw:CARD=<id>,DEV=<n> — which ALSA
# resolves through /dev/snd/controlC*, not /proc. That split is the whole
# opening: describe the card in a synthetic `cards` file, and let the real
# aloop card behind it carry the audio.
#
# A bind-mount over a procfs regular file works (verified on this kernel), so
# we rewrite just that one file inside the chroot's own /proc mount and leave
# every other view of the sound system real: card numbers, card ids, the
# pcm<M>c directories the function iterates, and the ALSA name resolution.
#
# The [name] field must still pass fullmatch("[A-Za-z0-9_]+"), which is why the
# card is called USBAudio and not USB-Audio — a hyphen makes the app skip the
# card entirely, and that fact cost this design its obvious first form.
#
#   usage: asound_overlay.sh <rootfs> [--generate-only]
set -euo pipefail
R="${1:?usage: asound_overlay.sh <rootfs> [--generate-only]}"
SUDO=sudo
USB_ID=USBAudio
# The label the app shows in the UI ("USB DEVICE ...") and logs.
USB_LABEL="GrainBrick Virtual Audio"
STATE_DIR="var/lib/knulli-vm"
CARDS_FILE="$R/$STATE_DIR/asound-cards"

# The driver field of a real USB sound card. Exactly what the app filters on.
DRIVER="USB-Audio"

$SUDO mkdir -p "$R/$STATE_DIR"
[ -e /proc/asound/cards ] || { echo "asound_overlay: no /proc/asound in this kernel" >&2; exit 1; }

# Regenerate from the REAL card table so card numbers, ids and every other
# card stay truthful — we only restate the one card's driver. Written in place
# (tee truncates the existing inode): a bind-mount follows the inode, so `cp`
# or `mv` here would leave the app reading a stale file forever.
gen() {
    awk -v id="$USB_ID" -v label="$USB_LABEL" -v drv="$DRIVER" '
        # header line of our card: " 2 [USBAudio       ]: Loopback - USBAudio"
        index($0, "[" id "]") || index($0, "[" id " ") {
            p = index($0, "]")
            if (p) { print substr($0, 1, p) ": " drv " - " label; next }
        }
        { print }
    ' /proc/asound/cards | $SUDO tee "$CARDS_FILE" >/dev/null
}
gen

if ! grep -q "$DRIVER" "$CARDS_FILE"; then
    echo "asound_overlay: WARNING: card '$USB_ID' is not in /proc/asound/cards — nothing to describe (run setup_audio.sh)" >&2
fi

[ "${2:-}" = "--generate-only" ] && { echo "asound_overlay: wrote $CARDS_FILE"; exit 0; }

# Apply inside the chroot. knulli-chroot.sh mounts its own proc, so the bind
# belongs to that mount, not to the VM's /proc.
if [ ! -d "$R/proc/asound" ]; then
    echo "asound_overlay: $R/proc/asound missing (chroot proc not mounted) — run knulli-chroot.sh first" >&2
    exit 1
fi
if $SUDO mountpoint -q "$R/proc/asound/cards"; then
    echo "asound_overlay: already bound"
else
    $SUDO mount --bind "$CARDS_FILE" "$R/proc/asound/cards"
    echo "asound_overlay: bound $CARDS_FILE -> $R/proc/asound/cards"
fi
$SUDO chroot "$R" grep -q "$DRIVER" /proc/asound/cards \
    && echo "asound_overlay: app now sees a USB-Audio capture card" \
    || echo "asound_overlay: WARNING: still no USB-Audio line inside the chroot" >&2
