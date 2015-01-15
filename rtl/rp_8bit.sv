/*
 * RP8 processor core
 * Copyright (C) 2014, 2014 Iztok Jeras
 * Copyright (C) 2007, 2008, 2009, 2010 Sebastien Bourdeauducq
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, version 3 of the License.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

module rp_8bit #(
  parameter int unsigned IRW =  8, // interrupt request width
  parameter int unsigned PAW = 11, // 16 bit words
  parameter int unsigned DAW = 13  //  8 bit bytes
)(
  // system signals
  input  logic           clk,
  input  logic           rst,
  // program bus
  output logic           bp_vld, // valid (address, write enable, write data)
  output logic           bp_wen, // write enable
  output logic [PAW-1:0] bp_adr, // address
  output logic  [16-1:0] bp_wdt, // write data
  input  logic  [16-1:0] bp_rdt, // read data
  input  logic [PAW-1:0] bp_npc, // new PC
  input  logic           bp_jmp, // debug jump request
  input  logic           bp_rdy, // ready (read data, new PC, debug jump request)
  // I/O peripheral bus
  output logic           io_wen, // write enable
  output logic           io_ren, // read  enable
  output logic   [6-1:0] io_adr, // address
  output logic   [8-1:0] io_wdt, // write data
  input  logic   [8-1:0] io_msk, // write mask
  input  logic   [8-1:0] io_rdt, // read data
  // data bus
  output logic           bd_req,
  output logic           bd_wen,
  output logic [DAW-1:0] bd_adr,
  output logic   [8-1:0] bd_wdt,
  input  logic   [8-1:0] bd_rdt,
  input  logic           bd_ack,
  // interrupt
  input  logic [IRW-1:0] irq_req,
  output logic [IRW-1:0] irq_ack
);

////////////////////////////////////////////////////////////////////////////////
// calculated parameters
////////////////////////////////////////////////////////////////////////////////

// maximum address width
localparam int unsigned MAW = PAW > DAW ? PAW : DAW;

// adder destination width
localparam int unsigned AW = MAW > 16 ? MAW : 16;

////////////////////////////////////////////////////////////////////////////////
// helper functions
////////////////////////////////////////////////////////////////////////////////

// binary to one hot
function logic [8-1:0] b2o (input logic [3-1:0] b);
  b2o = 8'h01 << b;
endfunction

////////////////////////////////////////////////////////////////////////////////
// type definitions
////////////////////////////////////////////////////////////////////////////////

// register file structure
typedef union packed {
  logic [32-1:0] [8-1:0] idx;
  struct packed {
    logic             [16-1:0] z, y, x;
    logic [32-2*3-1:0] [8-1:0] r;
  } nam;
} gpr_t;

// program memory pointer
typedef struct packed {
  logic [8-1:0] e;
  logic [8-1:0] h;
  logic [8-1:0] l;
} ifu_ptr_t;

// data memory pointer
typedef struct packed {
  logic [8-1:0] e;
  logic [8-1:0] h;
  logic [8-1:0] l;
} lsu_ptr_t;

// status register
typedef struct packed {logic i, t, h, s, v, n, z, c;} sreg_t;

// general purpose registers decode structure
typedef struct packed {
  // write access
  logic          we; // write enable
  logic          ww; // write word (0 - 8 bit mode, 1 - 16 bit mode)
  logic [16-1:0] wd; // write data 16 bit
  logic  [5-1:0] wa; // write address 
  // read word (16 bit) access
  logic  [5-1:0] rw; // read word address
  // read byte (8 bit) access
  logic  [5-1:0] rb; // read byte address
} gpr_dec_t;

// arithmetic logic unit decode structure
typedef struct packed {
  enum logic [2:0] {
    ADD = 3'b000, // addition
    SUB = 3'b001, // subtraction
    ADW = 3'b010, // addition    for word or address
    SBW = 3'b011, // subtraction for word or address
    AND = 3'b100, // logic and
    OR  = 3'b101, // logic or
    EOR = 3'b110, // logic eor
    SHR = 3'b111  // shift right
  } m;             // alu modes
  logic [8-1:0] d; // destination register value
  logic [8-1:0] r; // source      register value
  logic         c; // carry input
} alu_dec_t;

// multiplier decode structure
struct packed {
  struct packed {
    logic f; // fractional
    logic d; // destination (0 - unsigned, 1 - signed)
    logic r; // source      (0 - unsigned, 1 - signed)
  } m;             // adder modes
  logic [8-1:0] d; // destination register value
  logic [8-1:0] r; // source      register value
} mul_dec_t;

// status register decode structure
typedef struct packed {
  sreg_t s; // status
  sreg_t m; // mask
} srg_dec_t;

// instruction fetch unit decode structure
typedef struct packed {
  logic           sk; // skeep
  logic           be; // branch enable
  logic [PAW-1:0] ad; // address
  logic           we; // write enable (for SPM instruction)
  logic  [16-1:0] wd; // write data   (for SPM instruction)
} ifu_dec_t;

// input/output unit decode structure
typedef struct packed {
  logic           we; // write enable
  logic           re; // read  enable
  logic   [6-1:0] ad; // address
  logic   [8-1:0] wd; // write data
  logic   [8-1:0] ms; // write mask
} iou_dec_t;

typedef struct packed {
  logic           en; // enable
  logic           we; // write enable
  logic           st; // stack push/pop
  logic           sb; // subroutine/interrupt call/return
  logic [DAW-1:0] ad; // address
  logic   [8-1:0] wd; // write data
} lsu_dec_t;

// control decode structure
typedef struct packed {
  logic           slp; // sleep
  logic           brk; // break
  logic           wdr; // watchdog reset
} ctl_dec_t;

// entire decode structure
typedef struct packed {
  gpr_dec_t gpr; // general purpose registers
  alu_dec_t alu; // arithmetic logic unit
  alu_dec_t add; // address adder
  srg_dec_t srg; // status register
  ifu_dec_t ifu; // instruction fetch unit
  iou_dec_t iou; // input/output unit
  lsu_dec_t lsu; // load/store unit
  ctl_dec_t ctl; // control
} dec_t;

dec_t dec;

////////////////////////////////////////////////////////////////////////////////
// local variables
////////////////////////////////////////////////////////////////////////////////

// program word
logic [16-1:0] pw;

// read register values
logic  [8-1:0] Rd; // destination
logic  [8-1:0] Rr; // source
logic [16-1:0] Rw; // word
logic  [8-1:0] Rs; // nibble swap of Rd

// I/O read value
logic  [8-1:0] id;

// core state registers
ifu_ptr_t pc;    // program counter
lsu_ptr_t sp;    // stack pointer
sreg_t    sreg;  // status register
gpr_t     gpr;   // register file

// various sources of core stall
logic stall;

// ALU results
logic  [AW-0:0] alu_t; // result (full width plus carry)
logic   [8-1:0] alu_r; // result (8 bit byte)
sreg_t          alu_b; // status for ( 8 bit byte operations)
sreg_t          alu_w; // status for (16 bit word operations)
sreg_t          alu_s; // status

// multiplication results
logic [18-1:0] mul_t; // result tmp
logic [16-1:0] mul_r; // result
sreg_t         mul_s;

////////////////////////////////////////////////////////////////////////////////
// register addresses and immediates
////////////////////////////////////////////////////////////////////////////////

// bit constants
localparam logic          CX = 1'bx;
localparam logic          C0 = 1'b0;
localparam logic          C1 = 1'b1;

// byte (8 bit) constants
localparam logic  [8-1:0] KX = 8'hxx;
localparam logic  [8-1:0] K0 = 8'h00;
localparam logic  [8-1:0] KF = 8'hff;

// word (16 bit) constants
localparam logic [16-1:0] WX = 16'hxxxx;
localparam logic [16-1:0] W0 = 16'h0000;
localparam logic [16-1:0] WF = 16'hffff;

// register address constant
localparam logic [5-1:0] RX = 5'hxx;
localparam logic [5-1:0] R0 = 5'h00; // R1:R0 used for multiplication destination address
localparam logic [5-1:0] DX = 5'h1a; // index register X
localparam logic [5-1:0] DY = 5'h1c; // index register Y
localparam logic [5-1:0] DZ = 5'h1e; // index register Z

// program word (just a short variable name)
// TODO, there should be a registered version of the previous instruction for 32bit instructions
assign pw = bp_rdt;

// destination/source register address for full space bytes (used by MOV and arithmetic)
logic [5-1:0] db =         pw[8:4] ;
logic [5-1:0] rb = {pw[9], pw[3:0]};
// destination/source register address for full space words (used by MOVW)
logic [5-1:0] dw =        {pw[7:4], 1'b0};
logic [5-1:0] rw =        {pw[3:0], 1'b0};
// destination/source register address for high half space (used by MULS, arithmetic immediate, load store direct)
logic [5-1:0] dh =  {1'b1, pw[7:4]};
logic [5-1:0] rh =  {1'b1, pw[3:0]};
// destination/source register address for third quarter space (used by *MUL*)
logic [5-1:0] dm = {2'b10, pw[6:4]};
logic [5-1:0] rm = {2'b10, pw[2:0]};
// destination register address for index registers (used by ADIW/SBIW)
logic [5-1:0] di = {2'b11, pw[5:4], 1'b0};

// byte (8 bit) immediate for ALU operations
logic [8-1:0] kb = {pw[11:8], pw[3:0]};
// word (6bit) for address adder
logic [6-1:0] kw = {pw[7:6], pw[3:0]};

logic signed [12-1:0] Kl = pw[11:0];
logic signed  [7-1:0] Ks = pw[ 9:3];
logic         [6-1:0] q = {pw[13], pw[11:10], pw[2:0]};

// bit address
logic [3-1:0] b  = pw[2:0];

// reusable_results
logic Rd_b = Rd[b];

////////////////////////////////////////////////////////////////////////////////
// instruction decoder
////////////////////////////////////////////////////////////////////////////////

// constants for idling units
localparam gpr_dec_t GPR = '{we: C0, ww: C0, wd: WX, wa: 5'hxx, rb: RX, rw: RX};
localparam alu_dec_t ALU = '{m: 3'bxxx, d: KX, r: KX, c: CX};
localparam alu_dec_t MUL = '{m: 3'bxxx, d: KX, r: KX};
localparam srg_dec_t SRG = '{s: KX, m: K0};
localparam ifu_dec_t IFU = '{sk: C0, be: C0, ad: {PAW{CX}}, we: C0, wd: WX};
localparam iou_dec_t IOU = '{we: C0, re: C0, ad: 6'hxx, wd: KX, ms: KX};
localparam lsu_dec_t LSU = '{cs: C0, we: CX, ty: 2'bxx, ad: {DAW{CX}}};
localparam ctl_dec_t CTL = '{slp: C0, brk: C0, wdr: C0};

always_comb
casez (pw)
  // no operation, same as default
  16'b0000_0000_0000_0000: begin dec = '{ GPR, ALU, SRG, IFU, IOU, LSU, CTL }; end // NOP
  // arithmetic
  //                                    {  gpr                                alu                          srg                                }
  //                                    {  {we, ww, wd        , wa, rw, rb}   {m  , d , r , c     }        {s    , m    }                     }
  16'b0000_01??_????_????: begin dec = '{ '{C0, CX, WX        , RX, db, rb}, '{SUB, Rd, Rr, sreg.c}, MUL, '{alu_s, 8'h3f}, IFU, IOU, LSU, CTL }; end // CPC
  16'b0000_10??_????_????: begin dec = '{ '{C1, C0, {2{alu_r}}, db, db, rb}, '{SUB, Rd, Rr, sreg.c}, MUL, '{alu_s, 8'h3f}, IFU, IOU, LSU, CTL }; end // SBC
  16'b0000_11??_????_????: begin dec = '{ '{C1, C0, {2{alu_r}}, db, db, rb}, '{ADD, Rd, Rr, C0    }, MUL, '{alu_s, 8'h3f}, IFU, IOU, LSU, CTL }; end // ADD
  16'b0001_01??_????_????: begin dec = '{ '{C0, C0, WX        , RX, db, rb}, '{SUB, Rd, Rr, C0    }, MUL, '{alu_s, 8'h3f}, IFU, IOU, LSU, CTL }; end // CP
  16'b0001_10??_????_????: begin dec = '{ '{C1, C0, {2{alu_r}}, db, db, rb}, '{SUB, Rd, Rr, C0    }, MUL, '{alu_s, 8'h3f}, IFU, IOU, LSU, CTL }; end // SUB
  16'b0001_11??_????_????: begin dec = '{ '{C1, C0, {2{alu_r}}, db, db, rb}, '{ADD, Rd, Rr, sreg.c}, MUL, '{alu_s, 8'h3f}, IFU, IOU, LSU, CTL }; end // ADC
  16'b0011_????_????_????: begin dec = '{ '{C0, CX, WX        , RX, dw, RX}, '{SUB, Rd, kb, C0    }, MUL, '{alu_s, 8'h3f}, IFU, IOU, LSU, CTL }; end // CPI
  16'b0100_????_????_????: begin dec = '{ '{C1, C0, {2{alu_r}}, dw, dw, RX}, '{SUB, Rd, kb, sreg.c}, MUL, '{alu_s, 8'h3f}, IFU, IOU, LSU, CTL }; end // SBCI
  16'b0101_????_????_????: begin dec = '{ '{C1, C0, {2{alu_r}}, dw, dw, RX}, '{SUB, Rd, kb, C0    }, MUL, '{alu_s, 8'h3f}, IFU, IOU, LSU, CTL }; end // SUBI
  16'b1001_010?_????_0000: begin dec = '{ '{C1, C0, {2{alu_r}}, db, db, RX}, '{SUB, KF, Rd, C0    }, MUL, '{alu_s, 8'h1f}, IFU, IOU, LSU, CTL }; end // COM
  // TODO check the value of carry and overflow
  16'b1001_010?_????_0001: begin dec = '{ '{C1, C0, {2{alu_r}}, db, db, RX}, '{SUB, K0, Rd, C0    }, MUL, '{alu_s, 8'h3f}, IFU, IOU, LSU, CTL }; end // NEG
  16'b1001_010?_????_0011: begin dec = '{ '{C1, C0, {2{alu_r}}, db, db, RX}, '{ADD, Rd, K0, C1    }, MUL, '{alu_s, 8'h3e}, IFU, IOU, LSU, CTL }; end // INC
  16'b1001_010?_????_1010: begin dec = '{ '{C1, C0, {2{alu_r}}, db, db, RX}, '{SUB, Rd, K0, C1    }, MUL, '{alu_s, 8'h3e}, IFU, IOU, LSU, CTL }; end // DEC
  // logic // TODO check flags
  16'b0010_00??_????_????: begin dec = '{ '{C1, C0, {2{alu_r}}, db, db, rb}, '{AND, Rd, Rr, C0    }, MUL, '{alu_s, 8'h1e}, IFU, IOU, LSU, CTL }; end // AND
  16'b0111_????_????_????: begin dec = '{ '{C1, C0, {2{alu_r}}, dw, dw, RX}, '{AND, Rd, kb, C0    }, MUL, '{alu_s, 8'h1e}, IFU, IOU, LSU, CTL }; end // ANDI
  16'b0010_10??_????_????: begin dec = '{ '{C1, C0, {2{alu_r}}, db, db, rb}, '{OR , Rd, Rr, C0    }, MUL, '{alu_s, 8'h1e}, IFU, IOU, LSU, CTL }; end // OR
  16'b0110_????_????_????: begin dec = '{ '{C1, C0, {2{alu_r}}, dw, dw, RX}, '{OR , Rd, kb, C0    }, MUL, '{alu_s, 8'h1e}, IFU, IOU, LSU, CTL }; end // ORI
  16'b0010_01??_????_????: begin dec = '{ '{C1, C0, {2{alu_r}}, db, db, rb}, '{EOR, Rd, Rr, C0    }, MUL, '{alu_s, 8'h1e}, IFU, IOU, LSU, CTL }; end // EOR
  // shift right // TODO check flags
  16'b1001_010?_????_0110: begin dec = '{ '{C1, C0, {2{alu_r}}, db, db, RX}, '{SHR, Rd, K0, C0    }, MUL, '{alu_s, 8'h1f}, IFU, IOU, LSU, CTL }; end // LSR
  16'b1001_010?_????_0111: begin dec = '{ '{C1, C0, {2{alu_r}}, db, db, RX}, '{SHR, Rd, K0, sreg.c}, MUL, '{alu_s, 8'h1f}, IFU, IOU, LSU, CTL }; end // ROR
  16'b1001_010?_????_0101: begin dec = '{ '{C1, C0, {2{alu_r}}, db, db, RX}, '{SHR, Rd, K0, Rd[7] }, MUL, '{alu_s, 8'h1f}, IFU, IOU, LSU, CTL }; end // ASR
  // multiplication
  //                                    {  gpr                                mul                       srg                                }
  //                                    {  {we, ww, wd   , wa, rw, rb}        {m{f , d , r }, d , r }   {s    , m    }                     }
  16'b1001_11??_????_????: begin dec = '{ '{C1, C1, mul_r, R0, db, rb}, ALU, '{'{C0, C0, C0}, Rd, Rr}, '{mul_s, 8'h03}, IFU, IOU, LSU, CTL }; end // MUL
  16'b0000_0010_????_????: begin dec = '{ '{C1, C1, mul_r, R0, dh, rh}, ALU, '{'{C0, C1, C1}, Rd, Rr}, '{mul_s, 8'h03}, IFU, IOU, LSU, CTL }; end // MULS
  16'b0000_0011_0???_0???: begin dec = '{ '{C1, C1, mul_r, R0, dm, rm}, ALU, '{'{C0, C1, C0}, Rd, Rr}, '{mul_s, 8'h03}, IFU, IOU, LSU, CTL }; end // MULSU
  16'b0000_0011_0???_1???: begin dec = '{ '{C1, C1, mul_r, R0, dm, rm}, ALU, '{'{C1, C0, C0}, Rd, Rr}, '{mul_s, 8'h03}, IFU, IOU, LSU, CTL }; end // FMUL
  16'b0000_0011_1???_0???: begin dec = '{ '{C1, C1, mul_r, R0, dm, rm}, ALU, '{'{C1, C1, C1}, Rd, Rr}, '{mul_s, 8'h03}, IFU, IOU, LSU, CTL }; end // FMULS
  16'b0000_0011_1???_1???: begin dec = '{ '{C1, C1, mul_r, R0, dm, rm}, ALU, '{'{C1, C1, C0}, Rd, Rr}, '{mul_s, 8'h03}, IFU, IOU, LSU, CTL }; end // FMULSU
  // register moves
  //                                    {  gpr                                                         }
  //                                    {  {we, ww, wd     , wa, rw, rb}                               }
  16'b0010_11??_????_????: begin dec = '{ '{C1, C0, {2{Rr}}, db, db, rb}, ALU, MUL, SRG, IFU, IOU, LSU, CTL }; end // MOV
  16'b1110_????_????_????: begin dec = '{ '{C1, C0, {2{kb}}, dw, dw, RX}, ALU, MUL, SRG, IFU, IOU, LSU, CTL }; end // LDI
  16'b1001_010?_????_0010: begin dec = '{ '{C1, C0, {2{Rs}}, db, db, RX}, ALU, MUL, SRG, IFU, IOU, LSU, CTL }; end // SWAP
  // bit manipulation
  //                                    {                 srg                                    }
  //                                    {                 {s , m           }                     }
  16'b1001_010?_0???_1000: begin dec = '{ GPR, ALU, MUL, '{KF, b2o(pw[6:4])}, IFU, IOU, LSU, CTL }; end // BSET // create a common source instead of two b2o functions
  16'b1001_010?_1???_1000: begin dec = '{ GPR, ALU, MUL, '{K0, b2o(pw[6:4])}, IFU, IOU, LSU, CTL }; end // BCLR
  // 16-24 bit adder
  16'b1001_0110_????_????: begin dec = '{ '{C1, C1, alu_r, di, di, RX}, '{ADW, Rw, kw, C0}, MUL, '{alu_s, 8'h1f}, IFU, IOU, LSU, CTL }; end // ADIW
  16'b1001_0111_????_????: begin dec = '{ '{C1, C1, alu_r, di, di, RX}, '{SBW, Rw, kw, C0}, MUL, '{alu_s, 8'h1f}, IFU, IOU, LSU, CTL }; end // SBIW
  // bit manipulation
  16'b1111_101?_????_0???: begin dec = '{ '{C0, CX, WX                                      , RX, db, RX}, ALU, MUL, '{{CX,Rd_b,6'hxx}, 8'h40}, IFU, IOU, LSU, CTL }; end // SBT
  16'b1111_100?_????_0???: begin dec = '{ '{C1, C0, {2{Rd & ~b2o(b) | {8{sreg.t}} & b20(b)}}, db, db, RX}, ALU, MUL, SRG                      , IFU, IOU, LSU, CTL }; end // BLD  // TODO: ALU could be used

  /* TODO: SLEEP is not implemented */
  /* TODO: BREAK is not implemented */
  /* TODO: WDR is not implemented */
  // TODO: separate load from store instructions
//  16'b1001_00??_????_1111, // PUSH/POP
//  16'b1001_00??_????_1111, // PUSH/POP
  //                                    {  gpr                                   alu                                     lsu                   }
  //                                    {  {we, ww, wd           , wa, rw, rb}   {m  , d , r , c }                       {cs, we, ty, ad}      }
  16'b1001_00??_????_1100: begin dec = '{ '{C0, CX, WX           , RX, DX, RX}, ALU               , MUL, SRG, IFU, IOU, '{C1, C0, RG, ex}, CTL }; end // X
  16'b1001_00??_????_1101: begin dec = '{ '{C1, C1, alu_t[16-1:0], DX, DX, RX}, '{ADW, Rd, K0, C1}, MUL, SRG, IFU, IOU, '{C1, C0, RG, ex}, CTL }; end // X+
  16'b1001_00??_????_1110: begin dec = '{ '{C1, C1, alu_t[16-1:0], DX, DX, RX}, '{SBW, Rd, K0, C1}, MUL, SRG, IFU, IOU, '{C1, C0, RG, ea}, CTL }; end // -X
  16'b10?0_????_????_1???: begin dec = '{ '{C0, CX, WX           , RX, DY, RX}, '{ADW, Rd, q , C0}, MUL, SRG, IFU, IOU, '{C1, C0, RG, ea}, CTL }; end // Y+q
  16'b1001_00??_????_1001: begin dec = '{ '{C1, C1, alu_t[16-1:0], DY, DY, RX}, '{ADW, Rd, K0, C1}, MUL, SRG, IFU, IOU, '{C1, C0, RG, ey}, CTL }; end // Y+
  16'b1001_00??_????_1010: begin dec = '{ '{C1, C1, alu_t[16-1:0], DY, DY, RX}, '{SBW, Rd, K0, C1}, MUL, SRG, IFU, IOU, '{C1, C0, RG, ea}, CTL }; end // -Y
  16'b10?0_????_????_0???: begin dec = '{ '{C0, CX, WX           , RX, DZ, RX}, '{ADW, Rd, q , C0}, MUL, SRG, IFU, IOU, '{C1, C0, RG, ea}, CTL }; end // Z+q
  16'b1001_00??_????_0001: begin dec = '{ '{C1, C1, alu_t[16-1:0], DZ, DZ, RX}, '{ADW, Rd, K0, C1}, MUL, SRG, IFU, IOU, '{C1, C0, RG, ez}, CTL }; end // Z+
  16'b1001_00??_????_0010: begin dec = '{ '{C1, C1, alu_t[16-1:0], DZ, DZ, RX}, '{SBW, Rd, K0, C1}, MUL, SRG, IFU, IOU, '{C1, C0, RG, ea}, CTL }; end // -Z
  // I/O instructions
  //                                    {  gpr                                                  iou                                }
  //                                    {  {we, ww, wd      , wa, rw, rb}                       {we, re, ad, wd, ms    }           }
  16'b1011_0???_????_????: begin dec = '{ '{C1, C0, io_rdt  , db, RX, RX}, ALU, MUL, SRG, IFU, '{C0, C1, a , KX, KX    }, LSU, CTL }; end // IN
  16'b1011_1???_????_????: begin dec = '{ '{C0, C0, 16'hxxxx, RX, db, RX}, ALU, MUL, SRG, IFU, '{C1, C0, a , Rd, KF    }, LSU, CTL }; end // OUT
  16'b1001_1000_????_????: begin dec = '{ GPR                            , ALU, MUL, SRG, IFU, '{C1, C0, a , K0, b2o(b)}, LSU, CTL }; end // CBI
  16'b1001_1010_????_????: begin dec = '{ GPR                            , ALU, MUL, SRG, IFU, '{C1, C0, a , KF, b2o(b)}, LSU, CTL }; end // SBI
  // skips
  //                                    {  gpr                            alu                           ifu                            iou                            }
  //                                    {  {we, ww, wd    , wa, rw, rb}   {m  , d , r , c }             {sk        , be, ad, we, wd}   {we, re, ad, wd, ms}           }
  16'b0001_00??_????_????: begin dec = '{ '{C0, CX, {2{KX}, RX, db, rb}, '{SUB, Rd, Rr, C0}, MUL, SRG, '{ alu_s.z  , C0, 'x, C0, WX}, IOU                  , LSU, CTL }; end // CPSE
  16'b1001_1001_????_????: begin dec = '{ GPR                          , ALU               , MUL, SRG, '{~io_rdt[b], C0, 'x, C0, WX}, '{C0, C1, a , KX, KX}, LSU, CTL }; end // SBIC
  16'b1001_1011_????_????: begin dec = '{ GPR                          , ALU               , MUL, SRG, '{ io_rdt[b], C0, 'x, C0, WX}, '{C0, C1, a , KX, KX}, LSU, CTL }; end // SBIS
  16'b1111_110?_????_0???: begin dec = '{ '{C0, CX, {2{KX}, RX, db, RX}, ALU               , MUL, SRG, '{~Rd_b     , C0, 'x, C0, WX}, '{C0, C1, a , KX, KX}, LSU, CTL }; end // SBRC
  16'b1111_111?_????_0???: begin dec = '{ '{C0, CX, {2{KX}, RX, db, RX}, ALU               , MUL, SRG, '{ Rd_b     , C0, 'x, C0, WX}, '{C0, C1, a , KX, KX}, LSU, CTL }; end // SBRS
  // flow control
  16'b1100_????_????_????: begin dec = '{ GPR                          , '{SUB, PC, k , C1}, MUL, SRG, '{C0, C1, alu_t[PAW-1:0], C0, WX}, IOU, LSU              , CTL }; end // RJMP
  16'b1101_????_????_????: begin dec = '{ GPR                          , '{SUB, PC, k , C1}, MUL, SRG, '{C0, C1, alu_t[PAW-1:0], C0, WX}, IOU, '{C1, C1, PC, 'x}, CTL }; end // RCALL
  16'b1001_0100_0000_1001: begin dec = '{ '{C0, CX, {2{KX}, RX, DZ, RX}, ALU               , MUL, SRG, '{C0, C1, Rw            , C0, WX}, IOU, LSU              , CTL }; end // IJMP
  16'b1001_0101_0000_1001: begin dec = '{ '{C0, CX, {2{KX}, RX, DZ, RX}, ALU               , MUL, SRG, '{C0, C1, Rw            , C0, WX}, IOU, '{C1, C1, PC, 'x}, CTL }; end // ICALL
  16'b1001_0101_000?_1000: begin dec = '{}; end // RET / RETI
  // branches
  16'b1111_00??_????_????, begin dec = '{ GPR, '{ADW, PC, q , C0}, MUL, SRG, '{C0, C1, alu_t[PAW-1:0], C0, WX}, IOU, LSU, CTL }; end // BRBS
  16'b1111_01??_????_????, begin dec = '{ GPR, '{ADW, PC, q , C0}, MUL, SRG, '{C0, C1, alu_t[PAW-1:0], C0, WX}, IOU, LSU, CTL }; end // BRBC

  16'b1001_00??_????_0000: begin	pc_sel = PC_SEL_INC; pmem_ce = 1'b1; next_state = (pmem_d[9]) ? STS : LDS1;end

  16'b1001_0101_1100_1000: begin	/* LPM */	pmem_selz = 1'b1;	pmem_ce = 1'b1;	next_state = LPM; end
  // no operation, same as NOP
  default:                 begin dec = '{ GPR, ALU, SRG, IFU, IOU, LSU, CTL }; end // NOP
endcase

////////////////////////////////////////////////////////////////////////////////
// register file access
////////////////////////////////////////////////////////////////////////////////

// GPR write access
always_ff @ (posedge clk)
if (writeback) begin
  // TODO, add writeback option from load/store unit
else if (~stall) begin
  if (dec.gpr.we) begin
    // TODO recode this, so it is appropriate for a register file or at least optimized
    if (dec.gpr.ww) gpr.idx [{wa[5-1:1], 1'b0}+:2] <= wd;
    else            gpr.idx [ wa                 ] <= wd[8-1:0];
  end
end

// read word access
assign Rw = gpr.idx [{rw[5-1:1], 1'b0}+:2];
assign Rd = gpr.idx [rw];

// read byte access
assign Rr = gpr.idx [rb];

// swap of Rd
assign Rs = {Rd[3:0], Rd[7:4]};

////////////////////////////////////////////////////////////////////////////////
// ALU (8 bit)
////////////////////////////////////////////////////////////////////////////////

// adder
// TODO optimize adder
always_comb
casez (dec.alu.m)
  3'b??0: alu_t = dec.alu.d + dec.alu.r + dec.alu.c;
  3'b??1: alu_t = dec.alu.d - dec.alu.r - dec.alu.c;
endcase

// ALU mode selection
// TODO optimize mode encoding to allign with opcode bits for ADD/SUB
always_comb
case (alu.md)
  ADD: begin  alu_s = alu_b;  alu_r = alu_t[8-1:0];                 end
  SUB: begin  alu_s = alu_b;  alu_r = alu_t[8-1:0];                 end
  ADW: begin  alu_s = alu_w;  alu_r = 'x;                           end
  SBW: begin  alu_s = alu_w;  alu_r = 'x;                           end
  AND: begin  alu_s = alu_b;  alu_r = dec.alu.d & dec.alu.r;        end
  OR : begin  alu_s = alu_b;  alu_r = dec.alu.d | dec.alu.r;        end
  EOR: begin  alu_s = alu_b;  alu_r = dec.alu.d ^ dec.alu.r;        end
  SHR: begin  alu_s = alu_b;  alu_r = {dec.alu.c, dec.alu.d[7:1]};  end
endcase

// status for ( 8 bit byte operations)
assign alu_b.i = 1'bx;
assign alu_b.t = 1'bx;
assign alu_b.h = dec.alu.d[3] & dec.alu.r[3] | dec.alu.r[3] & ~alu_r[3] | ~alu_r[3] & dec.alu.d[3];
assign alu_b.s = alu_b.n ^ alu_b.v;
assign alu_b.v = dec.alu.d[7] & dec.alu.r[7] & ~alu_r[7] | ~dec.alu.d[7] & ~dec.alu.r[7] & alu_r[7];
assign alu_b.n = alu_r[7];
assign alu_b.z = ~|alu_r;
assign alu_b.c = (dec.alu.m == SHR) ? dec.alu.d[0] : alu_t[8];

// status for (16 bit word operations)
assign alu_w.i = 1'bx;
assign alu_w.t = 1'bx;
assign alu_w.h = 1'bx;
assign alu_w.s = alu_w.n ^ alu_w.v;
assign alu_w.v = ~dec.alu.d[15] & dec.alu.r[15];
assign alu_w.n = alu_t[15];
assign alu_w.z = ~|alu_t[15:0];
assign alu_w.c = alu_t[16];

////////////////////////////////////////////////////////////////////////////////
// multiplier (8 bit * 8 bit)
////////////////////////////////////////////////////////////////////////////////

assign mul_t = $signed({dec.mul.m.d & dec.mul.d[7], dec.mul.d})
             * $signed({dec.mul.m.r & dec.mul.r[7], dec.add.r});

assign mul_r = dec.mul.m.f ? {mul_t[14:0], C0} : mul_t[15:0];

assign mul_s.i = 1'bx;
assign mul_s.t = 1'bx;
assign mul_s.h = 1'bx;
assign mul_s.s = 1'bx;
assign mul_s.v = 1'bx;
assign mul_s.n = 1'bx;
assign mul_s.z = ~|mul_r;
assign mul_s.c = mul_t[15];

////////////////////////////////////////////////////////////////////////////////
// status register access
////////////////////////////////////////////////////////////////////////////////

// SREG decode structure
srg_dec_t srg = dec.srg;

// SREG write access
always_ff @ (posedge clk, posedge rst)
if (rst)  sreg <= 8'b00000000;
else if (~stall) begin
  if (iou.wen & iou.adr==ADR_SREG)  sreg <= iou.wdt;
  else                              sreg <= (srg.s &  sreg.m)
                                          | (sreg  & ~sreg.m);
end

////////////////////////////////////////////////////////////////////////////////
// instruction fetch unit
////////////////////////////////////////////////////////////////////////////////

// reset status
logic ifu_rst;

always_ff @(posedge clk, posedge rst)
if (rst) ifu_rst <= 1'b1;
else     ifu_rst <= 1'b0;

// TODO exception code should be here too

// TODO EIND register should be here

////////////////////////////////////////////////////////////////////////////////
// I/O unit
////////////////////////////////////////////////////////////////////////////////

assign io_wen = dec.iou.we; // write enable
assign io_ren = dec.iou.re; // read  enable
assign io_adr = dec.iou.ad; // address
assign io_wdt = dec.iou.wd; // write data
assign io_msk = dec.iou.ms; // write mask
assign id = io_rdt;     // read data

// TODO: SP and SREG access
// TODO: access to extended address space registers is arround

////////////////////////////////////////////////////////////////////////////////
// load/store unit
////////////////////////////////////////////////////////////////////////////////

// SP incrementing decrementing is done here

// TODO RAMPX, RAMPY, RAMPZ

logic [DAW-1:0] ex, ex, ez, ea;

logic [DAW-16:0] rampx;
logic [DAW-16:0] rampy;
logic [DAW-16:0] rampz;
logic [DAW-16:0] rampd;

assign ex = {rampx, Rw};
assign ey = {rampy, Rw};
assign ez = {rampz, Rw};
assign ed = {rampd, Rw};

////////////////////////////////////////////////////////////////////////////////
// exceptions
////////////////////////////////////////////////////////////////////////////////

logic [IRW-1:0] next_irq_ack;

always_comb
casez (irq)
  8'b????_???1: next_irq_ack = 8'b0000_0001;
  8'b????_??10: next_irq_ack = 8'b0000_0010;
  8'b????_?100: next_irq_ack = 8'b0000_0100;
  8'b????_1000: next_irq_ack = 8'b0000_1000;
  8'b???1_0000: next_irq_ack = 8'b0001_0000;
  8'b??10_0000: next_irq_ack = 8'b0010_0000;
  8'b?100_0000: next_irq_ack = 8'b0100_0000;
  8'b1000_0000: next_irq_ack = 8'b1000_0000;
  default:      next_irq_ack = 8'b0000_0000;
endcase

logic irq_ack_en;

always_ff @(posedge clk, posedge rst)
if (rst) irq_ack <= '0;
else     irq_ack <= irq_ack_en ? next_irq_ack : '0;

/* Priority encoder */

logic [$clog2(IRW)-1:0] PC_ex;

always_comb
casez (irq)
  8'b????_???1: PC_ex = 3'h0;
  8'b????_??10: PC_ex = 3'h1;
  8'b????_?100: PC_ex = 3'h2;
  8'b????_1000: PC_ex = 3'h3;
  8'b???1_0000: PC_ex = 3'h4;
  8'b??10_0000: PC_ex = 3'h5;
  8'b?100_0000: PC_ex = 3'h6;
  8'b1000_0000: PC_ex = 3'h7;
  default:      PC_ex = 3'h0;
endcase

/* AVR cores always execute at least one instruction after an IRET.
 * Therefore, the I bit is only valid one clock after it has been set. */

logic I_r;

always_ff @(posedge clk, posedge rst)
if (rst) I_r <= 1'b0;
else     I_r <= sreg.i;

wire irq_asserted = |irq;
wire irq_request = sreg.i & I_r & irq_asserted;

////////////////////////////////////////////////////////////////////////////////
// __verilator__ specific bench code
////////////////////////////////////////////////////////////////////////////////

`ifdef verilator

function void dump_state_core (
  output bit [32-1:0] [8-1:0] dump_gpr ,
  output int                  dump_pc  ,
  output int                  dump_sp  ,
  output bit          [8-1:0] dump_sreg
);
/*verilator public*/
  dump_gpr  = gpr.idx;
  dump_pc   = PC;
  dump_sp   = SP;
  dump_sreg = sreg;
endfunction: dump_state_core

`endif

endmodule: rp_8bit
