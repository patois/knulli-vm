#!/bin/bash
# Input self-test: drive the running app through the virtual joypad FIFO
# and prove every button produces a VISIBLE reaction. Screenshots are
# byte-compared (cmp) — viable because a settled GrainBrick screen is
# static (verified: two shots 1.2 s apart are identical).
#
#   ./tools/input_selftest.sh [out-dir]      # default: selftest-out/
#
# Each probe: shot -> input -> settle -> shot -> diff. NO-CHANGE lines
# are suspicious, not automatically failures (some buttons legitimately
# do nothing on some screens) — read the surrounding shots.
#
# Two GrainBrick traps this harness has to survive, both learned the hard
# way:
#  * PLAYBACK MAKES DIFFS MEANINGLESS. Once the transport runs (▶ flips
#    to ⏸, HITS counts up), the screen redraws constantly and every
#    later cmp says "changed" — including for buttons that did nothing.
#    START toggles the transport, so settle() stops it and re-checks.
#  * THE ORBIX SUB-SCREEN IS ITS OWN CONTEXT. On the ORBIX KEY page,
#    TAB-/TAB+ do not switch tabs and Y/L2/R2/MODE are inert by design;
#    buttons there move knobs instead. A NO-CHANGE on that page is not
#    evidence of an unbound button — re-probe on a main tab first.
# If a real person is using the VNC window, their keys arrive through
# keymapd and corrupt every diff: pause the sweep until they let go.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
KV="$HERE/knulli-vm"
OUT="${1:-$HERE/selftest-out}"; mkdir -p "$OUT"
n=0; fails=0

shot() { n=$((n+1)); "$KV" screenshot "$OUT/$(printf '%03d' "$n").png" >/dev/null 2>&1; }
last() { printf '%s/%03d.png' "$OUT" "$n"; }

settle() {  # stop transport if the screen animates; warn if it still does
    shot; local a; a=$(last); sleep 1.2; shot
    if ! cmp -s "$a" "$(last)"; then
        echo "  (animating — pressing START to stop the transport)"
        "$KV" input "hold START" >/dev/null; sleep 0.15
        "$KV" input "release START" >/dev/null; sleep 1
        shot; a=$(last); sleep 1.2; shot
        cmp -s "$a" "$(last)" || \
            echo "  WARNING: still animating — later diffs are not trustworthy"
    fi
}

probe() {  # LABEL  hold-cmd  release-cmd [ms-between]
    local label="$1" pre="$2" post="$3" gap="${4:-150}"
    shot; local a; a=$(last)
    "$KV" input "$pre" >/dev/null
    sleep "$(awk -v g="$gap" 'BEGIN{print g/1000}')"
    [ -n "$post" ] && "$KV" input "$post" >/dev/null
    sleep 0.35
    shot; local b; b=$(last)
    if cmp -s "$a" "$b"; then
        echo "NO-CHANGE  $label  (see $a)"; fails=$((fails + 1))
    else
        echo "changed    $label  ($a -> $b)"
    fi
}

btn()  { probe "$1" "hold $1" "release $1"; }
hat()  { probe "hat $1" "holdhat $1" "holdhat none" 200; }

echo "== baseline"
settle
echo "== dpad (hat): expect cursor/value movement"
hat up; hat down; hat left; hat right
echo "== face buttons"
settle; btn A; btn B; btn X; btn Y
echo "== shoulders"
settle; btn L1; btn R1; btn L2; btn R2
echo "== small buttons"
settle; btn SELECT; btn START; btn MODE
echo "== tabs"
settle; btn TAB-; btn TAB+

echo
echo "$fails NO-CHANGE probes (of $n shots) — cross-check each against the"
echo "screenshots; on the ORBIX sub-screen NO-CHANGE is expected for some."
