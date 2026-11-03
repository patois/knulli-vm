# knulli-vm

Run **apps built for the TrimUI Brick / KNULLI Linux** (like
[GrainBrick](https://github.com/ETRNLIAM/GrainBrick)) directly on your Mac,
inside the *actual* KNULLI userspace taken from a real knulli device image.

KNULLI images are Allwinner/Rockchip device firmware and cannot boot under
Virtualization.framework. This project boots a stock Ubuntu 24.04 arm64 Lima
VM and **chroots the OS squashfs from the knulli image** instead — the app
then runs against knulli's own CPython 3.12, knulli's system pygame, knulli's
ALSA stack, and knulli's own `/usr/bin/pygame` launcher (the same one
EmulationStation execs for pygame ports on the device), installed under
`/userdata/roms/ports/` exactly like on hardware.

## What this is / isn't

- **Not included in git** (created at install time, `.gitignore`d): the knulli
  image, the extracted rootfs, SDL2 sources/builds, app archives, venvs. The
  repo contains only the tooling.
- One deliberate substitution: knulli's SDL2 has a single video driver,
  `mali` (the device's GPU blob; the image ships no X11/kmsdrm/framebuffer).
  The installer builds stock **SDL2 2.32.x with X11** and shadows only that
  soname via `LD_LIBRARY_PATH` (`/opt/sdl2-x11`). Knulli keeps its own glibc,
  libasound, SDL2_ttf/image/mixer — and the built SDL satisfies the ≥2.32.8
  floor knulli's pygame enforces ("SDL downgrade" check).
- The app itself is never modified; run as distributed.

## Requirements — what to get and where from

| piece | where |
|---|---|
| Apple Silicon Mac + Homebrew | <https://brew.sh> (`brew install lima`) |
| Lima (VM host) | <https://github.com/lima-vm/lima> |
| Xcode Command Line Tools | `xcode-select --install` (needed only for `swiftc` → the host audio player; everything else installs without it, you just get no sound) |
| KNULLI image | **fetched automatically** by `install.sh` from the latest release of <https://github.com/knulli-cfw/distribution> (project site: <https://knulli.org>); manual download / other devices: pick the `.img.gz` asset whose prefix matches your device — e.g. `knulli-a133-trimui-brick-*.img.gz` for the original TrimUI Brick — and pass `--image` / `--image-device`. The device list lives on the releases page: <https://github.com/knulli-cfw/distribution/releases> |
| TrimUI Brick hardware info / official firmware | <https://www.trimui.com> (KNULLI is the community replacement; the StockOS is TrimUI's own) |
| Apps, e.g. GrainBrick | the app's own releases page — GrainBrick: <https://github.com/ETRNLIAM/GrainBrick/releases> (grab the release ZIP, not GitHub's "Source code" archives); then `./knulli-vm app add <zip-or-url>` |

Nothing else needs downloading by hand: the Ubuntu arm64 VM image is pulled by
Lima, and the SDL2 source by the installer.

## Install

```sh
./install.sh                    # downloads the latest knulli image for the
                                # TrimUI Brick (knulli-cfw/distribution)
./install.sh --image ./knulli-a133-trimui-brick-...img      # local image file
./install.sh --image-url https://.../knulli-....img.gz      # specific build
./install.sh --image-device knulli-h700-rg-cubexx           # other devices
./install.sh --app ~/Downloads/GrainBrick_beta_1.0_TrimUI_Brick_KNULLI.zip
./install.sh --vm-name studio --vnc-port 5902    # a second install on this Mac
```

The installer: creates the Lima VM (`vm/knulli.yaml`) → deploys guest scripts
→ fetches/verifies (sha256) the image → extracts the OS squashfs
(`lib/guest/extract_knulli.sh`; the GPT first-LBA sits at partition-entry
offset **32**, a classic parsing trap) → builds the SDL2 x11 compat library
→ sets up guest→Mac audio routing → builds the host audio player → installs
any `--app` you pass. Re-running it is safe: slow steps (VM, extraction,
SDL build) detect existing state and skip.

**Two installs on one Mac.** Lima forwards a VM's VNC port to the *same* port
on the Mac, so only one install can own 5901 — and a second install's forward
silently never binds, which means its `vnc://localhost:5901` shows the *first*
VM's screen. `install.sh` therefore checks the port before claiming it: if
something else already serves it (another knulli-vm install, Screen Sharing),
it takes the next free port and says so. Pass `--vnc-port` to pick one;
`knulli-vm vnc` and `knulli-vm status` always report the port that install
actually owns, and `vnc` refuses to hand out a URL served by a different VM.

## Using it

```sh
./knulli-vm start              # start services + default app (e.g. GrainBrick)
./knulli-vm vnc                # print this install's VNC URL + password
open vnc://localhost:5901      # ...or type it: macOS Screen Sharing, pass 'knulli'
./knulli-vm status             # VM / services / app / apps (+ which port)
./knulli-vm screenshot         # grab the display to a PNG
./knulli-vm stop               # stop the app (VM keeps running)
./knulli-vm down               # shut the VM down too (stops app + audio first)
./knulli-vm down --force       # ...hard kill, for a wedged guest that ignores
                               #    graceful shutdown
./knulli-vm up                 # bring a stopped VM back (waits for ssh, not
                               #    just the hypervisor, before reporting up)
```

`stop` vs `down`: `stop` kills the app tree and audio pipe inside the VM;
`down` does that first, then shuts the VM itself off (frees its RAM/CPU;
everything on disk is kept). Re-run `./install.sh` any time to heal a VM
after updates — it re-deploys guest scripts and re-verifies the SDL2 x11
closure.

**Apps** (install time or later; zip, directory, or URL):

```sh
./knulli-vm app add <zip|dir|url> [--name N] [--cmd C] [--default]
./knulli-vm app list            # knulli-vm app default NAME | app rm NAME
./knulli-vm start someapp
```

The zip is installed **as the device would install it**: a single top-level
directory inside the zip wins as the app root even with a loose `*.sh` next to
it (that `.sh` is KNULLI's launcher stub, not the app), the vendor's own
spelling is kept verbatim — `ports/grainbrick beta 1.0.1/` plus its sibling
`ports/GrainBrick beta 1.0.1.sh`, spaces and all — and when a stub is present
it is what gets run (`cd ports && sh './GrainBrick beta 1.0.1.sh'`), because
the stub hardcodes its app dir (`APP='/userdata/roms/ports/grainbrick beta
1.0.1'`) and does the first-run setup: creating and seeding `samples/`,
`projects/` and `recordings/` from `demo-samples/`/`demo-projects/`.
Sanitizing the directory name to something shell-friendly used to break that
lookup, so the stub was skipped and a fresh install showed an **empty sample
browser** the device would never show. Names with spaces are carried
base64-encoded to the guest instead of being mangled.

Only when a zip ships no stub does knulli-vm guess an entry point inside the
app dir (`gb_launch.py` → `main.py` → `run.sh` → a lone `*.sh`; override with
`--cmd`).
Re-adding an app name upgrades it in place while preserving the user's
`samples/`, `recordings/`, `projects/` and `*.json` settings inside the app
dir — same contract the app's own README promises for device upgrades.

**Input.** The VM has an emulated `retrogame_joypad` — a uinput replica of
knulli's `rocknix-joypad` kernel driver **on the TrimUI Brick specifically**:
same device name GrainBrick checks for, and the exact evdev code set the real
driver registers (four 0x120-block codes first, then the face buttons
*positionally* — printed B=BTN_SOUTH, A=BTN_EAST, X=BTN_NORTH, Y=BTN_WEST —
L1–R2, SELECT/START/MODE, and the two stick-click codes 0x13D/0x13E
repurposed as the Brick's TAB-/TAB+ keys, i.e. F1/F2; BTN_C/BTN_Z are *not*
registered). SDL numbers joystick buttons by ascending code, so matching the
set exactly is what makes the app's default mapping (B=4 A=5 Y=6 X=7 L1=8
R1=9 L2=10 R2=11 SELECT=12 START=13 TAB-=15 TAB+=16) land on the right
buttons. At the SDL layer it's indistinguishable from the onboard pad:

```sh
./knulli-vm input "hat down 150"        # tap; holdhat down / holdhat none for held
./knulli-vm input "press Y"             # names: A B X Y L1 R1 L2 R2 SELECT
                                        # START MODE TAB- TAB+ (F1/F2 and
                                        # SOUTH/EAST/NORTH/WEST/TL/TR/... alias)
./knulli-vm bridge                      # physical USB/BT pad plugged into the Mac
```

`bridge` reads the pad with pygame-ce/SDL2 on the Mac and streams held
button/dpad states into the VM over one ssh pipe — the app's own repeat
profiles then behave natively. (USB *passthrough* isn't possible: Lima/vz
exposes no USB, and Virtualization.framework's gamepad support is nil. The
bridge deliberately runs SDL's default *cocoa* video driver: the dummy
driver never pumps the Cocoa runloop that delivers pad-connect callbacks, so
an already-plugged pad stayed invisible until replug.) Button indices come
from a measured sweep of the real pad, not the assumed "standard" order —
see **Remapping inputs**.

**Keyboard.** While the VNC window has Mac keyboard focus, the keys are
mapped to the pad too (`lib/guest/keymapd.py` taps X11 globally without
grabbing, so the app still sees raw keys if it wants them). The map mirrors
the Brick's own panel — dpad on the left, SNES-lettered face cluster on the
right (X top, A right, B bottom, Y left), triggers under L1/R1:

| keys | Brick button | keys | Brick button |
|---|---|---|---|
| W A S D / arrows | dpad (diagonals combine) | Q / E | L1 / R1 (shoulders) |
| K | B (bottom) | Z / C | L2 / R2 (rear) |
| J | A (right) | BackSpace | SELECT |
| U or X | X (top) | Enter, space | START |
| I | Y (left) | m | MENU (logo) |
| F1 / F2 | TAB-/TAB+ (the Brick's F1/F2) | | |

The Brick has no analog sticks, so there is no L3/R3; FN is a gpio-keys OS
hotkey modifier, not a joystick event, so it has no mapping (F1/F2 *are*
joystick TAB-/TAB+ on the real device and are mapped as such, while also
reaching the app as raw keys through the same passive tap).

Fast taps are stretched to a minimum hold — **120 ms for buttons, 220 ms for
dpad steps** (measured against GrainBrick: its buttons are event-driven and
catch 80 ms taps, but it debounces hat steps under ~200 ms) — and keyboard
auto-repeat is absorbed as a single held key.

**Audio.** The guest has no sound device, so the chroot's ALSA `default` is
routed into a `snd-aloop` loopback card (`lib/guest/setup_audio.sh`) and
`knulli-vm audio start` (run automatically by `start`) captures the far end
over ssh into `bin/audioplay`, a tiny CoreAudio sink on the Mac. Three details
that look wrong but are right: the aloop cables are *cross-wired* (default
writes device 0 playback → host reads device 1 capture); `snd-dummy` occupies
card 0 on purpose because apps like GrainBrick open the mic as a hardcoded
`hw:1,0` — card 1 must be the loopback card; and the capture *subdevice* is
discovered at run time by `lib/guest/audio_capture.sh`, never hardcoded —
snd-aloop hands out one substream per opened stream (cable N = playback subN
→ capture subN), and GrainBrick opens several (its UI/SDL preview stream,
plus the `aplay` its audio pump spawns — or, in 1.0.1+, no `aplay` at all
because the app writes ALSA itself). So the script does not ask *who owns* a
stream, it asks **which cable carries motion**: the playback sub whose
`hw_ptr` actually advances is the one to capture, with the `aplay`-owned sub
winning when one exists and a short grace period first so the preview stream
can't win the race. Hardcoding sub0 once meant hours of "the app outputs pure
silence" while an orphaned app instance held sub0 in XRUN and real audio
flowed on sub3, unseen; an `aplay`-only search does the same thing to an app
that owns its stream (it finds nothing, gives up, and the app then sits
underrunning — which also costs input responsiveness). Latency is tuned for
playability: `arecord -B 100000 -F 25000` (100 ms buffer / 25 ms periods) and
25 ms CoreAudio chunks in `audioplay`, end-to-end ≈ 80–100 ms behind the VM.
(The 100 ms buffer is also what keeps an app that owns its own ALSA stream —
no `aplay` child — from underrunning while you read the cable.)

## Remapping inputs

Both input paths feed one vocabulary — the `retrogame_joypad` FIFO's button
names (`A B X Y L1 R1 L2 R2 SELECT START MODE TAB- TAB+`) and hat directions
(`up down left right`, diagonals spelled `upleft` etc.) — so remapping is
always "edit one small dict, restart its mapper".

**Keyboard (VNC window)** — the map lives in `lib/guest/keymapd.py`,
dict `KEYMAP`: keysym → `("btn", NAME)` or `("hat", DIR)` (default table
above, mirroring the Brick panel; two keys can share a button, like
`u`/`x` → X). Apply edits with:

```sh
./knulli-vm sync && ./knulli-vm keymap restart   # redeploy guest scripts, restart mapper
./knulli-vm keymap log                           # logs every mapped key press it sees
```

If the app misses quick taps, raise `BTN_HOLD`/`HAT_HOLD` in the same file
(the 120/220 ms floors are measured against GrainBrick: its buttons are
event-driven and catch 80 ms taps, but it debounces hat steps under
~200 ms). A held key machine-gunning instead of repeating means the floors
are *too short* against your VNC's auto-repeat.

**Physical pad (`knulli-vm bridge`)** — the map lives in
`lib/host/pad_bridge.py`, dicts `BUTTON_MAP` (pygame button index → name)
and `DPAD_BUTTONS` (index → direction; dpad arrives as buttons on some
pads). The shipped values were measured on a specific pad and are correct
for Xbox-order pads only by coincidence — **never copy an assumed standard
order, sweep your own pad once:**

```sh
./padenv/bin/python -I - <<'PY'   # press every button/stick once; prints changes
import os, time; os.environ["PYGAME_HIDE_SUPPORT_PROMPT"] = "1"
import pygame; pygame.display.init(); pygame.joystick.init()
while pygame.joystick.get_count() == 0: pygame.event.pump(); time.sleep(0.1)
j = pygame.joystick.Joystick(0)
pb, pa = [0]*j.get_numbuttons(), [0.0]*j.get_numaxes()
print(f"{j.get_name()!r}: {j.get_numbuttons()} btn {j.get_numaxes()} ax {j.get_numhats()} hat", flush=True)
while True:
    pygame.event.pump()
    for b in range(j.get_numbuttons()):
        v = j.get_button(b)
        if v != pb[b]: print(f"BUTTON {b} {'down' if v else 'up'}", flush=True); pb[b] = v
    for a in range(j.get_numaxes()):
        v = j.get_axis(a)
        if (v > 0.4) != (pa[a] > 0.4) or (v < -0.4) != (pa[a] < -0.4):
            print(f"AXIS {a} {v:+.2f}", flush=True); pa[a] = v
    time.sleep(0.02)
PY
```

Press dpad directions (including diagonals), every button, both sticks.
Two tells beat guessing when reading the log: an analog trigger moves its
axis *together with* its digital button (that is how L2/R2 were pinned on
this pad — buttons 13/16 dragged axes 2/5), and dpad diagonals fire as
*pairs* of buttons, which proves the four dpad indices even when the
direction labels are in question. Pads spoofing Microsoft's `045E:028E`
are the cautionary case: they may enumerate 17 buttons / 6 axes / 0 hats
in their own raw order, dpad-as-buttons included. Edit the dicts, then
just rerun `./knulli-vm bridge` — it runs on the Mac, no `sync` needed.
Pads with no dpad at all fall back to left-stick axes 0/1 automatically.

## Layout

```
install.sh              one-shot installer (image/VM/rootfs/SDL/audio/apps)
knulli-vm               day-to-day CLI (start/stop/app/input/bridge/audio/...)
vm/knulli.yaml          Lima template (Ubuntu 24.04 arm64, vz)
lib/guest/              deployed into guest ~/knulli-vm: chroot entry, virtual
                        joypad, keymapd (keyboard->pad), focusd, launcher,
                        audio routing, knulli-image extractor, SDL2 x11 builder
lib/host/pad_bridge.py  macOS gamepad bridge
lib/host/audioplay.swift CoreAudio sink for guest audio (built to bin/)
state/                  per-VM config + app registry (gitignored, holds VNC pass)
downloads/              images, SDL tarballs, app zips (gitignored)
bin/                    built host binaries (gitignored)
```

## Troubleshooting

- **`mountpoint`/`df` hang in the guest (100% sys spin)** — stacked duplicate
  bind-mounts. The `mountpoint -q` guards in `knulli-chroot.sh` are
  load-bearing; never remove them. Recovery: `sudo umount -l <path>` in a loop
  by explicit path.
- **"Dynamic linking causes SDL downgrade"** — `/opt/sdl2-x11` must hold
  SDL ≥ 2.32.8; re-run `lib/guest/build_sdl2_x11.sh`.
- **App stops reacting after restarting the joypad** — recreating the uinput
  device requires restarting the app (SDL delivers events only for opened
  joysticks): `knulli-vm stop && knulli-vm start`.
- **App silent, or dies/ignores input a few seconds in** — its ALSA stream
  underruns because nothing is draining the loopback card. `knulli-vm start`
  starts the audio pipe *before* the app for exactly this reason; if you
  killed the pipe mid-session, `knulli-vm audio start` (or restart the app).
- **"App outputs pure silence" but its own meters animate** — suspect the
  *capture*, not the app. Ground truth is in the guest:
  `sudo cat /proc/asound/card1/pcm0p/sub*/status` — the cable that matters is
  the sub whose `hw_ptr` **advances in real time** (`state: RUNNING` alone
  lies), and the same sub under `pcm1c/` is what to capture. `pgrep -a -x
  aplay` tells you which flavour you're running: GrainBrick ≤ 1.0 pumps
  through a child `aplay` (its sub *is* the main output), 1.0.1+ writes ALSA
  itself and spawns none. A second `gb_launch` process means an orphaned app
  instance (old builds of `stop` left them; they respawn their aplay when
  killed) — `knulli-vm stop` now kills the whole tree, clean leftovers with
  `sudo pkill -f 'gb_launch[.]py'` plus `sudo pkill -x aplay`. A sub in
  `state: XRUN` produces exactly the pure zeros that get mistaken for a
  silent app.
- **Clock healthy, bytes all zero — the app's render loop never engaged** —
  there is a third failure mode besides "wrong cable" and "underrun": the
  stream is real, the clock is real-time, and the app is writing *silence*.
  Measure it rather than argue with it: stop the Mac pipe (`knulli-vm audio
  stop`), capture the cable to a file yourself (`sudo arecord -D
  hw:Loopback,1,<sub> -f S16_LE -r 48000 -c 2 -t raw -q` for a few seconds),
  and compute RMS/peak/`nonzero%`; then prove the *path* with a tone you know
  is loud (`aplay -D default /tmp/sine.wav` in the chroot — a healthy path
  reads back a nonzero RMS and a nonzero-sample share, so the VM is then
  exonerated). With GrainBrick 1.0.1 in this state the app's own meters said
  GRAIN STATE ON / ACTIVE GRAINS 2 / DSP 1%, its audio subprocess fed the
  pump at exactly 192 kB/s (= 48 kHz stereo 16-bit) while burning ~3% of a
  core, and both of its cables read `RMS 0.0 peak 0 nonzero 0.00%` — a
  real-time stream of zeros, with the UI still fully responsive. That is the
  app's audio process, not the VM; take those numbers (plus the app's own
  `audio_process.log`, which ends at `AUDIO OUTPUT STARTED: default`) to the
  app's author. Same signature as a device that plays one note, then hangs at
  100% CPU while the UI keeps answering.
- **VNC shows the *other* VM's screen** — two installs cannot both own 5901
  (Lima forwards the guest port to the same port on the Mac, and the second
  forward never binds). `install.sh` picks a free port for later installs and
  prints it; `knulli-vm vnc` refuses to advertise a port another VM serves.
  Fix a stuck install with `./install.sh --vm-name <name> --vnc-port <free>`.
- **`arecord` says "Device or resource busy"** — an orphaned capture from a
  previous session holds the loopback: `knulli-vm audio stop` then `start`.
- **VNC keyboard/mouse laggy by seconds** — this was x11vnc starving its own
  client input queue while diffing the framebuffer (Recv-Q grew unboundedly
  under animation). Fixed by serving the display with TigerVNC `Xvnc`
  (X server + VNC in one) instead of Xvfb+x11vnc; `run_app.sh` prefers it
  automatically. If you're on the Xvfb fallback (no `Xvnc` binary), input
  lag is expected.
- **Keyboard does nothing on the VNC display** — `./knulli-vm keymap restart`
  first: that's the mapper (`keymapd.py`) being down or deaf, and it's a
  one-second fix; `./knulli-vm keymap log` then shows every mapped key it
  receives (if the log scrolls while you type but the app doesn't react,
  the problem is the joypad/app side, not the keyboard). Still nothing?
  No window manager exists, so `focusd.sh` (started by the launcher) keeps
  focus on the app window; check `pgrep -f focusd` and
  `~/knulli-vm-logs/focusd.log` in the guest. (keymapd is now self-healing — it never blocks its X event
  thread on the joypad FIFO and reconnects if the X connection dies — but
  an old-style deaf instance from before that fix needs one restart.)
- **VNC shows an auth error before the password prompt** — modern macOS
  Screen Sharing refuses auth-less servers; the launcher starts `Xvnc` with
  `-SecurityTypes VncAuth -PasswordFile` (x11vnc fallback: `-passwd`).
- **`pkill -f <pattern>` from a shell whose cmdline contains the pattern kills
  your own ssh session** — use `pattern[.]ext`.
- **Copies from host paths land double-nested (`dst/name/name/`)** — on
  Lima's virtiofs mount `cp -a path/ dest/` (trailing slash) copies the
  directory *itself*, not its contents; use the `path/.` form. This bit the
  app installer repeatedly before it was diagnosed.
- `limactl start` may stall on lima's optional containerd step; the VM is
  usable regardless — `limactl shell <vm>`.

## Status / known limits

- Video: TigerVNC `Xvnc` serves 1280×720 directly on the install's VNC port
  (5901, or the next free one — `knulli-vm status` says which; Xvfb+x11vnc
  only as fallback). Audio out: the VM path works — loopback → Mac speakers,
  48 kHz stereo, verified end to end by playing a tone through the chroot's
  `default` and measuring it back on the Mac. Which aloop sub carries the
  app's main output is discovered per run (see **Audio**), so nothing here
  assumes the app pumps through `aplay`. If a *specific app version* renders
  silence, that's the app; the troubleshooting bullet above shows how to tell
  the two apart in five commands. Mic in: apps open `hw:1,0` and get a
  *silent* loopback capture — there is no host-mic→guest pipe yet (would be
  the mirror of the playback path; `snd-aloop`'s free cross-cable is already
  there for it).
- Apps run as root in the chroot (knulli's own model); the VM is the sandbox —
  treat downloaded images/apps as untrusted accordingly.
