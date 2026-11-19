`timescale 1ns / 1ps
module tb_pluck;
    reg clk = 0, reset = 1;
    always #5 clk = ~clk;
    reg  [24:0] gate = 0;
    reg  [25*7-1:0] vel = 0;
    wire audio_out;
    wire signed [15:0] sample;
    synth_engine dut (.clk(clk), .reset(reset), .gate(gate), .velocity(vel),
        .wave_sel(2'd3), .attack_rate(16'd7182), .decay_rate(16'd2147),
        .sustain_level(8'd153), .release_rate(16'd2147),
        .audio_out(audio_out), .sample(sample));
    integer f, n = 0;
    initial begin
        f = $fopen("pluck_sim.txt", "w");
        vel[0*7 +: 7] = 7'd127; vel[9*7 +: 7] = 7'd40; vel[24*7 +: 7] = 7'd90;
        vel[12*7 +: 7] = 7'd1;
        #1000 reset = 0;
    end
    always @(posedge clk) if (!reset && dut.sample_cnt == 1000) begin
        $fwrite(f, "%0d %0d\n", gate, sample);    // gate used for this pass
        n = n + 1;
        case (n)
            100:   gate[0]  = 1;     // C2, vel 127
            2000:  gate[9]  = 1;     // A2, vel 40
            4000:  gate[24] = 1;     // C4, vel 90
            5000:  gate[12] = 1;     // C3, vel 1
            8000:  gate[0]  = 0;     // release C2
            9000:  gate[9]  = 0;
            9010:  gate[9]  = 1;     // re-strike A2 while it rings
            12000: gate = 0;
            14000: begin $fclose(f); $finish; end
        endcase
    end
endmodule
