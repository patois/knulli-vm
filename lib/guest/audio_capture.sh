#!/bin/bash
# In-guest: read the app's output cable and put it on stdout for the Mac.
#
# There is nothing to choose here, and that is the design. The chroot's ALSA
# `default` mixes every playback client through dmix onto ONE aloop substream
# (see lib/guest/setup_audio.sh), so the capture end is a single cable that
# exists as soon as the card does: hw:<card>,1,0, always up, carrying every
# stream the app has. Runtime substream discovery was tried first and could not
# be made honest — snd-aloop gives each opened stream its own sub, so a chooser
# had to guess which sub mattered, and while it guessed wrong (or went looking
# again) the Mac heard silence or a gap in the middle of a note.
#
# The cable map that makes ,1,0 the right answer: aloop pairs CROSS-DEVICE and
# same-substream — playback device 0 subN -> capture device 1 subN — so device
# 0's sub 0 (where dmix writes) is read at device 1's sub 0. Same-numbered
# device pairs carry nothing. Measured, not documented; see setup_audio.sh.
#
# The card is named, never numbered (setup_audio.sh pins it to index 2 today,
# and the day it isn't is exactly the day a number in two scripts disagrees with
# a number in one). The /proc/asound/cards lookup is not decoration either: the
# name is passed to arecord directly, so without the check a missing card fails
# as an arecord error instead of a sentence saying which card to go make.
# tools/audio_static_mix_test.sh covers the cable itself, on this card, with the
# app running.
#
# Runs as root (the guest user is not in the audio group). -B/-F are
# microseconds: 100 ms buffer / 25 ms periods keep the loopback->ssh pipe
# flowing in small quanta (low latency) while staying far above the app's
# ~21 ms DSP blocks (no xruns).
set -u
CARD_NAME=Loopback
CARD=$(awk -v n="$CARD_NAME" '/\][[:space:]]*:/ && (index($0,"[" n "]") || index($0,"[" n " ")) {print $1; exit}' /proc/asound/cards)
[ -n "$CARD" ] || { echo "audio_capture: no '$CARD_NAME' sound card (run setup_audio.sh)" >&2; exit 1; }
exec arecord -D "hw:$CARD_NAME,1,0" -f S16_LE -r 48000 -c 2 -t raw -q \
    -B 100000 -F 25000
