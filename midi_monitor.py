#!/usr/bin/env python3
"""Print MIDI messages from the Cmod A7 USB-UART at 31,250 baud.

Usage: midi_monitor.py [port] [baud]     (default /dev/ttyUSB1 31250; Ctrl-C to quit)

Uses termios2 because 31250 is not a standard termios speed. The ioctl numbers
are for x86 and ARM Linux.
"""
import array
import fcntl
import os
import sys
from datetime import datetime

BAUD = 31250

TCGETS2 = 0x802C542A
TCSETS2 = 0x402C542B
BOTHER = 0o010000
CBAUD = 0o010017
CIBAUD = 0o02003600000
CSIZE = 0o000060
CS8 = 0o000060
CSTOPB = 0o000100
CREAD = 0o000200
PARENB = 0o000400
CLOCAL = 0o004000
CRTSCTS = 0o20000000000
VTIME = 5
VMIN = 6

# struct termios2: 4 flag words, c_line + 19 c_cc bytes, 2 speed words
TERMIOS2_SIZE = 44
CFLAG_OFFSET = 8
CC_OFFSET = 17
ISPEED_OFFSET = 36
OSPEED_OFFSET = 40

NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]


def get_u32(buf, offset):
    return int.from_bytes(buf[offset:offset + 4], sys.byteorder)


def put_u32(buf, offset, value):
    buf[offset:offset + 4] = array.array("B", value.to_bytes(4, sys.byteorder))


def open_port(path, baud):
    """Open path in raw 8N1 mode at baud and return (fd, speed the driver reports)."""
    fd = os.open(path, os.O_RDONLY | os.O_NOCTTY)
    tio = array.array("B", bytes(TERMIOS2_SIZE))
    fcntl.ioctl(fd, TCGETS2, tio)

    cflag = get_u32(tio, CFLAG_OFFSET)
    cflag &= ~(CBAUD | CIBAUD | CSIZE | PARENB | CSTOPB | CRTSCTS) & 0xFFFFFFFF
    cflag |= BOTHER | (BOTHER << 16) | CS8 | CREAD | CLOCAL

    for offset in (0, 4, 12):  # c_iflag, c_oflag, c_lflag
        put_u32(tio, offset, 0)
    put_u32(tio, CFLAG_OFFSET, cflag)
    put_u32(tio, ISPEED_OFFSET, baud)
    put_u32(tio, OSPEED_OFFSET, baud)
    tio[CC_OFFSET + VMIN] = 1
    tio[CC_OFFSET + VTIME] = 0
    fcntl.ioctl(fd, TCSETS2, tio)

    fcntl.ioctl(fd, TCGETS2, tio)
    return fd, get_u32(tio, OSPEED_OFFSET)


def note_name(note):
    return f"{NOTE_NAMES[note % 12]}{note // 12 - 1}"


def message_length(status):
    """Bytes in a channel message: Program Change and Channel Pressure have 2."""
    return 2 if status & 0xF0 in (0xC0, 0xD0) else 3


def format_message(msg):
    """Describe one message from the keyboard (Note On/Off or Program Change)."""
    status = msg[0]
    hex_bytes = " ".join(f"{b:02x}" for b in msg)
    channel = (status & 0x0F) + 1
    if status & 0xF0 == 0xC0:
        return f"{hex_bytes}     Program  ch {channel}  {msg[1]:3d} (GM {msg[1] + 1})"
    kind = {0x90: "Note On ", 0x80: "Note Off"}.get(status & 0xF0)
    if kind is None or len(msg) != 3:
        return f"{hex_bytes}  unexpected status byte"
    _, note, velocity = msg
    return (f"{hex_bytes}  {kind} ch {channel}  "
            f"{note_name(note):<4} ({note:3d})  velocity {velocity:3d}")


def parse(data, pending):
    """Split bytes into messages, resyncing on status bytes.

    pending holds a partial message between calls. Returns (messages, stray),
    where stray lists bytes dropped because they were not part of a complete
    message.
    """
    messages = []
    stray = []
    for byte in data:
        if byte & 0x80:
            stray.extend(pending)  # previous message never completed
            pending[:] = [byte]
        elif pending:
            pending.append(byte)
            if len(pending) == message_length(pending[0]):
                messages.append(bytes(pending))
                pending.clear()
        else:
            stray.append(byte)
    return messages, stray


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "/dev/ttyUSB1"
    baud = int(sys.argv[2]) if len(sys.argv) > 2 else BAUD
    try:
        fd, speed = open_port(path, baud)
    except OSError as err:
        sys.exit(f"Could not open {path}: {err}")
    if speed != baud:
        sys.exit(f"{path} is at {speed} baud, not {baud}")

    print(f"Listening on {path} at {speed} baud. Press keys; Ctrl-C to quit.",
          flush=True)
    pending = []
    try:
        while True:
            data = os.read(fd, 256)
            if not data:
                sys.exit(f"{path} closed")
            messages, stray = parse(data, pending)
            stamp = datetime.now().strftime("%H:%M:%S.%f")[:-3]
            for msg in messages:
                print(f"{stamp}  {format_message(msg)}", flush=True)
            if stray:
                hex_bytes = " ".join(f"{b:02x}" for b in stray)
                print(f"{stamp}  stray byte(s) dropped: {hex_bytes}", flush=True)
    except KeyboardInterrupt:
        print()
    finally:
        os.close(fd)


if __name__ == "__main__":
    main()
