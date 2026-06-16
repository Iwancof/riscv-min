module rv32i_core #(
    parameter logic [31:0] RESET_PC = 32'h0000_0000
) (
    input  logic        clk,
    input  logic        rst_n,

    output logic [31:0] imem_addr_o,
    input  logic [31:0] imem_rdata_i,

    output logic [31:0] dmem_addr_o,
    output logic [31:0] dmem_wdata_o,
    output logic [3:0]  dmem_wstrb_o,
    input  logic [31:0] dmem_rdata_i,

    output logic [31:0] pc_o,
    output logic        trap_o,
    output logic        halt_o
);

    localparam logic [6:0] OP_LUI    = 7'b0110111,
                            OP_AUIPC  = 7'b0010111,
                            OP_JAL    = 7'b1101111,
                            OP_JALR   = 7'b1100111,
                            OP_BRANCH = 7'b1100011,
                            OP_LOAD   = 7'b0000011,
                            OP_STORE  = 7'b0100011,
                            OP_IMM    = 7'b0010011,
                            OP_REG    = 7'b0110011,
                            OP_SYSTEM = 7'b1110011;

    localparam logic [2:0] S_FETCH   = 3'd0,
                            S_DECODE  = 3'd1,
                            S_EXECUTE = 3'd2,
                            S_MEMORY  = 3'd3,
                            S_SHIFT   = 3'd4;

    logic [2:0]  state_q;
    logic [31:0] pc_q, ir_q, reg_a_q, alu_out_q;
    logic [4:0]  shf_cnt_q;

    logic [31:0] regs [1:7];

    wire [6:0] opcode = ir_q[6:0];
    wire [2:0] rd3    = ir_q[9:7];
    wire [2:0] funct3 = ir_q[14:12];
    wire [2:0] rs1_3  = ir_q[17:15];
    wire [2:0] rs2_3  = ir_q[22:20];
    wire [4:0] shamt  = ir_q[24:20];

    wire [31:0] imm_i = {{20{ir_q[31]}}, ir_q[31:20]};
    wire [31:0] imm_s = {{20{ir_q[31]}}, ir_q[31:25], ir_q[11:7]};
    wire [31:0] imm_b = {{19{ir_q[31]}}, ir_q[31], ir_q[7], ir_q[30:25], ir_q[11:8], 1'b0};
    wire [31:0] imm_u = {ir_q[31:12], 12'b0};
    wire [31:0] imm_j = {{11{ir_q[31]}}, ir_q[31], ir_q[19:12], ir_q[20], ir_q[30:21], 1'b0};

    logic [2:0] rf_raddr;
    wire [31:0] rf_rdata = (rf_raddr == 3'd0) ? 32'b0 : regs[rf_raddr];

    wire [31:0] pc_plus4 = pc_q + 32'd4;

    assign imem_addr_o = pc_q;
    assign pc_o        = pc_q;

    logic [31:0] alu_a, alu_b;
    logic        alu_do_sub;

    wire [32:0] alu_sum_ext = {1'b0, alu_a} + {1'b0, (alu_do_sub ? ~alu_b : alu_b)} + {32'b0, alu_do_sub};
    wire [31:0] alu_sum   = alu_sum_ext[31:0];
    wire        alu_carry = alu_sum_ext[32];
    wire        slt_res   = (alu_a[31] != alu_b[31]) ? alu_a[31] : alu_sum[31];
    wire [31:0] alu_result = alu_sum;

    logic branch_taken;
    always_comb begin
        case (funct3)
            3'b000:  branch_taken = (alu_sum == 32'b0);
            3'b001:  branch_taken = (alu_sum != 32'b0);
            3'b100:  branch_taken = slt_res;
            3'b101:  branch_taken = ~slt_res;
            3'b110:  branch_taken = ~alu_carry;
            3'b111:  branch_taken = alu_carry;
            default: branch_taken = 1'b0;
        endcase
    end

    logic [7:0] load_byte;
    always_comb begin
        case (alu_out_q[1:0])
            2'b00:   load_byte = dmem_rdata_i[7:0];
            2'b01:   load_byte = dmem_rdata_i[15:8];
            2'b10:   load_byte = dmem_rdata_i[23:16];
            default: load_byte = dmem_rdata_i[31:24];
        endcase
    end
    wire [15:0] load_half = alu_out_q[1] ? dmem_rdata_i[31:16] : dmem_rdata_i[15:0];

    logic [31:0] store_wdata;
    always_comb begin
        case (alu_out_q[1:0])
            2'b00:   store_wdata = rf_rdata;
            2'b01:   store_wdata = {rf_rdata[23:0], 8'b0};
            2'b10:   store_wdata = {rf_rdata[15:0], 16'b0};
            default: store_wdata = {rf_rdata[7:0],  24'b0};
        endcase
    end

    wire shf_right = (funct3 == 3'b101);
    wire shf_arith = ir_q[30];

    logic [2:0]  state_d;
    logic [31:0] pc_d;
    logic        rf_we;
    logic [2:0]  rf_waddr;
    logic [31:0] rf_wdata;
    logic        do_trap, do_halt;
    logic [31:0] dmem_addr_d, dmem_wdata_d;
    logic [3:0]  dmem_wstrb_d;

    assign dmem_addr_o  = dmem_addr_d;
    assign dmem_wdata_o = dmem_wdata_d;
    assign dmem_wstrb_o = dmem_wstrb_d;

    always_comb begin
        state_d      = state_q;
        pc_d         = pc_q;
        rf_raddr     = 3'd0;
        rf_we        = 1'b0;
        rf_waddr     = rd3;
        rf_wdata     = 32'b0;
        alu_a        = 32'b0;
        alu_b        = 32'b0;
        alu_do_sub   = 1'b0;
        do_trap      = 1'b0;
        do_halt      = 1'b0;
        dmem_addr_d  = alu_out_q;
        dmem_wdata_d = 32'b0;
        dmem_wstrb_d = 4'b0000;

        case (state_q)
            S_FETCH: state_d = S_DECODE;

            S_DECODE: begin
                rf_raddr = rs1_3;
                alu_a = pc_q;
                case (opcode)
                    OP_BRANCH: alu_b = imm_b;
                    OP_JAL:    alu_b = imm_j;
                    OP_AUIPC:  alu_b = imm_u;
                    OP_JALR:   alu_b = 32'd4;
                    default:   alu_b = 32'b0;
                endcase
                state_d = S_EXECUTE;
            end

            S_EXECUTE: begin
                rf_raddr = rs2_3;
                case (opcode)
                    OP_REG: begin
                        alu_a = reg_a_q;
                        alu_b = rf_rdata;
                        if (funct3 == 3'b000) begin
                            alu_do_sub = ir_q[30];
                            rf_we    = 1'b1;
                            rf_wdata = alu_result;
                            pc_d     = pc_plus4;
                            state_d  = S_FETCH;
                        end else if (funct3 == 3'b001 || funct3 == 3'b101) begin
                            state_d = S_SHIFT;
                        end else begin
                            pc_d    = pc_plus4;
                            state_d = S_FETCH;
                        end
                    end

                    OP_IMM: begin
                        alu_a = reg_a_q;
                        alu_b = imm_i;
                        if (funct3 == 3'b000) begin
                            rf_we    = 1'b1;
                            rf_wdata = alu_result;
                            pc_d     = pc_plus4;
                            state_d  = S_FETCH;
                        end else if (funct3 == 3'b001 || funct3 == 3'b101) begin
                            state_d = S_SHIFT;
                        end else begin
                            pc_d    = pc_plus4;
                            state_d = S_FETCH;
                        end
                    end

                    OP_LOAD: begin
                        alu_a   = reg_a_q;
                        alu_b   = imm_i;
                        state_d = S_MEMORY;
                    end

                    OP_STORE: begin
                        alu_a   = reg_a_q;
                        alu_b   = imm_s;
                        state_d = S_MEMORY;
                    end

                    OP_BRANCH: begin
                        alu_a      = reg_a_q;
                        alu_b      = rf_rdata;
                        alu_do_sub = 1'b1;
                        pc_d       = branch_taken ? alu_out_q : pc_plus4;
                        state_d    = S_FETCH;
                    end

                    OP_JAL: begin
                        pc_d     = alu_out_q;
                        rf_we    = 1'b1;
                        rf_wdata = pc_plus4;
                        state_d  = S_FETCH;
                    end

                    OP_JALR: begin
                        alu_a = reg_a_q;
                        alu_b = imm_i;
                        if (alu_result[1])
                            do_trap = 1'b1;
                        else begin
                            pc_d     = {alu_result[31:1], 1'b0};
                            rf_we    = 1'b1;
                            rf_wdata = alu_out_q;
                        end
                        state_d = S_FETCH;
                    end

                    OP_LUI: begin
                        rf_we    = 1'b1;
                        rf_wdata = imm_u;
                        pc_d     = pc_plus4;
                        state_d  = S_FETCH;
                    end

                    OP_AUIPC: begin
                        rf_we    = 1'b1;
                        rf_wdata = alu_out_q;
                        pc_d     = pc_plus4;
                        state_d  = S_FETCH;
                    end

                    OP_SYSTEM: begin
                        if (ir_q == 32'h0010_0073) do_halt = 1'b1;
                        else do_trap = 1'b1;
                        state_d = S_FETCH;
                    end

                    default: begin
                        pc_d    = pc_plus4;
                        state_d = S_FETCH;
                    end
                endcase
            end

            S_MEMORY: begin
                dmem_addr_d = alu_out_q;
                rf_raddr    = rs2_3;
                if (opcode == OP_LOAD) begin
                    rf_we = 1'b1;
                    case (funct3)
                        3'b000: rf_wdata = {{24{load_byte[7]}}, load_byte};
                        3'b001: begin
                            if (alu_out_q[0]) do_trap = 1'b1;
                            rf_wdata = {{16{load_half[15]}}, load_half};
                        end
                        3'b010: begin
                            if (alu_out_q[1:0] != 2'b00) do_trap = 1'b1;
                            rf_wdata = dmem_rdata_i;
                        end
                        3'b100: rf_wdata = {24'b0, load_byte};
                        3'b101: begin
                            if (alu_out_q[0]) do_trap = 1'b1;
                            rf_wdata = {16'b0, load_half};
                        end
                        default: do_trap = 1'b1;
                    endcase
                end else begin
                    dmem_wdata_d = store_wdata;
                    case (funct3)
                        3'b000: dmem_wstrb_d = 4'b0001 << alu_out_q[1:0];
                        3'b001: begin
                            if (alu_out_q[0]) do_trap = 1'b1;
                            dmem_wstrb_d = 4'b0011 << alu_out_q[1:0];
                        end
                        3'b010: begin
                            if (alu_out_q[1:0] != 2'b00) do_trap = 1'b1;
                            dmem_wstrb_d = 4'b1111;
                        end
                        default: do_trap = 1'b1;
                    endcase
                end
                pc_d    = pc_plus4;
                state_d = S_FETCH;
            end

            S_SHIFT: begin
                if (shf_cnt_q == 5'd0) begin
                    rf_we    = 1'b1;
                    rf_wdata = alu_out_q;
                    pc_d     = pc_plus4;
                    state_d  = S_FETCH;
                end
            end

            default: begin
                do_trap = 1'b1;
                state_d = S_FETCH;
            end
        endcase

        if (do_trap || do_halt) begin
            pc_d         = pc_q;
            rf_we        = 1'b0;
            dmem_wstrb_d = 4'b0000;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q   <= S_FETCH;
            pc_q      <= RESET_PC;
            ir_q      <= 32'b0;
            reg_a_q   <= 32'b0;
            alu_out_q <= 32'b0;
            shf_cnt_q <= 5'b0;
            trap_o    <= 1'b0;
            halt_o    <= 1'b0;
            for (int i = 1; i <= 7; i++) regs[i] <= 32'b0;
        end else if (halt_o || trap_o) begin
            // stall
        end else begin
            state_q <= state_d;

            case (state_q)
                S_FETCH:
                    ir_q <= imem_rdata_i;

                S_DECODE: begin
                    reg_a_q   <= rf_rdata;
                    alu_out_q <= alu_result;
                end

                S_EXECUTE: begin
                    pc_q <= pc_d;
                    if (rf_we && rf_waddr != 3'd0)
                        regs[rf_waddr] <= rf_wdata;
                    if (state_d == S_MEMORY)
                        alu_out_q <= alu_result;
                    if (state_d == S_SHIFT) begin
                        alu_out_q <= reg_a_q;
                        shf_cnt_q <= (opcode == OP_REG) ? rf_rdata[4:0] : shamt;
                    end
                end

                S_MEMORY: begin
                    pc_q <= pc_d;
                    if (rf_we && rf_waddr != 3'd0)
                        regs[rf_waddr] <= rf_wdata;
                end

                S_SHIFT: begin
                    if (shf_cnt_q != 5'd0) begin
                        if (shf_right)
                            alu_out_q <= {shf_arith & alu_out_q[31], alu_out_q[31:1]};
                        else
                            alu_out_q <= {alu_out_q[30:0], 1'b0};
                        shf_cnt_q <= shf_cnt_q - 5'd1;
                    end else begin
                        pc_q <= pc_d;
                        if (rf_we && rf_waddr != 3'd0)
                            regs[rf_waddr] <= rf_wdata;
                    end
                end

                default: ;
            endcase

            if (do_trap) begin
                trap_o  <= 1'b1;
                state_q <= S_FETCH;
            end
            if (do_halt) begin
                halt_o  <= 1'b1;
                state_q <= S_FETCH;
            end
        end
    end
endmodule
