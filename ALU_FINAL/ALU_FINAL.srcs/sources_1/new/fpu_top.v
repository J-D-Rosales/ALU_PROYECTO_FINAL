`timescale 1ns / 1ps
module fpu_top (
  input  wire        clk,
  input  wire        rst,
  input  wire        start,
  input  wire [31:0] op_a,
  input  wire [31:0] op_b,
  input  wire [1:0]  op_code,     // 00 ADD, 01 SUB, 10 MUL, 11 DIV
  input  wire        mode_fp,     // 0=half(16), 1=single(32)
  input  wire        round_mode,  // reservado; los bloques usan RNE
  output reg  [31:0] result,
  output reg         valid_out,
  output reg  [4:0]  flags        // {invalid, div_by_zero, overflow, underflow, inexact}
);

  // Códigos de operación
  parameter OP_ADD = 2'b00;
  parameter OP_SUB = 2'b01;
  parameter OP_MUL = 2'b10;
  parameter OP_DIV = 2'b11;

  // -----------------------------
  // Conversión de entradas (16->32 cuando mode_fp=0)
  // -----------------------------
  wire [31:0] a32_from16, b32_from16;
  // c=0 => 16->32 (usa [31:16] y expande)
  fp_converter u_convA_in (.din(op_a), .c(1'b0), .dout(a32_from16), .flags_conv(/*unused*/));
  fp_converter u_convB_in (.din(op_b), .c(1'b0), .dout(b32_from16), .flags_conv(/*unused*/));

  // Selección de operandos que entran a los bloques FP32
  wire [31:0] A = mode_fp ? op_a : a32_from16;
  wire [31:0] B = mode_fp ? op_b : b32_from16;

  // Para SUB = A + (-B): hacer flip del signo DESPUÉS de convertir
  wire [31:0] B_sub = {~B[31], B[30:0]};

  // -----------------------------
  // Gating de start por operación
  // -----------------------------
  wire start_mul = start & (op_code == OP_MUL);
  wire start_div = start & (op_code == OP_DIV);
  wire start_add = start & (op_code == OP_ADD);
  wire start_sub = start & (op_code == OP_SUB);

  // -----------------------------
  // Instancias de los bloques FP32
  // -----------------------------
  wire [31:0] y_mul, y_div, y_add, y_sub;
  wire        v_mul, v_div, v_add, v_sub;
  wire [4:0]  f_mul, f_div, f_add, f_sub;

  fpu_mul_fp32_vivado u_mul (
    .clk(clk), .rst(rst), .start(start_mul),
    .a(A), .b(B),
    .result(y_mul), .valid_out(v_mul), .flags(f_mul)
  );

  fpu_div_fp32_vivado u_div (
    .clk(clk), .rst(rst), .start(start_div),
    .a(A), .b(B),
    .result(y_div), .valid_out(v_div), .flags(f_div)
  );

  fpu_add_fp32_vivado u_sum(
    .clk(clk), .rst(rst), .start(start_add),
    .a(A), .b(B),
    .result(y_add), .valid_out(v_add), .flags(f_add)
  );

  fpu_add_fp32_vivado u_sub(
    .clk(clk), .rst(rst), .start(start_sub),
    .a(A), .b(B_sub),
    .result(y_sub), .valid_out(v_sub), .flags(f_sub)
  );

  // -----------------------------
  // Selección del camino activo (FP32)
  // -----------------------------
  reg [31:0] y_sel;
  reg        v_sel;
  reg [4:0]  f_sel;

  always @(*) begin
    case (op_code)
      OP_ADD: begin y_sel = y_add; v_sel = v_add; f_sel = f_add; end
      OP_SUB: begin y_sel = y_sub; v_sel = v_sub; f_sel = f_sub; end
      OP_MUL: begin y_sel = y_mul; v_sel = v_mul; f_sel = f_mul; end
      OP_DIV: begin y_sel = y_div; v_sel = v_div; f_sel = f_div; end
      default: begin y_sel = 32'd0; v_sel = 1'b0; f_sel = 5'd0; end
    endcase
  end

  // -----------------------------
  // Conversión de salida (32->16 cuando mode_fp=0)
  // Empaqueta en [31:16] y LSB=0
  // -----------------------------
  wire [31:0] y16_packed;
  wire [4:0]  f_conv16;
  // c=1 => 32->16 (RNE)
  fp_converter u_conv_out (.din(y_sel), .c(1'b1), .dout(y16_packed), .flags_conv(f_conv16));

  // -----------------------------
  // Salidas (con soporte de mode_fp)
  // -----------------------------
  always @(*) begin
    valid_out = v_sel;
    if (mode_fp) begin
      result = y_sel;
      flags  = f_sel;
    end else begin
      result = y16_packed;          // [31:16]=FP16, [15:0]=0
      flags  = f_sel | f_conv16;    // OR con flags de conversión a half
    end
  end

endmodule
