`timescale 1ns / 1ps
// =============================================================================
// synth_engine: 25-voice synthesizer with per-voice ADSR and 1-bit audio out
//
//   One oscillator + one envelope per key (no voice allocation needed).
//   Every SAMPLE_DIV clocks (100 MHz / 2048 = 48.828 kHz) the engine walks
//   through all 25 voices, one after another, 6 clocks per voice:
//     - advance the voice's phase accumulator (sets the pitch)
//     - turn the phase into a waveform sample (saw / square / triangle)
//     - step the ADSR envelope toward its current target
//     - step the voice's plucked string (Karplus-Strong, below)
//     - scale the waveform (or string) by envelope level and key velocity
//     - add the result into the mix
//   The 16-bit mix drives a first-order sigma-delta modulator whose 1-bit
//   output goes to the Pmod AMP2 (its on-board filter turns it back into audio).
//
// ADSR (exponential, like an analog envelope):
//   Each sample, level += (target - level) * rate / 2^20
//   so the time constant is  tau = 2^20 / rate  samples  (= 21.47 s / rate).
//     Attack : target 1.25 x full scale; switch to Decay on reaching full scale
//     Decay  : target = sustain_level; stays here (= Sustain) while key is held
//     Release: target slightly below 0; voice goes idle when it reaches 0
//   Overshooting targets make attack and release finish in finite time.
//
// PLUCK (wave_sel 3, Karplus-Strong plucked string):
//   Each key has a delay line of N samples (one period) in a shared block RAM.
//     y[n] = sat16( g * (y[n-N] + y[n-N-1]) / 2  +  excitation )
//   The 2-point average makes the loop delay N + 0.5 samples and dulls the
//   tone a little on every pass, like a real string.  g sets the ring time:
//   G_HOLD (4 s at C2 .. 2 s at C4) while held, G_REL (0.12 s) after release.
//   A key press adds N samples of low-passed noise x 4: harder strikes use
//   brighter noise, and the output is scaled by (vel+1)/128 as for ADSR.
//   No envelope: the ADSR still runs, only to detect key presses.
//
// PITCH TABLE: phase_inc = f * 2^24 / Fs with Fs = 100 MHz / 2048.
//   If the clock or SAMPLE_DIV changes, the tables must be regenerated
//   (pluck tables: pluck_tables.py in the project folder).
// =============================================================================
module synth_engine #(
    parameter SAMPLE_DIV = 2048,  // clocks per audio sample (must be > 6*25 + 1)
    parameter MIX_SHIFT  = 3,     // mix / 2^MIX_SHIFT: ~8 full-volume notes before clipping
    parameter SD_DIV     = 4      // sigma-delta update every SD_DIV clocks (25 MHz)
)(
    input  wire              clk,
    input  wire              reset,
    input  wire [24:0]       gate,           // 1 = key k held
    input  wire [25*7-1:0]   velocity,       // key k velocity at [7k+6 : 7k]
    input  wire [1:0]        wave_sel,       // 0 saw, 1 square, 2 triangle, 3 pluck
    input  wire [15:0]       attack_rate,    // tau = 21.47 s / rate
    input  wire [15:0]       decay_rate,
    input  wire [7:0]        sustain_level,  // 0..255 = 0..100 % of peak
    input  wire [15:0]       release_rate,
    output reg               audio_out,      // 1-bit sigma-delta audio
    output reg signed [15:0] sample          // current mixed sample (for debug)
);

    localparam ST_IDLE    = 2'd0;
    localparam ST_ATTACK  = 2'd1;
    localparam ST_DECAY   = 2'd2;   // decays to, then holds at, sustain level
    localparam ST_RELEASE = 2'd3;

    localparam signed [26:0] FULL_SCALE     = 27'sh0FFFFFF;
    localparam signed [26:0] ATTACK_TARGET  = 27'sh13FFFFF;  // 1.25 x full scale
    localparam signed [26:0] RELEASE_TARGET = -27'sh0100000; // just below zero

    // ---------------------------------------------------------------------
    // Pitch table: keys 0..24 = MIDI notes 36..60 (C2..C4)
    // ---------------------------------------------------------------------
    function [23:0] phase_inc;
        input [4:0] key;
        begin
            case (key)
            5'd0 : phase_inc = 24'd22473; // note 36,   65.41 Hz
            5'd1 : phase_inc = 24'd23810; // note 37,   69.30 Hz
            5'd2 : phase_inc = 24'd25226; // note 38,   73.42 Hz
            5'd3 : phase_inc = 24'd26726; // note 39,   77.78 Hz
            5'd4 : phase_inc = 24'd28315; // note 40,   82.41 Hz
            5'd5 : phase_inc = 24'd29998; // note 41,   87.31 Hz
            5'd6 : phase_inc = 24'd31782; // note 42,   92.50 Hz
            5'd7 : phase_inc = 24'd33672; // note 43,   98.00 Hz
            5'd8 : phase_inc = 24'd35674; // note 44,  103.83 Hz
            5'd9 : phase_inc = 24'd37796; // note 45,  110.00 Hz
            5'd10: phase_inc = 24'd40043; // note 46,  116.54 Hz
            5'd11: phase_inc = 24'd42424; // note 47,  123.47 Hz
            5'd12: phase_inc = 24'd44947; // note 48,  130.81 Hz
            5'd13: phase_inc = 24'd47620; // note 49,  138.59 Hz
            5'd14: phase_inc = 24'd50451; // note 50,  146.83 Hz
            5'd15: phase_inc = 24'd53451; // note 51,  155.56 Hz
            5'd16: phase_inc = 24'd56630; // note 52,  164.81 Hz
            5'd17: phase_inc = 24'd59997; // note 53,  174.61 Hz
            5'd18: phase_inc = 24'd63565; // note 54,  185.00 Hz
            5'd19: phase_inc = 24'd67344; // note 55,  196.00 Hz
            5'd20: phase_inc = 24'd71349; // note 56,  207.65 Hz
            5'd21: phase_inc = 24'd75591; // note 57,  220.00 Hz
            5'd22: phase_inc = 24'd80086; // note 58,  233.08 Hz
            5'd23: phase_inc = 24'd84849; // note 59,  246.94 Hz
            5'd24: phase_inc = 24'd89894; // note 60,  261.63 Hz
            default: phase_inc = 24'd0;
            endcase
        end
    endfunction

    // ---------------------------------------------------------------------
    // Pluck tables (generated by pluck_tables.py): delay-line length N,
    // offset in the shared RAM, and loop gains (Q16) while held / released
    // ---------------------------------------------------------------------
    function [9:0] ks_len;
        input [4:0] key;
        begin
            case (key)
            5'd0 : ks_len = 10'd746;     5'd1 : ks_len = 10'd704;     5'd2 : ks_len = 10'd665;     5'd3 : ks_len = 10'd627;
            5'd4 : ks_len = 10'd592;     5'd5 : ks_len = 10'd559;     5'd6 : ks_len = 10'd527;     5'd7 : ks_len = 10'd498;
            5'd8 : ks_len = 10'd470;     5'd9 : ks_len = 10'd443;     5'd10: ks_len = 10'd418;     5'd11: ks_len = 10'd395;
            5'd12: ks_len = 10'd373;     5'd13: ks_len = 10'd352;     5'd14: ks_len = 10'd332;     5'd15: ks_len = 10'd313;
            5'd16: ks_len = 10'd296;     5'd17: ks_len = 10'd279;     5'd18: ks_len = 10'd263;     5'd19: ks_len = 10'd249;
            5'd20: ks_len = 10'd235;     5'd21: ks_len = 10'd221;     5'd22: ks_len = 10'd209;     5'd23: ks_len = 10'd197;
            5'd24: ks_len = 10'd186;
            default: ks_len = 10'd0;
            endcase
        end
    endfunction

    function [13:0] ks_base;
        input [4:0] key;
        begin
            case (key)
            5'd0 : ks_base = 14'd0;       5'd1 : ks_base = 14'd746;     5'd2 : ks_base = 14'd1450;    5'd3 : ks_base = 14'd2115;
            5'd4 : ks_base = 14'd2742;    5'd5 : ks_base = 14'd3334;    5'd6 : ks_base = 14'd3893;    5'd7 : ks_base = 14'd4420;
            5'd8 : ks_base = 14'd4918;    5'd9 : ks_base = 14'd5388;    5'd10: ks_base = 14'd5831;    5'd11: ks_base = 14'd6249;
            5'd12: ks_base = 14'd6644;    5'd13: ks_base = 14'd7017;    5'd14: ks_base = 14'd7369;    5'd15: ks_base = 14'd7701;
            5'd16: ks_base = 14'd8014;    5'd17: ks_base = 14'd8310;    5'd18: ks_base = 14'd8589;    5'd19: ks_base = 14'd8852;
            5'd20: ks_base = 14'd9101;    5'd21: ks_base = 14'd9336;    5'd22: ks_base = 14'd9557;    5'd23: ks_base = 14'd9766;
            5'd24: ks_base = 14'd9963;
            default: ks_base = 14'd0;
            endcase
        end
    endfunction

    function [15:0] ks_ghold;
        input [4:0] key;
        begin
            case (key)
            5'd0 : ks_ghold = 16'd63828;   5'd1 : ks_ghold = 16'd63877;   5'd2 : ks_ghold = 16'd63922;   5'd3 : ks_ghold = 16'd63969;
            5'd4 : ks_ghold = 16'd64012;   5'd5 : ks_ghold = 16'd64055;   5'd6 : ks_ghold = 16'd64098;   5'd7 : ks_ghold = 16'd64137;
            5'd8 : ks_ghold = 16'd64176;   5'd9 : ks_ghold = 16'd64216;   5'd10: ks_ghold = 16'd64254;   5'd11: ks_ghold = 16'd64289;
            5'd12: ks_ghold = 16'd64323;   5'd13: ks_ghold = 16'd64357;   5'd14: ks_ghold = 16'd64391;   5'd15: ks_ghold = 16'd64425;
            5'd16: ks_ghold = 16'd64454;   5'd17: ks_ghold = 16'd64486;   5'd18: ks_ghold = 16'd64517;   5'd19: ks_ghold = 16'd64543;
            5'd20: ks_ghold = 16'd64571;   5'd21: ks_ghold = 16'd64601;   5'd22: ks_ghold = 16'd64626;   5'd23: ks_ghold = 16'd64653;
            5'd24: ks_ghold = 16'd64677;
            default: ks_ghold = 16'd0;
            endcase
        end
    endfunction

    function [15:0] ks_grel;
        input [4:0] key;
        begin
            case (key)
            5'd0 : ks_grel = 16'd27181;   5'd1 : ks_grel = 16'd28561;   5'd2 : ks_grel = 16'd29905;   5'd3 : ks_grel = 16'd31275;
            5'd4 : ks_grel = 16'd32593;   5'd5 : ks_grel = 16'd33886;   5'd6 : ks_grel = 16'd35188;   5'd7 : ks_grel = 16'd36412;
            5'd8 : ks_grel = 16'd37634;   5'd9 : ks_grel = 16'd38852;   5'd10: ks_grel = 16'd40014;   5'd11: ks_grel = 16'd41113;
            5'd12: ks_grel = 16'd42194;   5'd13: ks_grel = 16'd43251;   5'd14: ks_grel = 16'd44283;   5'd15: ks_grel = 16'd45286;
            5'd16: ks_grel = 16'd46203;   5'd17: ks_grel = 16'd47139;   5'd18: ks_grel = 16'd48036;   5'd19: ks_grel = 16'd48836;
            5'd20: ks_grel = 16'd49648;   5'd21: ks_grel = 16'd50474;   5'd22: ks_grel = 16'd51194;   5'd23: ks_grel = 16'd51923;
            5'd24: ks_grel = 16'd52601;
            default: ks_grel = 16'd0;
            endcase
        end
    endfunction

    // total delay-line length 10149 of 16384

    // ---------------------------------------------------------------------
    // Per-voice state (small arrays: one read and one write per clock, so
    // Vivado can put them in distributed RAM)
    // ---------------------------------------------------------------------
    reg [23:0] phase [0:24];
    reg [23:0] level [0:24];
    reg [1:0]  stage [0:24];

    // Pluck state: read pointer, previous delay-line sample, noise samples
    // still to add, noise low-pass state
    reg [9:0]         ks_ptr  [0:24];
    reg signed [15:0] ks_prev [0:24];
    reg [9:0]         ks_exc  [0:24];
    reg signed [15:0] ks_lp   [0:24];

    // All 25 delay lines (10149 samples used): one block RAM
    reg signed [15:0] ks_mem [0:16383];

    integer i;
    initial begin
        for (i = 0; i < 25; i = i + 1) begin
            phase[i]   = 24'd0;
            level[i]   = 24'd0;
            stage[i]   = ST_IDLE;
            ks_ptr[i]  = 10'd0;
            ks_prev[i] = 16'sd0;
            ks_exc[i]  = 10'd0;
            ks_lp[i]   = 16'sd0;
        end
        for (i = 0; i < 16384; i = i + 1)
            ks_mem[i] = 16'sd0;
    end

    // ---------------------------------------------------------------------
    // Sample timer
    // ---------------------------------------------------------------------
    localparam DIV_W = $clog2(SAMPLE_DIV);
    reg [DIV_W-1:0] sample_cnt;

    always @(posedge clk or posedge reset) begin
        if (reset)
            sample_cnt <= {DIV_W{1'b0}};
        else if (sample_cnt == SAMPLE_DIV - 1)
            sample_cnt <= {DIV_W{1'b0}};
        else
            sample_cnt <= sample_cnt + 1'b1;
    end

    // ---------------------------------------------------------------------
    // Voice sequencer: 5 steps per voice, voices 0..24, then output the mix
    // ---------------------------------------------------------------------
    reg        busy;
    reg        out_pend;   // all voices done: output the mix next clock
    reg [4:0]  v;          // voice being processed
    reg [2:0]  step;
    reg [31:0] lfsr;       // noise for the pluck excitation

    reg [23:0]        p_ph, p_inc, p_lvl;
    reg [1:0]         p_stage;
    reg               p_gate;
    reg [6:0]         p_vel;
    reg signed [15:0] p_wave;
    reg signed [26:0] p_diff;
    reg [15:0]        p_rate;
    reg signed [23:0] p_step;    // (diff * rate) >> 20: envelope step
    reg signed [32:0] p_amp;     // wave * envelope
    reg signed [24:0] p_amp2;    // (wave * envelope) * velocity
    reg signed [21:0] mix;       // sum of 25 voices

    // Pluck pipeline registers
    reg [9:0]         p_ptr, p_len, p_exc;
    reg [13:0]        p_base;
    reg [15:0]        p_ghold, p_grel;
    reg signed [15:0] p_prev, p_lp, p_y;
    reg signed [14:0] p_noise;
    reg               p_note_on, p_excite;
    reg signed [15:0] p_lpd;     // ((noise - lp) * brightness) >> 7
    reg signed [33:0] p_fb;      // (y[n-N] + y[n-N-1]) * g
    reg signed [15:0] ks_rd;     // delay-line read data (y[n-N])

    // Next stage, envelope target, new level and triangle fold.
    // Combinational, from the pipeline registers, so no flip-flops are inferred.
    reg [1:0]         ns;
    reg signed [26:0] target;
    reg signed [26:0] new_lvl;
    reg [15:0]        t_tri;

    always @(*) begin
        ns = p_stage;
        if (p_gate && (p_stage == ST_IDLE || p_stage == ST_RELEASE))
            ns = ST_ATTACK;                         // key pressed
        else if (!p_gate && (p_stage == ST_ATTACK || p_stage == ST_DECAY))
            ns = ST_RELEASE;                        // key released

        case (ns)
            ST_ATTACK:  target = ATTACK_TARGET;
            ST_DECAY:   target = {3'b000, sustain_level, 16'h0000};
            ST_RELEASE: target = RELEASE_TARGET;
            default:    target = 27'sd0;
        endcase

        t_tri   = p_ph[23] ? ~p_ph[22:7] : p_ph[22:7];
        new_lvl = $signed({3'b000, p_lvl}) + p_step;
    end

    // Pluck: noise brightness (16..127 / 128, harder = brighter), loop gain,
    // and the new string sample y with the excitation added and saturated
    wire [9:0]         ks_vel7   = p_vel * 10'd7;
    wire [7:0]         ks_bright = 8'd16 + ks_vel7[9:3];
    wire [15:0]        ks_g      = p_gate ? p_ghold : p_grel;
    wire signed [19:0] ks_sum    = (p_fb >>> 17) + (p_excite ? (p_lp <<< 2) : 20'sd0);
    wire signed [15:0] ks_y      = (ks_sum > 20'sd32767)  ?  16'sd32767 :
                                   (ks_sum < -20'sd32768) ? -16'sd32768 : ks_sum[15:0];
    wire [13:0]        ks_addr   = p_base + p_ptr;
    // |noise - lp| * 127 < 2^22, so bits 22:7 hold the whole >> 7 result
    wire signed [25:0] ks_lp_prod = ($signed({p_noise[14], p_noise}) - p_lp) * $signed({1'b0, ks_bright});

    // Delay-line RAM: read y[n-N] in step 1, write y[n] back in step 3
    always @(posedge clk) begin
        if (busy && step == 3'd3)
            ks_mem[ks_addr] <= ks_y;
        if (busy && step == 3'd1)
            ks_rd <= ks_mem[ks_addr];
    end

    // Control: sequencer counters, the mix and the output sample (reset)
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            busy     <= 1'b0;
            out_pend <= 1'b0;
            v        <= 5'd0;
            step     <= 3'd0;
            mix      <= 22'sd0;
            sample   <= 16'sd0;
            lfsr     <= 32'hACE1ACE1;
        end else if (!busy) begin
            if (out_pend) begin
                // Output the finished mix, with clipping
                out_pend <= 1'b0;
                if ((mix >>> MIX_SHIFT) > 22'sd32767)
                    sample <= 16'sd32767;
                else if ((mix >>> MIX_SHIFT) < -22'sd32768)
                    sample <= -16'sd32768;
                else
                    sample <= mix >>> MIX_SHIFT;
            end else if (sample_cnt == 0) begin
                busy <= 1'b1;
                v    <= 5'd0;
                step <= 3'd0;
                mix  <= 22'sd0;
            end
        end else if (step == 3'd5) begin
            // Step 5: add to the mix; next voice or finish
            mix  <= mix + (p_amp2 >>> 7);
            step <= 3'd0;
            if (v == 5'd24) begin
                busy     <= 1'b0;
                out_pend <= 1'b1;   // output the mix on the next clock
            end else begin
                v <= v + 1'b1;
            end
        end else begin
            if (step == 3'd0)       // one noise value per voice
                lfsr <= {1'b0, lfsr[31:1]} ^ (lfsr[0] ? 32'h80200003 : 32'h0);
            step <= step + 1'b1;
        end
    end

    // Envelope step product; only bits 43:20 are kept (the >> 20)
    wire signed [43:0] env_prod = p_diff * $signed({1'b0, p_rate});

    // Datapath: pipeline registers and per-voice state.  No reset, so these
    // are plain flip-flops and distributed RAM; they only change while busy.
    always @(posedge clk) begin
        if (busy) begin
            case (step)
            // Step 0: fetch this voice's state
            3'd0: begin
                p_ph    <= phase[v];
                p_lvl   <= level[v];
                p_stage <= stage[v];
                p_inc   <= phase_inc(v);
                p_gate  <= gate[v];
                p_vel   <= velocity[v*7 +: 7];
                p_ptr   <= ks_ptr[v];
                p_prev  <= ks_prev[v];
                p_exc   <= ks_exc[v];
                p_lp    <= ks_lp[v];
                p_len   <= ks_len(v);
                p_base  <= ks_base(v);
                p_ghold <= ks_ghold(v);
                p_grel  <= ks_grel(v);
                p_noise <= lfsr[14:0];
            end

            // Step 1: envelope stage change + target; waveform from phase
            3'd1: begin
                case (ns)
                    ST_ATTACK:  p_rate <= attack_rate;
                    ST_DECAY:   p_rate <= decay_rate;
                    ST_RELEASE: p_rate <= release_rate;
                    default:    p_rate <= 16'd0;
                endcase
                p_stage <= ns;
                p_diff  <= target - $signed({3'b000, p_lvl});

                case (wave_sel)
                    2'd1:    p_wave <= p_ph[23] ? -16'sd16384 : 16'sd16384;  // square (half amplitude: it's loud)
                    2'd2:    p_wave <= $signed({~t_tri[15], t_tri[14:0]});  // triangle
                    default: p_wave <= $signed(p_ph[23:8]);                  // sawtooth
                endcase

                // Pluck: key press (ADSR entering attack), noise low-pass step
                p_note_on <= (ns == ST_ATTACK) && (p_stage != ST_ATTACK);
                p_lpd     <= ks_lp_prod[22:7];
            end

            // Step 2: the multiplies
            3'd2: begin
                p_step <= env_prod[43:20];
                p_amp  <= p_wave * $signed({1'b0, p_lvl[23:8]});

                // Pluck: loop filter and gain; excitation counter
                p_fb     <= (ks_rd + p_prev) * $signed({1'b0, ks_g});
                p_lp     <= p_lp + p_lpd;
                p_excite <= p_note_on || (p_exc != 10'd0);
                p_exc    <= p_note_on ? p_len - 1'b1 :
                            (p_exc != 10'd0) ? p_exc - 1'b1 : 10'd0;
            end

            // Step 3: update envelope and pluck string, write state back
            3'd3: begin
                case (p_stage)
                    ST_ATTACK:
                        if (new_lvl >= FULL_SCALE) begin
                            level[v] <= FULL_SCALE[23:0];
                            stage[v] <= ST_DECAY;
                        end else begin
                            level[v] <= new_lvl[23:0];
                            stage[v] <= ST_ATTACK;
                        end
                    ST_DECAY: begin
                        level[v] <= (new_lvl < 0) ? 24'd0 :
                                    (new_lvl > FULL_SCALE) ? FULL_SCALE[23:0] : new_lvl[23:0];
                        stage[v] <= ST_DECAY;
                    end
                    ST_RELEASE:
                        if (new_lvl <= 0) begin
                            level[v] <= 24'd0;
                            stage[v] <= ST_IDLE;
                        end else begin
                            level[v] <= new_lvl[23:0];
                            stage[v] <= ST_RELEASE;
                        end
                    default: begin
                        level[v] <= 24'd0;
                        stage[v] <= ST_IDLE;
                    end
                endcase
                phase[v] <= p_ph + p_inc;

                // Pluck: y[n] is written to the RAM (above); save the state
                p_y        <= ks_y;
                ks_ptr[v]  <= (p_ptr == p_len - 1'b1) ? 10'd0 : p_ptr + 1'b1;
                ks_prev[v] <= ks_rd;
                ks_exc[v]  <= p_exc;
                ks_lp[v]   <= p_lp;
            end

            // Step 4: velocity gain (vel+1)/128: 1 -> 1.6 %, 127 -> 100 %
            3'd4:
                p_amp2 <= $signed((wave_sel == 2'd3) ? p_y : p_amp[31:16]) *
                          $signed({1'b0, p_vel} + 9'd1);

            default: ;
            endcase
        end
    end

    // ---------------------------------------------------------------------
    // First-order sigma-delta DAC: density of 1s follows the sample value
    // (0 -> 50 % ones = silence).  
    // This means: “a sample of 0 gives 50% ones, which is silence.”
    // The AMP2's low-pass filter does the rest.
    // ---------------------------------------------------------------------
    localparam SD_W = (SD_DIV > 1) ? $clog2(SD_DIV) : 1;
    reg [SD_W-1:0] sd_cnt;
    reg [16:0]     sd_acc;
    wire [15:0]    sd_in = {~sample[15], sample[14:0]};   // signed -> offset binary

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            sd_cnt    <= {SD_W{1'b0}};
            sd_acc    <= 17'd0;
            audio_out <= 1'b0;
        end else begin
            sd_cnt <= (sd_cnt == SD_DIV - 1) ? {SD_W{1'b0}} : sd_cnt + 1'b1;
            if (sd_cnt == 0) begin
                sd_acc    <= {1'b0, sd_acc[15:0]} + {1'b0, sd_in};
                audio_out <= sd_acc[16];
            end
        end
    end

endmodule
