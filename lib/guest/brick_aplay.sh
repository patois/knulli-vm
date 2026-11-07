#!/bin/bash
# knulli-vm's aplay, installed as <rootfs>/usr/local/bin/aplay so it comes first
# on the chroot's PATH. The real aplay stays at /usr/bin/aplay, untouched.
#
# WHY THIS EXISTS AT ALL. Output delay here is not in the wire, it is in the
# writer's own ALSA buffer. A stream that goes straight to the hardware (which is
# what asound.conf does now, because dmix pinned its mix position at zero — see
# setup_audio.sh) has no ring of ours to size: the buffer belongs to whoever
# opens the stream, and `aplay` with no size flags asks for its own default, which
# is a 500 ms buffer — negotiated 24000 frames / 6000 period on this card, read
# out of /proc/asound/card2/pcm0p/subN/hw_params. A click 2.000 s into a file
# therefore arrived on the cable 627 ms after it was written, measured on one
# clock at both ends. With a 20 ms buffer the same click arrived 202 ms after,
# which is the floor of everything downstream (loopback + reader + ssh + Mac).
# The old dmix config hid this by pinning the slave's buffer small.
#
# GrainBrick's audible path IS `aplay` (its DSP worker pipes raw S16 to aplay's
# stdin; the argv is built by AudioOutput._aplay_args, read out of the binary), so
# this wrapper is the one place the size can be set without touching the app —
# which is closed source and runs exactly as distributed.
#
# It does two things, and both are conditional:
#   * logs every argv it is called with (with a timestamp) to
#     /tmp/knulli-vm-aplay.log, so what the app actually asks for is a fact on
#     disk rather than a theory;
#   * injects a 20 ms buffer ONLY when the caller named no size of its own. An
#     app that sets --buffer-size/--period-size/-B/-F (GrainBrick has a
#     low-latency mode that does exactly that) is obeyed as written.
#
# Override the sizes from the environment (frames, not microseconds) to
# experiment: KBUFFER / KPERIOD.
set -u
LOG="${KAPLAY_LOG:-/tmp/knulli-vm-aplay.log}"
REAL=/usr/bin/aplay
[ -x "$REAL" ] || REAL=$(PATH=/usr/bin:/bin command -v aplay)

# Best effort, never fatal: an unwritable log must not cost the user their sound.
{ printf '%s.%03d' "$(date +%s)" "$(( 10#$(date +%N 2>/dev/null || echo 0) / 1000000 ))"
  printf ' aplay'; printf ' %q' "$@"; printf '\n'; } >>"$LOG" 2>/dev/null || true

info=0 timed=0
for a in "$@"; do
    case "$a" in
        # -v is VERBOSE on aplay (version is -V), so it must not count as info:
        # `aplay -v -D default` was classified as a query, skipped injection,
        # and negotiated its own 500 ms buffer again.
        -l|--list-devices|-L|--list-rawdevs|-h|--help|-V|--version) info=1;;
        -B|-F|-b|-p|--buffer-time|--period-time|--buffer-size|--period-size|\
        --buffer-time=*|--period-time=*|--buffer-size=*|--period-size=*) timed=1;;
    esac
done
# Listing and version queries must reach aplay exactly as typed.
if [ "$info" = 0 ] && [ "$timed" = 0 ]; then
    set -- --buffer-size "${KBUFFER:-960}" --period-size "${KPERIOD:-240}" "$@"
fi

# CAP oversized caller buffers. GrainBrick's audible worker asks, measured from
# this log, for `--buffer-size 7168 --period-size 512` — 149 ms of ring, which
# is right for the Brick's real DAC and wrong here: the consumer is a loopback
# + reader + ssh pipeline, and a realtime producer that starts behind by
# start_threshold (= the buffer, aplay's default) STAYS behind by that much for
# the whole note. 149 ms of the output latency the user hears is the app's own
# ring, and no amount of reader tuning can give it back. KMAXBUFFER caps it
# (0 = obey callers exactly, the pre-cap behaviour); the period is capped to a
# quarter so the buffer still holds four of them.
maxb=${KMAXBUFFER:-1024}
if [ "$info" = 0 ] && [ "$timed" = 1 ] && [ "$maxb" -gt 0 ]; then
    maxp=$(( maxb / 4 ))
    out=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --buffer-size)   v=$2; [ "$v" -gt "$maxb" ] 2>/dev/null && v=$maxb
                             out+=(--buffer-size "$v"); shift;;
            --buffer-size=*) v=${1#*=}; [ "$v" -gt "$maxb" ] 2>/dev/null && v=$maxb
                             out+=(--buffer-size="$v");;
            --period-size)   v=$2; [ "$v" -gt "$maxp" ] 2>/dev/null && v=$maxp
                             out+=(--period-size "$v"); shift;;
            --period-size=*) v=${1#*=}; [ "$v" -gt "$maxp" ] 2>/dev/null && v=$maxp
                             out+=(--period-size="$v");;
            *)               out+=("$1");;
        esac
        shift
    done
    set -- "${out[@]}"
    # Log what we ACTUALLY exec, not just what was asked: without this, "did
    # the cap apply?" is answered only by a negotiation dump, and hw_params
    # keeps a dead stream's values, so the dump can lie.
    { printf '%s.%03d final aplay' "$(date +%s)" "$(( 10#$(date +%N 2>/dev/null || echo 0) / 1000000 ))"
      printf ' %q' "$@"; printf '\n'; } >>"$LOG" 2>/dev/null || true
fi
exec "$REAL" "$@"
