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

    localparam [6:0] OP_LUI    = 7'b0110111, OP_AUIPC  = 7'b0010111,
                     OP_JAL    = 7'b1101111, OP_JALR   = 7'b1100111,
                     OP_BRANCH = 7'b1100011, OP_LOAD   = 7'b0000011,
                     OP_STORE  = 7'b0100011, OP_IMM    = 7'b0010011,
                     OP_REG    = 7'b0110011, OP_FENCE  = 7'b0001111,
                     OP_SYSTEM = 7'b1110011, OP_AMO    = 7'b0101111;

    localparam [1:0] MD_MUL = 2'd0, MD_DIV = 2'd1, MD_SHIFT = 2'd2;

    // ================================================================
    // Register file -- single read port
    // ================================================================
    logic [31:0] regs [1:31];
    logic [4:0]  rf_idx;
    wire  [31:0] rf_rdata = (rf_idx == 5'd0) ? 32'b0 : regs[rf_idx];

    // ================================================================
    // FSM
    // ================================================================
    localparam [2:0] S_FETCH  = 3'd0, S_FETCH2 = 3'd1, S_EXEC = 3'd2,
                     S_MEM    = 3'd3, S_WB     = 3'd4, S_MULDIV = 3'd5;
    logic [2:0] state;

    logic [31:0] pc_q, ir, alu_out;
    logic        ir_compressed;
    logic [15:0] hwbuf;

    logic [1:0]  md_op;
    logic        md_negate, md_hi_result;
    logic [5:0]  md_cnt;
    logic [31:0] md_hi, md_lo, md_b;
    logic        div_nq, div_nr, div_bz;

    logic [31:0] resv_addr;
    logic        resv_valid;

    // ================================================================
    // RV32C Decompressor
    // ================================================================
    function automatic [31:0] decompress(input [15:0] ci);
        logic [31:0] out;
        logic [4:0]  rd_c, rs2_c, rd_f, rs2_f, shamt;
        logic [5:0]  imm6;
        logic [6:0]  off7;
        logic [9:0]  nzuimm10;
        logic [11:0] imm12;
        logic [10:0] joff11;
        logic [12:0] bimm13;
        logic [20:0] jimm21;
        logic [8:0]  off9;
        logic [7:0]  off8;
        out = 32'h0;
        case (ci[1:0])
        2'b00: begin
            rd_c={2'b01,ci[4:2]}; rs2_c=rd_c;
            case (ci[15:13])
            3'b000: begin nzuimm10={ci[10:7],ci[12:11],ci[5],ci[6],2'b00};
                if(nzuimm10!=0) out={{2'b0,nzuimm10},5'd2,3'b000,rd_c,7'b0010011}; end
            3'b010: begin off7={ci[5],ci[12:10],ci[6],2'b00};
                out={5'b0,off7,{2'b01,ci[9:7]},3'b010,rd_c,7'b0000011}; end
            3'b110: begin off7={ci[5],ci[12:10],ci[6],2'b00};
                out={5'b0,off7[6:5],rs2_c,{2'b01,ci[9:7]},3'b010,off7[4:0],7'b0100011}; end
            default:;
            endcase
        end
        2'b01: begin
            rd_c={2'b01,ci[9:7]}; rs2_c={2'b01,ci[4:2]};
            rd_f=ci[11:7]; imm6={ci[12],ci[6:2]};
            case (ci[15:13])
            3'b000: begin imm12={{6{imm6[5]}},imm6}; out={imm12,rd_f,3'b000,rd_f,7'b0010011}; end
            3'b001: begin joff11={ci[12],ci[8],ci[10:9],ci[6],ci[7],ci[2],ci[11],ci[5:3]};
                jimm21={{9{joff11[10]}},joff11,1'b0};
                out={jimm21[20],jimm21[10:1],jimm21[11],jimm21[19:12],5'd1,7'b1101111}; end
            3'b010: begin imm12={{6{imm6[5]}},imm6}; out={imm12,5'd0,3'b000,rd_f,7'b0010011}; end
            3'b011: if(rd_f==5'd2) begin nzuimm10={ci[12],ci[4:3],ci[5],ci[2],ci[6],4'b0};
                    out={{{2{nzuimm10[9]}},nzuimm10},5'd2,3'b000,5'd2,7'b0010011};
                end else if(rd_f!=0) begin out={{14{imm6[5]}},imm6,12'b0}; out[11:7]=rd_f; out[6:0]=7'b0110111; end
            3'b100: case(ci[11:10])
                2'b00: out={7'b0,ci[6:2],rd_c,3'b101,rd_c,7'b0010011};
                2'b01: out={7'b0100000,ci[6:2],rd_c,3'b101,rd_c,7'b0010011};
                2'b10: begin imm12={{6{imm6[5]}},imm6}; out={imm12,rd_c,3'b111,rd_c,7'b0010011}; end
                2'b11: case({ci[12],ci[6:5]})
                    3'b000: out={7'b0100000,rs2_c,rd_c,3'b000,rd_c,7'b0110011};
                    3'b001: out={7'b0,rs2_c,rd_c,3'b100,rd_c,7'b0110011};
                    3'b010: out={7'b0,rs2_c,rd_c,3'b110,rd_c,7'b0110011};
                    3'b011: out={7'b0,rs2_c,rd_c,3'b111,rd_c,7'b0110011};
                    default:;
                endcase
                endcase
            3'b101: begin joff11={ci[12],ci[8],ci[10:9],ci[6],ci[7],ci[2],ci[11],ci[5:3]};
                jimm21={{9{joff11[10]}},joff11,1'b0};
                out={jimm21[20],jimm21[10:1],jimm21[11],jimm21[19:12],5'd0,7'b1101111}; end
            3'b110: begin off9={ci[12],ci[6:5],ci[2],ci[11:10],ci[4:3],1'b0}; bimm13={{4{off9[8]}},off9};
                out={bimm13[12],bimm13[10:5],5'd0,rd_c,3'b000,bimm13[4:1],bimm13[11],7'b1100011}; end
            3'b111: begin off9={ci[12],ci[6:5],ci[2],ci[11:10],ci[4:3],1'b0}; bimm13={{4{off9[8]}},off9};
                out={bimm13[12],bimm13[10:5],5'd0,rd_c,3'b001,bimm13[4:1],bimm13[11],7'b1100011}; end
            endcase
        end
        2'b10: begin
            rd_f=ci[11:7]; rs2_f=ci[6:2];
            case (ci[15:13])
            3'b000: if(rd_f!=0) out={7'b0,ci[6:2],rd_f,3'b001,rd_f,7'b0010011};
            3'b010: begin off8={ci[3:2],ci[12],ci[6:4],2'b00};
                if(rd_f!=0) out={4'b0,off8,5'd2,3'b010,rd_f,7'b0000011}; end
            3'b100: if(!ci[12]) begin
                    if(rs2_f==0) begin if(rd_f!=0) out={12'b0,rd_f,3'b000,5'd0,7'b1100111}; end
                    else out={7'b0,rs2_f,5'd0,3'b000,rd_f,7'b0110011};
                end else begin
                    if(rs2_f==0) begin if(rd_f==0) out=32'h00100073; else out={12'b0,rd_f,3'b000,5'd1,7'b1100111}; end
                    else out={7'b0,rs2_f,rd_f,3'b000,rd_f,7'b0110011};
                end
            3'b110: begin off8={ci[8:7],ci[12:9],2'b00};
                out={4'b0,off8[7:5],rs2_f,5'd2,3'b010,off8[4:0],7'b0100011}; end
            default:;
            endcase
        end
        default:;
        endcase
        decompress = out;
    endfunction

    // ================================================================
    // Decode (from ir)
    // ================================================================
    wire [6:0] opcode     = ir[6:0];
    wire [4:0] rd         = ir[11:7];
    wire [2:0] funct3     = ir[14:12];
    wire [4:0] rs2_idx    = ir[24:20];
    wire [6:0] funct7     = ir[31:25];
    wire       f7b5       = ir[30];
    wire [4:0] amo_funct5 = ir[31:27];

    wire [31:0] imm_i = {{20{ir[31]}}, ir[31:20]};
    wire [31:0] imm_s = {{20{ir[31]}}, ir[31:25], ir[11:7]};
    wire [31:0] imm_b = {{19{ir[31]}}, ir[31], ir[7], ir[30:25], ir[11:8], 1'b0};
    wire [31:0] imm_u = {ir[31:12], 12'b0};
    wire [31:0] imm_j = {{11{ir[31]}}, ir[31], ir[19:12], ir[20], ir[30:21], 1'b0};

    wire is_muldiv  = (opcode == OP_REG) && (funct7 == 7'b0000001);
    wire is_mul     = is_muldiv && !funct3[2];
    wire is_amo     = (opcode == OP_AMO);
    wire is_lr      = is_amo && (amo_funct5 == 5'b00010);
    wire is_sc      = is_amo && (amo_funct5 == 5'b00011);
    wire is_amo_rmw = is_amo && !is_lr && !is_sc;
    wire is_shift   = (funct3 == 3'b001) || (funct3 == 3'b101);

    // rv1 = alu_out (rs1 saved during FETCH), rv2 = rf_rdata (rs2 read in EXEC)
    wire [31:0] rv1 = alu_out;
    wire [31:0] rv2 = rf_rdata;

    // ================================================================
    // Fetch: decode instruction for ir and read rs1
    // ================================================================
    logic [31:0] fetch_ir;
    logic        fetch_compressed, fetch_cross;

    always_comb begin
        fetch_ir = 32'h0000_0013;
        fetch_compressed = 1'b0;
        fetch_cross = 1'b0;
        if (state == S_FETCH) begin
            if (!pc_q[1]) begin
                if (imem_rdata_i[1:0] != 2'b11) begin
                    fetch_ir = decompress(imem_rdata_i[15:0]);
                    fetch_compressed = 1'b1;
                end else
                    fetch_ir = imem_rdata_i;
            end else begin
                if (imem_rdata_i[17:16] != 2'b11) begin
                    fetch_ir = decompress(imem_rdata_i[31:16]);
                    fetch_compressed = 1'b1;
                end else
                    fetch_cross = 1'b1;
            end
        end else if (state == S_FETCH2) begin
            fetch_ir = {imem_rdata_i[15:0], hwbuf};
        end
    end

    // ================================================================
    // Register file index: rs1 of fetched instr during FETCH, rs2 otherwise
    // ================================================================
    always_comb begin
        if (state == S_FETCH || state == S_FETCH2)
            rf_idx = fetch_ir[19:15];
        else
            rf_idx = rs2_idx;
    end

    // ================================================================
    // ALU (shared with mul/div)
    // ================================================================
    wire [31:0] div_shifted_hi = {md_hi[30:0], md_lo[31]};

    logic [3:0] alu_op;
    logic [31:0] alu_a, alu_b;

    always_comb begin
        alu_op = 4'b0000;
        alu_a  = rv1;
        alu_b  = rv2;
        if (state == S_MULDIV) begin
            if (md_op == MD_MUL) begin
                alu_a = md_hi; alu_b = md_b;
            end else if (md_op == MD_DIV) begin
                alu_a = div_shifted_hi; alu_b = md_b; alu_op = 4'b1000;
            end
        end else begin
            case (opcode)
                OP_LUI:   begin alu_a = 32'b0; alu_b = imm_u; end
                OP_AUIPC: begin alu_a = pc_q;  alu_b = imm_u; end
                OP_JALR:  begin alu_b = imm_i; end
                OP_LOAD:  begin alu_b = imm_i; end
                OP_STORE: begin alu_b = imm_s; end
                OP_IMM:   begin if (!is_shift) alu_op = {1'b0, funct3}; alu_b = imm_i; end
                OP_REG:   begin if (!is_muldiv && !is_shift) alu_op = {f7b5, funct3}; end
                OP_BRANCH: alu_op = 4'b1000;
                OP_AMO:    alu_b = 32'b0;
                default: ;
            endcase
        end
    end

    wire        alu_do_sub = (alu_op == 4'b1000) || (alu_op == 4'b0010) || (alu_op == 4'b0011);
    wire [32:0] alu_ext    = {1'b0, alu_a} + {1'b0, alu_do_sub ? ~alu_b : alu_b} + {32'b0, alu_do_sub};
    wire [31:0] alu_sum    = alu_ext[31:0];
    wire        alu_carry  = alu_ext[32];
    wire        alu_lt     = (alu_a[31] != alu_b[31]) ? alu_a[31] : alu_sum[31];
    wire        alu_ltu    = !alu_carry;

    logic [31:0] alu_result;
    always_comb begin
        case (alu_op)
            4'b0000, 4'b1000: alu_result = alu_sum;
            4'b0010: alu_result = {31'b0, alu_lt};
            4'b0011: alu_result = {31'b0, alu_ltu};
            4'b0100: alu_result = alu_a ^ alu_b;
            4'b0110: alu_result = alu_a | alu_b;
            4'b0111: alu_result = alu_a & alu_b;
            default: alu_result = alu_sum;
        endcase
    end

    logic branch_taken;
    always_comb begin
        branch_taken = 1'b0;
        case (funct3)
            3'b000: branch_taken = (alu_sum == 32'b0);
            3'b001: branch_taken = (alu_sum != 32'b0);
            3'b100: branch_taken = alu_lt;
            3'b101: branch_taken = !alu_lt;
            3'b110: branch_taken = alu_ltu;
            3'b111: branch_taken = !alu_ltu;
            default: ;
        endcase
    end

    wire [31:0] pc_plus = pc_q + (ir_compressed ? 32'd2 : 32'd4);

    // ================================================================
    // Memory interface
    // ================================================================
    assign imem_addr_o = (state == S_FETCH2) ? {pc_q[31:2] + 30'd1, 2'b00}
                                             : {pc_q[31:2], 2'b00};
    assign pc_o        = pc_q;
    assign dmem_addr_o = {alu_out[31:2], 2'b00};

    wire [1:0] mem_off = alu_out[1:0];
    logic [7:0] load_byte;
    always_comb begin
        case (mem_off)
            2'b00: load_byte = dmem_rdata_i[7:0];
            2'b01: load_byte = dmem_rdata_i[15:8];
            2'b10: load_byte = dmem_rdata_i[23:16];
            default: load_byte = dmem_rdata_i[31:24];
        endcase
    end
    wire [15:0] load_half = mem_off[1] ? dmem_rdata_i[31:16] : dmem_rdata_i[15:0];

    logic [31:0] load_data;
    always_comb begin
        case (funct3)
            3'b000: load_data = {{24{load_byte[7]}}, load_byte};
            3'b001: load_data = {{16{load_half[15]}}, load_half};
            3'b010: load_data = dmem_rdata_i;
            3'b100: load_data = {24'b0, load_byte};
            3'b101: load_data = {16'b0, load_half};
            default: load_data = dmem_rdata_i;
        endcase
    end

    logic [31:0] store_data;
    always_comb begin
        case (mem_off)
            2'b00: store_data = rv2;
            2'b01: store_data = {rv2[23:0], 8'b0};
            2'b10: store_data = {rv2[15:0], 16'b0};
            default: store_data = {rv2[7:0], 24'b0};
        endcase
    end

    logic [3:0] store_strobe;
    always_comb begin
        store_strobe = 4'b0000;
        case (funct3[1:0])
            2'b00: store_strobe = 4'b0001 << mem_off;
            2'b01: store_strobe = 4'b0011 << mem_off;
            2'b10: store_strobe = 4'b1111;
            default: ;
        endcase
    end

    logic [31:0] amo_result;
    always_comb begin
        case (amo_funct5)
            5'b00001: amo_result = rv2;
            5'b00000: amo_result = dmem_rdata_i + rv2;
            5'b00100: amo_result = dmem_rdata_i ^ rv2;
            5'b01100: amo_result = dmem_rdata_i & rv2;
            5'b01000: amo_result = dmem_rdata_i | rv2;
            5'b10000: amo_result = ($signed(dmem_rdata_i) < $signed(rv2)) ? dmem_rdata_i : rv2;
            5'b10100: amo_result = ($signed(dmem_rdata_i) > $signed(rv2)) ? dmem_rdata_i : rv2;
            5'b11000: amo_result = (dmem_rdata_i < rv2) ? dmem_rdata_i : rv2;
            5'b11100: amo_result = (dmem_rdata_i > rv2) ? dmem_rdata_i : rv2;
            default:  amo_result = rv2;
        endcase
    end

    wire sc_success = is_sc && resv_valid && (resv_addr == alu_out);
    wire mem_do_write = (state == S_MEM) && (
        (opcode == OP_STORE) || is_amo_rmw || (is_sc && sc_success));

    assign dmem_wdata_o = is_amo_rmw ? amo_result : store_data;
    assign dmem_wstrb_o = mem_do_write ? ((is_amo_rmw || is_sc) ? 4'b1111 : store_strobe) : 4'b0000;

    // ================================================================
    // Mul/div iterative
    // ================================================================
    wire [32:0] mul_partial = md_lo[0] ? alu_ext : {1'b0, md_hi};
    wire [31:0] neg_hi   = ~md_hi + {31'b0, md_lo == 32'b0};
    wire [31:0] mul_final = md_hi_result ? (md_negate ? neg_hi : md_hi) : md_lo;
    wire [31:0] div_q     = div_bz ? 32'hFFFFFFFF : (div_nq ? (~md_lo + 32'd1) : md_lo);
    wire [31:0] div_r     = div_bz ? rv1 : (div_nr ? (~md_hi + 32'd1) : md_hi);
    wire [31:0] div_final = funct3[1] ? div_r : div_q;

    // ================================================================
    // Main FSM
    // ================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state      <= S_FETCH;
            pc_q       <= RESET_PC;
            halt_o     <= 1'b0;
            trap_o     <= 1'b0;
            resv_valid <= 1'b0;
        end else if (halt_o || trap_o) begin
            // frozen
        end else begin
            case (state)

            S_FETCH: begin
                if (fetch_cross) begin
                    hwbuf <= imem_rdata_i[31:16];
                    state <= S_FETCH2;
                end else begin
                    ir            <= fetch_ir;
                    ir_compressed <= fetch_compressed;
                    alu_out       <= rf_rdata;
                    state         <= S_EXEC;
                end
            end

            S_FETCH2: begin
                ir            <= fetch_ir;
                ir_compressed <= 1'b0;
                alu_out       <= rf_rdata;
                state         <= S_EXEC;
            end

            S_EXEC: begin
                case (opcode)
                    OP_LUI, OP_AUIPC: begin
                        alu_out <= alu_result;
                        state   <= S_WB;
                    end
                    OP_IMM: begin
                        if (is_shift) begin
                            md_lo <= rv1; md_cnt <= {1'b0, ir[24:20]};
                            md_op <= MD_SHIFT; state <= S_MULDIV;
                        end else begin
                            alu_out <= alu_result; state <= S_WB;
                        end
                    end
                    OP_REG: begin
                        if (is_muldiv) begin
                            md_cnt <= 6'd32;
                            if (is_mul) begin
                                md_op <= MD_MUL; md_hi <= 32'b0;
                                case (funct3[1:0])
                                    2'b00: begin md_lo<=rv2; md_b<=rv1; md_negate<=1'b0; md_hi_result<=1'b0; end
                                    2'b01: begin md_lo<=rv2[31]?(~rv2+32'd1):rv2; md_b<=rv1[31]?(~rv1+32'd1):rv1;
                                                 md_negate<=rv1[31]^rv2[31]; md_hi_result<=1'b1; end
                                    2'b10: begin md_lo<=rv2; md_b<=rv1[31]?(~rv1+32'd1):rv1;
                                                 md_negate<=rv1[31]; md_hi_result<=1'b1; end
                                    2'b11: begin md_lo<=rv2; md_b<=rv1; md_negate<=1'b0; md_hi_result<=1'b1; end
                                endcase
                            end else begin
                                md_op<=MD_DIV;
                                md_lo<=(!funct3[0]&&rv1[31])?~rv1+32'd1:rv1;
                                md_hi<=32'b0;
                                md_b<=(!funct3[0]&&rv2[31])?~rv2+32'd1:rv2;
                                div_nq<=!funct3[0]&&(rv1[31]^rv2[31])&&(rv2!=32'b0);
                                div_nr<=!funct3[0]&&rv1[31];
                                div_bz<=(rv2==32'b0);
                            end
                            state <= S_MULDIV;
                        end else if (is_shift) begin
                            md_lo<=rv1; md_cnt<={1'b0,rv2[4:0]};
                            md_op<=MD_SHIFT; state<=S_MULDIV;
                        end else begin
                            alu_out <= alu_result; state <= S_WB;
                        end
                    end
                    OP_BRANCH: begin
                        pc_q <= branch_taken ? (pc_q + imm_b) : pc_plus;
                        state <= S_FETCH;
                    end
                    OP_JAL: begin
                        alu_out <= pc_plus;
                        pc_q    <= pc_q + imm_j;
                        state   <= (rd != 5'd0) ? S_WB : S_FETCH;
                    end
                    OP_JALR: begin
                        alu_out <= pc_plus;
                        pc_q    <= {alu_result[31:1], 1'b0};
                        state   <= (rd != 5'd0) ? S_WB : S_FETCH;
                    end
                    OP_LOAD, OP_STORE, OP_AMO: begin
                        alu_out <= alu_result;
                        state   <= S_MEM;
                    end
                    OP_FENCE: begin pc_q <= pc_plus; state <= S_FETCH; end
                    OP_SYSTEM: begin
                        if (ir == 32'h00100073) halt_o <= 1'b1;
                        else trap_o <= 1'b1;
                    end
                    default: trap_o <= 1'b1;
                endcase
            end

            S_MEM: begin
                if (opcode == OP_LOAD) begin
                    alu_out <= load_data; state <= S_WB;
                end else if (opcode == OP_STORE) begin
                    if (resv_valid && resv_addr == alu_out) resv_valid <= 1'b0;
                    pc_q <= pc_plus; state <= S_FETCH;
                end else if (is_lr) begin
                    alu_out <= dmem_rdata_i; resv_addr <= alu_out;
                    resv_valid <= 1'b1; state <= S_WB;
                end else if (is_sc) begin
                    alu_out <= {31'b0, ~sc_success};
                    resv_valid <= 1'b0; state <= S_WB;
                end else begin
                    alu_out <= dmem_rdata_i;
                    if (resv_valid && resv_addr == alu_out) resv_valid <= 1'b0;
                    state <= S_WB;
                end
            end

            S_WB: begin
                if (rd != 5'd0) regs[rd] <= alu_out;
                if (opcode != OP_JAL && opcode != OP_JALR) pc_q <= pc_plus;
                state <= S_FETCH;
            end

            S_MULDIV: begin
                if (md_cnt != 6'd0) begin
                    case (md_op)
                        MD_MUL: begin md_hi<=mul_partial[32:1]; md_lo<={mul_partial[0],md_lo[31:1]}; end
                        MD_DIV: if (alu_carry) begin md_hi<=alu_sum; md_lo<={md_lo[30:0],1'b1}; end
                                else begin md_hi<=div_shifted_hi; md_lo<={md_lo[30:0],1'b0}; end
                        MD_SHIFT: if(funct3==3'b001) md_lo<={md_lo[30:0],1'b0};
                                  else if(f7b5) md_lo<={md_lo[31],md_lo[31:1]};
                                  else md_lo<={1'b0,md_lo[31:1]};
                        default:;
                    endcase
                    md_cnt <= md_cnt - 6'd1;
                end else begin
                    case (md_op)
                        MD_MUL:  alu_out <= mul_final;
                        MD_DIV:  alu_out <= div_final;
                        default: alu_out <= md_lo;
                    endcase
                    state <= S_WB;
                end
            end

            default: state <= S_FETCH;
            endcase
        end
    end
endmodule
