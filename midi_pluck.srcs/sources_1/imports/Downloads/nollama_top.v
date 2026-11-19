`timescale 1ns / 1ps

module nollama_top #(
    parameter CLK_HZ     = 100_000_000, // Input clock frequency in Hz (L17; measured ~100 MHz with heartbeat LED 2026-11-10)
    parameter ILA_RATE_HZ = 40_000      // ILA sample rate: 40 kHz = 25 us/sample -> 8192 samples = 204.8 ms
                                        // (4_000_000 = 250 ns/sample -> ~2 ms window for fine detail)
)(
    input  wire        clk,          // Clock input on pin L17
    input  wire        reset_btn,    // Active-High Reset (BTN0 on pin A18)
    
    // Matrix Physical Pins (Roland K-25M: 4 columns x 8 rows)
    output reg  [3:0]  cola,         // Pins M3, J1, L1, M1 (Top / Break contacts)
    output reg  [3:0]  colb,         // Pins L3, K2, L2, N3 (Bottom / Make contacts)
    input  wire [7:0]  row,          // Pins A16, K3, C15, H1, A15, B15, A14, J3 (Shared Sense lines)
    
    // Outputs
    output reg         midi_tx,      // MIDI serial stream (USB-UART pin J18)
    output reg         activity_led, // Lights up when keys are held down (pin A17)
    output reg         heartbeat_led, // Clock check (pin C16): toggles every CLK_HZ clocks

    // Audio: Pmod AMP2 plugged into header JA (top row)
    input  wire        wave_btn,      // BTN1 (B18): cycle waveform saw -> square -> triangle -> pluck
                                      //   (also sends a MIDI Program Change, see section 4)
    output wire        amp_ain,       // JA1 (G17): 1-bit sigma-delta audio
    output wire        amp_gain,      // JA2 (G19): AMP2 gain select
    output wire        amp_shutdown_n // JA4 (L18): high = amplifier on
);

    wire reset = reset_btn;

    // =========================================================================
    // 0. HEARTBEAT (clock-frequency check)
    //    Toggles every CLK_HZ clocks, so LED2 is 1 s on / 1 s off when the
    //    clock really is CLK_HZ.  No reset, so it keeps running while BTN0
    //    is held.
    // =========================================================================
    localparam HB_W = $clog2(CLK_HZ);
    reg [HB_W-1:0] hb_cnt = {HB_W{1'b0}};
    initial heartbeat_led = 1'b0;

    always @(posedge clk) begin
        if (hb_cnt == CLK_HZ - 1) begin
            hb_cnt        <= {HB_W{1'b0}};
            heartbeat_led <= ~heartbeat_led;
        end else begin
            hb_cnt <= hb_cnt + 1'b1;
        end
    end

    // =========================================================================
    // CLOCK-DERIVED CONSTANTS
    //   100 us tick  : CLK_HZ / 10,000      (100 MHz -> 10000)
    //   Scan step    : 32 us = CLK_HZ / 31,250 (100 MHz -> 3200)
    //   MIDI bit time: 31,250 baud = CLK_HZ / 31,250 (same as scan step)
    // =========================================================================
    localparam TICK_CLKS = CLK_HZ / 10000;
    localparam SCAN_CLKS = CLK_HZ / 31250;
    localparam BAUD_CLKS = CLK_HZ / 31250;

    localparam TICK_W = $clog2(TICK_CLKS);
    localparam SCAN_W = $clog2(SCAN_CLKS);
    localparam BAUD_W = $clog2(BAUD_CLKS);

    localparam [TICK_W-1:0] TICK_MAX = TICK_CLKS - 1;
    localparam [SCAN_W-1:0] SCAN_MAX = SCAN_CLKS - 1;
    localparam [BAUD_W-1:0] BAUD_MAX = BAUD_CLKS - 1;

    // =========================================================================
    // 1. 100-MICROSECOND TICK GENERATOR (Velocity and Debounce Reference)
    // =========================================================================
    reg [TICK_W-1:0] tick_timer;
    reg              tick_100us;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            tick_timer <= {TICK_W{1'b0}};
            tick_100us <= 1'b0;
        end else begin
            if (tick_timer == TICK_MAX) begin // CLK_HZ / TICK_CLKS = 10 kHz (100 us)
                tick_timer <= {TICK_W{1'b0}};
                tick_100us <= 1'b1;
            end else begin
                tick_timer <= tick_timer + 1'b1;
                tick_100us <= 1'b0;
            end
        end
    end

    // =========================================================================
    // 2. TWO-PHASE COLUMN SCANNER (COLA then COLB per column)
    // =========================================================================
    reg [SCAN_W-1:0] scan_timer;
    reg [2:0]        scan_phase;

    wire [1:0] active_col = scan_phase[2:1];
    wire       is_colb    = scan_phase[0];

    always @(*) begin
        cola = 4'b0000;
        colb = 4'b0000;
        if (!is_colb)
            cola[active_col] = 1'b1;
        else
            colb[active_col] = 1'b1;
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            scan_timer <= {SCAN_W{1'b0}};
            scan_phase <= 3'd0;
        end else begin
            if (scan_timer == SCAN_MAX) begin
                scan_timer <= {SCAN_W{1'b0}};
                scan_phase <= scan_phase + 1'b1;
            end else begin
                scan_timer <= scan_timer + 1'b1;
            end
        end
    end

    // =========================================================================
    // 3. KEY SENSING & VELOCITY FSM
    // =========================================================================
    localparam S_IDLE       = 3'b000;
    localparam S_DOWN       = 3'b001;
    localparam S_BOTTOM_DEB = 3'b010;
    localparam S_HELD       = 3'b011;
    localparam S_RELEASE    = 3'b100;

    reg [2:0]  key_state      [0:31];
    reg [11:0] key_timer      [0:31];
    reg [7:0]  deb_timer      [0:31];
    reg [6:0]  key_velocity   [0:31];

    reg [31:0] note_on_pending;
    reg [31:0] note_off_pending;
    reg [7:0]  top_sample;

    // Registers to capture the most recent key strike for debugging
    reg [4:0]  last_struck_key;
    reg [6:0]  last_struck_velocity;

    // Velocity curve: logarithmic in travel time, so each doubling of the
    // time between the top and bottom contacts lowers the velocity by about
    // 16.5.  Velocity 127 at 2 ms or faster, 1 at 400 ms or slower:
    //   v = 127 - 126 * ln(t / 2 ms) / ln(200), clamped to 1..127
    // The 12-bit tick count (100 us ticks, saturating at 409.5 ms) is first
    // turned into a 144-entry log-spaced index: exact below 3.2 ms, then
    // 16 steps per doubling.  The table is generated by velocity_curve.py.
    // Velocity never reaches 0, because a Note On with velocity 0 means Note Off.
    function [7:0] vel_index(input [11:0] t);
        begin
            if      (t[11]) vel_index = 8'd128 + t[10:7];
            else if (t[10]) vel_index = 8'd112 + t[9:6];
            else if (t[9])  vel_index = 8'd96  + t[8:5];
            else if (t[8])  vel_index = 8'd80  + t[7:4];
            else if (t[7])  vel_index = 8'd64  + t[6:3];
            else if (t[6])  vel_index = 8'd48  + t[5:2];
            else if (t[5])  vel_index = 8'd32  + t[4:1];
            else            vel_index = {3'd0, t[4:0]};
        end
    endfunction

    function [6:0] calc_velocity(input [11:0] ticks);
        reg [6:0] v;
        begin
            case (vel_index(ticks))
                  0: v = 7'd127;   1: v = 7'd127;   2: v = 7'd127;   3: v = 7'd127;
                  4: v = 7'd127;   5: v = 7'd127;   6: v = 7'd127;   7: v = 7'd127;
                  8: v = 7'd127;   9: v = 7'd127;  10: v = 7'd127;  11: v = 7'd127;
                 12: v = 7'd127;  13: v = 7'd127;  14: v = 7'd127;  15: v = 7'd127;
                 16: v = 7'd127;  17: v = 7'd127;  18: v = 7'd127;  19: v = 7'd127;
                 20: v = 7'd127;  21: v = 7'd126;  22: v = 7'd125;  23: v = 7'd124;
                 24: v = 7'd123;  25: v = 7'd122;  26: v = 7'd121;  27: v = 7'd120;
                 28: v = 7'd119;  29: v = 7'd118;  30: v = 7'd117;  31: v = 7'd117;
                 32: v = 7'd115;  33: v = 7'd114;  34: v = 7'd113;  35: v = 7'd111;
                 36: v = 7'd110;  37: v = 7'd109;  38: v = 7'd108;  39: v = 7'd107;
                 40: v = 7'd106;  41: v = 7'd105;  42: v = 7'd104;  43: v = 7'd103;
                 44: v = 7'd102;  45: v = 7'd101;  46: v = 7'd101;  47: v = 7'd100;
                 48: v = 7'd 99;  49: v = 7'd 97;  50: v = 7'd 96;  51: v = 7'd 95;
                 52: v = 7'd 94;  53: v = 7'd 92;  54: v = 7'd 91;  55: v = 7'd 90;
                 56: v = 7'd 89;  57: v = 7'd 88;  58: v = 7'd 87;  59: v = 7'd 87;
                 60: v = 7'd 86;  61: v = 7'd 85;  62: v = 7'd 84;  63: v = 7'd 83;
                 64: v = 7'd 82;  65: v = 7'd 81;  66: v = 7'd 79;  67: v = 7'd 78;
                 68: v = 7'd 77;  69: v = 7'd 76;  70: v = 7'd 75;  71: v = 7'd 74;
                 72: v = 7'd 73;  73: v = 7'd 72;  74: v = 7'd 71;  75: v = 7'd 70;
                 76: v = 7'd 69;  77: v = 7'd 68;  78: v = 7'd 68;  79: v = 7'd 67;
                 80: v = 7'd 66;  81: v = 7'd 64;  82: v = 7'd 63;  83: v = 7'd 62;
                 84: v = 7'd 61;  85: v = 7'd 59;  86: v = 7'd 58;  87: v = 7'd 57;
                 88: v = 7'd 56;  89: v = 7'd 55;  90: v = 7'd 54;  91: v = 7'd 54;
                 92: v = 7'd 53;  93: v = 7'd 52;  94: v = 7'd 51;  95: v = 7'd 50;
                 96: v = 7'd 49;  97: v = 7'd 48;  98: v = 7'd 46;  99: v = 7'd 45;
                100: v = 7'd 44; 101: v = 7'd 43; 102: v = 7'd 42; 103: v = 7'd 41;
                104: v = 7'd 40; 105: v = 7'd 39; 106: v = 7'd 38; 107: v = 7'd 37;
                108: v = 7'd 36; 109: v = 7'd 35; 110: v = 7'd 35; 111: v = 7'd 34;
                112: v = 7'd 33; 113: v = 7'd 31; 114: v = 7'd 30; 115: v = 7'd 29;
                116: v = 7'd 28; 117: v = 7'd 26; 118: v = 7'd 25; 119: v = 7'd 24;
                120: v = 7'd 23; 121: v = 7'd 22; 122: v = 7'd 21; 123: v = 7'd 21;
                124: v = 7'd 20; 125: v = 7'd 19; 126: v = 7'd 18; 127: v = 7'd 17;
                128: v = 7'd 16; 129: v = 7'd 15; 130: v = 7'd 13; 131: v = 7'd 12;
                132: v = 7'd 11; 133: v = 7'd 10; 134: v = 7'd  9; 135: v = 7'd  8;
                136: v = 7'd  7; 137: v = 7'd  6; 138: v = 7'd  5; 139: v = 7'd  4;
                140: v = 7'd  3; 141: v = 7'd  2; 142: v = 7'd  2; 143: v = 7'd  1;
                default: v = 7'd1;
            endcase
            calc_velocity = v;
        end
    endfunction

    integer k, r;

    // Key number for each row of the active column: {column, row}
    wire [4:0] scan_key [0:7];
    genvar sk;
    generate
        for (sk = 0; sk < 8; sk = sk + 1) begin : g_scan_key
            assign scan_key[sk] = {active_col, 3'b000} + sk;
        end
    endgenerate

    // Driven by the MIDI FIFO (section 4) and UART (section 5), declared
    // here because the key logic below uses them to clear pending flags
    reg        fifo_wr_en;
    reg [4:0]  fifo_serviced_key;
    reg        fifo_is_note_on;
    reg        fifo_rd_en;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            top_sample           <= 8'd0;
            note_on_pending      <= 32'd0;
            note_off_pending     <= 32'd0;
            activity_led         <= 1'b0;
            last_struck_key      <= 5'd0;
            last_struck_velocity <= 7'd0;
            for (k = 0; k < 32; k = k + 1) begin
                key_state[k]    <= S_IDLE;
                key_timer[k]    <= 12'd0;
                deb_timer[k]    <= 8'd0;
                key_velocity[k] <= 7'd0;
            end
        end else begin
            // 100 us Timers
            if (tick_100us) begin
                for (k = 0; k < 32; k = k + 1) begin
                    if (key_state[k] == S_DOWN && key_timer[k] < 12'd4095)
                        key_timer[k] <= key_timer[k] + 1'b1;
                    if (deb_timer[k] > 0)
                        deb_timer[k] <= deb_timer[k] - 1'b1;
                end
            end

            // Matrix Scan Evaluation
            if (scan_timer == SCAN_MAX) begin
                if (!is_colb) begin
                    top_sample <= row;
                end else begin
                    for (r = 0; r < 8; r = r + 1) begin
                        if (scan_key[r] < 25) begin
                            case (key_state[scan_key[r]])
                                S_IDLE: begin
                                    if (top_sample[r]) begin
                                        key_state[scan_key[r]] <= S_DOWN;
                                        key_timer[scan_key[r]] <= 12'd0;
                                    end
                                end

                                S_DOWN: begin
                                    if (row[r]) begin
                                        key_velocity[scan_key[r]]    <= calc_velocity(key_timer[scan_key[r]]);
                                        last_struck_key          <= scan_key[r];
                                        last_struck_velocity     <= calc_velocity(key_timer[scan_key[r]]);
                                        note_on_pending[scan_key[r]] <= 1'b1;
                                        key_state[scan_key[r]]       <= S_BOTTOM_DEB;
                                        deb_timer[scan_key[r]]       <= 8'd150;
                                    end else if (!top_sample[r]) begin
                                        key_state[scan_key[r]] <= S_IDLE;
                                    end
                                end

                                S_BOTTOM_DEB: begin
                                    if (deb_timer[scan_key[r]] == 0)
                                        key_state[scan_key[r]] <= S_HELD;
                                end

                                S_HELD: begin
                                    if (!row[r]) begin
                                        key_state[scan_key[r]] <= S_RELEASE;
                                    end
                                end

                                S_RELEASE: begin
                                    if (!top_sample[r]) begin
                                        note_off_pending[scan_key[r]] <= 1'b1;
                                        key_state[scan_key[r]]        <= S_IDLE;
                                    end else if (row[r]) begin
                                        key_state[scan_key[r]] <= S_HELD;
                                    end
                                end
                            endcase
                        end
                    end
                end
            end

            // Activity LED logic
            activity_led <= (key_state[0]  != S_IDLE) || (key_state[1]  != S_IDLE) ||
                            (key_state[2]  != S_IDLE) || (key_state[3]  != S_IDLE) ||
                            (key_state[4]  != S_IDLE) || (key_state[5]  != S_IDLE) ||
                            (key_state[6]  != S_IDLE) || (key_state[7]  != S_IDLE) ||
                            (key_state[8]  != S_IDLE) || (key_state[9]  != S_IDLE) ||
                            (key_state[10] != S_IDLE) || (key_state[11] != S_IDLE) ||
                            (key_state[12] != S_IDLE) || (key_state[13] != S_IDLE) ||
                            (key_state[14] != S_IDLE) || (key_state[15] != S_IDLE) ||
                            (key_state[16] != S_IDLE) || (key_state[17] != S_IDLE) ||
                            (key_state[18] != S_IDLE) || (key_state[19] != S_IDLE) ||
                            (key_state[20] != S_IDLE) || (key_state[21] != S_IDLE) ||
                            (key_state[22] != S_IDLE) || (key_state[23] != S_IDLE) ||
                            (key_state[24] != S_IDLE);

            // Clear pending bits
            if (fifo_wr_en) begin
                if (fifo_is_note_on)
                    note_on_pending[fifo_serviced_key]  <= 1'b0;
                else
                    note_off_pending[fifo_serviced_key] <= 1'b0;
            end
        end
    end

    // =========================================================================
    // 3b. ON-BOARD SYNTHESIZER (synth_engine.v -> Pmod AMP2)
    //     A key sounds while it is down: from the bottom contact closing
    //     (note-on) until the top contact opens (note-off), same as MIDI.
    // =========================================================================
    wire [24:0]     key_gate;
    wire [25*7-1:0] key_vel_bus;

    genvar g;
    generate
        for (g = 0; g < 25; g = g + 1) begin : g_keys
            assign key_gate[g] = (key_state[g] == S_BOTTOM_DEB) ||
                                 (key_state[g] == S_HELD) ||
                                 (key_state[g] == S_RELEASE);
            assign key_vel_bus[g*7 +: 7] = key_velocity[g];
        end
    endgenerate

    // ADSR settings. Sample rate Fs = CLK_HZ / 2048 = 48.828 kHz.
    // A rate is 2^20 / (tau_seconds * Fs), i.e. 21.47 s / tau.  Attack and
    // release take about 1.6 x tau to finish.
    localparam [15:0] ADSR_ATTACK  = 16'd7158;  // tau   3 ms
    localparam [15:0] ADSR_DECAY   = 16'd54;    // tau 400 ms
    localparam [7:0]  ADSR_SUSTAIN = 8'd153;    // 60 % of peak
    localparam [15:0] ADSR_RELEASE = 16'd86;    // tau 250 ms

    // Waveform button: sampled every 10 ms (debounce), each press steps
    // 0 saw -> 1 square -> 2 triangle -> 3 pluck (Karplus-Strong) -> 0
    localparam BTN_CLKS = CLK_HZ / 100;
    localparam BTN_W    = $clog2(BTN_CLKS);
    reg [BTN_W-1:0] btn_timer;
    reg [1:0]       btn_sync;
    reg             btn_prev;
    reg [1:0]       wave_sel;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            btn_timer <= {BTN_W{1'b0}};
            btn_sync  <= 2'b00;
            btn_prev  <= 1'b0;
            wave_sel  <= 2'd0;
        end else begin
            btn_sync <= {btn_sync[0], wave_btn};
            if (btn_timer == BTN_CLKS - 1) begin
                btn_timer <= {BTN_W{1'b0}};
                btn_prev  <= btn_sync[1];
                if (btn_sync[1] && !btn_prev)
                    wave_sel <= wave_sel + 1'b1;   // wraps 3 -> 0
            end else begin
                btn_timer <= btn_timer + 1'b1;
            end
        end
    end

    wire signed [15:0] synth_sample;

    synth_engine #(
        .SAMPLE_DIV (2048),   // pitch table in synth_engine.v assumes 100 MHz / 2048
        .MIX_SHIFT  (2)       // ~4 full-volume notes before clipping
    ) u_synth (
        .clk           (clk),
        .reset         (reset),
        .gate          (key_gate),
        .velocity      (key_vel_bus),
        .wave_sel      (wave_sel),
        .attack_rate   (ADSR_ATTACK),
        .decay_rate    (ADSR_DECAY),
        .sustain_level (ADSR_SUSTAIN),
        .release_rate  (ADSR_RELEASE),
        .audio_out     (amp_ain),
        .sample        (synth_sample)
    );

    assign amp_gain       = 1'b0;   // AMP2 gain select (check manual for which level is lower gain)
    assign amp_shutdown_n = 1'b1;   // amplifier always on

    // =========================================================================
    // 4. MIDI FIFO
    // =========================================================================
    reg [15:0] fifo_mem [0:15];
    reg [3:0]  fifo_wr_ptr;
    reg [3:0]  fifo_rd_ptr;
    reg [4:0]  fifo_count;
    reg [4:0]  q_scan;

    // Program Change: when BTN1 changes the waveform, send a General MIDI
    // instrument that sounds like it, so a PC synth (midi_synth.py) follows
    // along.  Also sent once after reset.  If BTN1 is pressed again before
    // the message is queued, only the newest waveform is sent.
    localparam [6:0] PROG_SAW      = 7'd81;  // GM 82 Lead 2 (sawtooth)
    localparam [6:0] PROG_SQUARE   = 7'd80;  // GM 81 Lead 1 (square)
    localparam [6:0] PROG_TRIANGLE = 7'd79;  // GM 80 Ocarina (soft, nearly pure tone)
    localparam [6:0] PROG_PLUCK    = 7'd24;  // GM 25 Acoustic Guitar (nylon)

    wire [6:0] wave_prog = (wave_sel == 2'd0) ? PROG_SAW :
                           (wave_sel == 2'd1) ? PROG_SQUARE :
                           (wave_sel == 2'd2) ? PROG_TRIANGLE : PROG_PLUCK;

    reg        prog_valid;   // a Program Change has been queued since reset
    reg [1:0]  prog_sent;    // wave_sel it was queued for
    wire       prog_req = !prog_valid || (prog_sent != wave_sel);

    // FIFO memory write: no reset, so it can be distributed RAM.  An entry
    // is {is_prog, note_on, note, velocity}, or {1, 0, program, 0} for a
    // Program Change.  Priority: Program Change, then note-on, then note-off.
    always @(posedge clk) begin
        if (fifo_count < 16) begin
            if (prog_req)
                fifo_mem[fifo_wr_ptr] <= {2'b10, wave_prog, 7'd0};
            else if (note_on_pending[q_scan])
                fifo_mem[fifo_wr_ptr] <= {2'b01, 7'd36 + q_scan, key_velocity[q_scan]};
            else if (note_off_pending[q_scan])
                fifo_mem[fifo_wr_ptr] <= {2'b00, 7'd36 + q_scan, 7'd0};
        end
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            q_scan            <= 5'd0;
            fifo_wr_ptr       <= 4'd0;
            fifo_count        <= 5'd0;
            fifo_wr_en        <= 1'b0;
            fifo_serviced_key <= 5'd0;
            fifo_is_note_on   <= 1'b0;
            prog_valid        <= 1'b0;
            prog_sent         <= 2'd0;
        end else begin
            fifo_wr_en <= 1'b0;

            if (fifo_count < 16) begin
                if (prog_req) begin
                    // fifo_wr_en stays low: it clears a key's pending flag
                    fifo_wr_ptr <= fifo_wr_ptr + 1'b1;
                    fifo_count  <= fifo_count + 1'b1 - (fifo_rd_en ? 1'b1 : 1'b0);
                    prog_valid  <= 1'b1;
                    prog_sent   <= wave_sel;
                end else if (note_on_pending[q_scan]) begin
                    fifo_wr_ptr           <= fifo_wr_ptr + 1'b1;
                    fifo_count            <= fifo_count + 1'b1 - (fifo_rd_en ? 1'b1 : 1'b0);
                    fifo_wr_en            <= 1'b1;
                    fifo_serviced_key     <= q_scan;
                    fifo_is_note_on       <= 1'b1;
                end else if (note_off_pending[q_scan]) begin
                    fifo_wr_ptr           <= fifo_wr_ptr + 1'b1;
                    fifo_count            <= fifo_count + 1'b1 - (fifo_rd_en ? 1'b1 : 1'b0);
                    fifo_wr_en            <= 1'b1;
                    fifo_serviced_key     <= q_scan;
                    fifo_is_note_on       <= 1'b0;
                end else if (fifo_rd_en) begin
                    fifo_count <= fifo_count - 1'b1;
                end

                if (q_scan == 5'd24)
                    q_scan <= 5'd0;
                else
                    q_scan <= q_scan + 1'b1;
            end else if (fifo_rd_en) begin
                fifo_count <= fifo_count - 1'b1;
            end
        end
    end

    // =========================================================================
    // 5. MIDI UART TRANSMITTER
    // =========================================================================
    localparam TX_IDLE      = 2'd0;
    localparam TX_LOAD_BYTE = 2'd1;
    localparam TX_SEND_BITS = 2'd2;

    reg [1:0]        tx_state;
    reg [BAUD_W-1:0] baud_cnt;
    reg [3:0]        bit_idx;
    reg [1:0]        byte_idx;
    reg [9:0]        shift_reg;
    reg [7:0]        tx_packet [0:2];
    reg [1:0]        tx_last;     // index of the packet's last byte

    // Packet bytes, latched when a FIFO entry is taken: (status, note,
    // velocity) for notes, (status, program) for a Program Change, all on
    // channel 1.  No reset: they're only read after being loaded.
    always @(posedge clk) begin
        if (tx_state == TX_IDLE && fifo_count > 0) begin
            tx_packet[0] <= fifo_mem[fifo_rd_ptr][15] ? 8'hC0 :
                            fifo_mem[fifo_rd_ptr][14] ? 8'h90 : 8'h80;
            tx_packet[1] <= {1'b0, fifo_mem[fifo_rd_ptr][13:7]};
            tx_packet[2] <= {1'b0, fifo_mem[fifo_rd_ptr][6:0]};
            tx_last      <= fifo_mem[fifo_rd_ptr][15] ? 2'd1 : 2'd2;
        end
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            midi_tx     <= 1'b1;
            tx_state    <= TX_IDLE;
            baud_cnt    <= {BAUD_W{1'b0}};
            bit_idx     <= 4'd0;
            byte_idx    <= 2'd0;
            shift_reg   <= 10'h3FF;
            fifo_rd_ptr <= 4'd0;
            fifo_rd_en  <= 1'b0;
        end else begin
            fifo_rd_en <= 1'b0;

            case (tx_state)
                TX_IDLE: begin
                    midi_tx <= 1'b1;
                    if (fifo_count > 0) begin
                        fifo_rd_ptr  <= fifo_rd_ptr + 1'b1;
                        fifo_rd_en   <= 1'b1;
                        byte_idx     <= 2'd0;
                        tx_state     <= TX_LOAD_BYTE;
                    end
                end

                TX_LOAD_BYTE: begin
                    shift_reg <= {1'b1, tx_packet[byte_idx], 1'b0};
                    bit_idx   <= 4'd0;
                    baud_cnt  <= {BAUD_W{1'b0}};
                    tx_state  <= TX_SEND_BITS;
                end

                TX_SEND_BITS: begin
                    midi_tx <= shift_reg[0];
                    if (baud_cnt < BAUD_MAX) begin
                        baud_cnt <= baud_cnt + 1'b1;
                    end else begin
                        baud_cnt  <= {BAUD_W{1'b0}};
                        shift_reg <= {1'b1, shift_reg[9:1]};
                        if (bit_idx < 4'd9) begin
                            bit_idx <= bit_idx + 1'b1;
                        end else begin
                            if (byte_idx < tx_last) begin
                                byte_idx <= byte_idx + 1'b1;
                                tx_state <= TX_LOAD_BYTE;
                            end else begin
                                tx_state <= TX_IDLE;
                            end
                        end
                    end
                end
            endcase
        end
    end

    // =========================================================================
    // 6a. ILA SAMPLE QUALIFIER (decimated so 8192 samples span a whole key strike)
    //     Sample interval = ILA_DIV / CLK_HZ = 25 us (2500 clks @ 100 MHz).
    //     8192 samples x 25 us = 204.8 ms, which covers
    //     travel times up to 204.8 ms (key_timer itself saturates at 4095
    //     ticks x 100 us = 409.5 ms).  25 us is shorter than the 32 us scan step,
    //     so every scan phase still appears in at least one sample.
    //     The ILA is clocked directly from clk: it must see a free-running
    //     clock or Vivado reports "clock has stopped" and cannot arm it.  To
    //     get the decimated window, set Capture Mode = BASIC with the capture
    //     condition dbg_ila_ce == 1 in the Hardware Manager.  Single-clock
    //     pulses (fifo_wr_en) are stretched so they are not missed between
    //     samples.
    // =========================================================================
    localparam ILA_DIV = CLK_HZ / ILA_RATE_HZ;
    localparam ILA_W   = $clog2(ILA_DIV);
    localparam [ILA_W-1:0] ILA_MAX = ILA_DIV - 1;

    reg [ILA_W-1:0] ila_cnt           = {ILA_W{1'b0}};
    reg             ila_ce            = 1'b0;
    reg             fifo_wr_en_sticky = 1'b0;

    // Free-running (no reset) so reset events can be captured too
    always @(posedge clk) begin
        if (ila_cnt == ILA_MAX) begin
            ila_cnt <= {ILA_W{1'b0}};
            ila_ce  <= 1'b1;
        end else begin
            ila_cnt <= ila_cnt + 1'b1;
            ila_ce  <= 1'b0;
        end

        // Hold any fifo_wr_en pulse until the ILA has taken its next sample
        if (ila_ce)
            fifo_wr_en_sticky <= fifo_wr_en;
        else
            fifo_wr_en_sticky <= fifo_wr_en_sticky | fifo_wr_en;
    end

    // =========================================================================
    // 6b. ILA DEBUG PROBES (All explicitly declared and marked)
    // =========================================================================
    (* mark_debug = "true" *) wire [3:0] dbg_cola              = cola;
    (* mark_debug = "true" *) wire [3:0] dbg_colb              = colb;
    (* mark_debug = "true" *) wire [7:0] dbg_row               = row;
    (* mark_debug = "true" *) wire [7:0] dbg_top_sample        = top_sample;
    (* mark_debug = "true" *) wire [2:0] dbg_scan_phase        = scan_phase;
    (* mark_debug = "true" *) wire [1:0] dbg_active_col        = active_col;
    
    // Key 0 (Lowest Note: C2) state & timer for real-time contact monitoring
    (* mark_debug = "true" *) wire [2:0] dbg_key0_state        = key_state[0];
    (* mark_debug = "true" *) wire [11:0] dbg_key0_timer       = key_timer[0];
    
    // Most recently struck key and velocity
    (* mark_debug = "true" *) wire [4:0] dbg_last_struck_key   = last_struck_key;
    (* mark_debug = "true" *) wire [6:0] dbg_last_velocity     = last_struck_velocity;
    
    // FIFO & MIDI Events
    (* mark_debug = "true" *) wire        dbg_fifo_wr_en       = fifo_wr_en_sticky; // stretched to one ILA sample
    (* mark_debug = "true" *) wire        dbg_fifo_is_note_on  = fifo_is_note_on;
    (* mark_debug = "true" *) wire [4:0] dbg_fifo_count        = fifo_count;
    (* mark_debug = "true" *) wire [1:0] dbg_tx_state          = tx_state;
    (* mark_debug = "true" *) wire        dbg_midi_tx          = midi_tx;
    (* mark_debug = "true" *) wire        dbg_activity_led     = activity_led;

    // Capture qualifier: use as the ILA capture condition (see 6a)
    (* mark_debug = "true" *) wire        dbg_ila_ce           = ila_ce;

    // On-board synth: one strobe per audio sample (every 2048 clocks).
    // Capture condition dbg_synth_ce == 1 records the audio stream at 48.828 kHz.
    reg [10:0] synth_ce_cnt = 11'd0;
    reg        synth_ce     = 1'b0;
    always @(posedge clk) begin
        synth_ce_cnt <= synth_ce_cnt + 1'b1;
        synth_ce     <= (synth_ce_cnt == 11'd0);
    end
    (* mark_debug = "true" *) wire        dbg_synth_ce         = synth_ce;
    (* mark_debug = "true" *) wire [15:0] dbg_synth_sample     = synth_sample;
    (* mark_debug = "true" *) wire [1:0]  dbg_wave_sel         = wave_sel;

endmodule
