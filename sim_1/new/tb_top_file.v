`timescale 1ns / 1ps

module tb_top_placa;

    // Inputs
    reg clk;
    reg btnC;
    reg [15:0] sw;
    
    // Outputs
    wire [15:0] led;
    wire [3:0] an;
    wire [6:0] seg;
    wire dp;
    
    // Instantiate the Unit Under Test (UUT)
    top_placa uut (
        .clk(clk),
        .btnC(btnC),
        .sw(sw),
        .led(led),
        .an(an),
        .seg(seg),
        .dp(dp)
    );
    
    //sw[10] == start
    //sw [14] === load bites
    //sw [5:2] == nibble a
    //sw [9: 6] === nibble b
    // sw [1:0] == op code
    always #0.1 clk = ~clk;
    
    // Test stimulus
    initial begin
        // Initialize Inputs
        clk = 0;
        btnC = 1;
        sw = 16'h0000;
        
        
        // Wait 100 ns for global reset
        #20;
        btnC= 0;
        //set division mode
        sw[1:0] = 2'b11;
        sw[11] = 1'b1;
        //set load off
        #3;
        sw[14] = 0;
        
        #3;
        sw[5:2] = 4'b0100;
        
        //first postedge
        #10;
        sw[14] = 1;
        #20;
        sw[14] = 0;
        #10;
        
        sw[5:2] = 4'b0000;
        
        //second and so on postedge
        #10;
        sw[14] = 1;
        #20;
        sw[14] = 0;
        #10;
        
        sw[5:2] = 4'b0000;
        
        //second and so on postedge
        #10;
        sw[14] = 1;
        #20;
        sw[14] = 0;
        #10;
        
        sw[5:2] = 4'b0000;
        
        //second and so on postedge
        #10;
        sw[14] = 1;
        #20;
        sw[14] = 0;
        #10;
        
        sw[5:2] = 4'b0000;
        
        //second and so on postedge
        #10;
        sw[14] = 1;
        #20;
        sw[14] = 0;
        #10;
        
        sw[5:2] = 4'b0000;
        
        //second and so on postedge
        #10;
        sw[14] = 1;
        #20;
        sw[14] = 0;
        #10;
        
        sw[5:2] = 4'b0000;
        
        //second and so on postedge
        #10;
        sw[14] = 1;
        #20;
        sw[14] = 0;
        #10;
        
        sw[5:2] = 4'b0000;
        
        //second and so on postedge
        #10;
        sw[14] = 1;
        #20;
        sw[14] = 0;
        #10;
        
        //*************************
        ///------------------------------------------
        //time to load the a_op
        #12;
        
        sw[9:6] = 4'b0011;
        
        //press btn load
        #10;
        sw[14] = 1;
        #20;
        sw[14] = 0;
        #10;
        
        sw[9:6] = 4'b1111;
        
        //press btn load
        #10;
        sw[14] = 1;
        #20;
        sw[14] = 0;
        #10;
        
        sw[9:6] = 4'b1000;
        
        //press btn load
        #10;
        sw[14] = 1;
        #20;
        sw[14] = 0;
        #10;
        
        sw[9:6] = 4'b0000;
        
        //press btn load
        #10;
        sw[14] = 1;
        #20;
        sw[14] = 0;
        #10;
        
        sw[9:6] = 4'b0000;
        
        //press btn load
        #10;
        sw[14] = 1;
        #20;
        sw[14] = 0;
        #10;
        sw[9:6] = 4'b0000;
        
        //press btn load
        #10;
        sw[14] = 1;
        #20;
        sw[14] = 0;
        #10;
        sw[9:6] = 4'b0000;
        
        //press btn load
        #10;
        sw[14] = 1;
        #20;
        sw[14] = 0;
        #10;
        sw[9:6] = 4'b0000;
        
        //press btn load
        #10;
        sw[14] = 1;
        #20;
        sw[14] = 0;
        #10;
        
        //load for the result
        #10;
        sw[10] = 1;
        #20;
        sw[10] = 0;
        #10;
        
        #30
        
        $finish;
        
        
    end

endmodule