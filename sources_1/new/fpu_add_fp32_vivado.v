`timescale 1ns/1ps
// ============================================================================
// fpu_add_fp32_vivado  -  FP32 IEEE-754  -  Pipeline de 3 etapas (latencia=3)
// ----------------------------------------------------------------------------
// Uso:
//   - start=1 por 1 ciclo con entradas estables a,b.
//   - Tras 3 ciclos: valid_out=1 por 1 ciclo con result/flags válidos.
//   - Se puede emitir 1 operación nueva por ciclo (pipeline llena).
//
// Etapas:
//   E0: Unpack & specials + preparación               (comb)  -> regs E1
//   E1: Alineación + suma/resta + normalización       (comb)  -> regs E2
//   E2: Redondeo RNE + empaquetado + flags            (comb)  -> regs salida
//
// Flags: {invalid, div_by_zero, overflow, underflow, inexact}
//   - div_by_zero = 0 en suma.
// ============================================================================
module fpu_add_fp32_vivado (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output reg  [31:0] result,
    output reg         valid_out,
    output reg  [4:0]  flags
);

    // -------------------------
    // E0 (comb): Unpack + clasificación + "specials"
    // -------------------------
    wire sA = a[31], sB = b[31];
    wire [7:0]  eA = a[30:23], eB = b[30:23];
    wire [22:0] fA = a[22:0],  fB = b[22:0];

    wire A_isZero = (eA==8'd0) && (fA==23'd0);
    wire B_isZero = (eB==8'd0) && (fB==23'd0);
    wire A_isSub  = (eA==8'd0) && (fA!=23'd0);
    wire B_isSub  = (eB==8'd0) && (fB!=23'd0);
    wire A_isInf  = (eA==8'hFF) && (fA==23'd0);
    wire B_isInf  = (eB==8'hFF) && (fB==23'd0);
    wire A_isNaN  = (eA==8'hFF) && (fA!=23'd0);
    wire B_isNaN  = (eB==8'hFF) && (fB!=23'd0);

    // Mantisas 24b (bit oculto=1 si normal)
    wire [23:0] MA_c = A_isSub ? {1'b0, fA} : {(eA!=8'd0), fA};
    wire [23:0] MB_c = B_isSub ? {1'b0, fB} : {(eB!=8'd0), fB};

    // Exponentes desbiaseados (convención subnormal = -126)
    function signed [12:0] unbias;
        input [7:0] E;
        begin
            if (E==8'd0) unbias = 13'sd1 - 13'sd127; // -126
            else         unbias = $signed({5'b0,E}) - 13'sd127;
        end
    endfunction
    wire signed [12:0] eA_unb_c = unbias(eA);
    wire signed [12:0] eB_unb_c = unbias(eB);

    // Specials de suma:
    // - NaN en entrada => qNaN + invalid
    // - (+Inf)+(-Inf) o (-Inf)+(+Inf) => qNaN + invalid
    // - Inf con finito o Inf+Inf (mismo signo) => ±Inf
    reg        sp_is_special_c;
    reg [31:0] sp_word_c;
    reg [4:0]  sp_flags_c;

    always @* begin
        sp_is_special_c = 1'b0;
        sp_word_c       = 32'b0;
        sp_flags_c      = 5'b0;

        if (A_isNaN || B_isNaN) begin
            sp_is_special_c = 1'b1;
            sp_flags_c      = 5'b1_0000;                 // invalid
            sp_word_c       = {1'b0, 8'hFF, 1'b1, 22'b0}; // qNaN
        end
        else if ((A_isInf && B_isInf) && (sA ^ sB)) begin
            sp_is_special_c = 1'b1;
            sp_flags_c      = 5'b1_0000;                 // invalid
            sp_word_c       = {1'b0, 8'hFF, 1'b1, 22'b0}; // qNaN
        end
        else if (A_isInf || B_isInf) begin
            sp_is_special_c = 1'b1;
            sp_word_c       = {(A_isInf ? sA : sB), 8'hFF, 23'b0}; // ±Inf
        end
        // (ceros/finito continúan por camino normal)
    end

    // -------------------------
    // Registros E1
    // -------------------------
    reg        v_e1;
    reg        sA_e1, sB_e1;
    reg [23:0] MA_e1, MB_e1;
    reg signed [12:0] eA_unb_e1, eB_unb_e1;

    reg        sp_is_special_e1;
    reg [31:0] sp_word_e1;
    reg [4:0]  sp_flags_e1;

    always @(posedge clk) begin
        if (rst) begin
            v_e1 <= 1'b0;
            sA_e1 <= 1'b0; sB_e1 <= 1'b0;
            MA_e1 <= 24'd0; MB_e1 <= 24'd0;
            eA_unb_e1 <= 13'sd0; eB_unb_e1 <= 13'sd0;
            sp_is_special_e1 <= 1'b0; sp_word_e1 <= 32'd0; sp_flags_e1 <= 5'd0;
        end else begin
            v_e1 <= start;
            if (start) begin
                sA_e1 <= sA; sB_e1 <= sB;
                MA_e1 <= MA_c; MB_e1 <= MB_c;
                eA_unb_e1 <= eA_unb_c; eB_unb_e1 <= eB_unb_c;
                sp_is_special_e1 <= sp_is_special_c;
                sp_word_e1       <= sp_word_c;
                sp_flags_e1      <= sp_flags_c;
            end
        end
    end

    // ---------------------------------------------------------
    // E1 (comb): Alineación + suma/resta + normalización previa
    // ---------------------------------------------------------
    reg        sL_c, sS_c;
    reg signed [12:0] eL_c, eS_c;
    reg [27:0] extL_c, extS_c;
    reg [5:0]  shift_c;
    reg [27:0] S_aligned_c;
    reg        sticky_dropped_c;

    reg        sOUT_c1;
    reg signed [12:0] eSUM1_c1;
    reg [23:0] frac_with_hidden_c1;
    reg        G_c1, R_c1, S_c1;
    reg        exact_zero_c1;

    // Auxiliares para lógica interna (declarados fuera del always para Verilog puro)
    reg [27:0] sum_ext;
    reg [27:0] diff_ext;
    reg [27:0] diff_norm;
    integer    i;
    integer    lz;
    reg        found;
    reg [27:0] dropped_mask; 
    always @* begin
        // Elegir mayor magnitud (exponente, luego mantisa)
        if ( (eA_unb_e1 > eB_unb_e1) ||
             ((eA_unb_e1 == eB_unb_e1) && (MA_e1 >= MB_e1)) ) begin
            sL_c = sA_e1;  sS_c = sB_e1;
            eL_c = eA_unb_e1; eS_c = eB_unb_e1;
            extL_c = {1'b0, MA_e1, 3'b000};
            extS_c = {1'b0, MB_e1, 3'b000};
        end else begin
            sL_c = sB_e1;  sS_c = sA_e1;
            eL_c = eB_unb_e1; eS_c = eA_unb_e1;
            extL_c = {1'b0, MB_e1, 3'b000};
            extS_c = {1'b0, MA_e1, 3'b000};
        end

        // Alineación con sticky de bits caídos
        if (eL_c >= eS_c) shift_c = (eL_c - eS_c); else shift_c = 6'd0;
        if (shift_c == 0) begin
            S_aligned_c      = extS_c;
            sticky_dropped_c = 1'b0;
        end else if (shift_c >= 6'd28) begin
            // todo lo que había en extS_c cae -> sticky = OR de todo
            S_aligned_c      = 28'd0;
            sticky_dropped_c = |extS_c;
        end else begin
            S_aligned_c      = (extS_c >> shift_c);
            // máscara con 'shift_c' bits bajos en 1: (1<<shift_c) - 1
            dropped_mask     = (28'h1 << shift_c) - 1;
            sticky_dropped_c = |(extS_c & dropped_mask);
        end 

        exact_zero_c1 = 1'b0;

        if (sA_e1 == sB_e1) begin
            // ================= SUMA =================
            sOUT_c1 = sL_c;
            sum_ext = extL_c + S_aligned_c;

            if (sum_ext == 28'd0) begin
                // +0 (p. ej., +0 + -0 con ambas mantisas 0)
                exact_zero_c1       = 1'b1;
                frac_with_hidden_c1 = 24'd0;
                G_c1 = 1'b0; R_c1 = 1'b0; S_c1 = 1'b0;
                eSUM1_c1 = eL_c;  // irrelevante
                sOUT_c1  = 1'b0;  // +0 por RNE
            end
            else if (sum_ext[27]) begin
                // 10.x -> shift der 1
                frac_with_hidden_c1 = sum_ext[27:4]; // 24b
                G_c1 = sum_ext[3];
                R_c1 = sum_ext[2];
                S_c1 = sum_ext[1] | sum_ext[0] | sticky_dropped_c;
                eSUM1_c1 = eL_c + 1;
            end else begin
                // 1.x
                frac_with_hidden_c1 = sum_ext[26:3];
                G_c1 = sum_ext[2];
                R_c1 = sum_ext[1];
                S_c1 = sum_ext[0] | sticky_dropped_c;
                eSUM1_c1 = eL_c;
            end
        end else begin
            // ================ RESTA =================
            sOUT_c1  = sL_c;
            diff_ext = extL_c - S_aligned_c;

            if (diff_ext == 28'd0) begin
                // Cancelación exacta -> +0
                exact_zero_c1       = 1'b1;
                frac_with_hidden_c1 = 24'd0;
                G_c1=1'b0; R_c1=1'b0; S_c1=1'b0;
                eSUM1_c1 = eL_c;
                sOUT_c1  = 1'b0; // +0
            end else begin
                // Contar ceros a la izquierda en [26:0] (bit 27=0 aquí)
                lz    = 0;
                found = 1'b0;
                for (i=26; i>=0; i=i-1) begin
                    if (!found && diff_ext[i]) begin
                        lz    = 26 - i;
                        found = 1'b1;
                    end
                end
                if (!found) lz = 27;

                // Normalizar a la izquierda
                diff_norm = diff_ext << lz;

                frac_with_hidden_c1 = diff_norm[26:3]; // 24b
                G_c1 = diff_norm[2];
                R_c1 = diff_norm[1];
                S_c1 = diff_norm[0] | sticky_dropped_c;
                eSUM1_c1 = eL_c - lz;
            end
        end
    end

    // -------------------------
    // Registros E2
    // -------------------------
    reg        v_e2;
    reg        sOUT_e2;
    reg [23:0] frac_with_hidden_e2;
    reg        G_e2, R_e2, S_e2;
    reg signed [12:0] eSUM1_e2;
    reg        exact_zero_e2;

    reg        sp_is_special_e2;
    reg [31:0] sp_word_e2;
    reg [4:0]  sp_flags_e2;

    always @(posedge clk) begin
        if (rst) begin
            v_e2 <= 1'b0;
            sOUT_e2 <= 1'b0;
            frac_with_hidden_e2 <= 24'd0;
            G_e2 <= 1'b0; R_e2 <= 1'b0; S_e2 <= 1'b0;
            eSUM1_e2 <= 13'sd0;
            exact_zero_e2 <= 1'b0;
            sp_is_special_e2 <= 1'b0; sp_word_e2 <= 32'd0; sp_flags_e2 <= 5'd0;
        end else begin
            v_e2 <= v_e1;
            if (v_e1) begin
                sOUT_e2 <= sOUT_c1;
                frac_with_hidden_e2 <= frac_with_hidden_c1;
                G_e2 <= G_c1; R_e2 <= R_c1; S_e2 <= S_c1;
                eSUM1_e2 <= eSUM1_c1;
                exact_zero_e2 <= exact_zero_c1;
                sp_is_special_e2 <= sp_is_special_e1;
                sp_word_e2       <= sp_word_e1;
                sp_flags_e2      <= sp_flags_e1;
            end
        end
    end

    // ---------------------------------------------------------
    // E2 (comb): Redondeo RNE + empaquetado + flags
    // ---------------------------------------------------------
    wire [22:0] frac_pre_c2 = frac_with_hidden_e2[22:0];
    wire        roundUp_c2  = G_e2 && (R_e2 || S_e2 || frac_pre_c2[0]);

    wire [24:0] rounded_c2  = {1'b0, frac_with_hidden_e2} + (roundUp_c2 ? 25'd1 : 25'd0);

    reg  [23:0] frac_fin_c2;
    reg  signed [12:0] eSUM2_c2;
    always @* begin
        if (rounded_c2[24]) begin
            // 10.x -> 1.x y exponente +1
            frac_fin_c2 = rounded_c2[24:1];
            eSUM2_c2    = eSUM1_e2 + 1;
        end else begin
            frac_fin_c2 = rounded_c2[23:0];
            eSUM2_c2    = eSUM1_e2;
        end
    end

    // Cero exacto
    wire is_zero_path_c2 = exact_zero_e2;

    // Exponente re-bias y estados
    wire signed [13:0] E_biased_c2     = eSUM2_c2 + 13'sd127;
    wire        overflow_c2            = (E_biased_c2 > 13'sd254);
    wire        under_biased_nonpos_c2 = (E_biased_c2 <= 0);
    wire        inexact_rnd_c2         = (G_e2 | R_e2 | S_e2);

    // Empaquetado normal/subnormal
    reg [31:0] normal_word_c2;
    reg [4:0]  normal_flags_c2;

    integer shift_den;
    reg [23:0] frac_den;
    reg        lost_bits;
    reg [23:0] mask24;

    always @* begin
        normal_word_c2  = 32'b0;
        normal_flags_c2 = 5'b0;

        if (is_zero_path_c2) begin
            normal_word_c2  = {1'b0, 8'd0, 23'd0}; // +0
        end
        else if (overflow_c2) begin
            normal_word_c2     = {sOUT_e2, 8'hFF, 23'b0}; // ±Inf
            normal_flags_c2[2] = 1'b1;                    // overflow
            normal_flags_c2[0] = inexact_rnd_c2;          // inexact
        end
        else if (under_biased_nonpos_c2) begin
            // Subnormalización
            shift_den = (1 - E_biased_c2);
            if (shift_den > 24) begin
                normal_word_c2     = {sOUT_e2, 8'd0, 23'd0}; // ±0
                normal_flags_c2[1] = 1'b1;                   // underflow
                lost_bits          = inexact_rnd_c2 | (|frac_fin_c2);
                normal_flags_c2[0] = lost_bits;
            end else begin
                frac_den = frac_fin_c2 >> shift_den;
                normal_word_c2     = {sOUT_e2, 8'd0, frac_den[22:0]};
                normal_flags_c2[1] = 1'b1;                   // underflow
                if (shift_den >= 24) begin
                    lost_bits = (|frac_fin_c2);
                end else if (shift_den != 0) begin
                    mask24 = ((24'h1 << shift_den) - 1);
                    lost_bits = |(frac_fin_c2 & mask24);
                end else begin
                    lost_bits = 1'b0;
                end
                normal_flags_c2[0] = inexact_rnd_c2 | lost_bits;
            end
        end
        else begin
            normal_word_c2     = {sOUT_e2, E_biased_c2[7:0], frac_fin_c2[22:0]};
            normal_flags_c2[0] = inexact_rnd_c2;
        end
    end

    // Selección final respetando specials
    wire [31:0] result_c2 = sp_is_special_e2 ? sp_word_e2  : normal_word_c2;
    wire [4:0]  flags_c2  = sp_is_special_e2 ? sp_flags_e2 : normal_flags_c2;

    // -------------------------
    // Registros de salida (E3)
    // -------------------------
    reg v_e2_reg, v_e3; // v_e2_reg solo para reset seguro como en tus módulos

    always @(posedge clk) begin
        if (rst) begin
            v_e2      <= 1'b0;
            v_e2_reg  <= 1'b0;
            v_e3      <= 1'b0;
            valid_out <= 1'b0;
            result    <= 32'd0;
            flags     <= 5'd0;
        end else begin
            v_e2_reg  <= v_e2;
            v_e3      <= v_e2_reg;
            valid_out <= v_e3;

            if (v_e2_reg) begin
                result <= result_c2;
                flags  <= flags_c2;
            end
        end
    end

endmodule
