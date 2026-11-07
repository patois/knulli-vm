# knulli-vm

Run **apps built for the TrimUI Brick / KNULLI Linux** — like
[GrainBrick](https://github.com/ETRNLIAM/GrainBrick) — on an Apple Silicon Mac,
inside the *actual* KNULLI userspace taken from a real knulli device image. The
app runs unmodified against knulli's own Python 3.12, knulli's system pygame,
knulli's ALSA stack and knulli's own `/usr/bin/pygame` launcher, installed under
`/userdata/roms/ports/` exactly like on the device. You see its screen over VNC,
hear it through the Mac's speakers, and drive it with the Mac's keyboard or a
gamepad.

KNULLI images are device firmware (Allwinner/Rockchip SoC, vendor GPU blob) and
cannot boot in a Mac VM, so knulli-vm boots a normal Ubuntu 24.04 arm64 VM with
[Lima](https://github.com/lima-vm/lima) and **chroots the OS squashfs** out of
the knulli image instead. One library is swapped: knulli's SDL2 only knows the
device's GPU, so the installer builds stock SDL2 with X11 alongside it. Nothing
else is substituted and the app is never modified.

## What it can do

- Run KNULLI/Brick apps as distributed — no recompiled or patched binaries.
- Show the app's screen at 1280×720 in macOS Screen Sharing over VNC.
- Play the app's sound on the Mac, about **50 ms** behind the app — usable for
  playing an instrument, not for pro-audio monitoring.
- Feed the app's **record** inputs with real signal: the Mac's microphone into
  the app's BUILT-IN MIC, and whatever the Mac is playing into the app's
  USB AUDIO input.
- Turn the Mac's keyboard into the Brick's buttons, or bridge a physical
  USB/Bluetooth gamepad plugged into the Mac.
- Install several apps, upgrade them in place, and keep the user's samples,
  recordings, projects and settings while doing it.

## What it cannot do

- **It is not a KNULLI device.** No EmulationStation, no PORTS menu, no
  booting the knulli image — you start apps with `knulli-vm start`. There is no
  device GPU, no device display, no device firmware, so "works here" and "works
  on the Brick" are not the same claim.
- **Apple Silicon Macs only.** The guest is arm64, so Intel Macs are out, and
  the installer is macOS-only.
- **No USB passthrough.** Lima/vz has no USB. The app's "USB AUDIO" input is
  the Mac's own audio by design; you cannot attach a real USB audio interface
  or USB MIDI controller.
- **No analog sticks.** The Brick has none, so neither does the emulated pad —
  no L3/R3. `FN` is a hardware hotkey modifier on the device, not a button the
  app can receive.
- **Still screenshots only, no video capture** (`knulli-vm screenshot`).
- **No apps included.** knulli-vm is tooling only; you bring the app ZIP.
- The original TrimUI Brick image is the verified target. `--image-device` will
  install another KNULLI device's userspace, but that path hasn't been retested
  since the audio and input work.
- Apps run as root *inside the chroot* — that is knulli's own model, and the VM
  is the sandbox. Treat images and app archives you feed it as untrusted.

## What you supply, what the installer fetches

| | You supply? | Needed? |
|---|---|---|
| Apple Silicon Mac | ✔ you | **mandatory** |
| This repo | ✔ you (clone or copy) | **mandatory** |
| [Homebrew](https://brew.sh) | ✔ you | **mandatory** |
| Lima — `brew install lima` | ✔ you | **mandatory** |
| The app ZIP (e.g. GrainBrick) | ✔ you, from the app's own releases page | **mandatory to run an app** — knulli-vm ships none |
| Xcode Command Line Tools — `xcode-select --install` | ✔ you | recommended — this is the *only* way to get **sound**. Without `swiftc` everything installs, but the app is silent and recording is unavailable |
| macOS permission prompts (Microphone, Screen Recording) | ✔ you, by clicking | only when you use `knulli-vm feed` |
| KNULLI device image (~2 GB) | installer fetches it | automatic — sha256-verified, from [knulli-cfw/distribution](https://github.com/knulli-cfw/distribution/releases). Only fetch it yourself for a specific build or device |
| Ubuntu 24.04 arm64 VM image | Lima | automatic |
| Guest packages (TigerVNC, xdotool, imagemagick, python3-xlib, squashfs-tools, alsa-utils) | installer (apt inside the VM) | automatic |
| SDL2 source for the X11 build | installer | automatic |
| Python venv for gamepad reading (`pygame-ce`) | `knulli-vm`, the first time you run `bridge` | automatic |

Nothing else needs downloading by hand. Budget roughly **15 GB of disk**: the VM
disk grows to about 11 GB in use, of which the extracted KNULLI userspace is
~4.7 GB. The VM is configured for 4 vCPUs and 8 GB RAM.

## Install

### 1. Prerequisites

```sh
brew install lima                                  # mandatory (needs Homebrew)
xcode-select --install                             # optional, but it is the only
                                                   #   way to get sound
git clone https://github.com/patois/knulli-vm      # mandatory
cd knulli-vm
```

Skipping `xcode-select --install` is fine for the screen and the controls — the
app just plays silently, and `feed` is unavailable. Install it and re-run
`./install.sh` when you want audio.

### 2. Run the installer (mandatory)

```sh
./install.sh
```

That single command creates the VM, deploys the guest scripts, resolves and
downloads the latest KNULLI image for the TrimUI Brick, verifies its sha256,
extracts the userspace, builds the SDL2 X11 library, sets up the audio routing,
builds the Mac audio bridges, and writes the install's config. Slow steps print
a ticking timer (`>>> extracting rootfs ... 45s`) — that is progress, not a hang.
Re-running `./install.sh` at any time is safe and is the way to heal an install
after updates: finished steps detect existing state and skip, so the 2 GB image
is not re-downloaded.

### 3. Add the app you want to run (mandatory, once per app)

knulli-vm ships no apps. Get the app's own release ZIP — for GrainBrick, from
<https://github.com/ETRNLIAM/GrainBrick/releases> (the release asset, **not**
GitHub's auto-generated "Source code" archives) — then:

```sh
./knulli-vm app add ~/Downloads/GrainBrick_beta_1.0_TrimUI_Brick_KNULLI.zip
```

A direct download URL works too (`app add https://.../GrainBrick_...zip`), as
does a plain directory.

### 4. Start it and connect

```sh
./knulli-vm start            # services + the default app + sound to the Mac
./knulli-vm vnc              # prints this install's VNC URL and password
open vnc://localhost:5901    # macOS Screen Sharing; password: knulli
```

Then just play: the keyboard map is below, sound comes out of the Mac.

### Optional install variations

Pass these to `./install.sh` instead of the bare command:

| Flag | Use it when |
|---|---|
| `--app <zip-or-url>` | you already have the app and want it installed during install (repeatable) |
| `--image ./knulli-a133-trimui-brick-….img` | you downloaded a specific image yourself |
| `--image-url https://…/knulli-….img.gz` | fetch a specific build from the releases page |
| `--image-device knulli-h700-rg-cubexx` | a different KNULLI device (asset prefix must match) |
| `--vm-name studio --vnc-port 5902` | a **second install on this Mac** — see below |
| `--vnc-pass secret` | change the VNC password (stored in `state/`, gitignored) |

**Two installs on one Mac.** Lima forwards a VM's VNC port to the *same* port on
the Mac, so only one install can own 5901 and a second one's forward silently
never binds — its URL would show the *first* VM's screen. The installer therefore
checks the port and takes the next free one, saying so. `knulli-vm vnc` and
`status` always report the port that install really owns, and `vnc` refuses to
hand out a URL some other VM serves. Give each install its own `--vm-name`.

## Day to day

```sh
./knulli-vm start              # start services + default app (audio included)
./knulli-vm start someapp      # start a specific installed app
./knulli-vm vnc                # this install's VNC URL + password
./knulli-vm status             # VM / display / audio / feeds / apps / port
./knulli-vm screenshot         # save the display as knulli-vm-shot.png
./knulli-vm stop               # stop the app; the VM keeps running
./knulli-vm down               # also shut the VM off (frees RAM/CPU, disk kept)
./knulli-vm down --force       # ...hard kill, for a guest ignoring shutdown
./knulli-vm up                 # bring a stopped VM back up
./knulli-vm help               # everything, with the input vocabulary
```

`stop` vs `down`: `stop` kills the app and its audio pipe *inside* the VM;
`down` does that first and then turns the VM off. Note that `stop` also stops any
recording feeds you had running — it prints which ones, so you can bring them
back with `feed mic` / `feed usb`.

Everything else has its own section below: `input` and `bridge` (controls),
`audio` and `feed` (sound), `keymap` (keyboard not mapping), `app` (installing
and upgrading apps), and `--vm NAME` in front of any command to drive a second
install on the same Mac.

## Controls

**Keyboard.** While the VNC window has focus, the keys map to the Brick's
buttons. The layout mirrors the device's own panel — dpad left, SNES-lettered
face cluster right (X top, A right, B bottom, Y left), triggers under the
shoulders:

| keys | Brick button | keys | Brick button |
|---|---|---|---|
| W A S D / arrows | dpad (diagonals combine) | Q / E | L1 / R1 (shoulders) |
| K | B (bottom) | Z / C | L2 / R2 (rear) |
| J | A (right) | BackSpace | SELECT |
| U or X | X (top) | Enter, space | START |
| I | Y (left) | m | MENU (logo) |
| F1 / F2 | TAB- / TAB+ | | |

If keys stop mapping, `./knulli-vm keymap restart` fixes it in a second;
`keymap log` then shows every mapped key it receives.

**Physical gamepad.** `./knulli-vm bridge` reads a USB/Bluetooth pad plugged
into the Mac and streams it into the VM — held buttons stay held, so the app's
own auto-repeat behaves natively. Stop it with Ctrl-C.

**From the shell** — useful for scripting a UI path:

```sh
./knulli-vm input "hat down 150"    # tap the dpad; holdhat down / holdhat none to hold
./knulli-vm input "press Y"         # A B X Y L1 R1 L2 R2 SELECT START MODE TAB- TAB+
```

## Sound

**Output is automatic.** `knulli-vm start` brings the sound pipe up *before* the
app (an app whose output nobody drains will underrun and can stop reacting to
input). If you hear nothing: `./knulli-vm audio status`, then
`./knulli-vm audio start`.

**Recording into the app** is opt-in, because macOS asks permission for it:

```sh
./knulli-vm feed mic     # the Mac's MICROPHONE  -> the app's BUILT-IN MIC
./knulli-vm feed usb     # what the Mac is PLAYING -> the app's USB AUDIO input
./knulli-vm feed status  # knulli-vm feed stop [usb|mic|all]
```

Four things to know:

1. **Grant the permission to your terminal app**, not to a binary — System
   Settings → Privacy & Security → **Microphone** (for `mic`) and → **Screen
   Recording** (for `usb`). The first `feed` fails with the exact fix printed if
   it's missing; after ticking Screen Recording you must relaunch the terminal.
2. **`feed usb` needs a display that is actually on.** macOS taps the Mac's
   system audio *through a display*, so a closed lid or a sleeping monitor
   leaves nothing to tap — having Screen Recording granted does not help. Wake
   or connect a display and run it again (`feed` says so when this is the
   problem). If the display sleeps *during* a take the feed stops and says why —
   run `feed usb` again; it will not quietly record silence. `feed usb --source
   mic` needs no display at all.
3. **Start the feed first, then press record in the app.** A feed whose stream
   is parked is normal, not hung — it flows the moment the app opens the input.
4. `feed usb` captures *everything* the Mac plays, including the app's own
   output coming back out of the Mac's speakers, so you can hear yourself
   re-amped. `feed usb --source mic` avoids that.

Both feeds can run at once; the app's own source toggle picks which one it
records.

## Apps

```sh
./knulli-vm app add <zip|dir|url> [--name N] [--cmd C] [--default]
./knulli-vm app list
./knulli-vm app default NAME      # what bare `start` launches
./knulli-vm app rm NAME
```

An app is installed the way the device would install it, including the vendor's
own spelling of its directory (`ports/grainbrick beta 1.0.1/` plus its sibling
`GrainBrick beta 1.0.1.sh`, spaces and all) and running that launcher stub
rather than guessing an entry point — the stub is what creates and seeds the
app's `samples/`, `projects/` and `recordings/`, so skipping it would leave you
with an empty sample browser the device would never show. Only if a ZIP ships no
stub does knulli-vm look for `gb_launch.py` / `main.py` / `run.sh` / a lone
`*.sh`; override with `--cmd`.

Re-adding the same app name **upgrades it in place** and preserves your
`samples/`, `recordings/`, `projects/` and `*.json` settings inside the app dir —
the same promise the app's own README makes for device upgrades.

## Remapping (optional)

Both input paths speak one vocabulary — button names `A B X Y L1 R1 L2 R2 SELECT
START MODE TAB- TAB+` and hat directions `up down left right upleft …` — so
remapping is always "edit one small dict, restart its mapper".

- **Keyboard:** `lib/guest/keymapd.py`, dict `KEYMAP` (two keys may share a
  button, like `u`/`x` → X). Apply with `./knulli-vm sync && ./knulli-vm keymap
  restart`. If the app misses quick taps, raise `BTN_HOLD`/`HAT_HOLD` in the
  same file (shipped: 120 ms buttons / 220 ms dpad, measured against GrainBrick).
- **Physical pad:** `lib/host/pad_bridge.py`, dicts `BUTTON_MAP` and
  `DPAD_BUTTONS`. The shipped values were measured on one specific pad and match
  the "standard" order only by coincidence, so sweep your own pad once — press
  every button, both sticks, every dpad direction, and read the indices it
  prints (the `padenv` venv appears the first time you run `bridge`):

  ```sh
  ./padenv/bin/python -I - <<'PY'
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

  Two tells help you read that log: an analog trigger moves an *axis* together
  with its *button*, and dpad diagonals fire as *pairs* of buttons — which proves
  which four indices are the dpad. Pads spoofing Microsoft's `045E:028E` often
  enumerate in their own raw order with the dpad arriving as buttons. Edit the
  dicts and just rerun `./knulli-vm bridge` — it runs on the Mac, no `sync`
  needed. Pads with no dpad fall back to left-stick axes automatically.

## Files on disk

```
install.sh              one-shot installer
knulli-vm               day-to-day CLI
vm/knulli.yaml          Lima template (Ubuntu 24.04 arm64, vz)
lib/guest/              scripts deployed into the VM (chroot entry, virtual
                        joypad, keyboard mapper, launcher, audio setup, both
                        audio directions, image extractor, SDL2 builder)
lib/host/               pad_bridge.py, audioplay.swift, audiocap.swift
tools/                  self-tests (audio mixer, input, keymap)
state/                  this install's config + app registry (gitignored;
                        contains the VNC password)
downloads/              images, SDL tarballs, app zips (gitignored)
bin/                    built Mac audio bridges (gitignored)
padenv/                 venv for gamepad reading (gitignored)
```

The VM itself lives in `~/.lima/<vm-name>/`; the extracted KNULLI userspace and
your installed apps live **inside** it, not in this folder.

To remove an install completely:

```sh
./knulli-vm down
limactl delete <vm-name>          # the name is in state/default, or: limactl list
rm -rf state downloads bin padenv
```

`limactl delete` destroys the VM disk — including any recordings, samples and
projects you made inside the app. Copy them out first if you want them.

## Troubleshooting

- **No sound.** `./knulli-vm audio status`, then `audio start`. If `install.sh`
  printed `no swiftc`, install the Xcode Command Line Tools and re-run it — the
  Mac-side audio player is built from Swift.
- **The app dies or stops reacting to input a few seconds in.** Its audio
  underruns when nothing drains it. `./knulli-vm audio start`, or restart the app.
- **Keyboard does nothing on the VNC screen.** `./knulli-vm keymap restart`
  first — that is the mapper, and it's a one-second fix. Then `keymap log`: if it
  scrolls while you type but the app ignores you, the problem is the app/pad side.
- **App ignores input after you restarted the joypad.** Recreating the emulated
  pad requires restarting the app: `./knulli-vm stop && ./knulli-vm start`.
- **VNC shows a different VM's screen.** Two installs collided on port 5901.
  Re-run `./install.sh --vm-name <name> --vnc-port <free>` for the stuck one.
- **"Device or resource busy" from arecord.** A capture from a previous session
  still holds the loopback: `./knulli-vm audio stop` then `start`.
- **"Dynamic linking causes SDL downgrade".** The X11 SDL build must be
  ≥ 2.32.8; re-run `./install.sh`, which rebuilds it.
- **VNC gives an auth error before asking for a password.** macOS Screen Sharing
  refuses servers with no auth; the launcher starts TigerVNC with VNC auth, so
  this means you're on a fallback path — `./knulli-vm status` shows which server
  is serving the display.
- **Input lags by whole seconds.** That is the Xvfb+x11vnc fallback starving its
  own input queue. `install.sh` installs TigerVNC, which serves display and VNC
  as one server and doesn't have the problem; make sure it succeeded.
- **`limactl start` stalls on a containerd step.** It's optional; the VM is
  usable anyway — `limactl shell <vm-name>`.

## Notes

- Where these numbers come from, why the audio path is wired the way it is, the
  measurement recipes, and the traps that cost hours are written up in maintainer
  notes (`INTERNALS.md`), which are deliberately kept out of git — ask the
  maintainer if you're changing the tooling and want them.
- KNULLI: <https://knulli.org> · images:
  <https://github.com/knulli-cfw/distribution/releases> · TrimUI hardware:
  <https://www.trimui.com>.
