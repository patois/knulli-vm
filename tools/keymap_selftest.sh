#!/bin/bash
# Keyboard self-test: prove every mapped key in keymapd.py reaches the app.
# Keys are injected with xdotool (XTEST) into the VM display — the exact
# path a VNC client's keyboard takes — and each press must produce a
# VISIBLE reaction (screenshot byte-diff) plus a line in keymap.log.
#
#   ./tools/keymap_selftest.sh [out-dir]     # default: keymap-out/
#
# Requirements: app running, keymapd up (knulli-vm keymap status), and a
# QUIET machine — a human on the VNC window or a parallel agent corrupts
# every diff (their keys arrive through the same mapper).
#
# The keys below are the shipped KEYMAP table (WASD/arrows=dpad,
# j=A k=B u/x=X i=Y, q/e=shoulders, z/c=rear, Bksp=Select, Enter/space=
# Start, m=Menu, F1/F2=tabs). NO-CHANGE means either the key is unmapped
# (keymap.log stays silent) or the app has no action for that button on
# the current screen (keymap.log shows it) — read the log line count to
# tell the two apart. See tools/input_selftest.sh's header for the
# transport/ORBIX traps that also apply here.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
KV="$HERE/knulli-vm"
VM="${KNV_VM:-$(cat "$HERE/state/default" 2>/dev/null || echo knulli-vm)}"
OUT="${1:-$HERE/keymap-out}"; mkdir -p "$OUT"
gexec() { limactl shell "$VM" -- bash -lc "$1"; }
n=0; fails=0

shot() { n=$((n+1)); "$KV" screenshot "$OUT/$(printf '%03d' "$n").png" >/dev/null 2>&1; }
last() { printf '%s/%03d.png' "$OUT" "$n"; }
loglines() { gexec 'cat ~/knulli-vm-logs/keymap.log /tmp/keymap.log 2>/dev/null | wc -l'; }

settle() {  # stop playback if the screen animates (START toggles transport)
    shot; local a; a=$(last); sleep 1.2; shot
    if ! cmp -s "$a" "$(last)"; then
        echo "  (animating — pressing START to stop the transport)"
        "$KV" input "hold START" >/dev/null; sleep 0.15
        "$KV" input "release START" >/dev/null; sleep 1
    fi
}

key() {  # KEYSYM  LABEL
    local ks="$1" label="${2:-$1}"
    local pre; pre=$(loglines)
    shot; local a; a=$(last)
    gexec "xdotool key --display :1 --clearmodifiers '$ks'" >/dev/null 2>&1
    sleep 0.45
    shot; local b; b=$(last)
    local post; post=$(loglines)
    if [ "$post" = "$pre" ]; then
        echo "UNMAPPED    $label ($ks)  — keymapd saw nothing"; fails=$((fails+1))
    elif cmp -s "$a" "$b"; then
        echo "mapped-only $label ($ks)  — keymapd mapped it, app showed no change (see $b)"
    else
        echo "ok          $label ($ks)  ($a -> $b)"
    fi
}

echo "== single-instance guard"
dup=$(gexec 'pgrep -f "gb_launch[.]py" | wc -l')
[ "$dup" -gt 1 ] && echo "WARNING: $dup app instances running — clean up first (knulli-vm stop, sweep orphans), diffs are meaningless otherwise"

echo "== baseline"
settle
echo "== dpad keys"
key w "up"; key s "down"; key a "left"; key d "right"
key Up Up; key Down Down; key Left Left; key Right Right
echo "== face cluster"
key j A; key k B; key u X; key i Y; key x "X (second binding)"
echo "== shoulders/triggers"
key q L1; key e R1; key z L2; key c R2
echo "== small"
key BackSpace Select; key Return Start; key space "Start (second binding)"; key m Menu
echo "== tabs"
key F1 "TAB-"; key F2 "TAB+"
echo "== diagonal (held combo: w+d = upright)"
pre=$(loglines); shot; a=$(last)
gexec "xdotool keydown --display :1 w; xdotool key --display :1 d; sleep 0.3; xdotool keyup --display :1 w" >/dev/null 2>&1
sleep 0.45; shot
[ "$(loglines)" = "$pre" ] && echo "UNMAPPED   upright combo" || { cmp -s "$a" "$(last)" && echo "mapped-only upright combo" || echo "ok          upright combo"; }

echo
echo "$fails UNMAPPED probes (of $n shots). mapped-only is usually the app"
echo "having no action for that button on the current screen — cross-check"
echo "against tools/input_selftest.sh, which drives the same buttons via FIFO."
