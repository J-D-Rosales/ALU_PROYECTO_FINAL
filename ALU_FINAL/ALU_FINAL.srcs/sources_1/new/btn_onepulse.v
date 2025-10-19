
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/14/2025 08:20:38 PM
// Design Name: 
// Module Name: btn_onepulse
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


`timescale 1ns/1ps
module btn_onepulse #(
  parameter integer STABLE_CYCLES = 1_000_000  // ~10ms @100MHz
)(
  input  wire clk,
  input  wire rst,
  input  wire sw_async,      // switch/botón asíncrono
  output reg  pulse_rise     // pulso 1 ciclo en flanco 0->1
);
  // Sincronizador 2FF
  reg s1, s2;
  always @(posedge clk) begin
    s1 <= sw_async;
    s2 <= s1;
  end

  // Debounce por contador
  reg        db_state;     // estado estable
  reg [19:0] cnt;          // 20 bits alcanzan hasta ~1,048,575
  always @(posedge clk) begin
    if (rst) begin
      db_state <= 1'b0;
      cnt      <= 20'd0;
    end else begin
      if (s2 != db_state) begin
        // cambió: contamos tiempo de estabilidad
        if (cnt == STABLE_CYCLES[19:0]) begin
          db_state <= s2;
          cnt      <= 20'd0;
        end else begin
          cnt <= cnt + 1'b1;
        end
      end else begin
        cnt <= 20'd0;
      end
    end
  end

  // Edge detector 0->1 sobre la señal debounced
  reg db_prev;
  always @(posedge clk) begin
    if (rst) begin
      db_prev   <= 1'b0;
      pulse_rise<= 1'b0;
    end else begin
      pulse_rise<= (db_state & ~db_prev);
      db_prev   <= db_state;
    end
  end
endmodule
