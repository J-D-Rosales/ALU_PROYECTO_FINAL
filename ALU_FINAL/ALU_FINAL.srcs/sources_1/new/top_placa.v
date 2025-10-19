`timescale 1ns / 1ps
module top_placa (
  input  wire        clk,        // 100 MHz
  input  wire        btnC,       // reset (botón centro)
  input  wire [15:0] sw,         // switches
  output wire [15:0] led,        // leds
  output wire [3:0]  an,         // 7seg anodos (activos en 0)
  output wire [6:0]  seg,        // 7seg segmentos (activos en 0)
  output wire        dp          // 7seg punto decimal (activo en 0)
);

  // =========================
  // Reset sincronizado
  // =========================
  reg rst_sync1, rst_sync2;
  always @(posedge clk) begin
    rst_sync1 <= btnC;
    rst_sync2 <= rst_sync1;
  end
  wire rst = rst_sync2;

  // =========================
  // Pulsos de START y LOAD
  // =========================
  wire start_pulse_raw, load_pulse;

  btn_onepulse #(.STABLE_CYCLES(5)) u_pstart ( //cambiar a 5 para el tb 1_000_000
    .clk(clk), .rst(rst), .sw_async(sw[10]), .pulse_rise(start_pulse_raw)
  );

  btn_onepulse #(.STABLE_CYCLES(5)) u_pload ( //cambiar a 5 para el tb 1_000_000
    .clk(clk), .rst(rst), .sw_async(sw[14]), .pulse_rise(load_pulse)
  );

  // =========================
  // Loader de A/B por nibbles
  // =========================
  wire [31:0] op_a, op_b;
  wire loading_a, loading_b, both_loaded;

  nibble_loader32 u_loader (
    .clk(clk), .rst(rst),
    .load_pulse(load_pulse),
    .nibble_a(sw[5:2]),
    .nibble_b(sw[9:6]),
    .op_a(op_a),
    .op_b(op_b),
    .loading_a(loading_a),
    .loading_b(loading_b),
    .both_loaded(both_loaded)
  );

  // =========================
  // SNAP de operandos al cerrar carga (flanco de both_loaded)
  // =========================
  reg        both_q;
  wire       both_rise = both_loaded & ~both_q;

  reg [31:0] op_a_snap, op_b_snap;
  reg        operands_ready;   // hay snapshot válido

  always @(posedge clk) begin
    if (rst) begin
      both_q         <= 1'b0;
      op_a_snap      <= 32'd0;
      op_b_snap      <= 32'd0;
      operands_ready <= 1'b0;
    end else begin
      both_q <= both_loaded;

      // Tomamos un "snapshot" solo cuando BOTH pasa de 0->1 (datos completos)
      if (both_rise) begin
        op_a_snap      <= op_a;
        op_b_snap      <= op_b;
        operands_ready <= 1'b1;
      end

      // Si el usuario empieza a recargar (both_loaded=0), invalidamos snapshot
      if (!both_loaded) begin
        operands_ready <= 1'b0;
      end
    end
  end

  // =========================
  // FPU TOP (FSM: IDLE -> ARM -> FIRE)
  // =========================
  wire [31:0] result;
  wire        valid_out;
  wire [4:0]  flags;

  reg        start_req;        // hubo start del usuario (pendiente)
  reg [1:0]  op_code_req;      // opcode capturado al pulsar start

  reg [31:0] op_a_hold, op_b_hold;
  reg [1:0]  op_code_hold;

  reg        start_to_fpu;     // pulso 1 ciclo
  reg        op_inflight;      // operación en curso
  reg        fire_next;        // disparar en el próximo ciclo (tras armar)

  always @(posedge clk) begin
    if (rst) begin
      start_req    <= 1'b0;
      op_code_req  <= 2'b00;

      op_a_hold    <= 32'd0;
      op_b_hold    <= 32'd0;
      op_code_hold <= 2'b00;

      start_to_fpu <= 1'b0;
      op_inflight  <= 1'b0;
      fire_next    <= 1'b0;
    end else begin
      start_to_fpu <= 1'b0; // default

      // Captura start del usuario (congela opcode en ese instante)
      if (start_pulse_raw)
        {start_req, op_code_req} <= {1'b1, sw[1:0]};

      // ARM: solo cuando hay snapshot válido y no hay operación en curso
      if (start_req && operands_ready && !op_inflight) begin
        op_a_hold    <= op_a_snap;  // <-- usar snapshot, no el wire directo
        op_b_hold    <= op_b_snap;
        op_code_hold <= op_code_req;
        fire_next    <= 1'b1;       // dispararemos al ciclo siguiente
        start_req    <= 1'b0;       // consumimos solicitud
        op_inflight  <= 1'b1;       // ocupados hasta valid_out
      end

      // FIRE: 1 ciclo después de ARM
      if (fire_next) begin
        start_to_fpu <= 1'b1;
        fire_next    <= 1'b0;
      end

      // Fin de operación
      if (valid_out)
        op_inflight <= 1'b0;
    end
  end

  fpu_top u_fputop (
    .clk(clk),
    .rst(rst),
    .start(start_to_fpu),
    .op_a(op_a_hold),
    .op_b(op_b_hold),
    .op_code(op_code_hold),
    .mode_fp(sw[11]),
    .round_mode(sw[12]),
    .result(result),
    .valid_out(valid_out),
    .flags(flags)
  );

  // =========================
  // Latch de result/flags al valid_out
  // =========================
  reg [31:0] result_lat;
  reg [4:0]  flags_lat;

  always @(posedge clk) begin
    if (rst) begin
      result_lat <= 32'd0;
      flags_lat  <= 5'd0;
    end else if (valid_out) begin
      result_lat <= result;
      flags_lat  <= flags;
    end
  end

  // =========================
  // 7-Segmentos (mostrar RESULT)
  // =========================
  wire mode_is_half = (sw[11] == 1'b0);
  wire [15:0] view16 =
    mode_is_half ? result_lat[31:16]
                 : (sw[13]==1'b0 ? result_lat[31:16] : result_lat[15:0]);

  sevenseg_driver #(.CLK_HZ(100_000_000)) u_sev (
    .clk(clk), .rst(rst),
    .value(view16),
    .an(an), .seg(seg), .dp(dp)
  );

  // =========================
  // Estirador de valid_out (~0.5 s)
  // =========================
  localparam integer VALID_HOLD_CYCLES = 50_000_000;
  reg [25:0] v_cnt;
  reg        valid_led;

  always @(posedge clk) begin
    if (rst) begin
      v_cnt     <= 26'd0;
      valid_led <= 1'b0;
    end else begin
      if (valid_out) begin
        v_cnt     <= VALID_HOLD_CYCLES[25:0];
        valid_led <= 1'b1;
      end else if (v_cnt != 0) begin
        v_cnt <= v_cnt - 1'b1;
        if (v_cnt == 1) valid_led <= 1'b0;
      end
    end
  end

  // =========================
  // LEDs
  // =========================
  assign led[3:0]  = flags_lat[3:0];
  assign led[4]    = valid_led;
  assign led[5]    = loading_a;
  assign led[6]    = loading_b;
  assign led[7]    = both_loaded;
  assign led[15]   = flags_lat[4];
  assign led[14:8] = 7'd0;

endmodule
