#!/bin/bash
# zip_layout — where does the app live inside an unpacked vendor zip?
# Sets ZIP_ROOT (the app directory to install) and ZIP_STUB (the vendor's
# launcher stub that belongs NEXT TO it in ports/; "" when the zip ships no
# such pairing and knulli-vm must detect an entry point inside the root).
#
# Why the pairing matters: vendor launcher stubs hardcode their app dir
# (APPDIR="/userdata/roms/ports/grainbrick-beta2" in GrainBrick BETA 2.0's,
# APP='/userdata/roms/ports/grainbrick beta 1.0.1' in 1.0.1's). Installing
# the zip's sibling layout VERBATIM — stub beside app dir, vendor's own
# directory name — is the difference between "running" and the stub's
# "not installed" error. See INTERNALS.md, "App dir names are the vendor's".
#
# Sourced by knulli-vm; exercised without a VM by tools/ziplayout_selftest.sh.

app_entry() {  # print the entry point inside an app dir, "" if none
    local f
    for f in gb_launch.py main.py run.sh; do
        [ -f "$1/$f" ] && { printf '%s\n' "$f"; return 0; }
    done
    return 1
}

zip_layout() {  # $1 = unpacked zip dir
    ZIP_ROOT="$1"; ZIP_STUB=""
    local ndirs nrest nstub dir
    ndirs=$(find "$1" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
    [ "$ndirs" = 1 ] || return 0
    dir=$(find "$1" -mindepth 1 -maxdepth 1 -type d)
    nrest=$(find "$1" -mindepth 1 -maxdepth 1 -type f ! -name '*.sh' | wc -l | tr -d ' ')
    nstub=$(find "$1" -mindepth 1 -maxdepth 1 -type f -name '*.sh' | wc -l | tr -d ' ')
    # The lone top-level dir is the app when either every other top-level file
    # is a launcher stub (GrainBrick 1.0.1's zip), or a stub sits beside it
    # together with plain docs (BETA 2.0's zip adds README_GRAINBRICK_BETA_2_0.txt
    # on the side, and the old "no non-.sh files at all" rule then collapsed
    # the whole zip into one app dir, hiding the payload from the stub's
    # hardcoded path). The docs branch requires the dir to actually hold an
    # entry point, so a flat app zip (main.py + run.sh + assets/) is never
    # torn apart around its data dir.
    if [ "$nrest" = 0 ] || { [ "$nstub" -ge 1 ] && app_entry "$dir" >/dev/null; }; then
        ZIP_ROOT="$dir"
        ZIP_STUB=$(find "$1" -mindepth 1 -maxdepth 1 -type f -name '*.sh' | head -1)
    fi
}
