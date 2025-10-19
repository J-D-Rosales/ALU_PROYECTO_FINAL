`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/14/2025 08:21:58 PM
// Design Name: 
// Module Name: nibble_loader32
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


module nibble_loader32(
  input  wire       clk,
  input  wire       rst,
  input  wire       load_pulse,   // 1-ciclo por 0->1 de sw[14]
  input  wire [3:0] nibble_a,     // sw[5:2]
  input  wire [3:0] nibble_b,     // sw[9:6]
  output reg  [31:0] op_a,
  output reg  [31:0] op_b,
  output wire       loading_a,
  output wire       loading_b,
  output wire       both_loaded
);
  localparam S_A   = 2'd0;
  localparam S_B   = 2'd1;
  localparam S_DONE= 2'd2;

  reg [1:0] state;
  reg [3:0] cnt; // 0..8

  assign loading_a   = (state == S_A);
  assign loading_b   = (state == S_B);
  assign both_loaded = (state == S_DONE);

  always @(posedge clk) begin
    if (rst) begin
      state <= S_A;
      cnt   <= 4'd0;
      op_a  <= 32'd0;
      op_b  <= 32'd0;
    end else begin
      if (load_pulse) begin
        case (state)
          S_A: begin
            // MSB primero: (<<4) luego OR nibble
            op_a <= (op_a << 4) | {28'd0, nibble_a};
            cnt  <= cnt + 1'b1;
            if (cnt == 4'd7) begin
              state <= S_B;
              cnt   <= 4'd0;
            end
          end
          S_B: begin
            op_b <= (op_b << 4) | {28'd0, nibble_b};
            cnt  <= cnt + 1'b1;
            if (cnt == 4'd7) begin
              state <= S_DONE;
              cnt   <= 4'd0;
            end
          end
          S_DONE: begin
            // siguiente pulso reinicia para volver a cargar A
            state <= S_A;
            cnt   <= 4'd0;
            op_a  <= 32'd0;
            op_b  <= 32'd0;
          end
        endcase
      end
    end
  end
endmodule

