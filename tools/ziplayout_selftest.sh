#!/bin/bash
# Zip-layout self-test: prove knulli-vm picks the right app root + vendor
# stub out of an unpacked vendor zip — without needing a VM.
#
#   ./tools/ziplayout_selftest.sh
#
# Vendor stubs hardcode their app dir (/userdata/roms/ports/<name>), so a
# mis-detected layout installs the payload under the wrong path and the stub
# reports the app as "not installed" — the exact failure GrainBrick BETA 2.0
# hit when its zip added a README next to the stub+app dir (case 2 below).
# Cases 1 and 2 mirror the real GrainBrick 1.0.1 and BETA 2.0 zips; the rest
# pin the flat-zip cases that must NOT be torn apart.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/host/zip_layout.sh"

pass=0 fail=0
check() { # name  unpacked_dir  expect_root_rel  expect_stub_rel
    local name="$1" u="$2" want_root="$3" want_stub="$4"
    zip_layout "$u"
    local got_root="${ZIP_ROOT#"$u"/}" got_stub="${ZIP_STUB#"$u"/}"
    [ "$ZIP_ROOT" = "$u" ] && got_root="."
    [ -z "$ZIP_STUB" ] && got_stub=""
    local root_ok="root=$got_root" stub_ok="stub=$got_stub" ok=1
    [ "$got_root" = "$want_root" ] || { root_ok="root=$got_root (want $want_root)"; ok=0; }
    [ "$got_stub" = "$want_stub" ] || { stub_ok="stub=$got_stub (want $want_stub)"; ok=0; }
    if [ "$ok" = 1 ]; then
        pass=$((pass + 1)); echo "PASS  $name"
    else
        fail=$((fail + 1)); echo "FAIL  $name: $root_ok, $stub_ok"
    fi
}

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# 1. GrainBrick 1.0.1's layout: stub + app dir, nothing else at top level.
u="$T/one"; mkdir -p "$u/grainbrick beta 1.0.1"
touch "$u/GrainBrick beta 1.0.1.sh" "$u/grainbrick beta 1.0.1/gb_launch.py"
check "stub + app dir (beta 1.0.1 layout)" "$u" \
    "grainbrick beta 1.0.1" "GrainBrick beta 1.0.1.sh"

# 2. GrainBrick BETA 2.0's layout: same pairing plus a README — the docs file
#    must not collapse the whole zip into one app dir.
u="$T/two"; mkdir -p "$u/grainbrick-beta2"
touch "$u/GrainBrick BETA 2.0.sh" "$u/README_GRAINBRICK_BETA_2_0.txt" "$u/grainbrick-beta2/main.py"
check "stub + app dir + README (beta 2.0 layout)" "$u" \
    "grainbrick-beta2" "GrainBrick BETA 2.0.sh"

# 3. Flat app zip: entry points live at top level; the lone dir is just data.
#    Must install as ONE dir, not be torn apart around assets/.
u="$T/three"; mkdir -p "$u/assets"
touch "$u/main.py" "$u/run.sh" "$u/assets/data.bin"
check "flat app zip stays one dir" "$u" "." ""

# 4. Bare app dir, no stub anywhere.
u="$T/four"; mkdir -p "$u/app"
touch "$u/app/main.py"
check "bare app dir" "$u" "app" ""

# 5. App dir + docs but NO stub: nothing pairs the stub to the dir, so the
#    old behavior stands — root is the unpack dir (app add then asks for
#    --cmd/--name rather than guessing across the vendor's layout).
u="$T/five"; mkdir -p "$u/app"
touch "$u/README.md" "$u/app/main.py"
check "app dir + docs, no stub" "$u" "." ""

# 6. Stub + docs + a dir that holds no entry point: not a vendor pairing.
u="$T/six"; mkdir -p "$u/assets"
touch "$u/launcher.sh" "$u/notes.txt" "$u/assets/pic.png"
check "stub beside a non-app dir" "$u" "." ""

# Optional: the real vendor zip when it is on disk (downloads/ is gitignored).
real="$HERE/../downloads/grainbrick.beta.1.0.1.zip"
if [ -f "$real" ]; then
    u="$T/real"; mkdir -p "$u"
    unzip -q "$real" -d "$u"
    check "real grainbrick.beta.1.0.1.zip" "$u" \
        "grainbrick beta 1.0.1" "GrainBrick beta 1.0.1.sh"
fi

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
