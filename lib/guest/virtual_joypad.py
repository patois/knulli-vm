#!/usr/bin/env python3
"""Virtual gamepad via /dev/uinput — stdlib only (ctypes), no pip deps.

Creates a joystick the way the KNULLI joypad driver does (name default:
retrogame_joypad) so SDL/pygame sees a "real" controller inside the VM.

Usage: sudo python3 virtual_joypad.py [name]

Commands via FIFO (echo "press SOUTH" > /tmp/joypad.fifo):
  press BUTTON [ms]   tap button (default 80 ms)
  hold BUTTON         press and keep held
  release BUTTON      release a held button
  hat DIR [ms]        dpad tap (default 120 ms); DIR: up|down|left|right|
                      upleft|upright|downleft|downright
  holdhat DIR         dpad held (repeat until 'holdhat none')
  holdhat none        release held dpad
  axis NAME VALUE     absolute stick: lx|ly  (-32767..32767)
Buttons: SOUTH EAST NORTH WEST TL TR TL2 TR2 SELECT START MODE C Z THUMBL THUMBR
"""
import ctypes
import fcntl
import os
import queue
import struct
import sys
import threading
import time

EV_SYN, EV_KEY, EV_ABS = 0x00, 0x01, 0x03
UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_SET_ABSBIT = 0x40045567
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502

ABS_CNT = 64
FIFO = os.environ.get("JOYPAD_FIFO", "/tmp/joypad.fifo")

# Canonical Linux joystick button block (linux/input-event-codes.h),
# BTN_A..BTN_THUMBR — the range SDL maps for game controllers
BTN = {
    "SOUTH": 0x130, "EAST": 0x131, "C": 0x132, "NORTH": 0x133,
    "WEST": 0x134, "Z": 0x135, "TL": 0x136, "TR": 0x137,
    "TL2": 0x138, "TR2": 0x139, "SELECT": 0x13A, "START": 0x13B,
    "MODE": 0x13C, "THUMBL": 0x13D, "THUMBR": 0x13E,
}
ABS_X, ABS_Y = 0x00, 0x01
ABS_HAT0X, ABS_HAT0Y = 0x10, 0x11
# direction -> list of (axis, value) — diagonals set both axes
HAT_DIR = {
    "up": [(ABS_HAT0Y, -1)], "down": [(ABS_HAT0Y, 1)],
    "left": [(ABS_HAT0X, -1)], "right": [(ABS_HAT0X, 1)],
    "upleft": [(ABS_HAT0Y, -1), (ABS_HAT0X, -1)],
    "upright": [(ABS_HAT0Y, -1), (ABS_HAT0X, 1)],
    "downleft": [(ABS_HAT0Y, 1), (ABS_HAT0X, -1)],
    "downright": [(ABS_HAT0Y, 1), (ABS_HAT0X, 1)],
}
HAT_NEUTRAL = [(ABS_HAT0X, 0), (ABS_HAT0Y, 0)]
AXIS = {"lx": ABS_X, "ly": ABS_Y}


class InputId(ctypes.Structure):
    _fields_ = [("bustype", ctypes.c_uint16), ("vendor", ctypes.c_uint16),
                ("product", ctypes.c_uint16), ("version", ctypes.c_uint16)]


class UInputUserDev(ctypes.Structure):
    # uapi/linux/uinput.h legacy layout: four parallel s32[ABS_CNT] arrays.
    # sizeof must equal the kernel's exactly (1116) or write() -> EINVAL.
    _fields_ = [("name", ctypes.c_char * 80), ("id", InputId),
                ("ff_effects_max", ctypes.c_int32),
                ("absmax", ctypes.c_int32 * ABS_CNT),
                ("absmin", ctypes.c_int32 * ABS_CNT),
                ("absfuzz", ctypes.c_int32 * ABS_CNT),
                ("absflat", ctypes.c_int32 * ABS_CNT)]


class Pad:
    def __init__(self, name):
        self.lock = threading.Lock()
        self.fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
        for ev in (EV_KEY, EV_ABS):
            fcntl.ioctl(self.fd, UI_SET_EVBIT, ev)
        for code in BTN.values():
            fcntl.ioctl(self.fd, UI_SET_KEYBIT, code)
        for ax in (ABS_X, ABS_Y, ABS_HAT0X, ABS_HAT0Y):
            fcntl.ioctl(self.fd, UI_SET_ABSBIT, ax)
        assert ctypes.sizeof(UInputUserDev) == 1116, ctypes.sizeof(UInputUserDev)
        dev = UInputUserDev()
        dev.name = name.encode()[:79]
        # Neutral ids: with the Xbox ids (045E:028E) SDL's backend renames the
        # device "Xbox 360 Controller" and apps that match the driver name
        # (retrogame_joypad) stop seeing it. rocknix-joypad reports no ids.
        dev.id = InputId(0x03, 0x0000, 0x0000, 0x0001)  # BUS_USB, unset ids
        for ax in (ABS_X, ABS_Y):
            dev.absmax[ax] = 32767
            dev.absmin[ax] = -32767
            dev.absfuzz[ax] = 16
            dev.absflat[ax] = 128
        for ax in (ABS_HAT0X, ABS_HAT0Y):
            dev.absmax[ax] = 1
            dev.absmin[ax] = -1
        os.write(self.fd, bytes(dev))
        fcntl.ioctl(self.fd, UI_DEV_CREATE)
        print(f"uinput device '{name}' created", flush=True)

    def raw(self, ty, code, val):
        with self.lock:
            os.write(self.fd, struct.pack("llHHi", int(time.time()), 0, ty, code, val))

    def syn(self):
        self.raw(EV_SYN, 0, 0)

    def key(self, code, down):
        self.raw(EV_KEY, code, 1 if down else 0)
        self.syn()

    def abs_(self, code, val):
        self.raw(EV_ABS, code, val)
        self.syn()

    def tap_key(self, code, ms=80):
        self.key(code, True)
        time.sleep(ms / 1000.0)
        self.key(code, False)

    def tap_hat(self, direction, ms=120):
        for code, val in HAT_DIR[direction]:
            self.abs_(code, val)
        time.sleep(ms / 1000.0)
        for c, v in HAT_NEUTRAL:
            self.abs_(c, v)

    def destroy(self):
        fcntl.ioctl(self.fd, UI_DEV_DESTROY)
        os.close(self.fd)


def fifo_reader(pad, q):
    if not os.path.exists(FIFO):
        os.mkfifo(FIFO)
    while True:
        with open(FIFO, "r") as fh:
            for line in fh:
                q.put(line.strip())


def handle(pad, line):
    parts = line.split()
    if not parts:
        return
    cmd = parts[0].lower()
    try:
        if cmd == "press" and parts[1].upper() in BTN:
            pad.tap_key(BTN[parts[1].upper()], int(parts[2]) if len(parts) > 2 else 80)
        elif cmd == "hold" and parts[1].upper() in BTN:
            pad.key(BTN[parts[1].upper()], True)
        elif cmd == "release" and parts[1].upper() in BTN:
            pad.key(BTN[parts[1].upper()], False)
        elif cmd == "hat" and parts[1].lower() in HAT_DIR:
            pad.tap_hat(parts[1].lower(), int(parts[2]) if len(parts) > 2 else 120)
        elif cmd == "holdhat" and parts[1].lower() in ("none", "neutral"):
            for c, v in HAT_NEUTRAL:
                pad.abs_(c, v)
        elif cmd == "holdhat" and parts[1].lower() in HAT_DIR:
            axes = HAT_DIR[parts[1].lower()]
            used = {c for c, _ in axes}
            for ax in (ABS_HAT0X, ABS_HAT0Y):
                if ax not in used:
                    pad.abs_(ax, 0)
            for code, val in axes:
                pad.abs_(code, val)
        elif cmd == "axis" and parts[1].lower() in AXIS:
            pad.abs_(AXIS[parts[1].lower()], max(-32767, min(32767, int(parts[2]))))
        else:
            print(f"unknown command: {line!r}", flush=True)
    except (IndexError, ValueError) as e:
        print(f"bad command {line!r}: {e}", flush=True)


def main():
    name = sys.argv[1] if len(sys.argv) > 1 else "retrogame_joypad"
    pad = Pad(name)
    q = queue.Queue()
    threading.Thread(target=fifo_reader, args=(pad, q), daemon=True).start()
    try:
        while True:
            try:
                handle(pad, q.get(timeout=2))
            except queue.Empty:
                pad.syn()  # keep-alive
    except KeyboardInterrupt:
        pass
    finally:
        pad.destroy()


if __name__ == "__main__":
    main()
