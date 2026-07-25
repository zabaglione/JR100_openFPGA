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
    32'h0000Fxxx: begin
        bridge_rd_data <= cfg_rd_data;
    end
    32'h3xxxxxxx: begin
        bridge_rd_data <= save_rd_data;
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
    wire            status_boot_done = pll_core_locked_s & pll_video_locked_s;
    wire            status_setup_done = pll_core_locked_s & pll_video_locked_s; // rising edge triggers a target command
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

    wire            target_dataslot_read;
    wire            target_dataslot_write;
    wire            target_dataslot_getfile = 1'b0;
    wire            target_dataslot_openfile = 1'b0;

    wire            target_dataslot_ack;
    wire            target_dataslot_done;
    wire    [2:0]   target_dataslot_err;

    wire    [15:0]  target_dataslot_id;
    wire    [31:0]  target_dataslot_slotoffset;
    wire    [31:0]  target_dataslot_bridgeaddr;
    wire    [31:0]  target_dataslot_length;

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
    wire    pll_video_locked_s;

synch_3 s_pll_lock  (pll_core_locked,  pll_core_locked_s,  clk_74a);
synch_3 s_vpll_lock (pll_video_locked, pll_video_locked_s, clk_74a);

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
// boot.rom loading
//
// The slot is host-pushed: at core launch (and whenever the user picks a new
// file) APF streams the 8 KiB image as 32-bit bridge writes at 0x00000000,
// and agg23's data_loader carries them across to the 57 MHz domain as single
// bytes for jr100_top's loader port. boot.rom is the MiSTer layout: character
// ROM in 0x0000-0x03FF, BASIC ROM in 0x0400-0x1FFF.
//
// The machine is held in reset by ~dataslot_allcomplete: zero from power-on
// until every slot is processed (command 0x008F), and it drops back to zero
// while a reload is in progress, so the CPU always comes out of reset into a
// fully written ROM and performs the real MC6800 reset-vector sequence.
////////////////////////////////////////////////////////////////////////////////

    wire        rom_wr;
    wire [27:0] rom_wr_addr;
    wire [7:0]  rom_wr_data;

data_loader #(
    .ADDRESS_MASK_UPPER_4       ( 4'h0 ),
    .ADDRESS_SIZE               ( 28 ),
    .WRITE_MEM_CLOCK_DELAY      ( 4 ),
    .WRITE_MEM_EN_CYCLE_LENGTH  ( 1 ),
    .OUTPUT_WORD_SIZE           ( 1 )
) rom_loader (
    .clk_74a              ( clk_74a ),
    .clk_memory           ( clk_sys ),

    .bridge_wr            ( bridge_wr ),
    .bridge_endian_little ( bridge_endian_little ),
    .bridge_addr          ( bridge_addr ),
    .bridge_wr_data       ( bridge_wr_data ),

    .write_en             ( rom_wr ),
    .write_addr           ( rom_wr_addr ),
    .write_data           ( rom_wr_data )
);

// The machine is held in reset only while the ROM slot itself is being
// written. Program slots (.prg/.bas) load into the RUNNING machine - the
// PROG container patches BASIC's workspace pointers, so resetting would
// destroy exactly the state it is loading into (jr100_top freezes the CPU
// through its prg/bas ports instead).
    reg     rom_slot_active_74 = 1'b1;   // power-on counts as the ROM phase
always @(posedge clk_74a) begin
    if (dataslot_requestwrite)
        rom_slot_active_74 <= (dataslot_requestwrite_id == 16'd0);
end

    wire    downloading_s;
synch_3 s_downloading (~dataslot_allcomplete & rom_slot_active_74,
                       downloading_s, clk_sys);

// .prg / .bas slots: host-pushed into a replay buffer, then fed to the
// machine at its own pace (the bridge has no backpressure; the loaders do).
    wire        prgl_wr,  basl_wr;
    wire [27:0] prgl_addr, basl_addr;
    wire [7:0]  prgl_data, basl_data;

data_loader #(
    .ADDRESS_MASK_UPPER_4       ( 4'h1 ),
    .ADDRESS_SIZE               ( 28 ),
    .WRITE_MEM_CLOCK_DELAY      ( 4 ),
    .WRITE_MEM_EN_CYCLE_LENGTH  ( 1 ),
    .OUTPUT_WORD_SIZE           ( 1 )
) prg_slot_loader (
    .clk_74a              ( clk_74a ),
    .clk_memory           ( clk_sys ),
    .bridge_wr            ( bridge_wr ),
    .bridge_endian_little ( bridge_endian_little ),
    .bridge_addr          ( bridge_addr ),
    .bridge_wr_data       ( bridge_wr_data ),
    .write_en             ( prgl_wr ),
    .write_addr           ( prgl_addr ),
    .write_data           ( prgl_data )
);

data_loader #(
    .ADDRESS_MASK_UPPER_4       ( 4'h2 ),
    .ADDRESS_SIZE               ( 28 ),
    .WRITE_MEM_CLOCK_DELAY      ( 4 ),
    .WRITE_MEM_EN_CYCLE_LENGTH  ( 1 ),
    .OUTPUT_WORD_SIZE           ( 1 )
) bas_slot_loader (
    .clk_74a              ( clk_74a ),
    .clk_memory           ( clk_sys ),
    .bridge_wr            ( bridge_wr ),
    .bridge_endian_little ( bridge_endian_little ),
    .bridge_addr          ( bridge_addr ),
    .bridge_wr_data       ( bridge_wr_data ),
    .write_en             ( basl_wr ),
    .write_addr           ( basl_addr ),
    .write_data           ( basl_data )
);

    wire        prg_download, prg_wr_s, prg_wait;
    wire        bas_download, bas_wr_s, bas_wait;
    wire [7:0]  prg_data, bas_data;

jr100_prog_feeder #(
    .SLOT_PRG ( 16'd1 ),
    .SLOT_BAS ( 16'd2 )
) prog_feeder (
    .clk       ( clk_sys ),
    .rst       ( rst_sys ),

    .clk_74a                    ( clk_74a ),
    .dataslot_requestwrite      ( dataslot_requestwrite ),
    .dataslot_requestwrite_id   ( dataslot_requestwrite_id ),
    .dataslot_requestwrite_size ( dataslot_requestwrite_size ),
    .dataslot_allcomplete       ( dataslot_allcomplete ),

    .buf_wr    ( prgl_wr | basl_wr ),
    .buf_addr  ( prgl_wr ? prgl_addr[15:0] : basl_addr[15:0] ),
    .buf_data  ( prgl_wr ? prgl_data : basl_data ),

    .prg_download ( prg_download ),
    .prg_wr       ( prg_wr_s ),
    .prg_data     ( prg_data ),
    .prg_wait     ( prg_wait ),

    .bas_download ( bas_download ),
    .bas_wr       ( bas_wr_s ),
    .bas_data     ( bas_data ),
    .bas_wait     ( bas_wait ),

    .feeding      (  )
);

// Media write-back and tape streaming: the MiSTer sector protocols of
// jr100_saver (slot 3) and jr100_tape_buf (slot 4) -> APF target commands.
    wire        img_mounted, img_readonly;
    wire [63:0] img_size;
    wire [31:0] sd_lba;
    wire        sd_wr, sd_ack;
    wire [7:0]  sd_buff_din;
    wire        tape_mounted, tape_readonly;
    wire [63:0] tape_size;
    wire [31:0] sd1_lba;
    wire        sd1_rd, sd1_wr, sd1_ack;
    wire [7:0]  sd1_buff_din;
    wire [8:0]  buff_addr;
    wire [7:0]  buff_dout;
    wire        buff_wr;
    wire [31:0] save_rd_data;

jr100_media_bridge #(
    .SLOT_SAVE ( 16'd3 ),
    .SLOT_TAPE ( 16'd4 ),
    .RD_BRIDGE ( 32'h50000000 ),
    .WR_BRIDGE ( 32'h30000000 )
) media_bridge (
    .clk      ( clk_sys ),
    .rst      ( rst_sys ),
    .clk_74a  ( clk_74a ),

    .dataslot_requestwrite      ( dataslot_requestwrite ),
    .dataslot_requestwrite_id   ( dataslot_requestwrite_id ),
    .dataslot_requestwrite_size ( dataslot_requestwrite_size ),
    .dataslot_update            ( dataslot_update ),
    .dataslot_update_id         ( dataslot_update_id ),
    .dataslot_update_size       ( dataslot_update_size ),
    .dataslot_allcomplete       ( dataslot_allcomplete ),

    .img_mounted  ( img_mounted ),
    .img_readonly ( img_readonly ),
    .img_size     ( img_size ),
    .sd_lba       ( sd_lba ),
    .sd_wr        ( sd_wr ),
    .sd_ack       ( sd_ack ),
    .save_din     ( sd_buff_din ),

    .tape_mounted  ( tape_mounted ),
    .tape_readonly ( tape_readonly ),
    .tape_size     ( tape_size ),
    .sd1_lba       ( sd1_lba ),
    .sd1_rd        ( sd1_rd ),
    .sd1_wr        ( sd1_wr ),
    .sd1_ack       ( sd1_ack ),
    .tape_din      ( sd1_buff_din ),

    .buff_addr ( buff_addr ),
    .buff_dout ( buff_dout ),
    .buff_wr   ( buff_wr ),

    .bridge_addr    ( bridge_addr ),
    .bridge_wr      ( bridge_wr ),
    .bridge_wr_data ( bridge_wr_data ),
    .bridge_rd_data ( save_rd_data ),

    .target_dataslot_read       ( target_dataslot_read ),
    .target_dataslot_write      ( target_dataslot_write ),
    .target_dataslot_id         ( target_dataslot_id ),
    .target_dataslot_slotoffset ( target_dataslot_slotoffset ),
    .target_dataslot_bridgeaddr ( target_dataslot_bridgeaddr ),
    .target_dataslot_length     ( target_dataslot_length ),
    .target_dataslot_ack        ( target_dataslot_ack ),
    .target_dataslot_done       ( target_dataslot_done ),
    .target_dataslot_err        ( target_dataslot_err )
);


////////////////////////////////////////////////////////////////////////////////
// Inputs: pad, dock USB keyboard, virtual keyboard
////////////////////////////////////////////////////////////////////////////////

    wire [44:0] key_matrix;
    wire [7:0]  joy_status;
    wire        vkb_active, vkb_pressed, vkb_shift, vkb_ctl;
    wire [2:0]  vkb_row;
    wire [3:0]  vkb_col;

// Reset covers ROM reloads too, so the tracked GRAPH state and the keyboard
// come up clean whenever the machine itself restarts.
jr100_pocket_input pocket_input (
    .clk         ( clk_sys ),
    .rst         ( machine_rst | downloading_s ),

    .cont1_key   ( cont1_key ),
    .cont3_key   ( cont3_key ),
    .cont3_joy   ( cont3_joy ),
    .cont3_trig  ( cont3_trig ),

    .key_matrix  ( key_matrix ),
    .joy_status  ( joy_status ),

    .vkb_active  ( vkb_active ),
    .vkb_row     ( vkb_row ),
    .vkb_col     ( vkb_col ),
    .vkb_pressed ( vkb_pressed ),
    .vkb_shift   ( vkb_shift ),
    .vkb_ctl     ( vkb_ctl )
);


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
    .rst            ( machine_rst ),
    .downloading    ( downloading_s ),
    .cpu_hold       ( 1'b0 ),

    // boot.rom bytes from the APF data slot (guarded to the 8 KiB window)
    .loader_we      ( rom_wr && (rom_wr_addr[27:13] == 15'd0) ),
    .loader_addr    ( rom_wr_addr[12:0] ),
    .loader_data    ( rom_wr_data ),

    // .prg / .bas program streams, replayed from the feeder buffer
    .prg_download   ( prg_download ),
    .prg_wr         ( prg_wr_s ),
    .prg_data       ( prg_data ),
    .prg_wait       ( prg_wait ),
    .bas_download   ( bas_download ),
    .bas_wr         ( bas_wr_s ),
    .bas_data       ( bas_data ),
    .bas_wait       ( bas_wait ),

    .save_req       ( save_pulse ),
    .img_mounted    ( img_mounted ),
    .img_readonly   ( img_readonly ),
    .img_size       ( img_size ),
    .sd_lba         ( sd_lba ),
    .sd_wr          ( sd_wr ),
    .sd_ack         ( sd_ack ),
    .sd_buff_addr   ( buff_addr ),
    .sd_buff_din    ( sd_buff_din ),

    .autostart_en   ( cfg_autostart_s ),

    .key_matrix     ( key_matrix ),
    .joy_status     ( joy_status ),
    .ext_ram_en     ( cfg_extram_s ),

    .pb7            (  ),
    .audio          ( jr_audio ),

    .tape_play      ( tape_pulse ),
    .tape_mounted   ( tape_mounted ),
    .tape_readonly  ( tape_readonly ),
    .tape_size      ( tape_size ),
    .tape_playing   (  ),
    .tape_recording (  ),
    .sd1_lba        ( sd1_lba ),
    .sd1_rd         ( sd1_rd ),
    .sd1_wr         ( sd1_wr ),
    .sd1_ack        ( sd1_ack ),
    .sd1_buff_din   ( sd1_buff_din ),
    .sd_buff_dout   ( buff_dout ),
    .sd_buff_wr     ( buff_wr ),

    .vid_pixel      ( vid_pixel ),
    .vid_de         ( vid_de ),
    .vid_hs         ( vid_hs ),
    .vid_vs         ( vid_vs ),
    .vid_hcnt       ( vid_hcnt ),
    .vid_vcnt       ( vid_vcnt ),

    .cen_pix_out    ( cen_pix ),

    .dbg_bus_addr   ( bus_addr ),
    .dbg_bus_wdata  ( bus_wdata ),
    .dbg_bus_we     ( bus_we ),

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
// Core settings and actions (interact.json), bridge registers at
// 0x0000F000-0x0000F018.
//
// The first attempt put these at 0x7xxxxxxx and no menu value ever reached
// the core on hardware. PocketCPC's proven layout keeps its registers in
// the low 64 KiB and serves READBACK at the same addresses, so this block
// mirrors that exactly. The region sits above the 8 KiB boot.rom push
// window, and every slot loader's address guard excludes it.
//
// Values are quasi-static (menu-driven), so they cross domains through
// plain synchronisers; actions are write-strobes turned into toggles here
// and edge-detected pulses on the far side.
////////////////////////////////////////////////////////////////////////////////

    reg  [2:0] cfg_color_74     = 3'd0;   // display colour (list)
    reg        cfg_autostart_74 = 1'b1;   // type RUN / USR hint after loads
    reg        cfg_extram_74    = 1'b0;   // 16 KiB extended RAM (needs reset)
    reg        act_reset_74     = 1'b0;   // toggles, one flip per action
    reg        act_save_74      = 1'b0;
    reg        act_tape_74      = 1'b0;

always @(posedge clk_74a) begin
    if (bridge_wr) begin
        case (bridge_addr)
            32'h0000F000: cfg_color_74     <= bridge_wr_data[2:0];
            32'h0000F004: cfg_autostart_74 <= bridge_wr_data[0];
            32'h0000F008: cfg_extram_74    <= bridge_wr_data[0];
            32'h0000F010: act_reset_74     <= ~act_reset_74;
            32'h0000F014: act_save_74      <= ~act_save_74;
            32'h0000F018: act_tape_74      <= ~act_tape_74;
            default: ;
        endcase
    end
end

// readback, PocketCPC-style: the OS can re-read what it wrote
    reg [31:0] cfg_rd_data;
always @(posedge clk_74a) begin
    case (bridge_addr)
        32'h0000F000: cfg_rd_data <= {29'd0, cfg_color_74};
        32'h0000F004: cfg_rd_data <= {31'd0, cfg_autostart_74};
        32'h0000F008: cfg_rd_data <= {31'd0, cfg_extram_74};
        default:      cfg_rd_data <= 32'd0;
    endcase
end

    wire       cfg_autostart_s, cfg_extram_s;
    wire       act_reset_t, act_save_t, act_tape_t;
synch_3 s_cfg_auto (cfg_autostart_74, cfg_autostart_s, clk_sys);
synch_3 s_cfg_xram (cfg_extram_74,    cfg_extram_s,    clk_sys);
synch_3 s_act_rst  (act_reset_74,     act_reset_t,     clk_sys);
synch_3 s_act_save (act_save_74,      act_save_t,      clk_sys);
synch_3 s_act_tape (act_tape_74,      act_tape_t,      clk_sys);

    reg  act_reset_q, act_save_q, act_tape_q;
    wire reset_pulse = act_reset_t ^ act_reset_q;
    wire save_pulse  = act_save_t  ^ act_save_q;
    wire tape_pulse  = act_tape_t  ^ act_tape_q;
always @(posedge clk_sys) begin
    act_reset_q <= act_reset_t;
    act_save_q  <= act_save_t;
    act_tape_q  <= act_tape_t;
end

// A user reset restarts the machine (and everything scoped to it) without
// reloading the ROM. Stretch it so the whole machine sees it.
    reg [7:0] user_rst_cnt = 8'd0;
always @(posedge clk_sys) begin
    if (reset_pulse)            user_rst_cnt <= 8'hFF;
    else if (user_rst_cnt != 0) user_rst_cnt <= user_rst_cnt - 8'd1;
end
    wire machine_rst = rst_sys | (user_rst_cnt != 8'd0);


////////////////////////////////////////////////////////////////////////////////
// GRAPH-mode flag, snooped from the machine itself.
//
// The ROM keeps its GRAPH-mode state in work RAM at 0x0014 (0x00 normal,
// 0x10 GRAPH; found by diffing work RAM across CTRL+V in the reference
// emulator, docs/KEYBOARD.md). Watching the CPU bus for writes to that byte
// tracks the real state exactly - including presses the ROM ignored, RETURN
// cancellation, and even a program POKEing the flag - which guessing from
// keystrokes could not (mismatch seen on hardware).
////////////////////////////////////////////////////////////////////////////////

    wire [15:0] bus_addr;
    wire [7:0]  bus_wdata;
    wire        bus_we;

    localparam [15:0] GRAPH_FLAG_ADDR = 16'h0014;

    reg         graph_flag = 1'b0;
always @(posedge clk_sys) begin
    if (machine_rst | downloading_s)
        graph_flag <= 1'b0;
    else if (bus_we && (bus_addr == GRAPH_FLAG_ADDR))
        graph_flag <= (bus_wdata != 8'h00);
end


////////////////////////////////////////////////////////////////////////////////
// Video output to the APF scaler
//
// The JR-100's native raster (7.159 MHz dot, 448x256 total, 62.4 Hz, a sync
// format deliberately not NTSC) stays entirely inside the machine. Driving
// the scaler's DDR link directly from that raster with a fabric-divided clock
// failed on hardware at three different phases, so the output stage instead
// stands on the one configuration this exact device has already proven: the
// core-template's 12.288 MHz PLL clock pair and 320x240@60 scan, with the
// machine's picture carried across in a dual-clock framebuffer.
//
// video_rgb_clock is not a status signal - apf_top uses it as the outclock of
// the DDIO cells that serialise RGB to 12-bit DDR, and video_rgb_clock_90
// drives the DDIO cell that forms the scaler's clock pin. Template style,
// both are true PLL outputs and the scan/data registers run on the 0-degree
// clock, so every path the DDR link depends on is PLL-to-PLL and constrained
// by derive_pll_clocks.
//
// The JR-100 being monochrome is what makes the bridge cheap: 256x192 at 1bpp
// is 48 Kbit, 1.5% of BRAM. Writer (62.4 Hz) and reader (60.0 Hz) free-run,
// so a moving image can show a slow tear line; on this machine's text-centric
// output that is acceptable, and fixing it later only needs a second buffer.
////////////////////////////////////////////////////////////////////////////////

// -- write side: the native raster drops its active window into the buffer --

    localparam [8:0] H_ACT_START = 9'd64;   // jr100_video H_ACT_START
    localparam [8:0] V_ACT_START = 9'd35;   // jr100_video V_ACT_START

    wire [8:0]  act_x = vid_hcnt - H_ACT_START;   // 0..255 while vid_de
    wire [8:0]  act_y = vid_vcnt - V_ACT_START;   // 0..191 while vid_de

// -- scanout clock pair: 12.288 MHz at 0 and 90 degrees, template-identical --

    wire    clk_vid;
    wire    clk_vid_90;
    wire    pll_video_locked;

apf_video_pll vpll (
    .refclk   ( clk_74a ),
    .rst      ( 1'b0 ),
    .outclk_0 ( clk_vid ),
    .outclk_1 ( clk_vid_90 ),
    .locked   ( pll_video_locked )
);

    wire    reset_n_vid;
synch_3 s_reset_vid (reset_n & pll_video_locked, reset_n_vid, clk_vid);

// -- scanout raster: 320x240 active in 400x512 total = 60.0 Hz exactly ------

    localparam [9:0] VID_H_BPORCH = 10'd10;
    localparam [9:0] VID_H_ACTIVE = 10'd320;
    localparam [9:0] VID_H_TOTAL  = 10'd400;
    localparam [9:0] VID_V_BPORCH = 10'd10;
    localparam [9:0] VID_V_ACTIVE = 10'd240;
    localparam [9:0] VID_V_TOTAL  = 10'd512;

// the 256x192 framebuffer window, centred in the 320x240 active area
    localparam [9:0] FB_X0 = VID_H_BPORCH + 10'd32;
    localparam [9:0] FB_Y0 = VID_V_BPORCH + 10'd24;

    reg  [9:0]  x_count = '0;
    reg  [9:0]  y_count = '0;

// The BRAM read is synchronous with one cycle of latency, so the address is
// issued for the NEXT scan position and the data arrives exactly when the
// counter reaches it.
    wire [9:0]  nx        = (x_count == VID_H_TOTAL - 10'd1) ? 10'd0
                                                             : x_count + 10'd1;
    wire [9:0]  fb_rd_x10 = nx      - FB_X0;
    wire [9:0]  fb_rd_y10 = y_count - FB_Y0;

    wire        fb_pix;

bram_block_dp #(
    .DATA ( 1 ),
    .ADDR ( 16 )
) framebuffer (
    .a_clk  ( clk_sys ),
    .a_wr   ( cen_pix & vid_de ),
    .a_addr ( {act_y[7:0], act_x[7:0]} ),
    .a_din  ( vid_pixel ),
    .a_dout (  ),

    .b_clk  ( clk_vid ),
    .b_wr   ( 1'b0 ),
    .b_addr ( {fb_rd_y10[7:0], fb_rd_x10[7:0]} ),
    .b_din  ( 1'b0 ),
    .b_dout ( fb_pix )
);

// -- picture composition, all in scanout coordinates ------------------------

    wire [9:0]  vx = x_count - VID_H_BPORCH;   // 0..319 inside the active area
    wire [9:0]  vy = y_count - VID_V_BPORCH;   // 0..239

    wire in_active = (x_count >= VID_H_BPORCH) &&
                     (x_count <  VID_H_BPORCH + VID_H_ACTIVE) &&
                     (y_count >= VID_V_BPORCH) &&
                     (y_count <  VID_V_BPORCH + VID_V_ACTIVE);
    wire in_fb     = (x_count >= FB_X0) && (x_count < FB_X0 + 10'd256) &&
                     (y_count >= FB_Y0) && (y_count < FB_Y0 + 10'd192);

// Bring-up dressing around the framebuffer window: an orange ring at the
// active-area edge, colour bars across the top band (any colour other than
// black or white proves the DDR link carries components intact), and a marker
// sweeping one pixel per frame along the bottom band to show the 60 Hz
// cadence. The framebuffer window itself shows the machine - black until the
// ROM loader lands in P2. Gated so P2 can turn the dressing off.
    localparam bit BRINGUP_BANDS = 1'b1;

    function automatic [23:0] palette(input [2:0] idx);
        case (idx)
            3'd0: palette = 24'hFFFFFF;  // white
            3'd1: palette = 24'hFFFF00;  // yellow
            3'd2: palette = 24'h00FFFF;  // cyan
            3'd3: palette = 24'h00FF00;  // green
            3'd4: palette = 24'hFF00FF;  // magenta
            3'd5: palette = 24'hFF0000;  // red
            3'd6: palette = 24'h0000FF;  // blue
            3'd7: palette = 24'h404040;  // grey
        endcase
    endfunction

    reg  [8:0]  marker_x = '0;

    wire in_ring   = (vx < 10'd2) || (vx >= 10'd318) ||
                     (vy < 10'd2) || (vy >= 10'd238);
    wire in_top    = (vy >= 10'd2)   && (vy < 10'd24);
    wire in_bot    = (vy >= 10'd216) && (vy < 10'd238);
    wire in_marker = in_bot && (vx >= {1'b0, marker_x}) &&
                               (vx <  {1'b0, marker_x} + 10'd16);

// Virtual keyboard overlay. Its state lives in the machine domain and only
// changes at human speed, so plain synchronisers per field are enough - the
// worst case is one frame of mixed cursor position.
    wire        vkb_active_v, vkb_pressed_v, vkb_shift_v, vkb_ctl_v;
    wire        vkb_graph_v;
    wire [2:0]  vkb_row_v;
    wire [3:0]  vkb_col_v;
synch_3         s_vkb_a (vkb_active,  vkb_active_v,  clk_vid);
synch_3         s_vkb_p (vkb_pressed, vkb_pressed_v, clk_vid);
synch_3         s_vkb_s (vkb_shift,   vkb_shift_v,   clk_vid);
synch_3         s_vkb_c (vkb_ctl,     vkb_ctl_v,     clk_vid);
synch_3         s_vkb_g (graph_flag,  vkb_graph_v,   clk_vid);
synch_3 #(3)    s_vkb_r (vkb_row,     vkb_row_v,     clk_vid);
synch_3 #(4)    s_vkb_l (vkb_col,     vkb_col_v,     clk_vid);

// The overlay reads its glyphs one clock ahead (BRAM latency), so it gets
// next-pixel coordinates; its outputs line up with the current pixel just
// like the framebuffer prefetch above.
    wire        in_active_n = (nx >= VID_H_BPORCH) &&
                              (nx <  VID_H_BPORCH + VID_H_ACTIVE) &&
                              (y_count >= VID_V_BPORCH) &&
                              (y_count <  VID_V_BPORCH + VID_V_ACTIVE);

    wire        ovl_hit;
    wire [23:0] ovl_rgb;

jr100_vkb_overlay vkb_overlay (
    .clk        ( clk_vid ),

    .nx         ( nx - VID_H_BPORCH ),
    .ny         ( y_count - VID_V_BPORCH ),
    .in_active_n( in_active_n ),

    .active     ( vkb_active_v ),
    .cur_row    ( vkb_row_v ),
    .cur_col    ( vkb_col_v ),
    .pressed    ( vkb_pressed_v ),
    .shift_held ( vkb_shift_v ),
    .ctl_held   ( vkb_ctl_v ),
    .graph_mode ( vkb_graph_v ),

    // shadow of the boot.rom character generator (first 1 KiB of the stream)
    .crom_clk   ( clk_sys ),
    .crom_wr    ( rom_wr && (rom_wr_addr[27:10] == 18'd0) ),
    .crom_addr  ( rom_wr_addr[9:0] ),
    .crom_data  ( rom_wr_data ),

    .hit        ( ovl_hit ),
    .rgb        ( ovl_rgb )
);

// Display colour: classic monochrome-monitor phosphors, same set as the
// MiSTer OSD. The JR-100's optional dedicated monitor (TR-120MIC) was a
// green display.
    wire [2:0]  cfg_color_v;
synch_3 #(3) s_cfg_col (cfg_color_74, cfg_color_v, clk_vid);

    reg [23:0] fg_color;
always @(*) begin
    case (cfg_color_v)
        3'd0: fg_color = 24'hFFFFFF;   // White
        3'd1: fg_color = 24'h33FF33;   // Green (P1)
        3'd2: fg_color = 24'hFFB000;   // Amber (P3)
        3'd3: fg_color = 24'h66FFFF;   // Cyan
        3'd4: fg_color = 24'hFF8020;   // Orange
        3'd5: fg_color = 24'h99BBFF;   // Blue
        3'd6: fg_color = 24'hFFE8C8;   // Paper
        default: fg_color = 24'hCCFFCC; // Mint
    endcase
end

    wire [23:0] fb_rgb   = fb_pix ? fg_color : 24'h000000;

    wire [23:0] scan_rgb = !in_active     ? 24'h000000 :
                           ovl_hit        ? ovl_rgb :
                           in_fb          ? fb_rgb :
                           !BRINGUP_BANDS ? 24'h000000 :
                           in_ring        ? 24'hFF8000 :
                           in_marker      ? 24'hFFFFFF :
                           in_top         ? palette(vx[7:5]) :
                           in_bot         ? 24'h202020 :
                                            24'h101010;

// -- scan counters and registered outputs, template-style -------------------

    reg [23:0]  vidout_rgb = 24'd0;
    reg         vidout_de  = 1'b0;
    reg         vidout_hs  = 1'b0;
    reg         vidout_vs  = 1'b0;

always @(posedge clk_vid) begin
    if (!reset_n_vid) begin
        x_count    <= '0;
        y_count    <= '0;
        marker_x   <= '0;
        vidout_rgb <= 24'd0;
        vidout_de  <= 1'b0;
        vidout_hs  <= 1'b0;
        vidout_vs  <= 1'b0;
    end else begin
        vidout_vs <= 1'b0;
        vidout_hs <= 1'b0;

        x_count <= nx;
        if (x_count == VID_H_TOTAL - 10'd1)
            y_count <= (y_count == VID_V_TOTAL - 10'd1) ? 10'd0
                                                        : y_count + 10'd1;

        // single-cycle strobes in the back porch, a few clocks apart
        if (x_count == 10'd0 && y_count == 10'd0) begin
            vidout_vs <= 1'b1;
            marker_x  <= (marker_x >= 9'd302) ? 9'd0 : marker_x + 9'd1;
        end
        if (x_count == 10'd3)
            vidout_hs <= 1'b1;

        vidout_de  <= in_active;
        vidout_rgb <= scan_rgb;
    end
end

assign video_rgb          = vidout_rgb;
assign video_de           = vidout_de;
assign video_hs           = vidout_hs;
assign video_vs           = vidout_vs;
assign video_skip         = 1'b0;
assign video_rgb_clock    = clk_vid;
assign video_rgb_clock_90 = clk_vid_90;

// unused machine outputs on this path; keep them observable so the tools do
// not prune the ports.
    wire unused_syncs = vid_hs | vid_vs;


////////////////////////////////////////////////////////////////////////////////
// Audio
//
// The JR-100's sound is the VIA Timer 1 square wave; jr100_top already
// applies the output gating and band limiting the MiSTer core uses.
//
// Feeding the raw 0/+0x4000 gate straight into I2S sounded broken on the
// device: every note start/stop is a 25%-full-scale DC step, which the
// Pocket's DAC and small speaker reproduce as pops and apparent clipping.
//
// With only DC blocking (fc ~30 Hz) the tone came out clean over the dock
// but "a bit bassy" everywhere and harsh on the built-in speaker: a full
// square wave carries low-end and high harmonics the real JR-100's small
// speaker physically cannot reproduce - its thin bright "pi!" IS that
// band limit. So the output stage models the speaker: a one-pole high-pass
// at ~240 Hz (fc = fs/(2*pi*32)) thins the lows the way a small cone does,
// and a one-pole low-pass at ~7.5 kHz softens the harmonics that excited
// the Pocket's speaker. Shift-and-add only; silence still decays to zero.
////////////////////////////////////////////////////////////////////////////////

    // ~48 kHz sample enable: 57.272727 MHz / 1193 = 48.007 kHz
    reg  [10:0]        cen_aud_cnt = 11'd0;
    reg                cen_aud = 1'b0;
always @(posedge clk_sys) begin
    cen_aud <= 1'b0;
    if (cen_aud_cnt == 11'd1192) begin
        cen_aud_cnt <= 11'd0;
        cen_aud     <= 1'b1;
    end else begin
        cen_aud_cnt <= cen_aud_cnt + 11'd1;
    end
end

    wire signed [17:0] aud_x = jr_audio ? 18'sd16384 : 18'sd0;
    reg  signed [17:0] aud_x1 = 18'sd0;
    reg  signed [17:0] aud_hp = 18'sd0;   // high-pass state (~240 Hz)
    reg  signed [17:0] aud_lp = 18'sd0;   // low-pass state (~7.5 kHz)
    wire signed [17:0] aud_d  = aud_hp - aud_lp;
always @(posedge clk_sys) begin
    if (cen_aud) begin
        aud_x1 <= aud_x;
        aud_hp <= aud_x - aud_x1 + (aud_hp - (aud_hp >>> 5));
        aud_lp <= aud_lp + (aud_d >>> 1) + (aud_d >>> 3);   // k = 5/8
    end
end

    // |aud_lp| never exceeds ~1.5x the step size, well inside 16 bits; the
    // clamp is defensive only.
    wire signed [15:0] audio_pcm =
        (aud_lp > 18'sd32767)  ? 16'sd32767  :
        (aud_lp < -18'sd32768) ? -16'sd32768 : aud_lp[15:0];

sound_i2s #(
    .CHANNEL_WIDTH ( 16 ),
    .SIGNED_INPUT  ( 1 )
) sound_i2s (
    .clk_74a    ( clk_74a ),
    .clk_audio  ( clk_sys ),

    .audio_l    ( audio_pcm ),
    .audio_r    ( audio_pcm ),

    .audio_mclk ( audio_mclk ),
    .audio_lrck ( audio_lrck ),
    .audio_dac  ( audio_dac )
);

endmodule

`default_nettype wire
