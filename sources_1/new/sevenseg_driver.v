`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/14/2025 08:22:35 PM
// Design Name: 
// Module Name: sevenseg_driver
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module sevenseg_driver #(
  parameter integer CLK_HZ = 100_000_000
)(
  input  wire        clk,
  input  wire        rst,
  input  wire [15:0] value,    // 4 hex dígitos
  output reg  [3:0]  an,       // anodos activos en 0
  output reg  [6:0]  seg,      // segments activos en 0
  output reg         dp        // punto decimal activo en 0 (apagado = 1)
);
  // Multiplexado ~1 kHz por dígito
  localparam integer REFRESH_HZ = 1000*4;
  localparam integer TICKS = CLK_HZ / REFRESH_HZ;
  reg [15:0] cnt;
  reg [1:0]  idx;     // dígito activo 0..3
  reg [3:0]  nib;

  // contador de refresco
  always @(posedge clk) begin
    if (rst) begin
      cnt <= 16'd0;
      idx <= 2'd0;
    end else begin
      if (cnt == TICKS[15:0]) begin
        cnt <= 16'd0;
        idx <= idx + 1'b1;
      end else begin
        cnt <= cnt + 1'b1;
      end
    end
  end

  // seleccionar nibble según dígito
  always @(*) begin
    case (idx)
      2'd0: nib = value[3:0];
      2'd1: nib = value[7:4];
      2'd2: nib = value[11:8];
      default: nib = value[15:12];
    endcase
  end

  // mapa hex -> 7 segmentos (abcdefg), activo-bajo
  function [6:0] hex7;
    input [3:0] h;
    begin
      case (h)
        4'h0: hex7 = 7'b1000000;
        4'h1: hex7 = 7'b1111001;
        4'h2: hex7 = 7'b0100100;
        4'h3: hex7 = 7'b0110000;
        4'h4: hex7 = 7'b0011001;
        4'h5: hex7 = 7'b0010010;
        4'h6: hex7 = 7'b0000010;
        4'h7: hex7 = 7'b1111000;
        4'h8: hex7 = 7'b0000000;
        4'h9: hex7 = 7'b0010000;
        4'hA: hex7 = 7'b0001000;
        4'hB: hex7 = 7'b0000011;
        4'hC: hex7 = 7'b1000110;
        4'hD: hex7 = 7'b0100001;
        4'hE: hex7 = 7'b0000110;
        4'hF: hex7 = 7'b0001110;
      endcase
    end
  endfunction

  // salida de segmentos y anodos
  always @(posedge clk) begin
    if (rst) begin
      seg <= 7'b1111111;
      dp  <= 1'b1;
      an  <= 4'b1111;
    end else begin
      seg <= hex7(nib);
      dp  <= 1'b1; // siempre apagado
      case (idx)
        2'd0: an <= 4'b1110;
        2'd1: an <= 4'b1101;
        2'd2: an <= 4'b1011;
        2'd3: an <= 4'b0111;
      endcase
    end
  end
endmodule

