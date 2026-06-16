module rv32i_core #(
    parameter logic [31:0] RESET_PC = 32'h0000_0000
) (
    input  logic        clk,
    input  logic        rst_n,
    output logic [31:0] imem_addr_o,
    input  logic [63:0] imem_rdata_i,   // 64 bits = 2 consecutive words
    output logic [31:0] dmem_addr_o,
    output logic [31:0] dmem_wdata_o,
    output logic [3:0]  dmem_wstrb_o,
    input  logic [31:0] dmem_rdata_i,
    output logic [31:0] pc_o,
    output logic        trap_o,
    output logic        halt_o
);
    // ================================================================
    // Opcodes
    // ================================================================
    localparam [6:0] OP_LUI    = 7'b0110111, OP_AUIPC  = 7'b0010111,
                     OP_JAL    = 7'b1101111, OP_JALR   = 7'b1100111,
                     OP_BRANCH = 7'b1100011, OP_LOAD   = 7'b0000011,
                     OP_STORE  = 7'b0100011, OP_IMM    = 7'b0010011,
                     OP_REG    = 7'b0110011, OP_FENCE  = 7'b0001111,
                     OP_SYSTEM = 7'b1110011, OP_AMO    = 7'b0101111;

    localparam [1:0] WB_EX = 2'b00, WB_MEM = 2'b01, WB_PC4 = 2'b10;

    // ================================================================
    // Register file  (x0 hardwired to 0)
    // ================================================================
    logic [31:0] regs [1:31];

    // ================================================================
    // Pipeline registers -- dual slots (A = older, B = younger)
    // ================================================================
    // --- IF/ID ---
    logic [31:0] ifid_pc_a, ifid_instr_a;
    logic        ifid_valid_a, ifid_compressed_a;
    logic [31:0] ifid_pc_b, ifid_instr_b;
    logic        ifid_valid_b, ifid_compressed_b;

    // --- ID/EX ---
    logic [31:0] idex_pc_a, idex_rs1_val_a, idex_rs2_val_a, idex_imm_a;
    logic [4:0]  idex_rd_a, idex_rs1_a, idex_rs2_a;
    logic [3:0]  idex_alu_op_a;
    logic [2:0]  idex_funct3_a;
    logic        idex_alu_src_imm_a, idex_alu_src_pc_a;
    logic        idex_mem_read_a, idex_mem_write_a, idex_rd_we_a;
    logic        idex_is_branch_a, idex_is_jal_a, idex_is_jalr_a;
    logic        idex_is_muldiv_a, idex_is_halt_a, idex_is_trap_a;
    logic        idex_is_amo_a, idex_is_lr_a, idex_is_sc_a;
    logic [4:0]  idex_amo_funct5_a;
    logic [1:0]  idex_wb_sel_a;
    logic        idex_valid_a, idex_compressed_a;

    logic [31:0] idex_pc_b, idex_rs1_val_b, idex_rs2_val_b, idex_imm_b;
    logic [4:0]  idex_rd_b, idex_rs1_b, idex_rs2_b;
    logic [3:0]  idex_alu_op_b;
    logic [2:0]  idex_funct3_b;
    logic        idex_alu_src_imm_b, idex_alu_src_pc_b;
    logic        idex_rd_we_b;
    logic        idex_is_branch_b, idex_is_jal_b, idex_is_jalr_b;
    logic [1:0]  idex_wb_sel_b;
    logic        idex_valid_b, idex_compressed_b;

    // --- EX/MEM ---
    logic [31:0] exmem_result_a, exmem_rs2_val_a, exmem_pc4_a;
    logic [4:0]  exmem_rd_a;
    logic [2:0]  exmem_funct3_a;
    logic        exmem_rd_we_a, exmem_mem_read_a, exmem_mem_write_a;
    logic        exmem_is_amo_a, exmem_is_lr_a, exmem_is_sc_a;
    logic [4:0]  exmem_amo_funct5_a;
    logic [1:0]  exmem_wb_sel_a;
    logic        exmem_is_halt_a, exmem_is_trap_a, exmem_valid_a;

    logic [31:0] exmem_result_b, exmem_pc4_b;
    logic [4:0]  exmem_rd_b;
    logic        exmem_rd_we_b;
    logic [1:0]  exmem_wb_sel_b;
    logic        exmem_valid_b;

    // --- MEM/WB ---
    logic [31:0] memwb_rd_data_a;
    logic [4:0]  memwb_rd_a;
    logic        memwb_rd_we_a, memwb_is_halt_a, memwb_is_trap_a, memwb_valid_a;

    logic [31:0] memwb_rd_data_b;
    logic [4:0]  memwb_rd_b;
    logic        memwb_rd_we_b, memwb_valid_b;

    // ================================================================
    // Mul/Div shared state (iterative, mutually exclusive)
    // ================================================================
    logic        md_active;
    logic        md_is_mul;
    logic        md_is_shift;
    logic [1:0]  md_shift_dir;  // {f7b5, funct3[2]} -> 00=SLL, 01=SRL, 11=SRA
    logic [5:0]  md_cnt;
    logic [31:0] md_lo, md_hi, md_b;
    logic        md_nq, md_nr, md_bz;
    logic [31:0] md_raw_dividend;
    logic        md_negate, md_hi_result;

    wire [32:0] div_trial   = {md_hi, md_lo[31]} - {1'b0, md_b};
    wire [32:0] mul_partial = {1'b0, md_hi} + {1'b0, md_b};
    wire        md_ready    = md_active && (md_cnt == 6'd0);

    // ================================================================
    // A extension -- LR/SC reservation set
    // ================================================================
    logic [31:0] resv_addr;
    logic        resv_valid;

    // ================================================================
    // RV32C Decompressor
    // ================================================================
    function automatic [31:0] decompress(input [15:0] ci);
        logic [31:0] out;
        logic [4:0]  rd_c, rs1_c, rs2_c;
        logic [4:0]  rd_f, rs2_f;
        logic [4:0]  shamt;
        logic [5:0]  imm6;
        logic [6:0]  off7;
        logic [7:0]  off8;
        logic [9:0]  nzuimm10;
        logic [11:0] imm12;
        logic [10:0] joff11;
        logic [12:0] bimm13;
        logic [20:0] jimm21;
        logic [8:0]  off9;

        out = 32'h0000_0000;

        case (ci[1:0])
        2'b00: begin
            rd_c  = {2'b01, ci[4:2]};
            rs1_c = {2'b01, ci[9:7]};
            rs2_c = {2'b01, ci[4:2]};
            case (ci[15:13])
            3'b000: begin
                nzuimm10 = {ci[10:7], ci[12:11], ci[5], ci[6], 2'b00};
                if (nzuimm10 != 10'd0) begin
                    imm12 = {2'b0, nzuimm10};
                    out = {imm12, 5'd2, 3'b000, rd_c, 7'b0010011};
                end
            end
            3'b010: begin
                off7 = {ci[5], ci[12:10], ci[6], 2'b00};
                out = {5'b0, off7, rs1_c, 3'b010, rd_c, 7'b0000011};
            end
            3'b110: begin
                off7 = {ci[5], ci[12:10], ci[6], 2'b00};
                out = {5'b0, off7[6:5], rs2_c, rs1_c, 3'b010, off7[4:0], 7'b0100011};
            end
            default: ;
            endcase
        end

        2'b01: begin
            rd_c  = {2'b01, ci[9:7]};
            rs2_c = {2'b01, ci[4:2]};
            rd_f  = ci[11:7];
            imm6  = {ci[12], ci[6:2]};

            case (ci[15:13])
            3'b000: begin
                imm12 = {{6{imm6[5]}}, imm6};
                out = {imm12, rd_f, 3'b000, rd_f, 7'b0010011};
            end
            3'b001: begin
                joff11 = {ci[12], ci[8], ci[10:9], ci[6], ci[7], ci[2], ci[11], ci[5:3]};
                jimm21 = {{9{joff11[10]}}, joff11, 1'b0};
                out = {jimm21[20], jimm21[10:1], jimm21[11], jimm21[19:12], 5'd1, 7'b1101111};
            end
            3'b010: begin
                imm12 = {{6{imm6[5]}}, imm6};
                out = {imm12, 5'd0, 3'b000, rd_f, 7'b0010011};
            end
            3'b011: begin
                if (rd_f == 5'd2) begin
                    nzuimm10 = {ci[12], ci[4:3], ci[5], ci[2], ci[6], 4'b0000};
                    imm12 = {{2{nzuimm10[9]}}, nzuimm10};
                    out = {imm12, 5'd2, 3'b000, 5'd2, 7'b0010011};
                end else if (rd_f != 5'd0) begin
                    out = {{14{imm6[5]}}, imm6, 12'b0};
                    out[11:7] = rd_f;
                    out[6:0]  = 7'b0110111;
                end
            end
            3'b100: begin
                case (ci[11:10])
                2'b00: begin
                    shamt = ci[6:2];
                    out = {7'b0000000, shamt, rd_c, 3'b101, rd_c, 7'b0010011};
                end
                2'b01: begin
                    shamt = ci[6:2];
                    out = {7'b0100000, shamt, rd_c, 3'b101, rd_c, 7'b0010011};
                end
                2'b10: begin
                    imm12 = {{6{imm6[5]}}, imm6};
                    out = {imm12, rd_c, 3'b111, rd_c, 7'b0010011};
                end
                2'b11: begin
                    case ({ci[12], ci[6:5]})
                    3'b000: out = {7'b0100000, rs2_c, rd_c, 3'b000, rd_c, 7'b0110011};
                    3'b001: out = {7'b0000000, rs2_c, rd_c, 3'b100, rd_c, 7'b0110011};
                    3'b010: out = {7'b0000000, rs2_c, rd_c, 3'b110, rd_c, 7'b0110011};
                    3'b011: out = {7'b0000000, rs2_c, rd_c, 3'b111, rd_c, 7'b0110011};
                    default: ;
                    endcase
                end
                endcase
            end
            3'b101: begin
                joff11 = {ci[12], ci[8], ci[10:9], ci[6], ci[7], ci[2], ci[11], ci[5:3]};
                jimm21 = {{9{joff11[10]}}, joff11, 1'b0};
                out = {jimm21[20], jimm21[10:1], jimm21[11], jimm21[19:12], 5'd0, 7'b1101111};
            end
            3'b110: begin
                off9 = {ci[12], ci[6:5], ci[2], ci[11:10], ci[4:3], 1'b0};
                bimm13 = {{4{off9[8]}}, off9};
                out = {bimm13[12], bimm13[10:5], 5'd0, rd_c, 3'b000, bimm13[4:1], bimm13[11], 7'b1100011};
            end
            3'b111: begin
                off9 = {ci[12], ci[6:5], ci[2], ci[11:10], ci[4:3], 1'b0};
                bimm13 = {{4{off9[8]}}, off9};
                out = {bimm13[12], bimm13[10:5], 5'd0, rd_c, 3'b001, bimm13[4:1], bimm13[11], 7'b1100011};
            end
            endcase
        end

        2'b10: begin
            rd_f  = ci[11:7];
            rs2_f = ci[6:2];
            case (ci[15:13])
            3'b000: begin
                shamt = ci[6:2];
                if (rd_f != 5'd0)
                    out = {7'b0000000, shamt, rd_f, 3'b001, rd_f, 7'b0010011};
            end
            3'b010: begin
                off8 = {ci[3:2], ci[12], ci[6:4], 2'b00};
                if (rd_f != 5'd0)
                    out = {4'b0, off8, 5'd2, 3'b010, rd_f, 7'b0000011};
            end
            3'b100: begin
                if (ci[12] == 1'b0) begin
                    if (rs2_f == 5'd0) begin
                        if (rd_f != 5'd0)
                            out = {12'b0, rd_f, 3'b000, 5'd0, 7'b1100111};
                    end else begin
                        out = {7'b0000000, rs2_f, 5'd0, 3'b000, rd_f, 7'b0110011};
                    end
                end else begin
                    if (rs2_f == 5'd0) begin
                        if (rd_f == 5'd0)
                            out = 32'h00100073;
                        else
                            out = {12'b0, rd_f, 3'b000, 5'd1, 7'b1100111};
                    end else begin
                        out = {7'b0000000, rs2_f, rd_f, 3'b000, rd_f, 7'b0110011};
                    end
                end
            end
            3'b110: begin
                off8 = {ci[8:7], ci[12:9], 2'b00};
                out = {4'b0, off8[7:5], rs2_f, 5'd2, 3'b010, off8[4:0], 7'b0100011};
            end
            default: ;
            endcase
        end

        default: ;
        endcase

        decompress = out;
    endfunction

    // ================================================================
    // IF stage -- Dual fetch from 64-bit window
    // ================================================================
    logic [31:0] pc_q;

    assign imem_addr_o = {pc_q[31:2], 2'b00};
    assign pc_o        = pc_q;

    // Pre-extract halfwords and words from the 64-bit window
    wire [15:0] hw_at_0 = imem_rdata_i[15:0];
    wire [15:0] hw_at_2 = imem_rdata_i[31:16];
    wire [15:0] hw_at_4 = imem_rdata_i[47:32];
    wire [15:0] hw_at_6 = imem_rdata_i[63:48];

    wire [31:0] word_at_0 = imem_rdata_i[31:0];
    wire [31:0] word_at_2 = imem_rdata_i[47:16];
    wire [31:0] word_at_4 = imem_rdata_i[63:32];

    // Instruction A: halfword and word at PC's position in window
    wire [15:0] if_hw_a = pc_q[1] ? hw_at_2 : hw_at_0;
    wire [31:0] if_word_a = pc_q[1] ? word_at_2 : word_at_0;

    // Decode instruction A (always valid since pc is always 2-byte aligned and fits in window)
    logic [31:0] if_instr_a;
    logic        if_compressed_a;
    logic [31:0] if_next_pc;  // PC of instruction B

    // Decode instruction B
    logic [31:0] if_instr_b;
    logic        if_compressed_b;
    logic        if_valid_b;

    // Instruction A is always fetchable (PC is 2-byte aligned, window is 8 bytes)
    wire         if_valid_a = 1'b1;

    always_comb begin
        if_instr_a      = 32'h0000_0013;
        if_compressed_a = 1'b0;
        if_next_pc      = pc_q;
        if_instr_b      = 32'h0000_0013;
        if_compressed_b = 1'b0;
        if_valid_b      = 1'b0;

        // Instruction A decode
        if (if_hw_a[1:0] != 2'b11) begin
            if_instr_a = decompress(if_hw_a);
            if_compressed_a = 1'b1;
            if_next_pc = pc_q + 32'd2;
        end else begin
            if_instr_a = if_word_a;
            if_compressed_a = 1'b0;
            if_next_pc = pc_q + 32'd4;
        end

        // Instruction B decode (depends on where A ends)
        // pc_q[1]=0, A compressed  -> B at offset 2 in window
        // pc_q[1]=0, A 32-bit      -> B at offset 4 in window
        // pc_q[1]=1, A compressed  -> B at offset 4 in window
        // pc_q[1]=1, A 32-bit      -> B at offset 6 in window
        if (!pc_q[1] && if_hw_a[1:0] != 2'b11) begin
            // B at offset 2
            if (hw_at_2[1:0] != 2'b11) begin
                if_instr_b = decompress(hw_at_2);
                if_compressed_b = 1'b1;
                if_valid_b = 1'b1;
            end else begin
                if_instr_b = word_at_2;
                if_compressed_b = 1'b0;
                if_valid_b = 1'b1;
            end
        end else if ((!pc_q[1] && if_hw_a[1:0] == 2'b11) ||
                     ( pc_q[1] && if_hw_a[1:0] != 2'b11)) begin
            // B at offset 4
            if (hw_at_4[1:0] != 2'b11) begin
                if_instr_b = decompress(hw_at_4);
                if_compressed_b = 1'b1;
                if_valid_b = 1'b1;
            end else begin
                if_instr_b = word_at_4;
                if_compressed_b = 1'b0;
                if_valid_b = 1'b1;
            end
        end else begin
            // B at offset 6 -- only compressed fits
            if (hw_at_6[1:0] != 2'b11) begin
                if_instr_b = decompress(hw_at_6);
                if_compressed_b = 1'b1;
                if_valid_b = 1'b1;
            end
            // else B doesn't fit, if_valid_b stays 0
        end
    end

    wire [31:0] if_pc_after_b = if_next_pc + (if_compressed_b ? 32'd2 : 32'd4);

    // ================================================================
    // Held instruction buffer -- for when slot B can't dual-issue
    // ================================================================
    logic [31:0] held_pc, held_instr;
    logic        held_valid, held_compressed;

    // ================================================================
    // Decode helpers for a generic instruction
    // ================================================================

    // Slot A decode
    wire [6:0] id_opcode_a = ifid_instr_a[6:0];
    wire [4:0] id_rd_a     = ifid_instr_a[11:7];
    wire [2:0] id_funct3_a = ifid_instr_a[14:12];
    wire       id_f7b5_a   = ifid_instr_a[30];
    wire [6:0] id_funct7_a = ifid_instr_a[31:25];

    logic [4:0] id_rs1_a, id_rs2_a;
    always_comb begin
        id_rs1_a = ifid_instr_a[19:15];
        id_rs2_a = ifid_instr_a[24:20];
        case (id_opcode_a)
            OP_LUI, OP_AUIPC, OP_JAL: begin id_rs1_a = 5'd0; id_rs2_a = 5'd0; end
            OP_JALR, OP_LOAD, OP_IMM:  id_rs2_a = 5'd0;
            default: ;
        endcase
    end

    wire [31:0] imm_i_a = {{20{ifid_instr_a[31]}}, ifid_instr_a[31:20]};
    wire [31:0] imm_s_a = {{20{ifid_instr_a[31]}}, ifid_instr_a[31:25], ifid_instr_a[11:7]};
    wire [31:0] imm_b_a = {{19{ifid_instr_a[31]}}, ifid_instr_a[31], ifid_instr_a[7],
                            ifid_instr_a[30:25], ifid_instr_a[11:8], 1'b0};
    wire [31:0] imm_u_a = {ifid_instr_a[31:12], 12'b0};
    wire [31:0] imm_j_a = {{11{ifid_instr_a[31]}}, ifid_instr_a[31], ifid_instr_a[19:12],
                            ifid_instr_a[20], ifid_instr_a[30:21], 1'b0};

    logic [31:0] id_imm_a;
    always_comb begin
        case (id_opcode_a)
            OP_LUI, OP_AUIPC:         id_imm_a = imm_u_a;
            OP_JAL:                    id_imm_a = imm_j_a;
            OP_BRANCH:                 id_imm_a = imm_b_a;
            OP_STORE:                  id_imm_a = imm_s_a;
            OP_AMO:                    id_imm_a = 32'b0;
            default:                   id_imm_a = imm_i_a;
        endcase
    end

    logic [3:0]  id_alu_op_a;
    logic        id_alu_src_imm_a, id_alu_src_pc_a;
    logic        id_mem_read_a, id_mem_write_a, id_rd_we_a;
    logic        id_is_branch_a, id_is_jal_a, id_is_jalr_a;
    logic        id_is_muldiv_a, id_is_halt_a, id_is_trap_a;
    logic        id_is_amo_a, id_is_lr_a, id_is_sc_a;
    logic [4:0]  id_amo_funct5_a;
    logic [1:0]  id_wb_sel_a;

    always_comb begin
        id_alu_op_a      = 4'b0000;
        id_alu_src_imm_a = 1'b0;
        id_alu_src_pc_a  = 1'b0;
        id_mem_read_a    = 1'b0;
        id_mem_write_a   = 1'b0;
        id_rd_we_a       = 1'b0;
        id_is_branch_a   = 1'b0;
        id_is_jal_a      = 1'b0;
        id_is_jalr_a     = 1'b0;
        id_is_muldiv_a   = 1'b0;
        id_is_halt_a     = 1'b0;
        id_is_trap_a     = 1'b0;
        id_is_amo_a      = 1'b0;
        id_is_lr_a       = 1'b0;
        id_is_sc_a       = 1'b0;
        id_amo_funct5_a  = 5'b0;
        id_wb_sel_a      = WB_EX;

        case (id_opcode_a)
            OP_LUI:    begin id_alu_src_imm_a = 1'b1; id_rd_we_a = 1'b1; end
            OP_AUIPC:  begin id_alu_src_imm_a = 1'b1; id_alu_src_pc_a = 1'b1; id_rd_we_a = 1'b1; end
            OP_JAL:    begin id_is_jal_a = 1'b1; id_rd_we_a = 1'b1; id_wb_sel_a = WB_PC4; end
            OP_JALR:   begin id_alu_src_imm_a = 1'b1; id_is_jalr_a = 1'b1; id_rd_we_a = 1'b1; id_wb_sel_a = WB_PC4; end
            OP_BRANCH: begin id_alu_op_a = 4'b1000; id_is_branch_a = 1'b1; end
            OP_LOAD:   begin id_alu_src_imm_a = 1'b1; id_mem_read_a = 1'b1; id_rd_we_a = 1'b1; id_wb_sel_a = WB_MEM; end
            OP_STORE:  begin id_alu_src_imm_a = 1'b1; id_mem_write_a = 1'b1; end
            OP_IMM:    begin
                id_alu_op_a = (id_funct3_a == 3'b101) ? {id_f7b5_a, id_funct3_a} : {1'b0, id_funct3_a};
                id_alu_src_imm_a = 1'b1; id_rd_we_a = 1'b1;
            end
            OP_REG: begin
                if (id_funct7_a == 7'b0000001) begin
                    id_is_muldiv_a = 1'b1; id_rd_we_a = 1'b1;
                end else begin
                    id_alu_op_a = {id_f7b5_a, id_funct3_a}; id_rd_we_a = 1'b1;
                end
            end
            OP_AMO: begin
                id_rd_we_a = 1'b1; id_mem_read_a = 1'b1; id_alu_src_imm_a = 1'b1; id_wb_sel_a = WB_MEM;
                id_amo_funct5_a = ifid_instr_a[31:27];
                if (ifid_instr_a[31:27] == 5'b00010) begin
                    id_is_lr_a = 1'b1;
                end else if (ifid_instr_a[31:27] == 5'b00011) begin
                    id_is_sc_a = 1'b1; id_mem_write_a = 1'b1; id_wb_sel_a = WB_EX;
                end else begin
                    id_is_amo_a = 1'b1; id_mem_write_a = 1'b1;
                end
            end
            OP_FENCE: ;
            OP_SYSTEM: begin
                if (ifid_instr_a == 32'h00100073) id_is_halt_a = 1'b1;
                else id_is_trap_a = 1'b1;
            end
            default: id_is_trap_a = 1'b1;
        endcase
    end

    // Slot B decode
    wire [6:0] id_opcode_b = ifid_instr_b[6:0];
    wire [4:0] id_rd_b     = ifid_instr_b[11:7];
    wire [2:0] id_funct3_b = ifid_instr_b[14:12];
    wire       id_f7b5_b   = ifid_instr_b[30];
    wire [6:0] id_funct7_b = ifid_instr_b[31:25];

    logic [4:0] id_rs1_b, id_rs2_b;
    always_comb begin
        id_rs1_b = ifid_instr_b[19:15];
        id_rs2_b = ifid_instr_b[24:20];
        case (id_opcode_b)
            OP_LUI, OP_AUIPC, OP_JAL: begin id_rs1_b = 5'd0; id_rs2_b = 5'd0; end
            OP_JALR, OP_LOAD, OP_IMM:  id_rs2_b = 5'd0;
            default: ;
        endcase
    end

    wire [31:0] imm_i_b = {{20{ifid_instr_b[31]}}, ifid_instr_b[31:20]};
    wire [31:0] imm_s_b = {{20{ifid_instr_b[31]}}, ifid_instr_b[31:25], ifid_instr_b[11:7]};
    wire [31:0] imm_b_b = {{19{ifid_instr_b[31]}}, ifid_instr_b[31], ifid_instr_b[7],
                            ifid_instr_b[30:25], ifid_instr_b[11:8], 1'b0};
    wire [31:0] imm_u_b = {ifid_instr_b[31:12], 12'b0};
    wire [31:0] imm_j_b = {{11{ifid_instr_b[31]}}, ifid_instr_b[31], ifid_instr_b[19:12],
                            ifid_instr_b[20], ifid_instr_b[30:21], 1'b0};

    logic [31:0] id_imm_b;
    always_comb begin
        case (id_opcode_b)
            OP_LUI, OP_AUIPC:         id_imm_b = imm_u_b;
            OP_JAL:                    id_imm_b = imm_j_b;
            OP_BRANCH:                 id_imm_b = imm_b_b;
            OP_STORE:                  id_imm_b = imm_s_b;
            OP_AMO:                    id_imm_b = 32'b0;
            default:                   id_imm_b = imm_i_b;
        endcase
    end

    logic [3:0]  id_alu_op_b;
    logic        id_alu_src_imm_b, id_alu_src_pc_b;
    logic        id_mem_read_b, id_mem_write_b, id_rd_we_b;
    logic        id_is_branch_b, id_is_jal_b, id_is_jalr_b;
    logic        id_is_muldiv_b, id_is_halt_b, id_is_trap_b;
    logic        id_is_amo_b, id_is_lr_b, id_is_sc_b;
    logic [1:0]  id_wb_sel_b;

    always_comb begin
        id_alu_op_b      = 4'b0000;
        id_alu_src_imm_b = 1'b0;
        id_alu_src_pc_b  = 1'b0;
        id_mem_read_b    = 1'b0;
        id_mem_write_b   = 1'b0;
        id_rd_we_b       = 1'b0;
        id_is_branch_b   = 1'b0;
        id_is_jal_b      = 1'b0;
        id_is_jalr_b     = 1'b0;
        id_is_muldiv_b   = 1'b0;
        id_is_halt_b     = 1'b0;
        id_is_trap_b     = 1'b0;
        id_is_amo_b      = 1'b0;
        id_is_lr_b       = 1'b0;
        id_is_sc_b       = 1'b0;
        id_wb_sel_b      = WB_EX;

        case (id_opcode_b)
            OP_LUI:    begin id_alu_src_imm_b = 1'b1; id_rd_we_b = 1'b1; end
            OP_AUIPC:  begin id_alu_src_imm_b = 1'b1; id_alu_src_pc_b = 1'b1; id_rd_we_b = 1'b1; end
            OP_JAL:    begin id_is_jal_b = 1'b1; id_rd_we_b = 1'b1; id_wb_sel_b = WB_PC4; end
            OP_JALR:   begin id_alu_src_imm_b = 1'b1; id_is_jalr_b = 1'b1; id_rd_we_b = 1'b1; id_wb_sel_b = WB_PC4; end
            OP_BRANCH: begin id_alu_op_b = 4'b1000; id_is_branch_b = 1'b1; end
            OP_LOAD:   begin id_alu_src_imm_b = 1'b1; id_mem_read_b = 1'b1; id_rd_we_b = 1'b1; id_wb_sel_b = WB_MEM; end
            OP_STORE:  begin id_alu_src_imm_b = 1'b1; id_mem_write_b = 1'b1; end
            OP_IMM: begin
                id_alu_op_b = (id_funct3_b == 3'b101) ? {id_f7b5_b, id_funct3_b} : {1'b0, id_funct3_b};
                id_alu_src_imm_b = 1'b1; id_rd_we_b = 1'b1;
            end
            OP_REG: begin
                if (id_funct7_b == 7'b0000001) begin
                    id_is_muldiv_b = 1'b1; id_rd_we_b = 1'b1;
                end else begin
                    id_alu_op_b = {id_f7b5_b, id_funct3_b}; id_rd_we_b = 1'b1;
                end
            end
            OP_AMO: begin
                id_rd_we_b = 1'b1; id_mem_read_b = 1'b1; id_alu_src_imm_b = 1'b1; id_wb_sel_b = WB_MEM;
                if (ifid_instr_b[31:27] == 5'b00010) id_is_lr_b = 1'b1;
                else if (ifid_instr_b[31:27] == 5'b00011) begin
                    id_is_sc_b = 1'b1; id_mem_write_b = 1'b1; id_wb_sel_b = WB_EX;
                end else begin
                    id_is_amo_b = 1'b1; id_mem_write_b = 1'b1;
                end
            end
            OP_FENCE: ;
            OP_SYSTEM: begin
                if (ifid_instr_b == 32'h00100073) id_is_halt_b = 1'b1;
                else id_is_trap_b = 1'b1;
            end
            default: id_is_trap_b = 1'b1;
        endcase
    end

    // ================================================================
    // Dual-issue feasibility
    // ================================================================
    wire b_is_shift = (id_opcode_b == OP_IMM || id_opcode_b == OP_REG) &&
                      (id_funct3_b == 3'b001 || id_funct3_b == 3'b101);
    wire b_structural = id_mem_read_b || id_mem_write_b || id_is_amo_b || id_is_lr_b || id_is_sc_b ||
                        id_is_muldiv_b || id_is_halt_b || id_is_trap_b || b_is_shift;
    wire b_raw = id_rd_we_a && (id_rd_a != 5'd0) &&
                 ((id_rs1_b == id_rd_a) || (id_rs2_b == id_rd_a));
    wire b_waw = id_rd_we_a && id_rd_we_b && (id_rd_a != 5'd0) && (id_rd_a == id_rd_b);
    wire a_is_redirect = id_is_jal_a || id_is_jalr_a || id_is_branch_a;

    wire a_is_shift = (id_opcode_a == OP_IMM || id_opcode_a == OP_REG) &&
                      (id_funct3_a == 3'b001 || id_funct3_a == 3'b101);
    wire can_dual_issue = ifid_valid_b && !b_structural && !b_raw && !b_waw && !a_is_redirect &&
                          !id_is_halt_a && !id_is_trap_a && !id_is_muldiv_a && !a_is_shift;

    // ================================================================
    // Register file read with WB write-through (4 read ports)
    // B writes after A (B more recent), so check B first
    // ================================================================
    wire [31:0] rf_rs1_a = (id_rs1_a == 5'd0) ? 32'b0 : regs[id_rs1_a];
    wire [31:0] rf_rs2_a = (id_rs2_a == 5'd0) ? 32'b0 : regs[id_rs2_a];
    wire [31:0] rf_rs1_b = (id_rs1_b == 5'd0) ? 32'b0 : regs[id_rs1_b];
    wire [31:0] rf_rs2_b = (id_rs2_b == 5'd0) ? 32'b0 : regs[id_rs2_b];

    wire wt_b_rs1_a = memwb_valid_b && memwb_rd_we_b && (memwb_rd_b != 5'd0) && (memwb_rd_b == id_rs1_a);
    wire wt_a_rs1_a = memwb_valid_a && memwb_rd_we_a && (memwb_rd_a != 5'd0) && (memwb_rd_a == id_rs1_a) && !wt_b_rs1_a;
    wire wt_b_rs2_a = memwb_valid_b && memwb_rd_we_b && (memwb_rd_b != 5'd0) && (memwb_rd_b == id_rs2_a);
    wire wt_a_rs2_a = memwb_valid_a && memwb_rd_we_a && (memwb_rd_a != 5'd0) && (memwb_rd_a == id_rs2_a) && !wt_b_rs2_a;

    wire wt_b_rs1_b = memwb_valid_b && memwb_rd_we_b && (memwb_rd_b != 5'd0) && (memwb_rd_b == id_rs1_b);
    wire wt_a_rs1_b = memwb_valid_a && memwb_rd_we_a && (memwb_rd_a != 5'd0) && (memwb_rd_a == id_rs1_b) && !wt_b_rs1_b;
    wire wt_b_rs2_b = memwb_valid_b && memwb_rd_we_b && (memwb_rd_b != 5'd0) && (memwb_rd_b == id_rs2_b);
    wire wt_a_rs2_b = memwb_valid_a && memwb_rd_we_a && (memwb_rd_a != 5'd0) && (memwb_rd_a == id_rs2_b) && !wt_b_rs2_b;

    wire [31:0] id_rs1_val_a = wt_b_rs1_a ? memwb_rd_data_b : (wt_a_rs1_a ? memwb_rd_data_a : rf_rs1_a);
    wire [31:0] id_rs2_val_a = wt_b_rs2_a ? memwb_rd_data_b : (wt_a_rs2_a ? memwb_rd_data_a : rf_rs2_a);
    wire [31:0] id_rs1_val_b = wt_b_rs1_b ? memwb_rd_data_b : (wt_a_rs1_b ? memwb_rd_data_a : rf_rs1_b);
    wire [31:0] id_rs2_val_b = wt_b_rs2_b ? memwb_rd_data_b : (wt_a_rs2_b ? memwb_rd_data_a : rf_rs2_b);

    // ================================================================
    // Hazard detection (load-use)
    // ================================================================
    wire id_uses_rs1_a = (id_opcode_a == OP_REG || id_opcode_a == OP_IMM || id_opcode_a == OP_LOAD ||
                          id_opcode_a == OP_STORE || id_opcode_a == OP_BRANCH || id_opcode_a == OP_JALR ||
                          id_opcode_a == OP_AMO);
    wire id_uses_rs2_a = (id_opcode_a == OP_REG || id_opcode_a == OP_STORE || id_opcode_a == OP_BRANCH ||
                          id_opcode_a == OP_AMO);
    wire id_uses_rs1_b_w = (id_opcode_b == OP_REG || id_opcode_b == OP_IMM || id_opcode_b == OP_LOAD ||
                            id_opcode_b == OP_STORE || id_opcode_b == OP_BRANCH || id_opcode_b == OP_JALR ||
                            id_opcode_b == OP_AMO);
    wire id_uses_rs2_b_w = (id_opcode_b == OP_REG || id_opcode_b == OP_STORE || id_opcode_b == OP_BRANCH ||
                            id_opcode_b == OP_AMO);

    wire load_use_a = idex_valid_a && idex_mem_read_a && (idex_rd_a != 5'd0) && ifid_valid_a &&
                      ((id_uses_rs1_a && idex_rd_a == id_rs1_a) ||
                       (id_uses_rs2_a && idex_rd_a == id_rs2_a));

    wire load_use_b_from_exa = idex_valid_a && idex_mem_read_a && (idex_rd_a != 5'd0) && ifid_valid_b && can_dual_issue &&
                               ((id_uses_rs1_b_w && idex_rd_a == id_rs1_b) ||
                                (id_uses_rs2_b_w && idex_rd_a == id_rs2_b));

    wire load_use = load_use_a || load_use_b_from_exa;

    // ================================================================
    // Forwarding (4 sources: exmem_b > exmem_a > memwb_b > memwb_a)
    // ================================================================
    wire [31:0] exmem_fwd_a = (exmem_wb_sel_a == WB_PC4) ? exmem_pc4_a : exmem_result_a;
    wire [31:0] exmem_fwd_b = (exmem_wb_sel_b == WB_PC4) ? exmem_pc4_b : exmem_result_b;

    // EX slot A rs1
    wire fwd_emb_rs1_a = exmem_valid_b && exmem_rd_we_b && (exmem_rd_b != 5'd0) && (exmem_rd_b == idex_rs1_a);
    wire fwd_ema_rs1_a = exmem_valid_a && exmem_rd_we_a && (exmem_rd_a != 5'd0) && (exmem_rd_a == idex_rs1_a) && !fwd_emb_rs1_a;
    wire fwd_mwb_rs1_a = memwb_valid_b && memwb_rd_we_b && (memwb_rd_b != 5'd0) && (memwb_rd_b == idex_rs1_a) && !fwd_emb_rs1_a && !fwd_ema_rs1_a;
    wire fwd_mwa_rs1_a = memwb_valid_a && memwb_rd_we_a && (memwb_rd_a != 5'd0) && (memwb_rd_a == idex_rs1_a) && !fwd_emb_rs1_a && !fwd_ema_rs1_a && !fwd_mwb_rs1_a;

    wire [31:0] fwd_rs1_a = fwd_emb_rs1_a ? exmem_fwd_b :
                             fwd_ema_rs1_a ? exmem_fwd_a :
                             fwd_mwb_rs1_a ? memwb_rd_data_b :
                             fwd_mwa_rs1_a ? memwb_rd_data_a : idex_rs1_val_a;

    // EX slot A rs2
    wire fwd_emb_rs2_a = exmem_valid_b && exmem_rd_we_b && (exmem_rd_b != 5'd0) && (exmem_rd_b == idex_rs2_a);
    wire fwd_ema_rs2_a = exmem_valid_a && exmem_rd_we_a && (exmem_rd_a != 5'd0) && (exmem_rd_a == idex_rs2_a) && !fwd_emb_rs2_a;
    wire fwd_mwb_rs2_a = memwb_valid_b && memwb_rd_we_b && (memwb_rd_b != 5'd0) && (memwb_rd_b == idex_rs2_a) && !fwd_emb_rs2_a && !fwd_ema_rs2_a;
    wire fwd_mwa_rs2_a = memwb_valid_a && memwb_rd_we_a && (memwb_rd_a != 5'd0) && (memwb_rd_a == idex_rs2_a) && !fwd_emb_rs2_a && !fwd_ema_rs2_a && !fwd_mwb_rs2_a;

    wire [31:0] fwd_rs2_a = fwd_emb_rs2_a ? exmem_fwd_b :
                             fwd_ema_rs2_a ? exmem_fwd_a :
                             fwd_mwb_rs2_a ? memwb_rd_data_b :
                             fwd_mwa_rs2_a ? memwb_rd_data_a : idex_rs2_val_a;

    // EX slot B rs1
    wire fwd_emb_rs1_b = exmem_valid_b && exmem_rd_we_b && (exmem_rd_b != 5'd0) && (exmem_rd_b == idex_rs1_b);
    wire fwd_ema_rs1_b = exmem_valid_a && exmem_rd_we_a && (exmem_rd_a != 5'd0) && (exmem_rd_a == idex_rs1_b) && !fwd_emb_rs1_b;
    wire fwd_mwb_rs1_b = memwb_valid_b && memwb_rd_we_b && (memwb_rd_b != 5'd0) && (memwb_rd_b == idex_rs1_b) && !fwd_emb_rs1_b && !fwd_ema_rs1_b;
    wire fwd_mwa_rs1_b = memwb_valid_a && memwb_rd_we_a && (memwb_rd_a != 5'd0) && (memwb_rd_a == idex_rs1_b) && !fwd_emb_rs1_b && !fwd_ema_rs1_b && !fwd_mwb_rs1_b;

    wire [31:0] fwd_rs1_b = fwd_emb_rs1_b ? exmem_fwd_b :
                             fwd_ema_rs1_b ? exmem_fwd_a :
                             fwd_mwb_rs1_b ? memwb_rd_data_b :
                             fwd_mwa_rs1_b ? memwb_rd_data_a : idex_rs1_val_b;

    // EX slot B rs2
    wire fwd_emb_rs2_b = exmem_valid_b && exmem_rd_we_b && (exmem_rd_b != 5'd0) && (exmem_rd_b == idex_rs2_b);
    wire fwd_ema_rs2_b = exmem_valid_a && exmem_rd_we_a && (exmem_rd_a != 5'd0) && (exmem_rd_a == idex_rs2_b) && !fwd_emb_rs2_b;
    wire fwd_mwb_rs2_b = memwb_valid_b && memwb_rd_we_b && (memwb_rd_b != 5'd0) && (memwb_rd_b == idex_rs2_b) && !fwd_emb_rs2_b && !fwd_ema_rs2_b;
    wire fwd_mwa_rs2_b = memwb_valid_a && memwb_rd_we_a && (memwb_rd_a != 5'd0) && (memwb_rd_a == idex_rs2_b) && !fwd_emb_rs2_b && !fwd_ema_rs2_b && !fwd_mwb_rs2_b;

    wire [31:0] fwd_rs2_b = fwd_emb_rs2_b ? exmem_fwd_b :
                             fwd_ema_rs2_b ? exmem_fwd_a :
                             fwd_mwb_rs2_b ? memwb_rd_data_b :
                             fwd_mwa_rs2_b ? memwb_rd_data_a : idex_rs2_val_b;

    // ================================================================
    // EX stage -- ALU A (full: ALU + branch + mul/div)
    // ================================================================
    wire [31:0] alu_a_a = idex_alu_src_pc_a ? idex_pc_a : fwd_rs1_a;
    wire [31:0] alu_b_a = idex_alu_src_imm_a ? idex_imm_a : fwd_rs2_a;

    wire        alu_do_sub_a = (idex_alu_op_a == 4'b1000) || (idex_alu_op_a == 4'b0010) || (idex_alu_op_a == 4'b0011);
    wire [32:0] alu_ext_a = {1'b0, alu_a_a} + {1'b0, alu_do_sub_a ? ~alu_b_a : alu_b_a} + {32'b0, alu_do_sub_a};
    wire [31:0] alu_sum_a   = alu_ext_a[31:0];
    wire        alu_carry_a = alu_ext_a[32];
    wire        alu_lt_a    = (alu_a_a[31] != alu_b_a[31]) ? alu_a_a[31] : alu_sum_a[31];
    wire        alu_ltu_a   = !alu_carry_a;

    logic [31:0] alu_result_a;
    always_comb begin
        case (idex_alu_op_a)
            4'b0000, 4'b1000: alu_result_a = alu_sum_a;
            4'b0010:          alu_result_a = {31'b0, alu_lt_a};
            4'b0011:          alu_result_a = {31'b0, alu_ltu_a};
            4'b0100:          alu_result_a = alu_a_a ^ alu_b_a;
            4'b0110:          alu_result_a = alu_a_a | alu_b_a;
            4'b0111:          alu_result_a = alu_a_a & alu_b_a;
            default:          alu_result_a = alu_sum_a;
        endcase
    end

    logic branch_taken_a;
    always_comb begin
        branch_taken_a = 1'b0;
        if (idex_is_branch_a) begin
            case (idex_funct3_a)
                3'b000:  branch_taken_a = (alu_sum_a == 32'b0);
                3'b001:  branch_taken_a = (alu_sum_a != 32'b0);
                3'b100:  branch_taken_a = alu_lt_a;
                3'b101:  branch_taken_a = !alu_lt_a;
                3'b110:  branch_taken_a = alu_ltu_a;
                3'b111:  branch_taken_a = !alu_ltu_a;
                default: ;
            endcase
        end
    end

    wire [31:0] branch_target_a = idex_pc_a + idex_imm_a;
    wire [31:0] ex_pc4_a = idex_pc_a + (idex_compressed_a ? 32'd2 : 32'd4);

    wire redirect_a = idex_valid_a && !idex_is_trap_a && !idex_is_halt_a &&
                      (idex_is_jal_a || idex_is_jalr_a || branch_taken_a);
    wire [31:0] redirect_target_a = idex_is_jalr_a ? {alu_result_a[31:1], 1'b0} : branch_target_a;

    // Shift detection -- iterative shifts reuse md_* state machine
    wire idex_is_shift_a = idex_valid_a && !idex_is_muldiv_a &&
                           (idex_alu_op_a == 4'b0001 || idex_alu_op_a == 4'b0101 || idex_alu_op_a == 4'b1101);

    // M extension -- iterative multiply / divide (slot A only)
    wire idex_is_mul_a = idex_is_muldiv_a && !idex_funct3_a[2];
    wire idex_is_div_a = idex_is_muldiv_a && idex_funct3_a[2];
    wire start_muldiv  = idex_valid_a && (idex_is_muldiv_a || idex_is_shift_a) && !md_active;

    wire        div_signed = !idex_funct3_a[0];
    wire [31:0] div_abs_a  = (div_signed && fwd_rs1_a[31]) ? (~fwd_rs1_a + 32'd1) : fwd_rs1_a;
    wire [31:0] div_abs_b  = (div_signed && fwd_rs2_a[31]) ? (~fwd_rs2_a + 32'd1) : fwd_rs2_a;

    // Iterative multiply result (64-bit negate for signed high-word)
    wire [63:0] mul_prod_raw = {md_hi, md_lo};
    wire [63:0] mul_prod_neg = ~mul_prod_raw + 64'd1;
    wire [63:0] mul_prod_final = md_negate ? mul_prod_neg : mul_prod_raw;
    wire [31:0] mul_result_iter = md_hi_result ? mul_prod_final[63:32] : mul_prod_final[31:0];

    // Divider result
    wire [31:0] div_q_final = md_bz ? 32'hFFFFFFFF : (md_nq ? (~md_lo + 32'd1) : md_lo);
    wire [31:0] div_r_final = md_bz ? md_raw_dividend : (md_nr ? (~md_hi + 32'd1) : md_hi);
    wire [31:0] div_result_iter = idex_funct3_a[1] ? div_r_final : div_q_final;

    wire [31:0] ex_result_a = (idex_is_shift_a && md_ready) ? md_lo :
                              (idex_is_muldiv_a && md_ready) ?
                              (md_is_mul ? mul_result_iter : div_result_iter) : alu_result_a;

    // ================================================================
    // EX stage -- ALU B (ALU + branch, no mul/div/mem)
    // ================================================================
    wire [31:0] alu_a_b = idex_alu_src_pc_b ? idex_pc_b : fwd_rs1_b;
    wire [31:0] alu_b_b = idex_alu_src_imm_b ? idex_imm_b : fwd_rs2_b;

    wire        alu_do_sub_b = (idex_alu_op_b == 4'b1000) || (idex_alu_op_b == 4'b0010) || (idex_alu_op_b == 4'b0011);
    wire [32:0] alu_ext_b = {1'b0, alu_a_b} + {1'b0, alu_do_sub_b ? ~alu_b_b : alu_b_b} + {32'b0, alu_do_sub_b};
    wire [31:0] alu_sum_b   = alu_ext_b[31:0];
    wire        alu_carry_b = alu_ext_b[32];
    wire        alu_lt_b    = (alu_a_b[31] != alu_b_b[31]) ? alu_a_b[31] : alu_sum_b[31];
    wire        alu_ltu_b   = !alu_carry_b;

    logic [31:0] alu_result_b;
    always_comb begin
        case (idex_alu_op_b)
            4'b0000, 4'b1000: alu_result_b = alu_sum_b;
            4'b0010:          alu_result_b = {31'b0, alu_lt_b};
            4'b0011:          alu_result_b = {31'b0, alu_ltu_b};
            4'b0100:          alu_result_b = alu_a_b ^ alu_b_b;
            4'b0110:          alu_result_b = alu_a_b | alu_b_b;
            4'b0111:          alu_result_b = alu_a_b & alu_b_b;
            default:          alu_result_b = alu_sum_b;
        endcase
    end

    logic branch_taken_b;
    always_comb begin
        branch_taken_b = 1'b0;
        if (idex_is_branch_b) begin
            case (idex_funct3_b)
                3'b000:  branch_taken_b = (alu_sum_b == 32'b0);
                3'b001:  branch_taken_b = (alu_sum_b != 32'b0);
                3'b100:  branch_taken_b = alu_lt_b;
                3'b101:  branch_taken_b = !alu_lt_b;
                3'b110:  branch_taken_b = alu_ltu_b;
                3'b111:  branch_taken_b = !alu_ltu_b;
                default: ;
            endcase
        end
    end

    wire [31:0] branch_target_b = idex_pc_b + idex_imm_b;
    wire [31:0] ex_pc4_b = idex_pc_b + (idex_compressed_b ? 32'd2 : 32'd4);

    wire redirect_b = idex_valid_b && !redirect_a &&
                      (idex_is_jal_b || idex_is_jalr_b || branch_taken_b);
    wire [31:0] redirect_target_b = idex_is_jalr_b ? {alu_result_b[31:1], 1'b0} : branch_target_b;

    wire [31:0] ex_result_b = alu_result_b;

    // ================================================================
    // Pipeline control
    // ================================================================
    wire redirect = redirect_a || redirect_b;
    wire [31:0] redirect_target = redirect_a ? redirect_target_a : redirect_target_b;

    wire stall_muldiv = idex_valid_a && (idex_is_muldiv_a || idex_is_shift_a) && !md_ready;
    wire stall_load   = load_use;
    wire stall_pipe   = stall_muldiv || stall_load;
    wire flush      = redirect || (idex_valid_a && (idex_is_trap_a || idex_is_halt_a));

    wire halted = halt_o || trap_o;

    // ================================================================
    // MEM stage -- load/store alignment (slot A only)
    // ================================================================
    wire [1:0] mem_off = exmem_result_a[1:0];
    assign dmem_addr_o = {exmem_result_a[31:2], 2'b00};

    logic [7:0] load_byte;
    always_comb begin
        case (mem_off)
            2'b00:   load_byte = dmem_rdata_i[7:0];
            2'b01:   load_byte = dmem_rdata_i[15:8];
            2'b10:   load_byte = dmem_rdata_i[23:16];
            default: load_byte = dmem_rdata_i[31:24];
        endcase
    end
    wire [15:0] load_half = mem_off[1] ? dmem_rdata_i[31:16] : dmem_rdata_i[15:0];

    logic [31:0] load_data;
    always_comb begin
        case (exmem_funct3_a)
            3'b000:  load_data = {{24{load_byte[7]}}, load_byte};
            3'b001:  load_data = {{16{load_half[15]}}, load_half};
            3'b010:  load_data = dmem_rdata_i;
            3'b100:  load_data = {24'b0, load_byte};
            3'b101:  load_data = {16'b0, load_half};
            default: load_data = dmem_rdata_i;
        endcase
    end

    logic [31:0] store_data;
    always_comb begin
        case (mem_off)
            2'b00:   store_data = exmem_rs2_val_a;
            2'b01:   store_data = {exmem_rs2_val_a[23:0], 8'b0};
            2'b10:   store_data = {exmem_rs2_val_a[15:0], 16'b0};
            default: store_data = {exmem_rs2_val_a[7:0],  24'b0};
        endcase
    end

    logic [3:0] store_strobe;
    always_comb begin
        store_strobe = 4'b0000;
        if (exmem_valid_a && exmem_is_amo_a)
            store_strobe = 4'b1111;
        else if (exmem_valid_a && exmem_is_sc_a)
            store_strobe = sc_success ? 4'b1111 : 4'b0000;
        else if (exmem_valid_a && exmem_mem_write_a) begin
            case (exmem_funct3_a)
                3'b000:  store_strobe = 4'b0001 << mem_off;
                3'b001:  store_strobe = 4'b0011 << mem_off;
                3'b010:  store_strobe = 4'b1111;
                default: ;
            endcase
        end
    end

    assign dmem_wdata_o = exmem_is_amo_a ? amo_result :
                          exmem_is_sc_a  ? exmem_rs2_val_a : store_data;
    assign dmem_wstrb_o = store_strobe;

    // ================================================================
    // A extension -- AMO + LR/SC
    // ================================================================
    logic [31:0] amo_result;
    always_comb begin
        case (exmem_amo_funct5_a)
            5'b00001: amo_result = exmem_rs2_val_a;
            5'b00000: amo_result = dmem_rdata_i + exmem_rs2_val_a;
            5'b00100: amo_result = dmem_rdata_i ^ exmem_rs2_val_a;
            5'b01100: amo_result = dmem_rdata_i & exmem_rs2_val_a;
            5'b01000: amo_result = dmem_rdata_i | exmem_rs2_val_a;
            5'b10000: amo_result = ($signed(dmem_rdata_i) < $signed(exmem_rs2_val_a)) ? dmem_rdata_i : exmem_rs2_val_a;
            5'b10100: amo_result = ($signed(dmem_rdata_i) > $signed(exmem_rs2_val_a)) ? dmem_rdata_i : exmem_rs2_val_a;
            5'b11000: amo_result = (dmem_rdata_i < exmem_rs2_val_a) ? dmem_rdata_i : exmem_rs2_val_a;
            5'b11100: amo_result = (dmem_rdata_i > exmem_rs2_val_a) ? dmem_rdata_i : exmem_rs2_val_a;
            default:  amo_result = exmem_rs2_val_a;
        endcase
    end

    wire sc_success = exmem_is_sc_a && resv_valid && (resv_addr == exmem_result_a);

    wire [31:0] mem_rd_data_a = exmem_is_sc_a  ? {31'b0, ~sc_success} :
                                (exmem_is_amo_a || exmem_is_lr_a) ? dmem_rdata_i :
                                (exmem_wb_sel_a == WB_MEM) ? load_data :
                                (exmem_wb_sel_a == WB_PC4) ? exmem_pc4_a : exmem_result_a;

    wire [31:0] mem_rd_data_b = (exmem_wb_sel_b == WB_PC4) ? exmem_pc4_b : exmem_result_b;

    // ================================================================
    // Sequential logic
    // ================================================================

    // Signal: did we actually dual-issue this cycle (for PC advancement)?
    // This is the decision made during the ID stage for what to send to IDEX.
    wire did_dual_issue = !stall_pipe && !flush && ifid_valid_a && can_dual_issue;

    // Signal: did we hold slot B this cycle?
    wire do_hold_b = !stall_pipe && !flush && ifid_valid_a && ifid_valid_b && !can_dual_issue && !held_valid;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pc_q            <= RESET_PC;
            ifid_valid_a    <= 1'b0;
            ifid_valid_b    <= 1'b0;
            idex_valid_a    <= 1'b0;
            idex_valid_b    <= 1'b0;
            exmem_valid_a   <= 1'b0;
            exmem_valid_b   <= 1'b0;
            memwb_valid_a   <= 1'b0;
            memwb_valid_b   <= 1'b0;
            trap_o          <= 1'b0;
            halt_o          <= 1'b0;
            md_active       <= 1'b0;
            resv_valid      <= 1'b0;
            held_valid      <= 1'b0;
        end else if (halted) begin
            // frozen
        end else begin
            // ---- WB: register file write ----
            if (memwb_valid_a && memwb_rd_we_a && memwb_rd_a != 5'd0)
                regs[memwb_rd_a] <= memwb_rd_data_a;
            if (memwb_valid_b && memwb_rd_we_b && memwb_rd_b != 5'd0)
                regs[memwb_rd_b] <= memwb_rd_data_b;

            if (memwb_valid_a && memwb_is_trap_a) trap_o <= 1'b1;
            if (memwb_valid_a && memwb_is_halt_a) halt_o <= 1'b1;

            // ---- MEM/WB ----
            memwb_valid_a   <= exmem_valid_a;
            memwb_rd_a      <= exmem_rd_a;
            memwb_rd_we_a   <= exmem_valid_a ? exmem_rd_we_a : 1'b0;
            memwb_rd_data_a <= mem_rd_data_a;
            memwb_is_halt_a <= exmem_valid_a && exmem_is_halt_a;
            memwb_is_trap_a <= exmem_valid_a && exmem_is_trap_a;

            memwb_valid_b   <= exmem_valid_b;
            memwb_rd_b      <= exmem_rd_b;
            memwb_rd_we_b   <= exmem_valid_b ? exmem_rd_we_b : 1'b0;
            memwb_rd_data_b <= mem_rd_data_b;

            // ---- EX/MEM ----
            if (stall_muldiv) begin
                exmem_valid_a <= 1'b0;
                exmem_valid_b <= 1'b0;
            end else begin
                exmem_valid_a     <= idex_valid_a;
                exmem_result_a    <= ex_result_a;
                exmem_rs2_val_a   <= fwd_rs2_a;
                exmem_pc4_a       <= ex_pc4_a;
                exmem_rd_a        <= idex_rd_a;
                exmem_funct3_a    <= idex_funct3_a;
                exmem_rd_we_a     <= idex_rd_we_a && !idex_is_trap_a && !idex_is_halt_a;
                exmem_mem_read_a  <= idex_mem_read_a;
                exmem_mem_write_a <= idex_mem_write_a && !idex_is_trap_a && !idex_is_halt_a;
                exmem_wb_sel_a    <= idex_wb_sel_a;
                exmem_is_halt_a   <= idex_is_halt_a;
                exmem_is_trap_a   <= idex_is_trap_a;
                exmem_is_amo_a    <= idex_is_amo_a;
                exmem_is_lr_a     <= idex_is_lr_a;
                exmem_is_sc_a     <= idex_is_sc_a;
                exmem_amo_funct5_a<= idex_amo_funct5_a;

                exmem_valid_b     <= redirect_a ? 1'b0 : idex_valid_b;
                exmem_result_b    <= ex_result_b;
                exmem_pc4_b       <= ex_pc4_b;
                exmem_rd_b        <= idex_rd_b;
                exmem_rd_we_b     <= idex_rd_we_b;
                exmem_wb_sel_b    <= idex_wb_sel_b;
            end

            // ---- ID/EX ----
            if (stall_muldiv) begin
                // hold
            end else if (flush || stall_load) begin
                idex_valid_a <= 1'b0;
                idex_valid_b <= 1'b0;
            end else begin
                idex_valid_a      <= ifid_valid_a;
                idex_pc_a         <= ifid_pc_a;
                idex_rs1_val_a    <= id_rs1_val_a;
                idex_rs2_val_a    <= id_rs2_val_a;
                idex_imm_a        <= id_imm_a;
                idex_rd_a         <= id_rd_a;
                idex_rs1_a        <= id_rs1_a;
                idex_rs2_a        <= id_rs2_a;
                idex_alu_op_a     <= id_alu_op_a;
                idex_funct3_a     <= id_funct3_a;
                idex_alu_src_imm_a<= id_alu_src_imm_a;
                idex_alu_src_pc_a <= id_alu_src_pc_a;
                idex_mem_read_a   <= id_mem_read_a;
                idex_mem_write_a  <= id_mem_write_a;
                idex_rd_we_a      <= id_rd_we_a;
                idex_is_branch_a  <= id_is_branch_a;
                idex_is_jal_a     <= id_is_jal_a;
                idex_is_jalr_a    <= id_is_jalr_a;
                idex_is_muldiv_a  <= id_is_muldiv_a;
                idex_wb_sel_a     <= id_wb_sel_a;
                idex_is_halt_a    <= id_is_halt_a;
                idex_is_trap_a    <= id_is_trap_a;
                idex_is_amo_a     <= id_is_amo_a;
                idex_is_lr_a      <= id_is_lr_a;
                idex_is_sc_a      <= id_is_sc_a;
                idex_amo_funct5_a <= id_amo_funct5_a;
                idex_compressed_a <= ifid_compressed_a;

                idex_valid_b      <= ifid_valid_a && can_dual_issue;
                idex_pc_b         <= ifid_pc_b;
                idex_rs1_val_b    <= id_rs1_val_b;
                idex_rs2_val_b    <= id_rs2_val_b;
                idex_imm_b        <= id_imm_b;
                idex_rd_b         <= id_rd_b;
                idex_rs1_b        <= id_rs1_b;
                idex_rs2_b        <= id_rs2_b;
                idex_alu_op_b     <= id_alu_op_b;
                idex_funct3_b     <= id_funct3_b;
                idex_alu_src_imm_b<= id_alu_src_imm_b;
                idex_alu_src_pc_b <= id_alu_src_pc_b;
                idex_rd_we_b      <= id_rd_we_b;
                idex_is_branch_b  <= id_is_branch_b;
                idex_is_jal_b     <= id_is_jal_b;
                idex_is_jalr_b    <= id_is_jalr_b;
                idex_wb_sel_b     <= id_wb_sel_b;
                idex_compressed_b <= ifid_compressed_b;
            end

            // ---- IF/ID ----
            if (stall_pipe) begin
                // hold IF/ID and held state
            end else if (flush) begin
                ifid_valid_a <= 1'b0;
                ifid_valid_b <= 1'b0;
                held_valid   <= 1'b0;
            end else if (do_hold_b) begin
                // IFID_A is being consumed by IDEX this cycle (above).
                // IFID_B can't dual-issue -- hold it for next cycle.
                // Insert bubble into IFID so next cycle the held replay takes effect.
                ifid_valid_a      <= 1'b0;
                ifid_valid_b      <= 1'b0;
                held_valid        <= 1'b1;
                held_pc           <= ifid_pc_b;
                held_instr        <= ifid_instr_b;
                held_compressed   <= ifid_compressed_b;
            end else if (held_valid) begin
                // Replay held instruction as slot A, fetch from memory as slot B
                ifid_valid_a      <= 1'b1;
                ifid_pc_a         <= held_pc;
                ifid_instr_a      <= held_instr;
                ifid_compressed_a <= held_compressed;
                ifid_valid_b      <= if_valid_a;
                ifid_pc_b         <= pc_q;
                ifid_instr_b      <= if_instr_a;
                ifid_compressed_b <= if_compressed_a;
                held_valid        <= 1'b0;
            end else begin
                // Normal fetch: load both slots from memory
                ifid_valid_a      <= if_valid_a;
                ifid_pc_a         <= pc_q;
                ifid_instr_a      <= if_instr_a;
                ifid_compressed_a <= if_compressed_a;
                ifid_valid_b      <= if_valid_b;
                ifid_pc_b         <= if_next_pc;
                ifid_instr_b      <= if_instr_b;
                ifid_compressed_b <= if_compressed_b;
            end

            // ---- PC update ----
            if (redirect) begin
                pc_q <= redirect_target;
                held_valid <= 1'b0;
            end else if (!stall_pipe) begin
                if (do_hold_b) begin
                    // Holding IFID_B. Next cycle we replay held + fetch.
                    // PC should point to the instruction AFTER the held one.
                    pc_q <= ifid_pc_b + (ifid_compressed_b ? 32'd2 : 32'd4);
                end else if (held_valid) begin
                    // Replaying held as IFID_A, fetching if_instr_a as IFID_B.
                    // Advance PC past the newly fetched instruction.
                    pc_q <= if_next_pc;
                end else if (if_valid_b) begin
                    pc_q <= if_pc_after_b;
                end else begin
                    pc_q <= if_next_pc;
                end
            end

            // ---- Mul/Div/Shift iterative unit ----
            if (start_muldiv && idex_is_shift_a) begin
                // Iterative shift setup
                md_active     <= 1'b1;
                md_is_shift   <= 1'b1;
                md_is_mul     <= 1'b0;
                md_lo         <= fwd_rs1_a;
                md_cnt        <= {1'b0, idex_alu_src_imm_a ? idex_imm_a[4:0] : fwd_rs2_a[4:0]};
                md_shift_dir  <= {idex_alu_op_a[3], idex_alu_op_a[2]};  // {f7b5, funct3[2]}: 00=SLL, 01=SRL, 11=SRA
            end else if (start_muldiv) begin
                md_active        <= 1'b1;
                md_is_shift      <= 1'b0;
                md_cnt           <= 6'd32;
                if (idex_is_mul_a) begin
                    // Iterative multiply setup
                    md_is_mul    <= 1'b1;
                    md_hi        <= 32'b0;
                    case (idex_funct3_a[1:0])
                        2'b00: begin // MUL
                            md_lo       <= fwd_rs2_a;
                            md_b        <= fwd_rs1_a;
                            md_negate   <= 1'b0;
                            md_hi_result<= 1'b0;
                        end
                        2'b01: begin // MULH
                            md_lo       <= (fwd_rs2_a[31]) ? (~fwd_rs2_a + 32'd1) : fwd_rs2_a;
                            md_b        <= (fwd_rs1_a[31]) ? (~fwd_rs1_a + 32'd1) : fwd_rs1_a;
                            md_negate   <= fwd_rs1_a[31] ^ fwd_rs2_a[31];
                            md_hi_result<= 1'b1;
                        end
                        2'b10: begin // MULHSU
                            md_lo       <= fwd_rs2_a;
                            md_b        <= (fwd_rs1_a[31]) ? (~fwd_rs1_a + 32'd1) : fwd_rs1_a;
                            md_negate   <= fwd_rs1_a[31];
                            md_hi_result<= 1'b1;
                        end
                        2'b11: begin // MULHU
                            md_lo       <= fwd_rs2_a;
                            md_b        <= fwd_rs1_a;
                            md_negate   <= 1'b0;
                            md_hi_result<= 1'b1;
                        end
                    endcase
                    md_nq <= 1'b0;
                    md_nr <= 1'b0;
                    md_bz <= 1'b0;
                    md_raw_dividend <= 32'b0;
                end else begin
                    // Divide setup
                    md_is_mul        <= 1'b0;
                    md_lo            <= div_abs_a;
                    md_hi            <= 32'b0;
                    md_b             <= div_abs_b;
                    md_nq            <= div_signed && (fwd_rs1_a[31] ^ fwd_rs2_a[31]) && (fwd_rs2_a != 32'b0);
                    md_nr            <= div_signed && fwd_rs1_a[31];
                    md_bz            <= (fwd_rs2_a == 32'b0);
                    md_raw_dividend  <= fwd_rs1_a;
                    md_negate        <= 1'b0;
                    md_hi_result     <= 1'b0;
                end
            end else if (md_active && md_cnt != 6'd0) begin
                if (md_is_shift) begin
                    case (md_shift_dir)
                        2'b00:   md_lo <= {md_lo[30:0], 1'b0};       // SLL
                        2'b01:   md_lo <= {1'b0, md_lo[31:1]};       // SRL
                        default: md_lo <= {md_lo[31], md_lo[31:1]};  // SRA
                    endcase
                end else if (md_is_mul) begin
                    // Multiply iteration: right-shift approach
                    if (md_lo[0]) begin
                        {md_hi, md_lo} <= {mul_partial, md_lo[31:1]};
                    end else begin
                        {md_hi, md_lo} <= {1'b0, md_hi, md_lo[31:1]};
                    end
                end else begin
                    // Divide iteration
                    if (!div_trial[32]) begin
                        md_hi  <= div_trial[31:0];
                        md_lo  <= {md_lo[30:0], 1'b1};
                    end else begin
                        md_hi  <= {md_hi[30:0], md_lo[31]};
                        md_lo  <= {md_lo[30:0], 1'b0};
                    end
                end
                md_cnt <= md_cnt - 6'd1;
            end else if (md_ready) begin
                md_active <= 1'b0;
            end

            // ---- LR/SC ----
            if (exmem_valid_a && exmem_is_lr_a) begin
                resv_addr  <= exmem_result_a;
                resv_valid <= 1'b1;
            end else if (exmem_valid_a && exmem_is_sc_a) begin
                resv_valid <= 1'b0;
            end else if (exmem_valid_a && exmem_mem_write_a && resv_valid &&
                         exmem_result_a == resv_addr) begin
                resv_valid <= 1'b0;
            end
        end
    end
endmodule
