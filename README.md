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

## Requirements

- Apple Silicon Mac, `brew install lima`, `python3`, `curl`.
- Xcode Command Line Tools (`xcrun swiftc`) for the small host audio player;
  everything still installs without it, you just get no sound.

## Install

```sh
./install.sh                    # downloads the latest knulli image for the
                                # TrimUI Brick (knulli-cfw/distribution)
./install.sh --image ./knulli-a133-trimui-brick-...img      # local image file
./install.sh --image-url https://.../knulli-....img.gz      # specific build
./install.sh --image-device knulli-h700-rg-cubexx           # other devices
./install.sh --app ~/Downloads/GrainBrick_beta_1.0_TrimUI_Brick_KNULLI.zip
```

The installer: creates the Lima VM (`vm/knulli.yaml`) → deploys guest scripts
→ fetches/verifies (sha256) the image → extracts the OS squashfs
(`lib/guest/extract_knulli.sh`; the GPT first-LBA sits at partition-entry
offset **32**, a classic parsing trap) → builds the SDL2 x11 compat library
→ sets up guest→Mac audio routing → builds the host audio player → installs
any `--app` you pass. Re-running it is safe: slow steps (VM, extraction,
SDL build) detect existing state and skip.

## Using it

```sh
./knulli-vm start              # start services + default app (e.g. GrainBrick)
open vnc://localhost:5901      # macOS Screen Sharing; password 'knulli'
./knulli-vm status             # VM / services / app / apps
./knulli-vm screenshot         # grab the display to a PNG
./knulli-vm stop
```

**Apps** (install time or later; zip, directory, or URL):

```sh
./knulli-vm app add <zip|dir|url> [--name N] [--cmd C] [--default]
./knulli-vm app list            # knulli-vm app default NAME | app rm NAME
./knulli-vm start someapp
```

Launch-script auto-detection: `gb_launch.py` → `main.py` → `run.sh` → a lone
`*.sh` (override with `--cmd`). A single top-level directory inside the zip
wins as the app root even with loose `*.sh` launcher companions next to it.
Apps land in `<rootfs>/userdata/roms/ports/<name>/` and are exec'd the way
knulli's EmulationStation does it (`cd <appdir> && /usr/bin/pygame <script>`).
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

`bridge` reads the pad via pygame-ce (macOS Game Controller framework) and
streams held button/dpad states into the VM over one ssh pipe — the app's own
repeat profiles then behave natively. (USB *passthrough* isn't possible:
Lima/vz exposes no USB, and Virtualization.framework's gamepad support is nil.)

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
→ capture subN), and GrainBrick opens several (its UI preview stream, plus
the aplay its audio pump spawns), so the only sub carrying the app's main
output is the one owned by the running `aplay` process. Hardcoding sub0 once
meant hours of "the app outputs pure silence" while an orphaned app instance
held sub0 in XRUN and real audio flowed on sub3, unseen. Latency is tuned for
playability: `arecord -B 100000 -F 25000` (100 ms buffer / 25 ms periods) and
25 ms CoreAudio chunks in `audioplay`, end-to-end ≈ 80–100 ms behind the VM.

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
  `pgrep -a -x aplay` (should be exactly one, under the app tree) and
  `sudo cat /proc/asound/card1/pcm0p/sub*/status` — find the sub whose
  `owner_pid` is that aplay; its `hw_ptr` must advance in real time, and
  the same sub under `pcm1c/` is the cable to capture. A second `gb_launch`
  process means an orphaned app instance (old builds of `stop` left them;
  they respawn their aplay when killed) — `knulli-vm stop` now kills the
  whole tree, clean leftovers with `sudo pkill -f 'gb_launch[.]py'` plus
  `sudo pkill -x aplay`. A sub in `state: XRUN` produces exactly the pure
  zeros that get mistaken for a silent app.
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
  focus on the app window; check `pgrep -f focusd` and `/tmp/focusd.log`
  in the guest. (keymapd is now self-healing — it never blocks its X event
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

- Video: TigerVNC `Xvnc` serves 1280×720 directly on :5901 (Xvfb+x11vnc only
  as fallback). Audio out: works (loopback → Mac speakers, 48 kHz stereo;
  the UI's separate preview stream lands on its own aloop sub and is not
  piped — main output is the pump's aplay stream, which is). Mic in: apps
  open `hw:1,0` and get a *silent* loopback
  capture — there is no host-mic→guest pipe yet (would be the mirror of the
  playback path; `snd-aloop`'s free cross-cable is already there for it).
- Apps run as root in the chroot (knulli's own model); the VM is the sandbox —
  treat downloaded images/apps as untrusted accordingly.
