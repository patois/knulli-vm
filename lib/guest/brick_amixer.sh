#!/bin/bash
# Stands in for the Brick's codec mixer inside the chroot, installed as
# /usr/local/bin/amixer (first on the chroot's PATH, so the app's bare
# `amixer` resolves here; the real binary stays at /usr/bin/amixer).
#
# Why: before recording from the built-in mic, GrainBrick's
# configure_builtin_mic() runs amixer for three controls —
#   'ADCL Input MIC1 Boost'   (must stay ON: its own docstring says capture
#                              fails with an ALSA I/O error if boost is off)
#   'MIC1 gain volume'
#   'ADC volume' 160,160
# — and reports AMIXER FAILED when a call returns non-zero. Those controls
# belong to the Allwinner A133 analog codec; the VM has no codec at all (its
# "mic" is an aloop card, which exposes no mixer elements), so every one of
# those calls would fail and the mic path would die before arecord starts.
#
# This shim fakes ONLY the codec elements the app asks for, remembers values
# so a later read returns what was set, and forwards literally everything else
# — including the USB volume mixer GrainBrick drives for real USB output — to
# the real amixer, untouched. It also logs every invocation: the app is closed
# source, and the log documents the exact argv it uses without having to
# reverse it.
#
# Nothing in the app is modified; this replaces a system binary the app calls,
# the same way /opt/sdl2-x11 replaces the mali-only SDL video backend.
set -u
REAL=/usr/bin/amixer
LOG=/tmp/brick-amixer.log
STATE=/tmp/brick-amixer.state

# Log first: a shim that silently lies is undebuggable.
printf '%s' "$(date +%s) amixer" >> "$LOG"
for a in "$@"; do printf ' %q' "$a" >> "$LOG"; done
printf '\n' >> "$LOG"

# --- pull out the control name this call targets ---------------------------
# amixer's own argv is a free-for-all (sget/sset/cget/cset, -c N, -D hw:N,
# optional index, quoted names with spaces, values after). We only need to
# know whether the named element is one of the codec's.
ctl="" verb="" card=""
prev=""
for a in "$@"; do
    case "$prev" in -c|--card) card="$a";; esac
    case "$a" in
        sget|sset|cget|cset) verb=$a ;;
    esac
    prev="$a"
done
# The control is the first argument after the verb that is not a value.
args=("$@"); found=0; i=0
while [ $i -lt ${#args[@]} ]; do
    if [ "${args[$i]}" = "$verb" ]; then found=1; i=$((i+1))
        [ $i -lt ${#args[@]} ] && ctl="${args[$i]}"; break; fi
    i=$((i+1))
done
[ $found = 1 ] || ctl=""

is_codec() {
    case "$1" in
        "ADCL Input MIC1 Boost"|"ADCR Input MIC2 Boost"|\
        "MIC1 gain volume"|"MIC2 gain volume"|\
        "MIC1 Boost gain volume"|"ADC volume"|"ADCL volume"|"ADCR volume"|\
        "ADC Left Volume"|"ADC Right Volume"|"MIC1 Boost Gain"|"MIC1 Gain Volume")
            return 0 ;;
    esac
    return 1
}

# amixer-shaped answer for an emulated element. Values persist in $STATE.
emit() { # name value
    local name="$1" val="$2"
    echo "Simple mixer control '$name',0"
    echo "  Capabilities: pvolume pswitch penum"
    echo "  Playback channels: Front Left - Front Right"
    echo "  Limits: Playback 0 - 255"
    echo "  Mono:"
    echo "  Front Left: Playback $val [${val}%]"
    echo "  Front Right: Playback $val [${val}%]"
}

if [ -n "$ctl" ] && is_codec "$ctl"; then
    key="$card|$ctl"
    cur=$(awk -F'\t' -v k="$key" '$1==k{print $2}' "$STATE" 2>/dev/null | tail -1)
    [ -n "$cur" ] || cur="160"
    case "$verb" in
        sset|cset)
            # last non-flag argument(s) after the control name are the values
            vals=""
            j=$((i+1))
            while [ $j -lt ${#args[@]} ]; do
                case "${args[$j]}" in -*) ;; *) vals="${vals:+$vals,}${args[$j]}";; esac
                j=$((j+1))
            done
            [ -n "$vals" ] || vals="$cur"
            grep -v "^$key$(printf '\t')" "$STATE" 2>/dev/null > "$STATE.new" || true
            printf '%s\t%s\n' "$key" "${vals%%,*}" >> "$STATE.new" && mv "$STATE.new" "$STATE"
            emit "$ctl" "${vals%%,*}"
            ;;
        *) emit "$ctl" "$cur" ;;
    esac
    exit 0
fi

[ -x "$REAL" ] || { echo "amixer shim: no real amixer at $REAL" >&2; exit 1; }
exec "$REAL" "$@"
