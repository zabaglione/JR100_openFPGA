//
// JR-100 for Analogue Pocket - user core top level
//
// Instantiated by the real top level, apf_top.
//
// The JR-100 machine itself lives in ../jr100 and is used unmodified; this
// file is the APF adapter that replaces the MiSTer 'emu' wrapper.
//
// Derived from open-fpga/core-template (Analogue).
//
// Copyright (C) 2026 Zabaglione
// SPDX-License-Identifier: GPL-2.0-or-later
//

`default_nettype none

module core_top (

//
// physical connections
//

///////////////////////////////////////////////////
// clock inputs 74.25mhz. not phase aligned, so treat these domains as asynchronous

input   wire            clk_74a, // mainclk1
input   wire            clk_74b, // mainclk1

///////////////////////////////////////////////////
// cartridge interface
// switches between 3.3v and 5v mechanically
// output enable for multibit translators controlled by pic32

// GBA AD[15:8]
inout   wire    [7:0]   cart_tran_bank2,
output  wire            cart_tran_bank2_dir,

// GBA AD[7:0]
inout   wire    [7:0]   cart_tran_bank3,
output  wire            cart_tran_bank3_dir,

// GBA A[23:16]
inout   wire    [7:0]   cart_tran_bank1,
output  wire            cart_tran_bank1_dir,

// GBA [7] PHI#
// GBA [6] WR#
// GBA [5] RD#
// GBA [4] CS1#/CS#
//     [3:0] unwired
inout   wire    [7:4]   cart_tran_bank0,
output  wire            cart_tran_bank0_dir,

// GBA CS2#/RES#
inout   wire            cart_tran_pin30,
output  wire            cart_tran_pin30_dir,
// when GBC cart is inserted, this signal when low or weak will pull GBC /RES low with a special circuit
// the goal is that when unconfigured, the FPGA weak pullups won't interfere.
// thus, if GBC cart is inserted, FPGA must drive this high in order to let the level translators
// and general IO drive this pin.
output  wire            cart_pin30_pwroff_reset,

// GBA IRQ/DRQ
inout   wire            cart_tran_pin31,
output  wire            cart_tran_pin31_dir,

// infrared
input   wire            port_ir_rx,
output  wire            port_ir_tx,
output  wire            port_ir_rx_disable,

// GBA link port
inout   wire            port_tran_si,
output  wire            port_tran_si_dir,
inout   wire            port_tran_so,
output  wire            port_tran_so_dir,
inout   wire            port_tran_sck,
output  wire            port_tran_sck_dir,
inout   wire            port_tran_sd,
output  wire            port_tran_sd_dir,

///////////////////////////////////////////////////
// cellular psram 0 and 1, two chips (64mbit x2 dual die per chip)

output  wire    [21:16] cram0_a,
inout   wire    [15:0]  cram0_dq,
input   wire            cram0_wait,
output  wire            cram0_clk,
output  wire            cram0_adv_n,
output  wire            cram0_cre,
output  wire            cram0_ce0_n,
output  wire            cram0_ce1_n,
output  wire            cram0_oe_n,
output  wire            cram0_we_n,
output  wire            cram0_ub_n,
output  wire            cram0_lb_n,

output  wire    [21:16] cram1_a,
inout   wire    [15:0]  cram1_dq,
input   wire            cram1_wait,
output  wire            cram1_clk,
output  wire            cram1_adv_n,
output  wire            cram1_cre,
output  wire            cram1_ce0_n,
output  wire            cram1_ce1_n,
output  wire            cram1_oe_n,
output  wire            cram1_we_n,
output  wire            cram1_ub_n,
output  wire            cram1_lb_n,

///////////////////////////////////////////////////
// sdram, 512mbit 16bit

output  wire    [12:0]  dram_a,
output  wire    [1:0]   dram_ba,
inout   wire    [15:0]  dram_dq,
output  wire    [1:0]   dram_dqm,
output  wire            dram_clk,
output  wire            dram_cke,
output  wire            dram_ras_n,
output  wire            dram_cas_n,
output  wire            dram_we_n,

///////////////////////////////////////////////////
// sram, 1mbit 16bit

output  wire    [16:0]  sram_a,
inout   wire    [15:0]  sram_dq,
output  wire            sram_oe_n,
output  wire            sram_we_n,
output  wire            sram_ub_n,
output  wire            sram_lb_n,

///////////////////////////////////////////////////
// vblank driven by dock for sync in a certain mode

input   wire            vblank,

///////////////////////////////////////////////////
// i/o to 6515D breakout usb uart

output  wire            dbg_tx,
input   wire            dbg_rx,

///////////////////////////////////////////////////
// i/o pads near jtag connector user can solder to

output  wire            user1,
input   wire            user2,

///////////////////////////////////////////////////
// RFU internal i2c bus

inout   wire            aux_sda,
output  wire            aux_scl,

///////////////////////////////////////////////////
// RFU, do not use
output  wire            vpll_feed,


//
// logical connections
//

///////////////////////////////////////////////////
// video, audio output to scaler
output  wire    [23:0]  video_rgb,
output  wire            video_rgb_clock,
output  wire            video_rgb_clock_90,
output  wire            video_de,
output  wire            video_skip,
output  wire            video_vs,
output  wire            video_hs,

output  wire            audio_mclk,
input   wire            audio_adc,
output  wire            audio_dac,
output  wire            audio_lrck,

///////////////////////////////////////////////////
// bridge bus connection
// synchronous to clk_74a
output  wire            bridge_endian_little,
input   wire    [31:0]  bridge_addr,
input   wire            bridge_rd,
output  reg     [31:0]  bridge_rd_data,
input   wire            bridge_wr,
input   wire    [31:0]  bridge_wr_data,

///////////////////////////////////////////////////
// controller data
//
// key bitmap:
//   [0]    dpad_up
//   [1]    dpad_down
//   [2]    dpad_left
//   [3]    dpad_right
//   [4]    face_a
//   [5]    face_b
//   [6]    face_x
//   [7]    face_y
//   [8]    trig_l1
//   [9]    trig_r1
//   [10]   trig_l2
//   [11]   trig_r2
//   [12]   trig_l3
//   [13]   trig_r3
//   [14]   face_select
//   [15]   face_start
//   [31:28] type
// joy values - unsigned
//   [ 7: 0] lstick_x
//   [15: 8] lstick_y
//   [23:16] rstick_x
//   [31:24] rstick_y
// trigger values - unsigned
//   [ 7: 0] ltrig
//   [15: 8] rtrig
//
input   wire    [31:0]  cont1_key,
input   wire    [31:0]  cont2_key,
input   wire    [31:0]  cont3_key,
input   wire    [31:0]  cont4_key,
input   wire    [31:0]  cont1_joy,
input   wire    [31:0]  cont2_joy,
input   wire    [31:0]  cont3_joy,
input   wire    [31:0]  cont4_joy,
input   wire    [15:0]  cont1_trig,
input   wire    [15:0]  cont2_trig,
input   wire    [15:0]  cont3_trig,
input   wire    [15:0]  cont4_trig

);

// not using the IR port, so turn off both the LED, and
// disable the receive circuit to save power
assign port_ir_tx = 0;
assign port_ir_rx_disable = 1;

// bridge endianness
assign bridge_endian_little = 0;

// cart is unused, so set all level translators accordingly
// directions are 0:IN, 1:OUT
assign cart_tran_bank3 = 8'hzz;
assign cart_tran_bank3_dir = 1'b0;
assign cart_tran_bank2 = 8'hzz;
assign cart_tran_bank2_dir = 1'b0;
assign cart_tran_bank1 = 8'hzz;
assign cart_tran_bank1_dir = 1'b0;
assign cart_tran_bank0 = 4'hf;
assign cart_tran_bank0_dir = 1'b1;
assign cart_tran_pin30 = 1'b0;      // reset or cs2, we let the hw control it by itself
assign cart_tran_pin30_dir = 1'bz;
assign cart_pin30_pwroff_reset = 1'b0;  // hardware can control this
assign cart_tran_pin31 = 1'bz;      // input
assign cart_tran_pin31_dir = 1'b0;  // input

// link port is unused, set to input only to be safe
// each bit may be bidirectional in some applications
assign port_tran_so = 1'bz;
assign port_tran_so_dir = 1'b0;     // SO is output only
assign port_tran_si = 1'bz;
assign port_tran_si_dir = 1'b0;     // SI is input only
assign port_tran_sck = 1'bz;
assign port_tran_sck_dir = 1'b0;    // clock direction can change
assign port_tran_sd = 1'bz;
assign port_tran_sd_dir = 1'b0;     // SD is input and not used

// The JR-100's entire address space is 42 KiB, so it lives in block RAM and
// none of the external memories are used. Tie them all off.
assign cram0_a = 'h0;
assign cram0_dq = {16{1'bZ}};
assign cram0_clk = 0;
assign cram0_adv_n = 1;
assign cram0_cre = 0;
assign cram0_ce0_n = 1;
assign cram0_ce1_n = 1;
assign cram0_oe_n = 1;
assign cram0_we_n = 1;
assign cram0_ub_n = 1;
assign cram0_lb_n = 1;

assign cram1_a = 'h0;
assign cram1_dq = {16{1'bZ}};
assign cram1_clk = 0;
assign cram1_adv_n = 1;
assign cram1_cre = 0;
assign cram1_ce0_n = 1;
assign cram1_ce1_n = 1;
assign cram1_oe_n = 1;
assign cram1_we_n = 1;
assign cram1_ub_n = 1;
assign cram1_lb_n = 1;

assign dram_a = 'h0;
assign dram_ba = 'h0;
assign dram_dq = {16{1'bZ}};
assign dram_dqm = 'h0;
assign dram_clk = 'h0;
assign dram_cke = 'h0;
assign dram_ras_n = 'h1;
assign dram_cas_n = 'h1;
assign dram_we_n = 'h1;

assign sram_a = 'h0;
assign sram_dq = {16{1'bZ}};
assign sram_oe_n  = 1;
assign sram_we_n  = 1;
assign sram_ub_n  = 1;
assign sram_lb_n  = 1;

assign dbg_tx = 1'bZ;
assign user1 = 1'bZ;
assign aux_scl = 1'bZ;
assign vpll_feed = 1'bZ;


// for bridge write data, we just broadcast it to all bus devices
// for bridge read data, we have to mux it
always @(*) begin
    casex(bridge_addr)
    default: begin
        bridge_rd_data <= 0;
    end
    32'hF8xxxxxx: begin
        bridge_rd_data <= cmd_bridge_rd_data;
    end
    endcase
end


//
// host/target command handler
//
    wire            reset_n;                // driven by host commands, can be used as core-wide reset
    wire    [31:0]  cmd_bridge_rd_data;

// bridge host commands
// synchronous to clk_74a
    wire            status_boot_done = pll_core_locked_s;
    wire            status_setup_done = pll_core_locked_s; // rising edge triggers a target command
    wire            status_running = reset_n; // we are running as soon as reset_n goes high

    wire            dataslot_requestread;
    wire    [15:0]  dataslot_requestread_id;
    wire            dataslot_requestread_ack = 1;
    wire            dataslot_requestread_ok = 1;

    wire            dataslot_requestwrite;
    wire    [15:0]  dataslot_requestwrite_id;
    wire    [31:0]  dataslot_requestwrite_size;
    wire            dataslot_requestwrite_ack = 1;
    wire            dataslot_requestwrite_ok = 1;

    wire            dataslot_update;
    wire    [15:0]  dataslot_update_id;
    wire    [31:0]  dataslot_update_size;

    wire            dataslot_allcomplete;

    wire     [31:0] rtc_epoch_seconds;
    wire     [31:0] rtc_date_bcd;
    wire     [31:0] rtc_time_bcd;
    wire            rtc_valid;

    wire            savestate_supported;
    wire    [31:0]  savestate_addr;
    wire    [31:0]  savestate_size;
    wire    [31:0]  savestate_maxloadsize;

    wire            savestate_start;
    wire            savestate_start_ack;
    wire            savestate_start_busy;
    wire            savestate_start_ok;
    wire            savestate_start_err;

    wire            savestate_load;
    wire            savestate_load_ack;
    wire            savestate_load_busy;
    wire            savestate_load_ok;
    wire            savestate_load_err;

    wire            osnotify_inmenu;

// bridge target commands
// synchronous to clk_74a

    reg             target_dataslot_read;
    reg             target_dataslot_write;
    reg             target_dataslot_getfile;    // require additional param/resp structs to be mapped
    reg             target_dataslot_openfile;   // require additional param/resp structs to be mapped

    wire            target_dataslot_ack;
    wire            target_dataslot_done;
    wire    [2:0]   target_dataslot_err;

    reg     [15:0]  target_dataslot_id;
    reg     [31:0]  target_dataslot_slotoffset;
    reg     [31:0]  target_dataslot_bridgeaddr;
    reg     [31:0]  target_dataslot_length;

    wire    [31:0]  target_buffer_param_struct; // to be mapped/implemented when using some Target commands
    wire    [31:0]  target_buffer_resp_struct;  // to be mapped/implemented when using some Target commands

// bridge data slot access
// synchronous to clk_74a

    wire    [9:0]   datatable_addr;
    wire            datatable_wren;
    wire    [31:0]  datatable_data;
    wire    [31:0]  datatable_q;

core_bridge_cmd icb (

    .clk                ( clk_74a ),
    .reset_n            ( reset_n ),

    .bridge_endian_little   ( bridge_endian_little ),
    .bridge_addr            ( bridge_addr ),
    .bridge_rd              ( bridge_rd ),
    .bridge_rd_data         ( cmd_bridge_rd_data ),
    .bridge_wr              ( bridge_wr ),
    .bridge_wr_data         ( bridge_wr_data ),

    .status_boot_done       ( status_boot_done ),
    .status_setup_done      ( status_setup_done ),
    .status_running         ( status_running ),

    .dataslot_requestread       ( dataslot_requestread ),
    .dataslot_requestread_id    ( dataslot_requestread_id ),
    .dataslot_requestread_ack   ( dataslot_requestread_ack ),
    .dataslot_requestread_ok    ( dataslot_requestread_ok ),

    .dataslot_requestwrite      ( dataslot_requestwrite ),
    .dataslot_requestwrite_id   ( dataslot_requestwrite_id ),
    .dataslot_requestwrite_size ( dataslot_requestwrite_size ),
    .dataslot_requestwrite_ack  ( dataslot_requestwrite_ack ),
    .dataslot_requestwrite_ok   ( dataslot_requestwrite_ok ),

    .dataslot_update            ( dataslot_update ),
    .dataslot_update_id         ( dataslot_update_id ),
    .dataslot_update_size       ( dataslot_update_size ),

    .dataslot_allcomplete   ( dataslot_allcomplete ),

    .rtc_epoch_seconds      ( rtc_epoch_seconds ),
    .rtc_date_bcd           ( rtc_date_bcd ),
    .rtc_time_bcd           ( rtc_time_bcd ),
    .rtc_valid              ( rtc_valid ),

    .savestate_supported    ( savestate_supported ),
    .savestate_addr         ( savestate_addr ),
    .savestate_size         ( savestate_size ),
    .savestate_maxloadsize  ( savestate_maxloadsize ),

    .savestate_start        ( savestate_start ),
    .savestate_start_ack    ( savestate_start_ack ),
    .savestate_start_busy   ( savestate_start_busy ),
    .savestate_start_ok     ( savestate_start_ok ),
    .savestate_start_err    ( savestate_start_err ),

    .savestate_load         ( savestate_load ),
    .savestate_load_ack     ( savestate_load_ack ),
    .savestate_load_busy    ( savestate_load_busy ),
    .savestate_load_ok      ( savestate_load_ok ),
    .savestate_load_err     ( savestate_load_err ),

    .osnotify_inmenu        ( osnotify_inmenu ),

    .target_dataslot_read       ( target_dataslot_read ),
    .target_dataslot_write      ( target_dataslot_write ),
    .target_dataslot_getfile    ( target_dataslot_getfile ),
    .target_dataslot_openfile   ( target_dataslot_openfile ),

    .target_dataslot_ack        ( target_dataslot_ack ),
    .target_dataslot_done       ( target_dataslot_done ),
    .target_dataslot_err        ( target_dataslot_err ),

    .target_dataslot_id         ( target_dataslot_id ),
    .target_dataslot_slotoffset ( target_dataslot_slotoffset ),
    .target_dataslot_bridgeaddr ( target_dataslot_bridgeaddr ),
    .target_dataslot_length     ( target_dataslot_length ),

    .target_buffer_param_struct ( target_buffer_param_struct ),
    .target_buffer_resp_struct  ( target_buffer_resp_struct ),

    .datatable_addr         ( datatable_addr ),
    .datatable_wren         ( datatable_wren ),
    .datatable_data         ( datatable_data ),
    .datatable_q            ( datatable_q )

);

// Target commands are unused until the data-slot loader lands (P2-1).
always @(posedge clk_74a) begin
    target_dataslot_read       <= 0;
    target_dataslot_write      <= 0;
    target_dataslot_getfile    <= 0;
    target_dataslot_openfile   <= 0;
    target_dataslot_id         <= 0;
    target_dataslot_slotoffset <= 0;
    target_dataslot_bridgeaddr <= 0;
    target_dataslot_length     <= 0;
end


////////////////////////////////////////////////////////////////////////////////
// Clocking
//
// One PLL output drives everything: 57.272727 MHz, which is 4x the NTSC colour
// burst and the JR-100's own crystal chain. jr100_top divides it internally
// with clock enables (/8 pixel, /64 CPU) exactly as the real machine does.
////////////////////////////////////////////////////////////////////////////////

    wire    clk_sys;            // 57.272727 MHz
    wire    pll_core_locked;
    wire    pll_core_locked_s;

synch_3 s_pll_lock (pll_core_locked, pll_core_locked_s, clk_74a);

jr100_pll pll (
    .refclk         ( clk_74a ),
    .rst            ( 1'b0 ),
    .outclk_0       ( clk_sys ),
    .locked         ( pll_core_locked )
);

// Bring the framework reset across into the system clock domain.
    wire    reset_n_sys;
synch_3 s_reset (reset_n & pll_core_locked, reset_n_sys, clk_sys);

    wire    rst_sys = ~reset_n_sys;


////////////////////////////////////////////////////////////////////////////////
// JR-100 machine
////////////////////////////////////////////////////////////////////////////////

    wire        vid_pixel;
    wire        vid_de;
    wire        vid_hs;
    wire        vid_vs;
    wire [8:0]  vid_hcnt;
    wire [8:0]  vid_vcnt;
    wire        cen_pix;
    wire        jr_audio;

jr100_top jr100 (
    .clk            ( clk_sys ),
    .rst            ( rst_sys ),
    .downloading    ( 1'b0 ),
    .cpu_hold       ( 1'b0 ),

    // ROM loader - fed by the APF data slot in P2-1
    .loader_we      ( 1'b0 ),
    .loader_addr    ( 13'd0 ),
    .loader_data    ( 8'd0 ),

    // .prg / .bas loaders - P5-1
    .prg_download   ( 1'b0 ),
    .prg_wr         ( 1'b0 ),
    .prg_data       ( 8'd0 ),
    .prg_wait       (  ),
    .bas_download   ( 1'b0 ),
    .bas_wr         ( 1'b0 ),
    .bas_data       ( 8'd0 ),
    .bas_wait       (  ),

    // BASIC save - P6-1
    .save_req       ( 1'b0 ),
    .img_mounted    ( 1'b0 ),
    .img_readonly   ( 1'b0 ),
    .img_size       ( 64'd0 ),
    .sd_lba         (  ),
    .sd_wr          (  ),
    .sd_ack         ( 1'b0 ),
    .sd_buff_addr   ( 9'd0 ),
    .sd_buff_din    (  ),

    .autostart_en   ( 1'b0 ),

    // Inputs - P3
    .key_matrix     ( 45'd0 ),
    .joy_status     ( 8'd0 ),
    .ext_ram_en     ( 1'b0 ),

    .pb7            (  ),
    .audio          ( jr_audio ),

    // Virtual cassette - P6-2
    .tape_play      ( 1'b0 ),
    .tape_mounted   ( 1'b0 ),
    .tape_readonly  ( 1'b0 ),
    .tape_size      ( 64'd0 ),
    .tape_playing   (  ),
    .tape_recording (  ),
    .sd1_lba        (  ),
    .sd1_rd         (  ),
    .sd1_wr         (  ),
    .sd1_ack        ( 1'b0 ),
    .sd1_buff_din   (  ),
    .sd_buff_dout   ( 8'd0 ),
    .sd_buff_wr     ( 1'b0 ),

    .vid_pixel      ( vid_pixel ),
    .vid_de         ( vid_de ),
    .vid_hs         ( vid_hs ),
    .vid_vs         ( vid_vs ),
    .vid_hcnt       ( vid_hcnt ),
    .vid_vcnt       ( vid_vcnt ),

    .cen_pix_out    ( cen_pix ),

    .cen_cpu_out    (  ),
    .boundary       (  ),
    .dbg_pc         (  ),
    .dbg_sp         (  ),
    .dbg_ix         (  ),
    .dbg_a          (  ),
    .dbg_b          (  ),
    .dbg_cc         (  ),
    .dbg_ora        (  ),
    .dbg_orb        (  ),
    .dbg_ddra       (  ),
    .dbg_ddrb       (  ),
    .dbg_acr        (  ),
    .dbg_pcr        (  ),
    .dbg_ifr        (  ),
    .dbg_ier        (  ),
    .dbg_sr         (  ),
    .dbg_t1         (  ),
    .dbg_t1l        (  ),
    .dbg_t2         (  ),
    .dbg_t2l        (  )
);


////////////////////////////////////////////////////////////////////////////////
// Video output to the APF scaler
//
// The JR-100 raster is 448x256 total with a 256x192 active window, a 7.159091
// MHz dot clock and a 62.4 Hz frame rate. That is the real machine's own
// composite format and deliberately not NTSC standard.
//
// APF wants single-cycle HS/VS strobes rather than the level syncs jr100_video
// produces, so they are generated from the raster counters directly, which
// makes their position explicit.
////////////////////////////////////////////////////////////////////////////////

    localparam [8:0] H_ACT_START = 9'd64;   // jr100_video H_ACT_START
    localparam [8:0] V_ACT_START = 9'd35;   // jr100_video V_ACT_START

// The pixel phase counter tracks jr100_top's own /8 enable: cen_pix is high on
// the last cycle of a pixel, so pix_phase is 0 on the cycle where new video
// data becomes valid and 7 on its last stable cycle.
    reg  [2:0]  pix_phase = 3'd0;
always @(posedge clk_sys) begin
    if (rst_sys)        pix_phase <= 3'd0;
    else if (cen_pix)   pix_phase <= 3'd0;
    else                pix_phase <= pix_phase + 3'd1;
end

// Scaler clocks. Both are 50% duty and 90 degrees apart; video_rgb_clock rises
// in the middle of the data window (phase 4), leaving four system cycles of
// setup and four of hold around the sampling edge.
    reg         pix_clk    = 1'b0;
    reg         pix_clk_90 = 1'b0;
always @(posedge clk_sys) begin
    if (rst_sys) begin
        pix_clk    <= 1'b0;
        pix_clk_90 <= 1'b0;
    end else begin
        if (pix_phase == 3'd3) pix_clk    <= 1'b1;
        if (pix_phase == 3'd7) pix_clk    <= 1'b0;
        if (pix_phase == 3'd5) pix_clk_90 <= 1'b1;
        if (pix_phase == 3'd1) pix_clk_90 <= 1'b0;
    end
end

// Active-window coordinates, valid while vid_de is high.
    wire [8:0]  act_x = vid_hcnt - H_ACT_START;
    wire [8:0]  act_y = vid_vcnt - V_ACT_START;

// ---------------------------------------------------------------------------
// Bring-up pattern. Nothing loads the ROM yet, so the JR-100 raster is blank
// and a black screen would not distinguish "scaler locked" from "no signal".
// The pattern draws a one-pixel border, eight colour bars and a marker that
// steps one line per frame, which makes the lock, the active-area size and the
// vertical cadence all visible on the device. Removed in P2-1.
// ---------------------------------------------------------------------------
    localparam bit BRINGUP_PATTERN = 1'b1;

    reg [15:0]  frame_count = 16'd0;
    reg         vs_seen = 1'b0;
always @(posedge clk_sys) begin
    if (rst_sys) begin
        frame_count <= 16'd0;
        vs_seen     <= 1'b0;
    end else if (cen_pix) begin
        vs_seen <= vid_vs;
        if (vid_vs & ~vs_seen) frame_count <= frame_count + 16'd1;
    end
end

    wire [7:0]  marker_y = frame_count[7:0];
    wire        in_border = (act_x == 9'd0) || (act_x == 9'd255) ||
                            (act_y == 9'd0) || (act_y == 9'd191);
    wire        in_marker = (act_x >= 9'd120) && (act_x < 9'd136) &&
                            (act_y >= {1'b0, marker_y}) &&
                            (act_y <  {1'b0, marker_y} + 9'd8) &&
                            (marker_y < 8'd184);

    reg [23:0]  bar_rgb;
always @(*) begin
    case (act_x[7:5])
        3'd0: bar_rgb = 24'hFFFFFF;
        3'd1: bar_rgb = 24'hFFFF00;
        3'd2: bar_rgb = 24'h00FFFF;
        3'd3: bar_rgb = 24'h00FF00;
        3'd4: bar_rgb = 24'hFF00FF;
        3'd5: bar_rgb = 24'hFF0000;
        3'd6: bar_rgb = 24'h0000FF;
        3'd7: bar_rgb = 24'h202020;
    endcase
end

    wire [23:0] pattern_rgb = in_marker ? 24'hFFFFFF :
                              in_border ? 24'hFF8000 : bar_rgb;

// JR-100 picture over the bring-up background. The display colour is
// selectable on MiSTer; white until the interact.json plumbing lands in P7-1.
//
// The machine's own pixel has to stay in the visible path even while the
// pattern is up: with the pattern simply overriding it, vid_pixel became dead
// logic and Quartus removed the CPU, the VIA and every BRAM along with it -
// the first build fitted in 435 ALMs and 8 Kbit, the same as an empty core.
    wire [23:0] active_rgb = vid_pixel       ? 24'hFFFFFF :
                             BRINGUP_PATTERN ? pattern_rgb :
                                               24'h000000;

    reg [23:0]  vidout_rgb = 24'd0;
    reg         vidout_de  = 1'b0;
    reg         vidout_hs  = 1'b0;
    reg         vidout_vs  = 1'b0;
always @(posedge clk_sys) begin
    if (rst_sys) begin
        vidout_rgb <= 24'd0;
        vidout_de  <= 1'b0;
        vidout_hs  <= 1'b0;
        vidout_vs  <= 1'b0;
    end else if (cen_pix) begin
        vidout_de  <= vid_de;
        vidout_rgb <= vid_de ? active_rgb : 24'h000000;

        // Single-cycle strobes. VS marks the top-left of the frame; HS follows
        // a few dots later so the two never coincide.
        vidout_vs  <= (vid_hcnt == 9'd0) && (vid_vcnt == 9'd0);
        vidout_hs  <= (vid_hcnt == 9'd3);
    end
end

assign video_rgb          = vidout_rgb;
assign video_de           = vidout_de;
assign video_hs           = vidout_hs;
assign video_vs           = vidout_vs;
assign video_skip         = 1'b0;
assign video_rgb_clock    = pix_clk;
assign video_rgb_clock_90 = pix_clk_90;

// jr100_top's level syncs are unused on this path; keep them observable so the
// tools do not prune the ports.
    wire unused_syncs = vid_hs | vid_vs | jr_audio;


////////////////////////////////////////////////////////////////////////////////
// Audio
//
// Silence for now; the JR-100 BEEP is connected over I2S in P4-1.
////////////////////////////////////////////////////////////////////////////////

assign audio_mclk = audgen_mclk;
assign audio_dac = audgen_dac;
assign audio_lrck = audgen_lrck;

// generate MCLK = 12.288mhz with fractional accumulator
    reg         [21:0]  audgen_accum = 22'd0;
    reg                 audgen_mclk = 1'b0;
    localparam  [20:0]  CYCLE_48KHZ = 21'd122880 * 2;
always @(posedge clk_74a) begin
    audgen_accum <= audgen_accum + CYCLE_48KHZ;
    if(audgen_accum >= 21'd742500) begin
        audgen_mclk <= ~audgen_mclk;
        audgen_accum <= audgen_accum - 21'd742500 + CYCLE_48KHZ;
    end
end

// generate SCLK = 3.072mhz by dividing MCLK by 4
    reg [1:0]   aud_mclk_divider = 2'd0;
    wire        audgen_sclk = aud_mclk_divider[1] /* synthesis keep*/;
always @(posedge audgen_mclk) begin
    aud_mclk_divider <= aud_mclk_divider + 1'b1;
end

// shift out audio data as I2S
// 32 total bits per channel, but only 16 active bits at the start and then 16 dummy bits
//
    reg     [4:0]   audgen_lrck_cnt = 5'd0;
    reg             audgen_lrck = 1'b0;
    reg             audgen_dac = 1'b0;
always @(negedge audgen_sclk) begin
    audgen_dac <= 1'b0;
    // 48khz * 64
    audgen_lrck_cnt <= audgen_lrck_cnt + 1'b1;
    if(audgen_lrck_cnt == 31) begin
        // switch channels
        audgen_lrck <= ~audgen_lrck;
    end
end

endmodule

`default_nettype wire
