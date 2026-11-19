`timescale 1ns / 1ps
module tb_synth;
    reg clk = 0, reset = 1;
    always #5 clk = ~clk;                 // 100 MHz
    reg  [24:0] gate = 0;
    reg  [25*7-1:0] vel = 0;
    reg  [1:0] wave_sel = 0;
    wire audio_out;
    wire signed [15:0] sample;

    synth_engine dut (.clk(clk), .reset(reset), .gate(gate), .velocity(vel),
        .wave_sel(wave_sel), .attack_rate(16'd7182), .decay_rate(16'd2147),
        .sustain_level(8'd128), .release_rate(16'd2147),
        .audio_out(audio_out), .sample(sample));

    integer f, ones = 0, n = 0;
    always @(posedge clk) begin
        if (!reset) begin
            ones = ones + ((dut.sd_cnt == 0) ? audio_out : 0);
            n = n + 1;
            if (n == 2048) begin
                $fwrite(f, "%0d %0d %0d %0d %0d %0d\n", $time, sample, dut.level[21], dut.stage[21], dut.level[9], ones);
                ones = 0; n = 0;
            end
        end
    end

    initial begin
        f = $fopen("samples.txt", "w");
        vel[21*7 +: 7] = 7'd127;
        vel[9*7  +: 7] = 7'd64;
        #1000 reset = 0;
        #1_000_000  gate[21] = 1;     // 1 ms: A3 (220 Hz) down, full velocity
        #19_000_000 gate[9]  = 1;     // 20 ms: A2 (110 Hz) down, half velocity
        #30_000_000 gate[21] = 0;     // 50 ms: release A3
        #20_000_000 gate[9]  = 0;     // 70 ms: release A2
        #20_000_000 wave_sel = 2; gate[21] = 1;   // 90 ms: A3 triangle
        #20_000_000 $fclose(f); $finish;
    end
endmodule
