#!/usr/bin/env python3
"""Verify which SDL joystick-button index each button name lands on.

Creates a THROWAWAY uinput device built from virtual_joypad.py's BTN table
(does not disturb the live retrogame_joypad), opens it with SDL, presses
every button and reports the SDL index that lights up — then compares with
GrainBrick's default ButtonMapping (recovered from its Nuitka constant
pool): B=4 A=5 Y=6 X=7 L1=8 R1=9 L2=10 R2=11 SELECT=12 START=13 [14]
TAB-=15 TAB+=16. SDL numbers buttons by the driver's registration order
(evdev code rank), so this catches any code-set drift that would silently
swap the app's actions.

Run inside the chroot (knulli's python+pygame), dummy video is fine:
  SDL_VIDEODRIVER=dummy ~/knulli-vm/knulli-chroot.sh \
      python3 /root/knulli-vm/sdl_pad_probe.py
(the guest home is visible in the chroot as /root only if bind-mounted;
 simplest: copy next to this script and run with its dir on sys.path)
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from virtual_joypad import BTN, Pad  # noqa: E402

import pygame  # noqa: E402

# GrainBrick's shipped defaults = what the real knulli driver produces
EXPECTED = {"B": 4, "A": 5, "Y": 6, "X": 7, "L1": 8, "R1": 9, "L2": 10,
            "R2": 11, "SELECT": 12, "START": 13, "MODE": 14,
            "TAB-": 15, "TAB+": 16}
PRIMARY = list(EXPECTED)  # device vocabulary (aliases share codes)

NAME = "knulli_probe_pad"


def main():
    pygame.init()
    pygame.joystick.init()
    pad = Pad(NAME)
    try:
        # SDL adds hotplugged joysticks during event pumping — poll
        j = None
        t0 = time.time()
        while j is None and time.time() - t0 < 5:
            pygame.event.pump()
            for i in range(pygame.joystick.get_count()):
                jo = pygame.joystick.Joystick(i)
                jo.init()
                if NAME in jo.get_name():
                    j = jo
                    break
            if j is None:
                time.sleep(0.1)
        if j is None:
            sys.exit(f"probe pad {NAME!r} not visible to SDL "
                     f"(count={pygame.joystick.get_count()})")
        print(f"device {j.get_name()!r}: {j.get_numbuttons()} buttons, "
              f"{j.get_numhats()} hats, {j.get_numaxes()} axes")
        bad = 0
        for n in PRIMARY:
            pad.key(BTN[n], True)
            idx, t0 = None, time.time()
            while time.time() - t0 < 1.5:
                pygame.event.pump()
                ds = [i for i in range(j.get_numbuttons()) if j.get_button(i)]
                if ds:
                    idx = ds
                    break
                time.sleep(0.02)
            pad.key(BTN[n], False)
            want = [EXPECTED[n]]
            ok = idx == want
            bad += not ok
            print(f"{'OK ' if ok else 'BAD'} {n:6s} sdl={idx} expected={want}")
            time.sleep(0.1)
        print("ALL OK" if not bad else f"{bad} MISMATCHES")
        return 1 if bad else 0
    finally:
        pad.destroy()


if __name__ == "__main__":
    sys.exit(main())
