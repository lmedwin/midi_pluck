#!/usr/bin/env python3
"""Play MIDI from the Cmod A7 USB-UART through FluidSynth.

Usage: midi_synth.py [port] [--baud N] [--velocity N] [--program N] [--soundfont FILE]

Needs: sudo apt install fluidsynth fluid-soundfont-gm
Ctrl-C to quit. Only one program can read the port, so stop midi_monitor.py first.
"""
import argparse
import os
import shutil
import subprocess
import sys

from midi_monitor import BAUD, format_message, open_port, parse

SOUNDFONT = "/usr/share/sounds/sf2/FluidR3_GM.sf2"
AUDIO_DRIVER = "pulseaudio"


def start_synth(soundfont, program, audio_driver):
    """Start FluidSynth reading commands from stdin, with its prompt silenced."""
    synth = subprocess.Popen(
        ["fluidsynth", "-n", "-a", audio_driver, "-g", "1.0", "-r", "48000",
         "-o", "audio.period-size=128", "-o", "audio.periods=3", soundfont],
        stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, text=True, bufsize=1)
    send(synth, f"prog 0 {program}")
    return synth


def send(synth, command):
    synth.stdin.write(command + "\n")
    synth.stdin.flush()


def synth_command(msg, velocity):
    """Return the FluidSynth command for a message, or None if it isn't handled.

    Program Change (sent when BTN1 changes the FPGA waveform) switches the
    instrument; FluidSynth channels are 0-based like the MIDI status byte.
    """
    status = msg[0]
    kind = status & 0xF0
    if kind == 0xC0:
        return f"prog {status & 0x0F} {msg[1]}"
    if len(msg) != 3:
        return None
    _, note, value = msg
    if kind == 0x90 and value > 0:
        return f"noteon 0 {note} {velocity if velocity is not None else value}"
    if kind in (0x80, 0x90):
        return f"noteoff 0 {note}"
    return None


def main():
    parser = argparse.ArgumentParser(description="Play the keyboard through FluidSynth.")
    parser.add_argument("port", nargs="?", default="/dev/ttyUSB1")
    parser.add_argument("--baud", type=int, default=BAUD)
    parser.add_argument("--velocity", type=int, choices=range(1, 128), metavar="1-127",
                        help="play every note at this velocity instead of the keyboard's")
    parser.add_argument("--program", type=int, default=0, choices=range(128), metavar="0-127",
                        help="starting General MIDI instrument (default 0, piano); "
                             "BTN1 on the board then switches it with Program Change")
    parser.add_argument("--soundfont", default=SOUNDFONT)
    parser.add_argument("--audio-driver", default=AUDIO_DRIVER)
    args = parser.parse_args()

    if not shutil.which("fluidsynth"):
        sys.exit("FluidSynth not found. Install it with: "
                 "sudo apt install fluidsynth fluid-soundfont-gm")
    if not os.path.isfile(args.soundfont):
        sys.exit(f"SoundFont not found: {args.soundfont}\n"
                 "Install one with: sudo apt install fluid-soundfont-gm")

    try:
        fd, speed = open_port(args.port, args.baud)
    except OSError as err:
        sys.exit(f"Could not open {args.port}: {err}")
    if speed != args.baud:
        sys.exit(f"{args.port} is at {speed} baud, not {args.baud}")

    synth = start_synth(args.soundfont, args.program, args.audio_driver)
    print(f"Playing from {args.port} at {speed} baud. Ctrl-C to quit.", flush=True)
    pending = []
    try:
        while True:
            data = os.read(fd, 256)
            if not data:
                sys.exit(f"{args.port} closed")
            messages, stray = parse(data, pending)
            for msg in messages:
                command = synth_command(msg, args.velocity)
                if command:
                    send(synth, command)
                print(format_message(msg), flush=True)
            if stray:
                hex_bytes = " ".join(f"{b:02x}" for b in stray)
                print(f"stray byte(s) dropped: {hex_bytes}", flush=True)
    except KeyboardInterrupt:
        print()
    except BrokenPipeError:
        sys.exit("FluidSynth stopped unexpectedly")
    finally:
        os.close(fd)
        try:
            synth.stdin.close()
        except BrokenPipeError:
            pass
        synth.terminate()
        synth.wait()


if __name__ == "__main__":
    main()
