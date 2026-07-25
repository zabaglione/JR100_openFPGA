// Testbench: drive the real jr100_media_bridge RTL through a tape-record
// sector and a tape-play sector, with a host model that mimics
// io_bridge_peripheral's transaction timing (4-cycle read window, write
// pulses), and a client model with the registered-din behaviour of
// jr100_tape_buf. Reports any byte mismatch.

`timescale 1ns/1ps

module tb_media_bridge;

    logic clk = 0;      // 57.27 MHz-ish
    logic clk74 = 0;    // 74.25 MHz-ish
    always #8.73 clk = ~clk;
    always #6.73 clk74 = ~clk74;

    logic rst = 1;
    logic machine_rst = 0;

    // slot bookkeeping
    logic        req_wr = 0;
    logic [15:0] req_wr_id = 0;
    logic [31:0] req_wr_size = 0;
    logic        ds_update = 0;
    logic [15:0] ds_update_id = 0;
    logic [31:0] ds_update_size = 0;
    logic        allcomplete = 0;

    // save client (idle)
    logic [31:0] sd_lba = 0;
    logic        sd_wr = 0;
    logic        sd_ack;
    logic [7:0]  save_din = 0;

    // tape client
    logic [31:0] sd1_lba = 0;
    logic        sd1_rd = 0, sd1_wr = 0;
    logic        sd1_ack;
    logic [7:0]  tape_din;

    logic [8:0]  buff_addr;
    logic [7:0]  buff_dout;
    logic        buff_wr;

    // bridge
    logic [31:0] bridge_addr = 0;
    logic        bridge_wr = 0;
    logic [31:0] bridge_wr_data = 0;
    logic [31:0] bridge_rd_data;

    // target commands
    logic        t_read, t_write;
    logic [15:0] t_id;
    logic [31:0] t_offset, t_bridgeaddr, t_length;
    logic        t_ack = 0, t_done = 0;

    wire img_mounted, img_readonly, tape_mounted, tape_readonly;
    wire [63:0] img_size, tape_size;

jr100_media_bridge dut (
    .clk(clk), .rst(rst), .machine_rst(machine_rst), .clk_74a(clk74),
    .dataslot_requestwrite(req_wr),
    .dataslot_requestwrite_id(req_wr_id),
    .dataslot_requestwrite_size(req_wr_size),
    .dataslot_update(ds_update),
    .dataslot_update_id(ds_update_id),
    .dataslot_update_size(ds_update_size),
    .dataslot_allcomplete(allcomplete),
    .img_mounted(img_mounted), .img_readonly(img_readonly), .img_size(img_size),
    .sd_lba(sd_lba), .sd_wr(sd_wr), .sd_ack(sd_ack), .save_din(save_din),
    .tape_mounted(tape_mounted), .tape_readonly(tape_readonly), .tape_size(tape_size),
    .sd1_lba(sd1_lba), .sd1_rd(sd1_rd), .sd1_wr(sd1_wr), .sd1_ack(sd1_ack),
    .tape_din(tape_din),
    .buff_addr(buff_addr), .buff_dout(buff_dout), .buff_wr(buff_wr),
    .bridge_addr(bridge_addr), .bridge_wr(bridge_wr),
    .bridge_wr_data(bridge_wr_data), .bridge_rd_data(bridge_rd_data),
    .target_dataslot_read(t_read), .target_dataslot_write(t_write),
    .target_dataslot_id(t_id), .target_dataslot_slotoffset(t_offset),
    .target_dataslot_bridgeaddr(t_bridgeaddr), .target_dataslot_length(t_length),
    .target_dataslot_ack(t_ack), .target_dataslot_done(t_done),
    .target_dataslot_err(3'd0)
);

    // tape client: registered din, exactly like jr100_tape_buf
    byte unsigned sector[512];
    always @(posedge clk) tape_din <= sector[buff_addr];

    // capture of the playback strobes
    byte unsigned played[512];
    int played_cnt = 0;
    always @(posedge clk) if (buff_wr && sd1_ack) begin
        played[buff_addr] = buff_dout;
        played_cnt++;
    end

    // host "file"
    byte unsigned filebuf[512];

    // host model: services one target command per request
    initial begin : host
        forever begin
            @(posedge clk74);
            if (t_write) begin
                // ack, then burst-read 128 words with the peripheral's timing
                t_ack <= 1; @(posedge clk74); t_ack <= 0;
                for (int w = 0; w < 128; w++) begin
                    bridge_addr <= t_bridgeaddr + w*4;
                    repeat (4) @(posedge clk74);   // ST_READ_0 window
                    for (int b = 0; b < 4; b++)
                        filebuf[w*4 + b] = bridge_rd_data[8*(3-b) +: 8];
                    repeat (6) @(posedge clk74);   // inter-transaction gap
                end
                t_done <= 1; repeat (2) @(posedge clk74); t_done <= 0;
            end else if (t_read) begin
                t_ack <= 1; @(posedge clk74); t_ack <= 0;
                for (int w = 0; w < 128; w++) begin
                    bridge_addr <= t_bridgeaddr + w*4;
                    bridge_wr_data <= {filebuf[w*4], filebuf[w*4+1],
                                       filebuf[w*4+2], filebuf[w*4+3]};
                    @(posedge clk74);
                    bridge_wr <= 1;
                    @(posedge clk74);
                    bridge_wr <= 0;
                    repeat (4) @(posedge clk74);
                end
                t_done <= 1; repeat (2) @(posedge clk74); t_done <= 0;
            end
        end
    end

    int errors = 0;

    initial begin
        for (int i = 0; i < 512; i++) sector[i] = byte'((i * 7 + 3) & 8'hFF);

        repeat (10) @(posedge clk);
        rst = 0;
        repeat (10) @(posedge clk);

        // mount the tape (deferload update, id 4)
        @(posedge clk74); ds_update <= 1; ds_update_id <= 16'd4;
        ds_update_size <= 32'd65536;
        repeat (3) @(posedge clk74); ds_update <= 0;
        repeat (30) @(posedge clk);

        // ---- record one sector ----
        sd1_lba <= 32'd0;
        sd1_wr  <= 1;
        @(posedge clk iff sd1_ack);
        sd1_wr  <= 0;
        @(posedge clk iff !sd1_ack);
        repeat (20) @(posedge clk);

        for (int i = 0; i < 512; i++) begin
            if (filebuf[i] !== sector[i]) begin
                if (errors < 8)
                    $display("WRITE MISMATCH file[%0d]=%02x expect %02x",
                             i, filebuf[i], sector[i]);
                errors++;
            end
        end
        $display("record path: %s (%0d errors)", errors ? "FAIL" : "PASS", errors);

        // ---- play the sector back ----
        played_cnt = 0;
        sd1_rd <= 1;
        @(posedge clk iff sd1_ack);
        sd1_rd <= 0;
        @(posedge clk iff !sd1_ack);
        repeat (20) @(posedge clk);

        begin
            int rerrors = 0;
            if (played_cnt != 512)
                $display("play strobes: %0d (expect 512)", played_cnt);
            for (int i = 0; i < 512; i++) begin
                if (played[i] !== sector[i]) begin
                    if (rerrors < 8)
                        $display("READ MISMATCH byte[%0d]=%02x expect %02x",
                                 i, played[i], sector[i]);
                    rerrors++;
                end
            end
            $display("play path  : %s (%0d errors)", rerrors ? "FAIL" : "PASS",
                     rerrors);
            errors += rerrors;
        end

        if (errors == 0) $display("ALL PASS");
        $finish;
    end

    initial begin
        #4_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
