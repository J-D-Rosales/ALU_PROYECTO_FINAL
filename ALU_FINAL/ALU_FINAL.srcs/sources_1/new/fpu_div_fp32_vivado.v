`timescale 1ns/1ps
// ============================================================================
// fpu_div_fp32_vivado  -  FP32 IEEE-754  -  Pipeline de 3 etapas (latencia=3)
// ----------------------------------------------------------------------------
// Uso con tu fpu_top (sin cambios):
//   - Presenta a,b y un pulso start=1 (1 ciclo).
//   - En k+3: valid_out=1 (1 ciclo), result/flags válidos.
//   - Puedes lanzar 1 operación nueva por ciclo (pipeline llena).
//
// Etapas (paralelas a MUL):
//   E0: Unpack & specials           (comb)  -> regs E1
//   E1: Cociente escalado + normal  (comb)  -> regs E2
//   E2: RNE + empaquetado           (comb)  -> regs salida
// ============================================================================
module fpu_div_fp32_vivado (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,        // pulso 1 ciclo para "emitir" una nueva operación
    input  wire [31:0] a,            // FP32
    input  wire [31:0] b,            // FP32
    output reg  [31:0] result,       // FP32
    output reg         valid_out,    // pulso 1 ciclo, 3 ciclos después de start
    output reg  [4:0]  flags         // {invalid, div_by_zero, overflow, underflow, inexact}
);

    localparam BIAS = 127;

    // -------------------------
    // E0 (comb): Unpack + casos
    // -------------------------
    // Unpack
    wire sA = a[31], sB = b[31];
    wire [7:0]  eA = a[30:23], eB = b[30:23];
    wire [22:0] fA = a[22:0],  fB = b[22:0];

    // Clasificación
    wire A_isZero = (eA==8'd0) && (fA==23'd0);
    wire B_isZero = (eB==8'd0) && (fB==23'd0);
    wire A_isSub  = (eA==8'd0) && (fA!=23'd0);
    wire B_isSub  = (eB==8'd0) && (fB!=23'd0);
    wire A_isInf  = (eA==8'hFF) && (fA==23'd0);
    wire B_isInf  = (eB==8'hFF) && (fB==23'd0);
    wire A_isNaN  = (eA==8'hFF) && (fA!=23'd0);
    wire B_isNaN  = (eB==8'hFF) && (fB!=23'd0);

    // Signo de salida
    wire sOUT_c = sA ^ sB;

    // Mantisas 24b (oculto=1 si normal)
    wire [23:0] MA_c = A_isSub ? {1'b0, fA} : {(eA!=8'd0), fA};
    wire [23:0] MB_c = B_isSub ? {1'b0, fB} : {(eB!=8'd0), fB};

    // Exponentes desbiaseados (signed)
    function signed [12:0] unbias(input [7:0] E);
    begin
        if (E==8'd0) unbias = 13'sd1 - 13'sd127;  // -126
        else         unbias = $signed({5'b0,E}) - 13'sd127;
    end
    endfunction
    wire signed [12:0] eA_unb_c = unbias(eA);
    wire signed [12:0] eB_unb_c = unbias(eB);

    // Specials (comb)
    reg        sp_is_special_c;
    reg [31:0] sp_word_c;
    reg [4:0]  sp_flags_c;

    always @* begin
        sp_is_special_c = 1'b0;
        sp_word_c       = 32'b0;
        sp_flags_c      = 5'b0;

        // NaN en entrada o formas inválidas (0/0, Inf/Inf) => qNaN + invalid
        if (A_isNaN || B_isNaN || (A_isZero && B_isZero) || (A_isInf && B_isInf)) begin
            sp_is_special_c = 1'b1;
            sp_flags_c      = 5'b1_0000;                 // invalid
            sp_word_c       = {1'b0, 8'hFF, 1'b1, 22'b0}; // qNaN
        end
        // x / 0 (con x finito !=0) => ±Inf + div_by_zero
        else if (B_isZero && !(A_isZero || A_isNaN || A_isInf)) begin
            sp_is_special_c = 1'b1;
            sp_flags_c      = 5'b0_1000;                 // div_by_zero
            sp_word_c       = {sOUT_c, 8'hFF, 23'b0};    // ±Inf
        end
        // Inf / finito => ±Inf
        else if (A_isInf && !(B_isInf)) begin
            sp_is_special_c = 1'b1;
            sp_word_c       = {sOUT_c, 8'hFF, 23'b0};    // ±Inf
        end
        // 0 / Inf => 0
        else if (A_isZero && B_isInf) begin
            sp_is_special_c = 1'b1;
            sp_word_c       = {sOUT_c, 8'd0, 23'd0};     // ±0
        end
        // (Otros casos pasan al camino normal)
    end

    // -------------------------
    // Registros E1
    // -------------------------
    reg        v_e1;
    reg        sOUT_e1;
    reg [23:0] MA_e1, MB_e1;
    reg signed [12:0] eDIFF0_e1;
    reg        sp_is_special_e1;
    reg [31:0] sp_word_e1;
    reg [4:0]  sp_flags_e1;

    always @(posedge clk) begin
        if (rst) begin
            v_e1 <= 1'b0;
            sOUT_e1 <= 1'b0; MA_e1 <= 24'd0; MB_e1 <= 24'd0; eDIFF0_e1 <= 13'sd0;
            sp_is_special_e1 <= 1'b0; sp_word_e1 <= 32'd0; sp_flags_e1 <= 5'd0;
        end else begin
            v_e1 <= start;
            if (start) begin
                sOUT_e1 <= sOUT_c;
                MA_e1   <= MA_c;
                MB_e1   <= MB_c;
                eDIFF0_e1 <= eA_unb_c - eB_unb_c;   // exponente de división
                sp_is_special_e1 <= sp_is_special_c;
                sp_word_e1       <= sp_word_c;
                sp_flags_e1      <= sp_flags_c;
            end
        end
    end

    // ---------------------------------------------------------
    // E1 (comb): División de mantisas + pre-normalización
    // ---------------------------------------------------------
    // Idea: Queremos el cociente normalizado en 1.x con 23 bits + G + R.
    // - Si MA >= MB, Q en [1,2) -> desplazar NUM por 25 bits.
    // - Si MA <  MB, Q en [0.5,1) -> desplazar NUM por 26 bits y exponente-1.
    //
    // Q_scaled produce (bit oculto + 23 fracc + G + R) = 1 + 23 + 2 = 26 bits.
    // Sticky S proviene de (remainder != 0).
    reg  [25:0] Q_scaled_c;    // [25]=bit entero/oculto, [24:2]=frac_pre, [1]=G, [0]=R
    reg         S_c;           // sticky
    reg  signed [12:0] eDIFF1_c;

    always @* begin
        if (MA_e1 >= MB_e1 && MB_e1 != 24'd0) begin
            // Q in [1,2): usar <<25
            // Nota: usar división y modulo enteros (sintetizables en FPGA).
            Q_scaled_c = ( {MA_e1, 25'b0} / MB_e1 );
            S_c        = ( ( {MA_e1, 25'b0} % MB_e1 ) != 0 );
            eDIFF1_c   = eDIFF0_e1; // sin ajuste
        end else if (MB_e1 != 24'd0) begin
            // Q in [0.5,1): usar <<26 y exponente-1 para normalizar
            Q_scaled_c = ( {MA_e1, 26'b0} / MB_e1 );
            S_c        = ( ( {MA_e1, 26'b0} % MB_e1 ) != 0 );
            eDIFF1_c   = eDIFF0_e1 - 1; // compensar el shift extra
        end else begin
            // MB_e1==0 nunca debería pasar por specials; proteger para evitar X
            Q_scaled_c = 26'd0;
            S_c        = 1'b0;
            eDIFF1_c   = eDIFF0_e1;
        end
    end

    // -------------------------
    // Registros E2
    // -------------------------
    reg        v_e2;
    reg        sOUT_e2;
    reg [25:0] Q_scaled_e2;
    reg        S_e2;
    reg signed [12:0] eDIFF1_e2;
    reg        sp_is_special_e2;
    reg [31:0] sp_word_e2;
    reg [4:0]  sp_flags_e2;

    always @(posedge clk) begin
        if (rst) begin
            v_e2 <= 1'b0; sOUT_e2 <= 1'b0; Q_scaled_e2 <= 26'd0; S_e2 <= 1'b0; eDIFF1_e2 <= 13'sd0;
            sp_is_special_e2 <= 1'b0; sp_word_e2 <= 32'd0; sp_flags_e2 <= 5'd0;
        end else begin
            v_e2 <= v_e1;
            if (v_e1) begin
                sOUT_e2 <= sOUT_e1;
                Q_scaled_e2 <= Q_scaled_c;
                S_e2        <= S_c;
                eDIFF1_e2   <= eDIFF1_c;
                sp_is_special_e2 <= sp_is_special_e1;
                sp_word_e2       <= sp_word_e1;
                sp_flags_e2      <= sp_flags_e1;
            end
        end
    end

    // ---------------------------------------------------------
    // E2 (comb): RNE + empaquetado (igual filosofía que MUL)
    // ---------------------------------------------------------
    wire [22:0] frac_pre_c2 = Q_scaled_e2[24:2]; // 23 bits de fracción
    wire        G_c2        = Q_scaled_e2[1];
    wire        R_c2        = Q_scaled_e2[0];
    wire        S_c2        = S_e2;              // sticky viene del resto != 0
    wire        roundUp_c2  = G_c2 && (R_c2 || S_c2 || frac_pre_c2[0]);

    // Mantisa con oculto (24 bits) y suma de redondeo con captura de carry
    wire [23:0] frac_with_hidden_c2 = {Q_scaled_e2[25], frac_pre_c2};
    wire [24:0] rounded_c2 = {1'b0, frac_with_hidden_c2}
                           + (roundUp_c2 ? 25'd1 : 25'd0);

    reg  [23:0] frac_fin_c2;
    reg  signed [12:0] eSUM2_c2;
    always @* begin
        if (rounded_c2[24]) begin
            // 10.x -> 1.x y exponente +1
            frac_fin_c2 = rounded_c2[24:1];
            eSUM2_c2    = eDIFF1_e2 + 1;
        end else begin
            frac_fin_c2 = rounded_c2[23:0];
            eSUM2_c2    = eDIFF1_e2;
        end
    end

    // Exponente re-sesgado y estados
    wire signed [13:0] E_biased_c2     = eSUM2_c2 + 13'sd127;
    wire        overflow_c2            = (E_biased_c2 > 13'sd254);
    wire        under_biased_nonpos_c2 = (E_biased_c2 <= 0);
    wire        inexact_rnd_c2         = (G_c2 | R_c2 | S_c2);

    // Empaquetado normal/subnormal (idéntica estructura a MUL)
    reg [31:0] normal_word_c2;
    reg [4:0]  normal_flags_c2;
    // Variables auxiliares fuera de bloques nombrados para compatibilidad Verilog
    integer shift;
    reg [23:0] frac_den;
    reg        lost_bits;
    reg [23:0] mask;

    always @* begin
        normal_word_c2  = 32'b0;
        normal_flags_c2 = 5'b0;

        if (overflow_c2) begin
            normal_word_c2     = {sOUT_e2, 8'hFF, 23'b0};
            normal_flags_c2[2] = 1'b1;           // overflow
            normal_flags_c2[0] = inexact_rnd_c2; // inexact
        end else if (under_biased_nonpos_c2) begin
            // Subnormalización (underflow)
            shift = (1 - E_biased_c2);
            if (shift > 24) begin
                normal_word_c2     = {sOUT_e2, 8'd0, 23'd0};   // ±0
                normal_flags_c2[1] = 1'b1;                     // underflow
                lost_bits          = inexact_rnd_c2 | (|frac_fin_c2);
                normal_flags_c2[0] = lost_bits;                // inexact si hay pérdida
            end else begin
                frac_den = frac_fin_c2 >> shift;
                normal_word_c2     = {sOUT_e2, 8'd0, frac_den[22:0]};
                normal_flags_c2[1] = 1'b1;                     // underflow
                if (shift >= 24) begin
                    lost_bits = (|frac_fin_c2);
                end else if (shift != 0) begin
                    mask = ((24'h1 << shift) - 1);
                    lost_bits = |(frac_fin_c2 & mask);
                end else begin
                    lost_bits = 1'b0;
                end
                normal_flags_c2[0] = inexact_rnd_c2 | lost_bits;
            end
        end else begin
            normal_word_c2     = {sOUT_e2, E_biased_c2[7:0], frac_fin_c2[22:0]};
            normal_flags_c2[0] = inexact_rnd_c2;
        end
    end

    // Selección final respetando specials
    wire [31:0] result_c2 = sp_is_special_e2 ? sp_word_e2  : normal_word_c2;
    // Flags: mergea specials + normales, y conserva div_by_zero/invalid si venían
    wire [4:0]  flags_c2  = sp_is_special_e2 ? sp_flags_e2 : normal_flags_c2;

    // -------------------------
    // Registros de salida (E3)
    // -------------------------
    reg v_e3;
    always @(posedge clk) begin
        if (rst) begin
            v_e2      <= 1'b0;
            v_e3      <= 1'b0;
            valid_out <= 1'b0;
            result    <= 32'd0;
            flags     <= 5'd0;
        end else begin
            v_e3      <= v_e2;
            valid_out <= v_e3;
            if (v_e2) begin
                result <= result_c2;
                flags  <= flags_c2;
            end
        end
    end

endmodule
