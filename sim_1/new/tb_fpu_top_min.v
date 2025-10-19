
//old version
/*`timescale 1ns/1ps
module tb_fpu_top;

  // ====== Reloj / Reset ======
  reg clk = 1'b0;
  always #5 clk = ~clk; // 100 MHz

  reg rst = 1'b1;

  // ====== Interfaz del DUT ======
  reg         start      = 1'b0;
  reg  [31:0] op_a       = 32'd0;
  reg  [31:0] op_b       = 32'd0;
  reg  [1:0]  op_code    = 2'b00; // 2'b10 = MUL (dejamos fijo)
  reg         mode_fp    = 1'b1;  // 1 = single
  reg         round_mode = 1'b0;  // reservado (tu top lo ignora)

  wire [31:0] result;
  wire        valid_out;
  wire [4:0]  flags;

  // ====== Instancia del TOP ======
  fpu_top dut (
    .clk(clk), .rst(rst), .start(start),
    .op_a(op_a), .op_b(op_b),
    .op_code(op_code),
    .mode_fp(mode_fp),
    .round_mode(round_mode),
    .result(result), .valid_out(valid_out), .flags(flags)
  );

  // ====== Helpers FP32 (constantes en hex) ======
  // Normales
  localparam [31:0] F_1_0       = 32'h3F80_0000; //  1.0
  localparam [31:0] F_N1_0      = 32'hBF80_0000; // -1.0
  localparam [31:0] F_1_5       = 32'h3FC0_0000; //  1.5
  localparam [31:0] F_2_0       = 32'h4000_0000; //  2.0
  localparam [31:0] F_3_5       = 32'b01000000011000000000000000000000; //  3.5
  localparam [31:0] F_N2_25     = 32'b11000000000100000000000000000000; // -2.25
  localparam [31:0] F_5_0       = 32'h40A0_0000; //  5.0
  localparam [31:0] F_10_0      = 32'h4120_0000; // 10.0

  // Especiales
  localparam [31:0] P_ZERO      = 32'h0000_0000; // +0
  localparam [31:0] N_ZERO      = 32'h8000_0000; // -0
  localparam [31:0] P_INF       = 32'h7F80_0000; // +Inf
  localparam [31:0] N_INF       = 32'hFF80_0000; // -Inf
  localparam [31:0] QNAN        = 32'h7FC0_0000; // qNaN
  localparam [31:0] MAX_NORM    = 32'h7F7F_FFFF; // máx normal
  localparam [31:0] MIN_NORM    = 32'h0080_0000; // mín normal
  localparam [31:0] MIN_SUB     = 32'h0000_0001; // mín subnormal

  // ====== Secuencia muy simple ======

  initial begin
  
  
    //TEST DE SUMAS
    repeat (4) @(posedge clk);
    rst = 1'b0;
    
    //suma code
    op_code = 2'b00;
    
    // ---- Caso 1: normal + normal (exacto) ----
    // op_a = 40600000
    // op_b = 3F800000
    // resultado = 40200000
    $display("\n[CASE 1] 3.5 - 1.0");
    op_a = F_3_5; op_b = F_N1_0; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A=0x%08h  B=0x%08h  -> R=0x%08h  FLAGS=%05b", op_a, op_b, result, flags);
    
    
    //negative + negative
    //---- Caso 2: -2 + -1 = -0 ----
    // op_a = 0 con el primer digito 0 para que sea +0
    // op_b = 3F800000 (hexadecimal)
    $display("\n[CASE 2] -2 + -1"); 
    op_a = 32'hc0000000; op_b = 32'hbf800000; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A=0x%08h  B=0x%08h  -> R=0x%08h  FLAGS=%05b", op_a, op_b, result, flags);


    //negative + positive
    //---- Caso 2.0.1: -2 + 1 = -0 ----
    // op_a = -2
    // op_b = 3F800000 (hexadecimal)
    $display("\n[CASE 2] -2 + 1"); 
    op_a = 32'hc0000000; op_b = 32'h3f800000; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A=0x%08h  B=0x%08h  -> R=0x%08h  FLAGS=%05b", op_a, op_b, result, flags);
    
    
    //inf + positive
    //---- Caso 2.0.1: -2 + 1 = -0 ----
    $display("\n[CASE 2] inf + 1"); 
    op_a = P_INF; op_b = 32'h3f800000; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A=0x%08h  B=0x%08h  -> R=0x%08h  FLAGS=%05b", op_a, op_b, result, flags);
    
    //-inf + negative
    //---- Caso 2.0.1: -inf + -1 = -0 ----
    $display("\n[CASE 2] -inf + -1"); 
    op_a = N_INF; op_b = 32'hbf800000; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A=0x%08h  B=0x%08h  -> R=0x%08h  FLAGS=%05b", op_a, op_b, result, flags);




    #20;
    rst = 1'b1;
    #10;
    //
    // OPERACIONES DE RESTA
    //
    repeat (4) @(posedge clk);
    rst = 1'b0;
    
    //sub code
    op_code = 2'b01;
    
    //positive (bigger) - positive 
    //---- Caso 2.0.1: 5 - 3 = 2 ----
    $display("\n[SUB] 5 - 3"); 
    op_a = 32'h40a00000; op_b = 32'h40400000; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A=0x%08h  B=0x%08h  -> R=0x%08h  FLAGS=%05b", op_a, op_b, result, flags);
    
    //positive - positive(bigger)  
    //---- Caso 2.0.1: 3 - 5 = -2 ----
    $display("\n[SUB] 3 - 5"); 
    op_a = 32'h40400000; op_b = 32'h40a00000; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A=0x%08h  B=0x%08h  -> R=0x%08h  FLAGS=%05b", op_a, op_b, result, flags);
    
    //inf - inf  
    //---- Caso 2.0.1: inf - inf = NaN ----
    //flags work
    $display("\n[SUB] 3 - 5"); 
    op_a = P_INF; op_b = P_INF; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A=0x%08h  B=0x%08h  -> R=0x%08h  FLAGS=%05b", op_a, op_b, result, flags);
    
    //inf - positive  
    //---- Caso 2.0.1: inf - 3 = inf ----
    //flags work
    $display("\n[SUB] inf - 3"); 
    op_a = P_INF; op_b = 32'h40400000; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A=0x%08h  B=0x%08h  -> R=0x%08h  FLAGS=%05b", op_a, op_b, result, flags);
    
    //-inf - negative  
    //---- Caso 2.0.1: -inf - 3 = -inf ----
    //flags work
    $display("\n[SUB] -inf - -3"); 
    op_a = N_INF; op_b = 32'hc0400000; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A=0x%08h  B=0x%08h  -> R=0x%08h  FLAGS=%05b", op_a, op_b, result, flags);
    
    //
    //SECCION DE MULTIPLICACION
    //
    
    #20;
    rst = 1'b1;
    #10;
    //
    // OPERACIONES DE MUL
    //
    repeat (4) @(posedge clk);
    rst = 1'b0;
    
    //mul code
    op_code = 2'b10;
    
    //Caso  0 * 5.0 = 0
    op_a = 32'h00000000; op_b = 32'h40a00000; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A=0x%08h  B=0x%08h  -> R=0x%08h  FLAGS=%05b", op_a, op_b, result, flags);
    
    //Caso  0.5 * 4.0 = 2.0
    op_a = 32'h3f000000; op_b = 32'h40800000; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A=0x%08h  B=0x%08h  -> R=0x%08h  FLAGS=%05b", op_a, op_b, result, flags);
    
    //Caso 2.0 * 1.0 = 2.0
    op_a = 32'h40000000; op_b = 32'h3f800000; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A=0x%08h  B=0x%08h  -> R=0x%08h  FLAGS=%05b", op_a, op_b, result, flags);
    
    //Caso 2.0 * -1.0 = -2.0 
    op_a = 32'h40000000; op_b = 32'hbf800000; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A=0x%08h  B=0x%08h  -> R=0x%08h  FLAGS=%05b", op_a, op_b, result, flags);
    
    //Caso -2.0 * -1.0 = 2.0
    op_a = 32'hc0000000; op_b = 32'hbf800000; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A=0x%08h  B=0x%08h  -> R=0x%08h  FLAGS=%05b", op_a, op_b, result, flags);
    
    //Caso inf * inf = NaN
    op_a = P_INF; op_b = P_INF; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A=0x%08h  B=0x%08h  -> R=0x%08h  FLAGS=%05b", op_a, op_b, result, flags);
    
    //Caso inf * -inf = NaN
    op_a = P_INF; op_b = N_INF; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A=0x%08h  B=0x%08h  -> R=0x%08h  FLAGS=%05b", op_a, op_b, result, flags);

    //Caso calaberita
    $display("\n[CASE] 💀"); 
    op_a = 32'h00000001; op_b = 32'h40490fdb; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A=0x%08h  B=0x%08h  -> R=0x%08h  FLAGS=%05b", op_a, op_b, result, flags);

    //
    //SECCIÓN DE DIVISIÓN
    //
    #20;
    rst = 1'b1;
    #10;
    repeat (4) @(posedge clk);
    rst = 1'b0;
    
    //div code
    op_code = 2'b11;


    //Caso  0 / 5.0 = 0
    op_a = 32'h00000000; op_b = 32'h40a00000; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A=0x%08h  B=0x%08h  -> R=0x%08h  FLAGS=%05b", op_a, op_b, result, flags);
    
    //Caso  5.0 / 0 = NaN
    op_a = 32'h40a00000; op_b = 32'h00000000; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A=0x%08h  B=0x%08h  -> R=0x%08h  FLAGS=%05b", op_a, op_b, result, flags);
    
    //Caso  -2.0 / -1.0 = 2.0
    op_a = 32'hc0000000; op_b = 32'hbf800000; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A=0x%08h  B=0x%08h  -> R=0x%08h  FLAGS=%05b", op_a, op_b, result, flags);

    //Caso  inf / 0.0 = Nan
    op_a = P_INF; op_b = P_ZERO; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A=0x%08h  B=0x%08h  -> R=0x%08h  FLAGS=%05b", op_a, op_b, result, flags);



    //Caso  6.0/ -3.0 = -2
    op_a = 32'h40c00000; op_b = 32'hc0400000; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A=0x%08h  B=0x%08h  -> R=0x%08h  FLAGS=%05b", op_a, op_b, result, flags);
    
    
    //Caso  1.0/1.0 = 1.0
    op_a = 32'h3f800000; op_b = 32'h3f800000; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A=0x%08h  B=0x%08h  -> R=0x%08h  FLAGS=%05b", op_a, op_b, result, flags);

    $display("\n*** FIN DE LA SIMULACION ***\n");
    #20 $finish;

  end
  
endmodule
*/

`timescale 1ns/1ps
module tb_fpu_top;

  // ====== Reloj / Reset ======
  reg clk = 1'b0;
  always #5 clk = ~clk; // 100 MHz

  reg rst = 1'b1;

  // ====== Interfaz del DUT ======
  reg         start      = 1'b0;
  reg  [31:0] op_a       = 32'd0;
  reg  [31:0] op_b       = 32'd0;
  reg  [1:0]  op_code    = 2'b00; // 2'b10 = MUL (dejamos fijo)
  reg         mode_fp    = 1'b1;  // 1 = single
  reg         round_mode = 1'b0;  // reservado (tu top lo ignora)

  wire [31:0] result;
  wire        valid_out;
  wire [4:0]  flags;

  // ====== Instancia del TOP ======
  fpu_top dut (
    .clk(clk), .rst(rst), .start(start),
    .op_a(op_a), .op_b(op_b),
    .op_code(op_code),
    .mode_fp(mode_fp),
    .round_mode(round_mode),
    .result(result), .valid_out(valid_out), .flags(flags)
  );

  // ====== Helpers FP32 (constantes en hex) ======
  // Normales
  localparam [31:0] F_1_0       = 32'h3F80_0000; //  1.0
  localparam [31:0] F_N1_0      = 32'hBF80_0000; // -1.0
  localparam [31:0] F_1_5       = 32'h3FC0_0000; //  1.5
  localparam [31:0] F_2_0       = 32'h4000_0000; //  2.0
  localparam [31:0] F_3_5       = 32'b01000000011000000000000000000000; //  3.5
  localparam [31:0] F_N2_25     = 32'b11000000000100000000000000000000; // -2.25
  localparam [31:0] F_5_0       = 32'h40A0_0000; //  5.0
  localparam [31:0] F_10_0      = 32'h4120_0000; // 10.0

  // Especiales
  localparam [31:0] P_ZERO      = 32'h0000_0000; // +0
  localparam [31:0] N_ZERO      = 32'h8000_0000; // -0
  localparam [31:0] P_INF       = 32'h7F80_0000; // +Inf
  localparam [31:0] N_INF       = 32'hFF80_0000; // -Inf
  localparam [31:0] QNAN        = 32'h7FC0_0000; // qNaN
  localparam [31:0] MAX_NORM    = 32'h7F7F_FFFF; // máx normal
  localparam [31:0] MIN_NORM    = 32'h0080_0000; // mín normal
  localparam [31:0] MIN_SUB     = 32'h0000_0001; // mín subnormal
  
   // ====== Helpers FP16 (constantes en hex, en los LOW 16 bits) ======
  // Normales
  localparam [15:0] H_1_0       = 16'h3C00; //  1.0
  localparam [15:0] H_2_0       = 16'h4000; //  2.0
  localparam [15:0] H_3_0       = 16'h4200; //  3.0
  localparam [15:0] H_5_0       = 16'h4500; //  5.0
  localparam [15:0] H_MIN_NORM  = 16'h0400; //  2^-14
  localparam [15:0] H_0_5       = 16'h3800; //  0.5
  localparam [15:0] H_0_5_ULP   = 16'h3801; //  0.5 + 1 ulp (para provocar inexact/underflow)
  localparam [15:0] H_MAX       = 16'h7BFF; //  65504 (máx finito)
  // Especiales
  localparam [15:0] H_P_ZERO    = 16'h0000; // +0
  localparam [15:0] H_P_INF     = 16'h7C00; // +Inf
  localparam [15:0] H_N_INF     = 16'hFC00; // -Inf

  // ====== Secuencia muy simple ======

  initial begin
  
  
    //TEST DE SUMAS
    repeat (4) @(posedge clk);
    rst = 1'b0;
    
    //suma code
    op_code = 2'b00;
    
    $display("\n[CASE 1] 5.0 + 3.0");
    op_a = 32'h40a00000; op_b = 32'h40400000; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A=0x%08h  B=0x%08h  -> R=0x%08h  FLAGS=%05b", op_a, op_b, result, flags);
    
    
    //inf + -inf

    $display("\n[CASE 2] +inf + -inf"); 
    op_a = P_INF; op_b = N_INF; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A=0x%08h  B=0x%08h  -> R=0x%08h  FLAGS=%05b", op_a, op_b, result, flags);


    //
    //SECCIÓN DE DIVISIÓN
    //
    #20;
    rst = 1'b1;
    #10;
    repeat (4) @(posedge clk);
    rst = 1'b0;
    
    //div code
    op_code = 2'b11;

    
    //Caso  1.0 / 0 = NaN
    $display("\n[CASE 4] 1.0 / 0.0"); 
    op_a = 32'h3f800000; op_b = 32'h00000000; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A=0x%08h  B=0x%08h  -> R=0x%08h  FLAGS=%05b", op_a, op_b, result, flags);
    
     //
    //SECCION DE MULTIPLICACION
    //
    
    #20;
    rst = 1'b1;
    #10;
    //
    // OPERACIONES DE MUL
    //
    repeat (4) @(posedge clk);
    rst = 1'b0;
    
    //mul code
    op_code = 2'b10;
    
    //Caso  2^-126 * 0.5+2^-24 
    $display("\n[CASE 5] 2^-126 * 0.5+2^-24"); 
    op_a = 32'h00800000; op_b = 32'h3F000001; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A=0x%08h  B=0x%08h  -> R=0x%08h  FLAGS=%05b", op_a, op_b, result, flags);
    
    
    //Caso  3.4e38 * 2.0
    $display("\n[CASE 6] 3.4e38 * 2.0"); 
    op_a = 32'h7F7FFFFF; op_b = 32'h40000000; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A=0x%08h  B=0x%08h  -> R=0x%08h  FLAGS=%05b", op_a, op_b, result, flags);
    
    
    

    // ========= BLOQUE FP16 (mode_fp=0) =========
    // Repite misma secuencia pero empaquetando FP16 en los LOW 16 bits
    #20; rst = 1'b1; #10; repeat (4) @(posedge clk); rst = 1'b0;
    mode_fp = 1'b0; // ahora HALF (16 bits)

    // SUM (FP16)
    op_code = 2'b00; // ADD

    $display("\n[FP16 CASE 1] 5.0 + 3.0");
    op_a = {H_5_0, 16'h0000}; op_b = {H_3_0, 16'h0000}; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A16=0x%04h B16=0x%04h -> R=0x%04h FLAGS=%05b",
             op_a[31:16], op_b[31:16], result[31:16], flags);

    $display("\n[FP16 CASE 2] +inf + -inf");
    op_a = {H_P_INF, 16'h0000}; op_b = {H_N_INF, 16'h0000 }; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A16=0x%04h B16=0x%04h -> R=0x%04h FLAGS=%05b",
             op_a[31:16], op_b[31:16], result[31:16], flags);

    // DIV (FP16)
    #20; rst = 1'b1; #10; repeat (4) @(posedge clk); rst = 1'b0;
    op_code = 2'b11; // DIV

    $display("\n[FP16 CASE 3] 1.0 / 0.0");
    op_a = {H_1_0, 16'h0000}; op_b = {H_P_ZERO, 16'h0000}; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A16=0x%04h B16=0x%04h -> R=0x%04h FLAGS=%05b",
             op_a[31:16], op_b[31:16], result[31:16], flags);

    // MUL (FP16)
    #20; rst = 1'b1; #10; repeat (4) @(posedge clk); rst = 1'b0;
    op_code = 2'b10; // MUL

    $display("\n[FP16 CASE 4] 2^-14 * (0.5 + 1 ulp)  -> subnormal, probable inexact/underflow");
    op_a = {H_MIN_NORM, 16'h0000 }; op_b = {H_0_5_ULP, 16'h0000 }; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A16=0x%04h B16=0x%04h -> R=0x%04h FLAGS=%05b",
             op_a[31:16], op_b[31:16], result[31:16], flags);

    $display("\n[FP16 CASE 5] max_half * 2.0  (65504 * 2)");
    op_a = {H_MAX, 16'h0000 }; op_b = {H_2_0, 16'h0000}; start = 1'b1; @(posedge clk); start = 1'b0;
    @(posedge valid_out);
    $display("  A16=0x%04h B16=0x%04h -> R=0x%04h FLAGS=%05b",
             op_a[31:16], op_b[31:16], result[31:16], flags);

    // ===== FIN =====
    $display("\n*** FIN DE LA SIMULACION ***\n");
    #20 $finish;
  end
  
endmodule
