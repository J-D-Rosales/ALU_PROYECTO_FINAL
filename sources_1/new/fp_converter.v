`timescale 1ns/1ps

// ============================================================================
// fp_converter
//  - c=0 : FP16 (en din[31:16]) -> FP32 en dout[31:0], flags_conv=0
//  - c=1 : FP32 (en din[31:0])  -> FP16 en dout[31:16], dout[15:0]=0, flags_conv válidas
// Flags: {invalid, div_by_zero(=0), overflow, underflow, inexact}
// ============================================================================
module fp_converter (
  input  wire [31:0] din,
  input  wire        c,           // 0: 16->32, 1: 32->16 (RNE)
  output reg  [31:0] dout,
  output reg  [4:0]  flags_conv
);
  wire [31:0] up32;
  wire [15:0] dn16;
  wire [4:0]  fconv16;

  // FP16 -> FP32 (usa din[31:16])
  fp16_to_fp32 u_up (
    .h(din[31:16]),
    .f(up32)
  );

  // FP32 -> FP16 (RNE)
  fp32_to_fp16_rne u_dn (
    .f32(din),
    .h16(dn16),
    .flags_conv(fconv16)
  );

  always @* begin
    if (c == 1'b0) begin
      // 16 -> 32
      dout       = up32;
      flags_conv = 5'd0;
    end else begin
      // 32 -> 16
      dout       = {dn16, 16'h0000};  // [31:16]=half, LSBs a 0
      flags_conv = fconv16;
    end
  end
endmodule

// ============================================================================
// fp16_to_fp32  (half -> single, combinacional)
// FP16: s[15], e[14:10], f[9:0],   bias=15
// FP32: s[31], e[30:23], f[22:0],  bias=127
// ============================================================================
module fp16_to_fp32 (
  input  wire [15:0] h,
  output reg  [31:0] f
);
  wire       s = h[15];
  wire [4:0] e = h[14:10];
  wire [9:0] m = h[9:0];

  reg  [7:0]  e_out;
  reg  [22:0] f_out;

  integer i;
  integer lz;           // leading zeros en m
  reg [9:0] mant_norm;  // mantisa normalizada (bit9=1)

  always @* begin
    if (e == 5'h1F) begin
      // Inf/NaN
      if (m == 10'd0) begin
        e_out = 8'hFF; f_out = 23'd0;                       // ±Inf
      end else begin
        e_out = 8'hFF; f_out = {1'b1, m, 12'd0};            // qNaN con payload
      end
    end else if (e == 5'd0) begin
      if (m == 10'd0) begin
        e_out = 8'd0;  f_out = 23'd0;                       // ±0
      end else begin
        // subnormal: normalizar
        mant_norm = m;
        lz = 0;
        for (i = 0; i < 10; i = i + 1) begin
          if (mant_norm[9] == 1'b0) begin
            mant_norm = mant_norm << 1;
            lz = lz + 1;
          end
        end
        // valor = 1.xxx * 2^(-14 - lz)
        e_out = (8'd127 - 8'd14) - lz[7:0];
        f_out = {mant_norm[8:0], 14'd0};                    // quitar 1 oculto y expandir
      end
    end else begin
      // normal
      e_out = (e - 5'd15) + 8'd127;                         // re-bias
      f_out = {m, 13'd0};                                   // expandir fracción
    end
    f = {s, e_out, f_out};
  end
endmodule

// ============================================================================
// fp32_to_fp16_rne  (single -> half, combinacional, RNE)
// Flags: {invalid, 0, overflow, underflow, inexact}
// ============================================================================
module fp32_to_fp16_rne (
  input  wire [31:0] f32,
  output reg  [15:0] h16,
  output reg  [4:0]  flags_conv
);
  wire       s  = f32[31];
  wire [7:0] e  = f32[30:23];
  wire [22:0] m = f32[22:0];

  localparam [7:0] EXP32_INF = 8'hFF;
  localparam [4:0] EXP16_INF = 5'h1F;

  // estados/flags
  reg  [4:0] e16;
  reg  [9:0] frac16;
  reg        overflow, underflow, inexact, invalid;

  // normal path (GRS)
  reg  [10:0] mant11;       // 1 oculto + 10 frac
  reg         G, R, Sbit;
  reg         roundUp;
  reg  [11:0] sum12;        // 12 bits para capturar carry

  // subnormal helpers
  integer     e16_signed;   // e' = e-127+15
  integer     N, N_lim;
  reg  [23:0] M24;          // {1,m}
  reg  [23:0] shifted;
  reg         guard_bit;
  reg  [23:0] mask24;
  reg  [9:0]  frac_pre_sub;
  reg         Gs, Rs, Ss;
  reg  [9:0]  frac_rounded;

  // temporales para evitar slicing de expresiones (compatibilidad Verilog-2001)
  integer     e16_plus1_int;
  reg   [4:0] e16_plus1;
  reg   [4:0] e16_norm;

  always @* begin
    // defaults
    e16 = 5'd0; frac16 = 10'd0;
    overflow = 1'b0; underflow = 1'b0; inexact = 1'b0; invalid = 1'b0;
    h16 = {s, 5'd0, 10'd0};

    if (e == EXP32_INF) begin
      if (m == 23'd0) begin
        e16 = EXP16_INF; frac16 = 10'd0;                 // ±Inf
      end else begin
        // NaN: qNaN 0x7E00; invalid=1 si era sNaN (quiet bit m[22]==0)
        e16 = EXP16_INF; frac16 = 10'h200;
        invalid = (m[22] == 1'b0);
      end
      h16 = {s, e16, frac16};

    end else if ((e == 8'd0) && (m == 23'd0)) begin
      // ±0
      h16 = {s, 5'd0, 10'd0};

    end else begin
      // finito
      e16_signed = (e - 8'd127) + 15;   // entero con signo
      M24        = {1'b1, m};          // 1.m

      if (e16_signed >= 31) begin
        // overflow -> Inf, inexact=1
        e16 = EXP16_INF; frac16 = 10'd0;
        overflow = 1'b1; inexact = 1'b1;
        h16 = {s, e16, frac16};

      end else if (e16_signed <= 0) begin
        // -------- SUBNORMAL en half --------
        N     = 1 - e16_signed;               // N >= 1
        N_lim = (N > 31) ? 31 : N;

        shifted      = (N_lim >= 24) ? 24'd0 : (M24 >> N_lim);
        frac_pre_sub = shifted[9:0];

        // G/R/S para RNE
        guard_bit = (N_lim == 0) ? 1'b0 :
                    ((N_lim > 24) ? 1'b0 : ((M24 >> (N_lim-1)) & 24'd1));
        if (N_lim <= 1) begin
          Ss = 1'b0;
        end else if (N_lim > 24) begin
          Ss = (M24 != 24'd0);
        end else begin
          mask24 = (24'h1 << (N_lim-1)) - 1;
          Ss     = |(M24 & mask24);
        end
        Gs = guard_bit; Rs = 1'b0;

        inexact      = inexact | (Gs | Rs | Ss);
        frac_rounded = frac_pre_sub + (Gs & (Ss | frac_pre_sub[0]));

        if ((e16_signed == 0) && (frac_rounded == 10'd1024)) begin
          // "desborda" a mínimo normal
          e16 = 5'd1; frac16 = 10'd0; underflow = 1'b0;
        end else begin
          e16 = 5'd0; frac16 = frac_rounded[9:0];
          underflow = (Gs | Rs | Ss);   // pérdida de precisión
        end
        h16 = {s, e16, frac16};

      end else begin
        // -------- NORMAL en half --------
        mant11  = {1'b1, m[22:13]};           // 11 bits
        G       = m[12];
        R       = m[11];
        Sbit    = |m[10:0];
        roundUp = G & (R | Sbit | mant11[0]); // RNE

        sum12   = {1'b0, mant11} + {11'd0, roundUp};   // 12 bits
        inexact = (G | R | Sbit);

        // evita (e16_signed + 1)[4:0]
        e16_plus1_int = e16_signed + 1;
        e16_plus1     = e16_plus1_int[4:0];  // truncado (permitido)
        e16_norm      = e16_signed[4:0];

        if (sum12[11]) begin                 // hubo carry
          if (e16_plus1_int >= 31) begin
            e16 = EXP16_INF; frac16 = 10'd0; overflow = 1'b1; inexact = 1'b1;
          end else begin
            e16    = e16_plus1;
            frac16 = 10'd0;
          end
        end else begin
          e16    = e16_norm;
          frac16 = sum12[9:0];
        end
        h16 = {s, e16, frac16};
      end
    end

    flags_conv = {invalid, 1'b0, overflow, underflow, inexact};
  end
endmodule
