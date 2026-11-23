# midi_pluck

An FPGA keyboard controller and synthesizer for a **Roland K-25M** 25-key keyboard,
running on a **Digilent Cmod A7-35T** (Artix-7).

The FPGA scans the keyboard's velocity-sensing key matrix and does two things with it:

- **Sends MIDI** (Note On/Off with velocity, plus Program Change) at 31,250 baud over
  the Cmod's USB-UART, so a PC can play it through any software synth.
- **Plays the notes itself** on a 25-voice synthesizer (saw, square, triangle, or a
  Karplus-Strong plucked string), as 1-bit audio on header pin JA1.

## Features

- Velocity from the time between the top (break) and bottom (make) contacts, on a
  logarithmic curve: 2 ms or faster → 127, 400 ms or slower → 1
- Contact debouncing and full polyphony (every key has its own voice, no voice stealing)
- 25-voice synth at 48.8 kHz with a per-voice exponential ADSR envelope
- Karplus-Strong pluck mode with velocity-dependent brightness
- 1-bit sigma-delta audio output on JA1, for an RC low-pass filter or a Pmod AMP2
- **BTN1** cycles the waveform (saw → square → triangle → pluck) and sends a matching
  MIDI Program Change, so the PC instrument follows the FPGA's sound
- **BTN0** resets; **LED1** lights while a key is held; **LED2** blinks at 0.5 Hz as a clock check

| Waveform | Program Change sent | General MIDI instrument |
|----------|---------------------|-------------------------|
| Saw      | 81 | Lead 2 (sawtooth) |
| Square   | 80 | Lead 1 (square)   |
| Triangle | 79 | Ocarina           |
| Pluck    | 24 | Acoustic guitar (nylon) |

## Hardware

- Digilent Cmod A7-35T (100 MHz clock on L17)
- Roland K-25M keyboard (4 × 2 column lines, 8 row lines)
- For the on-board synth: an RC low-pass filter on JA1 (see the
  [design notes](docs/design_overview.md#audio-output)) or a Digilent Pmod AMP2 in the
  top row of header JA, then an amplifier, headphones, or an oscilloscope
- USB cable to a PC for power, programming, and MIDI

### Pin assignments

| Signal | Cmod A7 pins | Notes |
|--------|--------------|-------|
| `cola[3:0]` | M3, L1, K2, J1 | Top (break) contact columns, driven |
| `colb[3:0]` | L3, N3, M1, L2 | Bottom (make) contact columns, driven |
| `row[7:0]`  | A16, K3, C15, H1, A15, B15, A14, J3 | Row sense inputs, internal pull-downs |
| `midi_tx`   | J18 | USB-UART transmit (MIDI to PC) |
| `reset_btn` | A18 | BTN0 |
| `wave_btn`  | B18 | BTN1 |
| `activity_led` / `heartbeat_led` | A17 / C16 | LED1 / LED2 |
| `amp_ain` / `amp_gain` / `amp_shutdown_n` | G17 / G19 / L18 | JA1 / JA2 / JA4; GAIN and ~SHUTDOWN are only used by a Pmod AMP2 |

The constraints file is the authority:
`midi_pluck.srcs/constrs_1/imports/Downloads/nollama_top.xdc`.

## Repository layout

| Path | What it is |
|------|------------|
| [`docs/design_overview.md`](docs/design_overview.md) | Detailed design notes: scanner, velocity, MIDI, synth, debugging, and project history |
| `midi_pluck.xpr` | Vivado project |
| `midi_pluck.srcs/sources_1/imports/Downloads/nollama_top.v` | Top level: matrix scanner, velocity, MIDI FIFO and UART, button and LEDs |
| `midi_pluck.srcs/sources_1/new/synth_engine.v` | 25-voice synthesizer, ADSR, pluck, sigma-delta output |
| `midi_pluck.srcs/constrs_1/imports/Downloads/nollama_top.xdc` | Pins, clock, and flash configuration |
| `midi_pluck.srcs/sim_1/new/tb_nollama_top.v` | Self-checking testbench for the top level |
| `midi_pluck.srcs/sim_1/new/tb_synth_engine.v`, `tb_pluck.v` | Testbenches for the synthesizer |
| `midi_monitor.py` | Prints the MIDI messages arriving from the board |
| `midi_synth.py` | Plays the board's MIDI through FluidSynth |
| `velocity_curve.py` | Generates (and checks) the velocity table in `nollama_top.v` |
| `pluck_tables.py` | Generates the Karplus-Strong tables in `synth_engine.v` and a bit-exact model |

## Building

Built with **Vivado 2025.2**.

1. Open `midi_pluck.xpr` in Vivado.
2. Run **Generate Bitstream**.
3. Open the Hardware Manager, connect to the board, and program
   `midi_pluck.runs/impl_1/nollama_top.bit` to try it (lost at power-off).

### Writing to flash (so it starts at power-on)

The Cmod A7-35T has a 4 MB Micron N25Q032A Quad-SPI flash.

1. In the Vivado Tcl console, make a configuration file from the bitstream:
   ```tcl
   write_cfgmem -format mcs -size 4 -interface SPIx4 \
       -loadbit {up 0x0 midi_pluck.runs/impl_1/nollama_top.bit} \
       -file midi_pluck.mcs -force
   ```
2. In the Hardware Manager, right-click the FPGA → **Add Configuration Memory Device**
   → choose **n25q32-3.3v-spi-x1_x2_x4**.
3. Right-click the memory device → **Program Configuration Memory Device**, select
   `midi_pluck.mcs`, and enable Erase, Program, and Verify.
4. Unplug and replug the USB cable. The design loads from flash, and LED2 starts blinking.

## Playing on a PC

The board appears as a USB serial port (usually `/dev/ttyUSB1` on Linux). The scripts
need Python 3 and Linux; they set the non-standard 31,250 baud with `termios2`.

```bash
python3 midi_monitor.py                # print the messages
sudo apt install fluidsynth fluid-soundfont-gm
python3 midi_synth.py                  # play them through FluidSynth
python3 midi_synth.py --program 24     # start on a different instrument
```

Only one program can read the port at a time, so stop `midi_monitor.py` before
running `midi_synth.py`. Press BTN1 on the board to change the instrument.

## Simulation

The testbenches run in Vivado's simulator (**Run Simulation** with `tb_nollama_top` as
top) or from the command line:

```bash
source /opt/Vivado/2025.2/Vivado/settings64.sh    # adjust to your install
mkdir -p sim_run && cd sim_run                     # keeps simulator files out of the sources
S=../midi_pluck.srcs
xvlog $S/sources_1/imports/Downloads/nollama_top.v $S/sources_1/new/synth_engine.v \
      $S/sim_1/new/tb_nollama_top.v
xelab tb_nollama_top -s tb_top
xsim tb_top -R
```

`tb_nollama_top` strikes keys at different speeds, checks the MIDI bytes and velocities,
and tests debouncing, chords, reset, and the BTN1 Program Change. It ends with
`=== RESULT: PASS`. The synth testbenches (`tb_synth` in `tb_synth_engine.v`, and
`tb_pluck`) are run the same way with `synth_engine.v`.

## Regenerating tables

If you change the clock, sample rate, or velocity curve, regenerate the tables rather
than editing them by hand:

```bash
python3 velocity_curve.py --check      # does nollama_top.v match the curve?
python3 velocity_curve.py --write      # rewrite the table in nollama_top.v
python3 pluck_tables.py verilog        # print the pluck tables for synth_engine.v
```

## License

MIT. See [LICENSE](LICENSE).
