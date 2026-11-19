`timescale 1ns / 1ps

// Drives nollama_top from a 100 MHz clock, models the key matrix and the
// waveform button (BTN1), decodes midi_tx as a 31,250 baud UART and checks
// the MIDI bytes: Note On/Off with velocity, and Program Change from BTN1.
// Expected velocities come from velocity_curve.py (2 ms -> 127, 400 ms -> 1),
// allowing about +/-0.3 ms for where the strike falls in the scan cycle.
module tb_nollama_top;

    localparam real BIT_NS = 32000.0;

    // Program Change numbers sent for each waveform (see nollama_top.v section 4)
    localparam [7:0] PROG_SAW      = 8'd81;
    localparam [7:0] PROG_SQUARE   = 8'd80;
    localparam [7:0] PROG_TRIANGLE = 8'd79;
    localparam [7:0] PROG_PLUCK    = 8'd24;

    reg         clk   = 1'b0;
    reg         btn   = 1'b1;    // reset held at start: the design has no power-up reset in simulation
    reg         wbtn  = 1'b0;    // BTN1, waveform select
    reg  [24:0] top   = 25'd0;   // top (break) contacts, indexed by key
    reg  [24:0] bot   = 25'd0;   // bottom (make) contacts
    wire [3:0]  cola, colb;
    reg  [7:0]  row;
    wire        tx, led, heartbeat, amp_ain, amp_gain, amp_shutdown_n;

    always #5 clk = ~clk;        // 100 MHz

    nollama_top dut (.clk(clk), .reset_btn(btn), .cola(cola), .colb(colb),
                     .row(row), .midi_tx(tx), .activity_led(led),
                     .heartbeat_led(heartbeat), .wave_btn(wbtn), .amp_ain(amp_ain),
                     .amp_gain(amp_gain), .amp_shutdown_n(amp_shutdown_n));

    // Key matrix: a closed contact connects the driven column to its row
    integer c, r, key;
    always @* begin
        row = 8'd0;
        for (c = 0; c < 4; c = c + 1)
            for (r = 0; r < 8; r = r + 1) begin
                key = c * 8 + r;
                if (key < 25 && ((cola[c] && top[key]) || (colb[c] && bot[key])))
                    row[r] = 1'b1;
            end
    end

    // UART receiver
    reg [7:0] rx [0:255];
    integer   rx_n = 0, framing_errors = 0, i;
    reg [7:0] b;
    always @(negedge tx) if (tx === 1'b0 && dut.reset === 1'b0) begin
        #(BIT_NS * 1.5);
        for (i = 0; i < 8; i = i + 1) begin
            b[i] = tx;
            #(BIT_NS);
        end
        if (tx !== 1'b1) framing_errors = framing_errors + 1;
        rx[rx_n] = b;
        rx_n = rx_n + 1;
    end

    integer passed = 0, failed = 0, rd = 0;

    task check(input ok, input [8*48-1:0] what);
        begin
            if (ok) begin passed = passed + 1; $display("  PASS  %0s", what); end
            else    begin failed = failed + 1; $display("  FAIL  %0s", what); end
        end
    endtask

    // Check the next three received bytes (Note On / Note Off)
    task expect_msg(input [7:0] status, input [7:0] note, input integer vmin, input integer vmax,
                    input [8*48-1:0] what);
        begin
            if (rx_n < rd + 3) begin
                check(1'b0, what);
                $display("        only %0d new byte(s)", rx_n - rd);
            end else begin
                $display("        got %02x %02x %02x", rx[rd], rx[rd+1], rx[rd+2]);
                check(rx[rd] == status && rx[rd+1] == note && rx[rd+2] >= vmin && rx[rd+2] <= vmax, what);
                rd = rd + 3;
            end
        end
    endtask

    // Check the next two received bytes (Program Change, channel 1)
    task expect_prog(input [7:0] program, input [8*48-1:0] what);
        begin
            if (rx_n < rd + 2) begin
                check(1'b0, what);
                $display("        only %0d new byte(s)", rx_n - rd);
            end else begin
                $display("        got %02x %02x", rx[rd], rx[rd+1]);
                check(rx[rd] == 8'hC0 && rx[rd+1] == program, what);
                rd = rd + 2;
            end
        end
    endtask

    task strike(input integer k, input real gap_ms);
        begin
            top[k] = 1'b1;
            #(gap_ms * 1e6);
            bot[k] = 1'b1;
            #3e6;
        end
    endtask

    task release_key(input integer k);
        begin
            #20e6;
            bot[k] = 1'b0;
            #5e6;
            top[k] = 1'b0;
            #3e6;
        end
    endtask

    // BTN1 is sampled every 10 ms, so hold it well past one sample
    task press_wave;
        begin
            wbtn = 1'b1;
            #30e6;
            wbtn = 1'b0;
            #30e6;
        end
    endtask

    realtime t0, t1;
    integer  n;
    reg      seen0, seen9, seen24;

    initial begin
        $timeformat(-6, 1, " us", 10);

        $display("--- Reset and timing");
        #1000;
        btn = 1'b0;
        #2e6;
        expect_prog(PROG_SAW, "Program Change saw after reset");
        check(dut.wave_sel == 2'd0, "waveform starts at saw");
        @(posedge dut.tick_100us); t0 = $realtime;
        @(posedge dut.tick_100us); t1 = $realtime;
        check(t1 - t0 > 99990 && t1 - t0 < 100010, "tick is 100 us");
        @(posedge cola[1]); t0 = $realtime;
        @(posedge colb[1]); t1 = $realtime;
        check(t1 - t0 > 31990 && t1 - t0 < 32010, "scan step is 32 us");

        $display("--- Reset button");
        press_wave;                     // move off saw so reset has something to undo
        expect_prog(PROG_SQUARE, "Program Change square");
        btn = 1'b1;
        #1000;
        check(dut.reset === 1'b1, "button asserts reset");
        check(tx === 1'b1, "MIDI line idle during reset");
        btn = 1'b0;
        #2e6;
        check(dut.wave_sel == 2'd0, "reset returns waveform to saw");
        expect_prog(PROG_SAW, "Program Change saw after reset button");

        $display("--- Key 0, 5 ms strike");
        fork begin @(negedge tx); t0 = $realtime; @(posedge tx); t1 = $realtime; end
             strike(0, 5.0); join
        $display("        status byte first low pulse %f us", (t1 - t0) / 1000);
        check(t1 - t0 > 159900 && t1 - t0 < 160100, "MIDI bit time is 32 us (31,250 baud)");
        expect_msg(8'h90, 8'h24, 104, 107, "Note On C2, velocity for 5 ms");
        check(led === 1'b1, "activity LED on while held");
        release_key(0);
        expect_msg(8'h80, 8'h24, 0, 0, "Note Off C2");
        check(led === 1'b0, "activity LED off after release");

        $display("--- Other keys and velocity range");
        strike(10, 20.0);
        expect_msg(8'h90, 8'h2e, 72, 73, "Note On key 10, velocity for 20 ms");
        release_key(10);
        expect_msg(8'h80, 8'h2e, 0, 0, "Note Off key 10");
        strike(24, 0.5);
        expect_msg(8'h90, 8'h3c, 127, 127, "Note On key 24, fastest strike = 127");
        release_key(24);
        expect_msg(8'h80, 8'h3c, 0, 0, "Note Off key 24");
        strike(17, 95.0);
        expect_msg(8'h90, 8'h35, 35, 35, "Note On key 17, velocity for 95 ms");
        release_key(17);
        expect_msg(8'h80, 8'h35, 0, 0, "Note Off key 17");
        strike(5, 450.0);
        expect_msg(8'h90, 8'h29, 1, 1, "Note On key 5, slowest strike = 1");
        release_key(5);
        expect_msg(8'h80, 8'h29, 0, 0, "Note Off key 5");

        $display("--- Partial press sends nothing");
        n = rx_n;
        top[7] = 1'b1; #10e6; top[7] = 1'b0; #5e6;
        check(rx_n == n, "top contact alone sends no MIDI");
        check(led === 1'b0, "FSM back to idle after partial press");

        $display("--- Contact bounce");
        top[12] = 1'b1; #5e6;
        repeat (4) begin bot[12] = 1'b1; #300e3; bot[12] = 1'b0; #300e3; end
        bot[12] = 1'b1; #5e6;
        expect_msg(8'h90, 8'h30, 1, 127, "bouncing make contact gives one Note On");
        check(rx_n == rd, "no duplicate Note On");
        #20e6;
        repeat (4) begin bot[12] = 1'b0; #300e3; bot[12] = 1'b1; #300e3; end
        bot[12] = 1'b0; #5e6;
        repeat (4) begin top[12] = 1'b0; #300e3; top[12] = 1'b1; #300e3; end
        top[12] = 1'b0; #5e6;
        expect_msg(8'h80, 8'h30, 0, 0, "bouncing release gives a Note Off");
        check(rx_n == rd, "no duplicate Note Off");

        $display("--- Three-note chord");
        top[0] = 1'b1; top[9] = 1'b1; top[24] = 1'b1; #5e6;
        bot[0] = 1'b1; bot[9] = 1'b1; bot[24] = 1'b1; #5e6;
        seen0 = 0; seen9 = 0; seen24 = 0;
        check(rx_n == rd + 9, "three Note Ons");
        for (n = rd; n + 2 < rx_n; n = n + 3) begin
            $display("        got %02x %02x %02x", rx[n], rx[n+1], rx[n+2]);
            if (rx[n] == 8'h90 && rx[n+1] == 8'h24) seen0  = 1;
            if (rx[n] == 8'h90 && rx[n+1] == 8'h2d) seen9  = 1;
            if (rx[n] == 8'h90 && rx[n+1] == 8'h3c) seen24 = 1;
        end
        check(seen0 && seen9 && seen24, "chord notes correct");
        rd = rx_n;
        bot[0] = 1'b0; bot[9] = 1'b0; bot[24] = 1'b0; #2e6;
        top[0] = 1'b0; top[9] = 1'b0; top[24] = 1'b0; #5e6;
        // Released inside the 15 ms bottom-contact debounce, so Note Off must wait for it
        check(rx_n == rd, "no Note Off during 15 ms debounce");
        #10e6;
        check(rx_n == rd + 9, "three Note Offs after debounce");
        rd = rx_n;

        $display("--- Waveform button (BTN1) sends Program Change");
        press_wave;
        check(dut.wave_sel == 2'd1, "BTN1 selects square");
        expect_prog(PROG_SQUARE, "Program Change square");
        press_wave;
        check(dut.wave_sel == 2'd2, "BTN1 selects triangle");
        expect_prog(PROG_TRIANGLE, "Program Change triangle");
        strike(3, 5.0);
        expect_msg(8'h90, 8'h27, 104, 107, "Note On key 3 before BTN1");
        press_wave;
        check(dut.wave_sel == 2'd3, "BTN1 selects pluck while key held");
        expect_prog(PROG_PLUCK, "Program Change pluck while key held");
        release_key(3);
        expect_msg(8'h80, 8'h27, 0, 0, "Note Off key 3 after BTN1");
        press_wave;
        check(dut.wave_sel == 2'd0, "BTN1 wraps from pluck to saw");
        expect_prog(PROG_SAW, "Program Change saw after wrap");
        wbtn = 1'b1; #100e6; wbtn = 1'b0; #30e6;
        check(dut.wave_sel == 2'd1, "holding BTN1 steps once");
        expect_prog(PROG_SQUARE, "Program Change square after long press");
        check(rx_n == rd, "only one Program Change for a long press");

        check(framing_errors == 0, "no UART framing errors");

        $display("=== %0d passed, %0d failed, %0d MIDI bytes, sim time %t", passed, failed, rx_n, $realtime);
        if (failed == 0) $display("=== RESULT: PASS"); else $display("=== RESULT: FAIL");
        $finish;
    end

    initial begin
        #2000e6;
        $display("=== RESULT: TIMEOUT");
        $finish;
    end

endmodule
