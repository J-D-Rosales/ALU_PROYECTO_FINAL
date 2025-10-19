`timescale 1ns/1ps
// ============================================================================
// fpu_mul_fp32_vivado  -  FP32 IEEE-754  -  Pipeline de 3 etapas (latencia=3)
// ----------------------------------------------------------------------------
// Uso con tu fpu_top (sin cambios):
//   - Presenta a,b y un pulso start=1 (1 ciclo).
//   - En k+3: valid_out=1 (1 ciclo), result/flags válidos.
//   - Puedes lanzar 1 operación nueva por ciclo (pipeline llena).
//
// Etapas:
//   E0: Unpack & specials  (comb)  -> regs E1
//   E1: Producto + normaliz (comb) -> regs E2
//   E2: RNE + empaquetado   (comb) -> regs salida
// ============================================================================
module fpu_mul_fp32_vivado (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,        // pulso 1 ciclo para "emitir" una nueva operación
    input  wire [31:0] a,            // FP32
    input  wire [31:0] b,            // FP32
    output reg  [31:0] result,       // FP32
    output reg         valid_out,    // pulso 1 ciclo, 3 ciclos después de start
    output reg  [4:0]  flags         // {invalid, div_by_zero, overflow, underflow, inexact}
);

    localparam BIAS = 127; // because is for 32 bits

    // ----------------------------------------------------------------------------
    // E0 (comb): Unpack + clasificación + preparar mantisas/exponentes y "specials"
    // ----------------------------------------------------------------------------
    // Unpack
    wire sA = a[31], sB = b[31]; // sA = signo de A, sB = signo de B, puede ser 1 = negativo o 0 = positivo
    wire [7:0]  eA = a[30:23], eB = b[30:23]; // exponentes en formato de IEEE
    wire [22:0] fA = a[22:0],  fB = b[22:0]; // las fracciones en formato de IEEE

    // Clasificación, es el estándar de IEEE
    // formatos a seguir (regla prestablecidad)
    wire A_isZero = (eA==8'd0) && (fA==23'd0); // cero es E = 0, Y F = 0 (FORMATO DE IEEE)
    wire B_isZero = (eB==8'd0) && (fB==23'd0); // 
    wire A_isSub  = (eA==8'd0) && (fA!=23'd0); //  Subnormal o denormal E == 0  y F != 0 
    wire B_isSub  = (eB==8'd0) && (fB!=23'd0);
    wire A_isInf  = (eA==8'hFF) && (fA==23'd0); // si el exponente es el maximo E = 255 y fracción = 0
    wire B_isInf  = (eB==8'hFF) && (fB==23'd0); 
    wire A_isNaN  = (eA==8'hFF) && (fA!=23'd0); // PARA QUE sea NaN, la fracción debe ser 0 y el exponente 255
    wire B_isNaN  = (eB==8'hFF) && (fB!=23'd0);
    

    // Signo salida
    wire sOUT_c = sA ^ sB; // porque positivo =0, y negativo = 1

    // Specials (combinacional)
    reg        sp_is_special_c; // if it's 1 we don't follow the normal path, but we short that
    reg [31:0] sp_word_c; // what is going to be the result if it's special
    reg [4:0]  sp_flags_c; // the flags as usual.

    // Logic for handle the special cases:
    always @(*) begin
    // we put the default sp_is_special_c as 0, and the rest also, because is like rest
        sp_is_special_c = 1'b0;
        sp_word_c       = 32'b0;
        sp_flags_c      = 5'b0;

        if (A_isNaN || B_isNaN) begin // si alguno de los dos son NaNs
            sp_is_special_c = 1'b1;
            sp_flags_c      = 5'b1_0000;                 // invalid
            sp_word_c       = {1'b0, 8'hFF, 1'b1, 22'b0}; // quiet NaN
            // we raise invalid, and we propagate the error, but not ivalid. 
        end else if ((A_isZero && B_isInf) || (B_isZero && A_isInf)) begin
            sp_is_special_c = 1'b1;
            sp_flags_c      = 5'b1_0000;                 // invalid
            sp_word_c       = {1'b0, 8'hFF, 1'b1, 22'b0}; // quiet NaN
        end else if (A_isInf || B_isInf) begin
            sp_is_special_c = 1'b1;
            sp_word_c       = {sOUT_c, 8'hFF, 23'b0};    // ±Inf depending on the sign
        end else if (A_isZero || B_isZero) begin
            sp_is_special_c = 1'b1;
            sp_word_c       = {sOUT_c, 8'd0, 23'd0};     // ±0 depeding on the sign.
        end
    end


    // we convert the fraction into matinsas to proper work with them.
    // _c is for combinational
    // Mantisas 24b (1 oculto si normal, 0 si subnormal)
    wire [23:0] MA_c = A_isSub ? {1'b0, fA} : {(eA!=8'd0), fA};
    wire [23:0] MB_c = B_isSub ? {1'b0, fB} : {(eB!=8'd0), fB};
    
    // Exponentes desbiasados
    // cuando el exponente es 0, entonces el exponenete sera -126 y no -127
    // esto es por el estándar de IEEE, para tener un salto mas suave
    function signed [12:0] unbias(input [7:0] E);
        begin
            if (E==8'd0) unbias = 13'sd1 - 13'sd127;
            else         unbias = $signed({5'b0,E}) - 13'sd127;
        end
    endfunction
    
    wire signed [12:0] eA_unb_c = unbias(eA);
    wire signed [12:0] eB_unb_c = unbias(eB);

// fin del primer pipeline. 0

    // ----------------------------------------------------------------------------
    // Registros E1 (capturan en start)
    // ----------------------------------------------------------------------------
    reg        v_e1;                    // "tag" de validez de la operación en E1
    reg        sOUT_e1;         // registro del signo pero del pipeline 1
    reg [23:0] MA_e1, MB_e1; // matinsas del pipeline 1
    reg signed [12:0] eSUM0_e1; // el exponente sumado de e1 (signed)
    reg        sp_is_special_e1; // saber si en e1 hay algun especial
    reg [31:0] sp_word_e1; // si es especial entonces colocar el preterminado
    reg [4:0]  sp_flags_e1; // los flags pero correspondientes a e1

    always @(posedge clk) begin
        if (rst) begin // cositas del reset para cada caso del pipeline
            v_e1 <= 1'b0;
            sOUT_e1 <= 1'b0; MA_e1 <= 24'd0; MB_e1 <= 24'd0; eSUM0_e1 <= 13'sd0;
            sp_is_special_e1 <= 1'b0; sp_word_e1 <= 32'd0; sp_flags_e1 <= 5'd0;
        end else begin
            v_e1 <= start;  // acepta una operación cuando start=1
            if (start) begin
                sOUT_e1 <= sOUT_c; // el signo de mantiene
                MA_e1   <= MA_c; // las mantisas son iguales todavia
                MB_e1   <= MB_c;//
                eSUM0_e1 <= eA_unb_c + eB_unb_c; // al multiplicar se suman los exponentes
                sp_is_special_e1 <= sp_is_special_c; // esto es por el carry del incio
                sp_word_e1       <= sp_word_c; // esto es por el carry del inicio
                sp_flags_e1      <= sp_flags_c;// esto es por el flag carry del inico
                // los ultimos 3 solo fucnionan si es especial, en otro caso es cerito
            end
        end
    end

    // ----------------------------------------------------------------------------
    // E1 (comb): Producto + pre-normalización
    // ----------------------------------------------------------------------------
    wire [47:0] PROD_c = MA_e1 * MB_e1; //xd esto debiera ser lo mas importante
    // al multiplicar nos va a dar un vector de 47, lo cual es bastante
    // de esa manera debemos comprimirmo
    
    reg  [47:0] Pn_c;
    reg  signed [12:0] eSUM1_c; // xponente ajustado para compensar el desplazamiento hecho a Pn_c.
    always @(*) begin
        if (PROD_c[47]) begin
            Pn_c    = PROD_c >> 1;           // 10.x -> 1.x
            eSUM1_c = eSUM0_e1 + 1;
        end else if (PROD_c[46]) begin
            Pn_c    = PROD_c;                // 1.x
            eSUM1_c = eSUM0_e1;
        end else begin
            Pn_c    = PROD_c << 1;           // 0.x
            eSUM1_c = eSUM0_e1 - 1;
        end
    end

// fin del pipeline 1

    // ----------------------------------------------------------------------------
    // Registros E2
    // ----------------------------------------------------------------------------
    reg        v_e2;
    reg        sOUT_e2;
    reg [47:0] Pn_e2;
    reg signed [12:0] eSUM1_e2;
    reg        sp_is_special_e2;
    reg [31:0] sp_word_e2;
    reg [4:0]  sp_flags_e2;

    always @(posedge clk) begin
        if (rst) begin
            v_e2 <= 1'b0; sOUT_e2 <= 1'b0; Pn_e2 <= 48'd0; eSUM1_e2 <= 13'sd0;
            sp_is_special_e2 <= 1'b0; sp_word_e2 <= 32'd0; sp_flags_e2 <= 5'd0;
        end else begin
            v_e2 <= v_e1;
            if (v_e1) begin
                sOUT_e2 <= sOUT_e1;
                Pn_e2   <= Pn_c;
                eSUM1_e2 <= eSUM1_c;
                sp_is_special_e2 <= sp_is_special_e1;
                sp_word_e2       <= sp_word_e1;
                sp_flags_e2      <= sp_flags_e1;
            end
        end
    end

    // ----------------------------------------------------------------------------
    // E2 (comb): Redondeo RNE + empaquetado
    // ----------------------------------------------------------------------------
    // fracción 23 = Pn[45:23], G=Pn[22], R=Pn[21], S=OR(Pn[20:0])
    wire [22:0] frac_pre_c2 = Pn_e2[45:23];
    wire        G_c2        = Pn_e2[22];
    wire        R_c2        = Pn_e2[21];
    wire        S_c2        = |Pn_e2[20:0];
    wire        roundUp_c2  = G_c2 && (R_c2 || S_c2 || frac_pre_c2[0]);

    wire [23:0] frac_with_hidden_c2 = {Pn_e2[46], frac_pre_c2};
    
    wire [24:0] rounded_c2          = {1'b0, frac_with_hidden_c2} + (roundUp_c2 ? 25'd1 : 25'd0);

    reg  [23:0] frac_fin_c2; // la fracion final despues del redondeo
    reg  signed [12:0] eSUM2_c2; // exponente final despues del redondeo
    
    always @(*) begin
        if (rounded_c2[24]) begin
            frac_fin_c2 = {1'b1, rounded_c2[24:1]};
            eSUM2_c2    = eSUM1_e2 + 1;
        end else begin
            frac_fin_c2 = rounded_c2[23:0];
            eSUM2_c2    = eSUM1_e2;
        end
    end
// esta parte solo fue el redondeo, la sigueinte sera un pcoo de enpacamiento.

    // Exponente re-sesgado y estados
    wire signed [13:0] E_biased_c2     = eSUM2_c2 + 13'sd127; // se vuelve a biasar con el exponente + 127
    wire        overflow_c2            = (E_biased_c2 > 13'sd254);//si es qu eel exponenete se paso de 254, es overflo
    wire        under_biased_nonpos_c2 = (E_biased_c2 <= 0);// si el expoennete es emnor o igaul a 0 es underbiadse
    wire        inexact_rnd_c2         = (G_c2 | R_c2 | S_c2); // inexacto por el redondeo.

    // Empaquetado normal/subnormal
    reg [31:0] normal_word_c2;
    reg [4:0]  normal_flags_c2;
    
    
    always @(*) begin
        normal_word_c2  = 32'b0; // el default de los words
        normal_flags_c2 = 5'b0;

        if (overflow_c2) begin // overflow
            normal_word_c2     = {sOUT_e2, 8'hFF, 23'b0};
            normal_flags_c2[2] = 1'b1;                 // overflow
            normal_flags_c2[0] = inexact_rnd_c2;       // inexact
            
        end else if (under_biased_nonpos_c2) begin : bloque1 // por que no es sitem verilog
            integer shift; // cuanto tengo correr para formar un subnormla
            reg [23:0] frac_den; // la fraccion que queda
            reg        lost_bits; // los bits que voy a perder si creo el subnormal
            reg [23:0] mask;

            shift = (1 - E_biased_c2); // el mínimo es 1, y el max -126, así que lo restamos
            if (shift > 24) begin // el numero es tan minusculo que no cabe :/
                normal_word_c2     = {sOUT_e2, 8'd0, 23'd0}; // todo a 0
                normal_flags_c2[1] = 1'b1;             // underflow
                lost_bits          = inexact_rnd_c2 | (|frac_fin_c2); // se perdio bits?
                normal_flags_c2[0] = lost_bits; // la primera flag es activa si se perdio bits
            end else begin // en este caso si puede formar el subnormal
                frac_den = frac_fin_c2 >> shift; // shiteamos la cantidad necesaria para formar un subnormal
                normal_word_c2     = {sOUT_e2, 8'd0, frac_den[22:0]};  // armamos la plabra
                normal_flags_c2[1] = 1'b1;             // underflow
                if (shift >= 24) begin // si el shift es 24 o mas 
                    lost_bits = (|frac_fin_c2); // los bits perdidos
                end else if (shift != 0) begin // se es menor 
                    mask = ((24'h1 << shift) - 1); // shifteamos la mascara
                    lost_bits = |(frac_fin_c2 & mask); // bits perdidos la shitear
                end else begin
                    lost_bits = 1'b0; // no se perdieron bits
                end
                normal_flags_c2[0] = inexact_rnd_c2 | lost_bits; // por si se perfieron bits
            end
        end else begin // en otro caso, solo unir el normal_word
            normal_word_c2     = {sOUT_e2, E_biased_c2[7:0], frac_fin_c2[22:0]};
            normal_flags_c2[0] = inexact_rnd_c2; // ver si es inexacto
        end
    end
// fin del ultimo pipelina
    // Selección final (respeta specials con misma latencia)
    wire [31:0] result_c2 = sp_is_special_e2 ? sp_word_e2  : normal_word_c2;
    wire [4:0]  flags_c2  = sp_is_special_e2 ? sp_flags_e2 : normal_flags_c2;

    // ----------------------------------------------------------------------------
    // Registros de salida (E3): latencia total = 3 ciclos
    // ----------------------------------------------------------------------------
    reg v_e3;
    // saludo a la bandera para colcoar los ultimos resultados y flags.
    always @(posedge clk) begin
        if (rst) begin
            v_e2      <= 1'b0; // (ya reseteado arriba, repetido por seguridad)
            v_e3      <= 1'b0;
            valid_out <= 1'b0;
            result    <= 32'd0;
            flags     <= 5'd0;
        end else begin
            // avanzar "tag" de validez
            v_e3      <= v_e2;
            valid_out <= v_e3;          // pulso 1 ciclo cuando los datos del camino llegan

            if (v_e2) begin
                result <= result_c2;
                flags  <= flags_c2;
            end
        end
    end

endmodule
