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

    // Compact control-flow encoding (saves DFFE+decode area vs 3 separate bits)
    localparam [1:0] CF_NONE = 2'd0, CF_BRANCH = 2'd1, CF_JAL = 2'd2, CF_JALR = 2'd3;

    // Compact AMO type encoding (saves DFFE+decode area vs 3 separate bits)
    localparam [1:0] AMO_NONE = 2'd0, AMO_LR = 2'd1, AMO_SC = 2'd2, AMO_RMW = 2'd3;

    // ================================================================
    // Register file  (x0 hardwired to 0)
    // ================================================================
    logic [31:0] regs [1:31];

    // ================================================================
    // Pipeline registers -- dual slots (A = older, B = younger)
    // 3-stage pipeline: IF/ID merged (fetch+decompress+decode+issue in one
    // stage, no IFID registers) -> EX -> MEM.
    // ================================================================
    // --- ID/EX ---
    logic [31:0] idex_pc_a, idex_imm_a;
    logic [4:0]  idex_rd_a, idex_rs1_a, idex_rs2_a;
    logic [3:0]  idex_alu_op_a;
    logic [2:0]  idex_funct3_a;
    logic        idex_alu_src_imm_a, idex_alu_src_pc_a;
    logic        idex_mem_read_a, idex_mem_write_a, idex_rd_we_a;
    logic [1:0]  idex_cf_a;  // CF_NONE / CF_BRANCH / CF_JAL / CF_JALR
    logic        idex_is_muldiv_a, idex_is_halt_a, idex_is_trap_a;
    logic [1:0]  idex_amo_type_a;  // AMO_NONE / AMO_LR / AMO_SC / AMO_RMW
    logic [4:0]  idex_amo_funct5_a;
    logic [1:0]  idex_wb_sel_a;
    logic        idex_valid_a, idex_compressed_a;

    // Derived signals from compact encodings
    wire idex_is_branch_a = (idex_cf_a == CF_BRANCH);
    wire idex_is_jal_a    = (idex_cf_a == CF_JAL);
    wire idex_is_jalr_a   = (idex_cf_a == CF_JALR);
    wire idex_is_amo_a    = (idex_amo_type_a == AMO_RMW);
    wire idex_is_lr_a     = (idex_amo_type_a == AMO_LR);
    wire idex_is_sc_a     = (idex_amo_type_a == AMO_SC);

    logic [31:0] idex_imm_b;
    logic [4:0]  idex_rd_b, idex_rs1_b, idex_rs2_b;
    logic [3:0]  idex_alu_op_b;
    logic        idex_alu_src_imm_b;
    logic        idex_rd_we_b;
    logic        idex_valid_b;

    // --- EX/MEM ---
    logic [31:0] exmem_result_a, exmem_rs2_val_a;
    logic [4:0]  exmem_rd_a;
    logic [2:0]  exmem_funct3_a;
    logic        exmem_rd_we_a, exmem_mem_read_a, exmem_mem_write_a;
    logic [1:0]  exmem_amo_type_a;  // AMO_NONE / AMO_LR / AMO_SC / AMO_RMW
    logic [4:0]  exmem_amo_funct5_a;
    logic        exmem_is_halt_a, exmem_is_trap_a, exmem_valid_a;

    // Derived signals from compact encoding
    wire exmem_is_amo_a = (exmem_amo_type_a == AMO_RMW);
    wire exmem_is_lr_a  = (exmem_amo_type_a == AMO_LR);
    wire exmem_is_sc_a  = (exmem_amo_type_a == AMO_SC);

    // --- EXMEM_B eliminated: slot B commits directly from EX phase 1.
    //     The MEM stage always holds a bubble during phase 1 (the phase-0
    //     stall gated EXMEM), so B shares the single RF write port for free.

    // --- MEM/WB eliminated: register file write now happens directly from EXMEM ---

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

    // ================================================================
    // ALU sharing state: time-multiplex slot A's ALU for slot B
    // ================================================================
    logic        ex_phase;           // 0 = computing slot A, 1 = computing slot B
    logic [31:0] ex_result_a_saved;  // holds A's result during phase 1
    logic [31:0] ex_rs2_a_saved;     // holds A's fwd_rs2 during phase 1

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
    logic [15:0] if_hw_b_sel;
    logic [31:0] if_word_b_sel;
    logic        if_b_32_fits;

    // Instruction A is always fetchable (PC is 2-byte aligned, window is 8 bytes)

    always_comb begin
        if_instr_a      = 32'h0000_0013;
        if_compressed_a = 1'b0;
        if_next_pc      = pc_q;
        if_instr_b      = 32'h0000_0013;
        if_compressed_b = 1'b0;
        if_valid_b      = 1'b0;
        if_hw_b_sel     = hw_at_2;
        if_word_b_sel   = word_at_2;
        if_b_32_fits    = 1'b1;

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
        // Preselect B halfword/word, then single decompress call below
        if (!pc_q[1] && if_hw_a[1:0] != 2'b11) begin
            if_hw_b_sel  = hw_at_2;
            if_word_b_sel = word_at_2;
            if_b_32_fits = 1'b1;
        end else if ((!pc_q[1] && if_hw_a[1:0] == 2'b11) ||
                     ( pc_q[1] && if_hw_a[1:0] != 2'b11)) begin
            if_hw_b_sel  = hw_at_4;
            if_word_b_sel = word_at_4;
            if_b_32_fits = 1'b1;
        end else begin
            if_hw_b_sel  = hw_at_6;
            if_word_b_sel = 32'h0000_0013;
            if_b_32_fits = 1'b0;
        end

        // Single B decompressor call
        if (if_hw_b_sel[1:0] != 2'b11) begin
            if_instr_b = decompress(if_hw_b_sel);
            if_compressed_b = 1'b1;
            if_valid_b = 1'b1;
        end else if (if_b_32_fits) begin
            if_instr_b = if_word_b_sel;
            if_compressed_b = 1'b0;
            if_valid_b = 1'b1;
        end
    end

    wire [31:0] if_pc_after_b = if_next_pc + (if_compressed_b ? 32'd2 : 32'd4);

    // ================================================================
    // Decode helpers for a generic instruction
    // ================================================================

    // Slot A decode
    wire [6:0] id_opcode_a = if_instr_a[6:0];
    wire [4:0] id_rd_a     = if_instr_a[11:7];
    wire [2:0] id_funct3_a = if_instr_a[14:12];
    wire       id_f7b5_a   = if_instr_a[30];
    wire [6:0] id_funct7_a = if_instr_a[31:25];

    logic [4:0] id_rs1_a, id_rs2_a;
    always_comb begin
        id_rs1_a = if_instr_a[19:15];
        id_rs2_a = if_instr_a[24:20];
        case (id_opcode_a)
            OP_LUI, OP_AUIPC, OP_JAL: begin id_rs1_a = 5'd0; id_rs2_a = 5'd0; end
            OP_JALR, OP_LOAD, OP_IMM:  id_rs2_a = 5'd0;
            default: ;
        endcase
    end

    wire [31:0] imm_i_a = {{20{if_instr_a[31]}}, if_instr_a[31:20]};
    wire [31:0] imm_s_a = {{20{if_instr_a[31]}}, if_instr_a[31:25], if_instr_a[11:7]};
    wire [31:0] imm_b_a = {{19{if_instr_a[31]}}, if_instr_a[31], if_instr_a[7],
                            if_instr_a[30:25], if_instr_a[11:8], 1'b0};
    wire [31:0] imm_u_a = {if_instr_a[31:12], 12'b0};
    wire [31:0] imm_j_a = {{11{if_instr_a[31]}}, if_instr_a[31], if_instr_a[19:12],
                            if_instr_a[20], if_instr_a[30:21], 1'b0};

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
                id_amo_funct5_a = if_instr_a[31:27];
                if (if_instr_a[31:27] == 5'b00010) begin
                    id_is_lr_a = 1'b1;
                end else if (if_instr_a[31:27] == 5'b00011) begin
                    id_is_sc_a = 1'b1; id_mem_write_a = 1'b1; id_wb_sel_a = WB_EX;
                end else begin
                    id_is_amo_a = 1'b1; id_mem_write_a = 1'b1;
                end
            end
            OP_FENCE: ;
            OP_SYSTEM: begin
                if (if_instr_a == 32'h00100073) id_is_halt_a = 1'b1;
                else id_is_trap_a = 1'b1;
            end
            default: id_is_trap_a = 1'b1;
        endcase
    end

    // Slot B decode
    wire [6:0] id_opcode_b = if_instr_b[6:0];
    wire [4:0] id_rd_b     = if_instr_b[11:7];
    wire [2:0] id_funct3_b = if_instr_b[14:12];
    wire       id_f7b5_b   = if_instr_b[30];
    wire [6:0] id_funct7_b = if_instr_b[31:25];

    logic [4:0] id_rs1_b, id_rs2_b;
    always_comb begin
        id_rs1_b = if_instr_b[19:15];
        id_rs2_b = if_instr_b[24:20];
        case (id_opcode_b)
            OP_LUI, OP_AUIPC, OP_JAL: begin id_rs1_b = 5'd0; id_rs2_b = 5'd0; end
            OP_JALR, OP_LOAD, OP_IMM:  id_rs2_b = 5'd0;
            default: ;
        endcase
    end

    wire [31:0] imm_i_b = {{20{if_instr_b[31]}}, if_instr_b[31:20]};
    wire [31:0] imm_s_b = {{20{if_instr_b[31]}}, if_instr_b[31:25], if_instr_b[11:7]};
    wire [31:0] imm_b_b = {{19{if_instr_b[31]}}, if_instr_b[31], if_instr_b[7],
                            if_instr_b[30:25], if_instr_b[11:8], 1'b0};
    wire [31:0] imm_u_b = {if_instr_b[31:12], 12'b0};
    wire [31:0] imm_j_b = {{11{if_instr_b[31]}}, if_instr_b[31], if_instr_b[19:12],
                            if_instr_b[20], if_instr_b[30:21], 1'b0};

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
                if (if_instr_b[31:27] == 5'b00010) id_is_lr_b = 1'b1;
                else if (if_instr_b[31:27] == 5'b00011) begin
                    id_is_sc_b = 1'b1; id_mem_write_b = 1'b1; id_wb_sel_b = WB_EX;
                end else begin
                    id_is_amo_b = 1'b1; id_mem_write_b = 1'b1;
                end
            end
            OP_FENCE: ;
            OP_SYSTEM: begin
                if (if_instr_b == 32'h00100073) id_is_halt_b = 1'b1;
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
    wire b_is_control = (id_opcode_b == OP_BRANCH) || (id_opcode_b == OP_JAL) ||
                        (id_opcode_b == OP_JALR) || (id_opcode_b == OP_AUIPC);
    wire b_structural = id_mem_read_b || id_mem_write_b || id_is_amo_b || id_is_lr_b || id_is_sc_b ||
                        id_is_muldiv_b || id_is_halt_b || id_is_trap_b || b_is_shift || b_is_control;
    wire b_raw = id_rd_we_a && (id_rd_a != 5'd0) &&
                 ((id_rs1_b == id_rd_a) || (id_rs2_b == id_rd_a));
    wire b_waw = id_rd_we_a && id_rd_we_b && (id_rd_a != 5'd0) && (id_rd_a == id_rd_b);
    wire a_is_redirect = id_is_jal_a || id_is_jalr_a || id_is_branch_a;

    wire a_is_shift = (id_opcode_a == OP_IMM || id_opcode_a == OP_REG) &&
                      (id_funct3_a == 3'b001 || id_funct3_a == 3'b101);

    // Bypass-readiness check for slot B (B has no forwarding network).
    // Write timing analysis: results write to the RF at the end of the
    // producer's MEM cycle (slot A) or EX phase-1 cycle (slot B), and B's
    // EX-stage RF read happens one full cycle after issue. The only producer
    // whose write is still invisible at that point is the instruction in EX
    // slot A right now -- everything older has already reached the RF.
    wire b_needs_bypass = idex_valid_a && idex_rd_we_a && (idex_rd_a != 5'd0) &&
                          ((id_rs1_b == idex_rd_a) || (id_rs2_b == idex_rd_a));

    wire can_dual_issue = if_valid_b && !b_structural && !b_raw && !b_waw && !a_is_redirect &&
                          !id_is_halt_a && !id_is_trap_a && !id_is_muldiv_a && !a_is_shift &&
                          !b_needs_bypass;

    // ================================================================
    // EX-stage register file reads (moved from ID to save pipeline regs)
    // ================================================================
    // Shared RF read ports: time-multiplexed between A (phase 0) and B (phase 1)
    wire [4:0]  rf_rs1_idx = in_phase_b ? idex_rs1_b : idex_rs1_a;
    wire [4:0]  rf_rs2_idx = in_phase_b ? idex_rs2_b : idex_rs2_a;
    wire [31:0] ex_rf_rs1 = (rf_rs1_idx == 5'd0) ? 32'b0 : regs[rf_rs1_idx];
    wire [31:0] ex_rf_rs2 = (rf_rs2_idx == 5'd0) ? 32'b0 : regs[rf_rs2_idx];

    // ================================================================
    // Hazard detection (load-use)
    // ================================================================
    wire id_uses_rs1_a = (id_opcode_a == OP_REG || id_opcode_a == OP_IMM || id_opcode_a == OP_LOAD ||
                          id_opcode_a == OP_STORE || id_opcode_a == OP_BRANCH || id_opcode_a == OP_JALR ||
                          id_opcode_a == OP_AMO);
    wire id_uses_rs2_a = (id_opcode_a == OP_REG || id_opcode_a == OP_STORE || id_opcode_a == OP_BRANCH ||
                          id_opcode_a == OP_AMO);
    // Load-use for a dependent slot-B is impossible: b_needs_bypass already
    // rejects dual-issue whenever EX slot A (incl. loads) writes B's sources.
    wire load_use = idex_valid_a && idex_mem_read_a && (idex_rd_a != 5'd0) &&
                    ((id_uses_rs1_a && idex_rd_a == id_rs1_a) ||
                     (id_uses_rs2_a && idex_rd_a == id_rs2_a));

    // ================================================================
    // Forwarding (single source: exmem_a)
    // Slot B results are already in the RF (written at EX phase-1), so no
    // exmem_b source exists. MEMWB was eliminated; its role is covered by
    // the write-from-MEM timing (EX reads see it one cycle later).
    // ================================================================
    wire fwd_ema_rs1_a = exmem_valid_a && exmem_rd_we_a && (exmem_rd_a != 5'd0) && (exmem_rd_a == idex_rs1_a);
    wire fwd_ema_rs2_a = exmem_valid_a && exmem_rd_we_a && (exmem_rd_a != 5'd0) && (exmem_rd_a == idex_rs2_a);

    wire [31:0] fwd_rs1_a = fwd_ema_rs1_a ? exmem_result_a : ex_rf_rs1;
    wire [31:0] fwd_rs2_a = fwd_ema_rs2_a ? exmem_result_a : ex_rf_rs2;

    // Slot B is bypass-free: uses direct EX-stage RF reads

    // ================================================================
    // EX stage -- Shared ALU (time-multiplexed for slots A and B)
    // ================================================================
    // Phase 0: ALU computes slot A's result
    // Phase 1: ALU computes slot B's result using B's operands
    wire in_phase_b = (ex_phase == 1'b1);

    // Slot A operands (used in phase 0)
    wire [31:0] alu_a_a = idex_alu_src_pc_a ? idex_pc_a : fwd_rs1_a;
    wire [31:0] alu_b_a = idex_alu_src_imm_a ? idex_imm_a : fwd_rs2_a;

    // Mux ALU inputs: phase 0 = slot A, phase 1 = slot B
    wire [31:0] alu_in_a = in_phase_b ? ex_rf_rs1 : alu_a_a;
    wire [31:0] alu_in_b = in_phase_b ? (idex_alu_src_imm_b ? idex_imm_b : ex_rf_rs2) : alu_b_a;
    wire [3:0]  alu_op   = in_phase_b ? idex_alu_op_b : idex_alu_op_a;

    wire        alu_do_sub = (alu_op == 4'b1000) || (alu_op == 4'b0010) || (alu_op == 4'b0011);
    wire [32:0] alu_ext = {1'b0, alu_in_a} + {1'b0, alu_do_sub ? ~alu_in_b : alu_in_b} + {32'b0, alu_do_sub};
    wire [31:0] alu_sum   = alu_ext[31:0];
    wire        alu_carry = alu_ext[32];
    wire        alu_lt    = (alu_in_a[31] != alu_in_b[31]) ? alu_in_a[31] : alu_sum[31];
    wire        alu_ltu   = !alu_carry;

    logic [31:0] alu_result;
    always_comb begin
        case (alu_op)
            4'b0000, 4'b1000: alu_result = alu_sum;
            4'b0010:          alu_result = {31'b0, alu_lt};
            4'b0011:          alu_result = {31'b0, alu_ltu};
            4'b0100:          alu_result = alu_in_a ^ alu_in_b;
            4'b0110:          alu_result = alu_in_a | alu_in_b;
            4'b0111:          alu_result = alu_in_a & alu_in_b;
            default:          alu_result = alu_sum;
        endcase
    end

    // Branch logic uses ALU results (only valid in phase 0 when slot A is active)
    logic branch_taken_a;
    always_comb begin
        branch_taken_a = 1'b0;
        if (idex_is_branch_a && !in_phase_b) begin
            case (idex_funct3_a)
                3'b000:  branch_taken_a = (alu_sum == 32'b0);
                3'b001:  branch_taken_a = (alu_sum != 32'b0);
                3'b100:  branch_taken_a = alu_lt;
                3'b101:  branch_taken_a = !alu_lt;
                3'b110:  branch_taken_a = alu_ltu;
                3'b111:  branch_taken_a = !alu_ltu;
                default: ;
            endcase
        end
    end

    wire [31:0] branch_target_a = idex_pc_a + idex_imm_a;
    wire [31:0] ex_pc4_a = idex_pc_a + (idex_compressed_a ? 32'd2 : 32'd4);

    wire redirect_a = idex_valid_a && !idex_is_trap_a && !idex_is_halt_a && !in_phase_b &&
                      (idex_is_jal_a || idex_is_jalr_a || branch_taken_a);
    wire [31:0] redirect_target_a = idex_is_jalr_a ? {alu_result[31:1], 1'b0} : branch_target_a;

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

    // ex_result_a uses alu_result (which is for slot A in phase 0)
    wire [31:0] ex_result_a = (idex_is_shift_a && md_ready) ? md_lo :
                              (idex_is_muldiv_a && md_ready) ?
                              (md_is_mul ? mul_result_iter : div_result_iter) : alu_result;

    // ALU phase stall: when phase 0 has valid B, need 1 extra cycle for phase 1
    wire stall_alu_phase = idex_valid_a && idex_valid_b && !ex_phase && !stall_muldiv;

    // ================================================================
    // Pipeline control
    // ================================================================
    wire redirect = redirect_a;
    wire [31:0] redirect_target = redirect_target_a;

    wire stall_muldiv = idex_valid_a && (idex_is_muldiv_a || idex_is_shift_a) && !md_ready;
    wire stall_load   = load_use;
    wire flush      = redirect || (idex_valid_a && !in_phase_b && (idex_is_trap_a || idex_is_halt_a));

    // No EXMEM-dependency stall needed: a producer in MEM writes the RF at the
    // end of this cycle, and a consumer issued this cycle reads the RF in EX
    // next cycle -- the write is already visible.
    wire stall_pipe   = stall_muldiv || stall_load || stall_alu_phase;

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
                                exmem_mem_read_a ? load_data :
                                exmem_result_a;

    // ================================================================
    // Register file write -- SINGLE port shared by both slots.
    // Slot B commits straight from the ALU at the end of EX phase 1; the MEM
    // stage is guaranteed to hold a bubble in that cycle (stall_alu_phase
    // gated EXMEM to invalid), so the two writers can never collide.
    // ================================================================
    wire        rf_wb_b  = in_phase_b && idex_valid_b && idex_rd_we_b;
    wire [4:0]  rf_waddr = rf_wb_b ? idex_rd_b : exmem_rd_a;
    wire [31:0] rf_wdata = rf_wb_b ? alu_result : mem_rd_data_a;
    wire        rf_we    = (rf_wb_b || (exmem_valid_a && exmem_rd_we_a)) && (rf_waddr != 5'd0);

    // ================================================================
    // Sequential logic
    // ================================================================

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pc_q            <= RESET_PC;
            idex_valid_a    <= 1'b0;
            idex_valid_b    <= 1'b0;
            exmem_valid_a   <= 1'b0;
            trap_o          <= 1'b0;
            halt_o          <= 1'b0;
            md_active       <= 1'b0;
            resv_valid      <= 1'b0;
            ex_phase        <= 1'b0;
        end else if (halted) begin
            // frozen
        end else begin
            // ---- WB: single-port register file write (A from MEM, B from EX phase 1) ----
            if (rf_we)
                regs[rf_waddr] <= rf_wdata;

            if (exmem_valid_a && exmem_is_trap_a) trap_o <= 1'b1;
            if (exmem_valid_a && exmem_is_halt_a) halt_o <= 1'b1;

            // ---- ALU phase control ----
            if (flush) begin
                ex_phase <= 1'b0;
            end else if (stall_alu_phase) begin
                ex_phase <= 1'b1;
                ex_result_a_saved <= ex_result_a;
                ex_rs2_a_saved    <= fwd_rs2_a;
            end else begin
                ex_phase <= 1'b0;
            end

            // ---- EX/MEM (valid/control only; payload in unconditional block below) ----
            if (stall_muldiv || stall_alu_phase) begin
                exmem_valid_a <= 1'b0;
            end else begin
                exmem_valid_a     <= idex_valid_a;
                exmem_rd_we_a     <= idex_rd_we_a && !idex_is_trap_a && !idex_is_halt_a;
                exmem_mem_read_a  <= idex_mem_read_a;
                exmem_mem_write_a <= idex_mem_write_a && !idex_is_trap_a && !idex_is_halt_a;
                exmem_is_halt_a   <= idex_is_halt_a;
                exmem_is_trap_a   <= idex_is_trap_a;
            end

            // ---- ID/EX ----
            if (stall_muldiv || stall_alu_phase) begin
                // hold
            end else if (flush || stall_load) begin
                idex_valid_a <= 1'b0;
                idex_valid_b <= 1'b0;
            end else begin
                idex_valid_a      <= 1'b1;
                idex_pc_a         <= pc_q;
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
                idex_cf_a         <= id_is_branch_a ? CF_BRANCH :
                                     id_is_jal_a    ? CF_JAL :
                                     id_is_jalr_a   ? CF_JALR : CF_NONE;
                idex_is_muldiv_a  <= id_is_muldiv_a;
                idex_wb_sel_a     <= id_wb_sel_a;
                idex_is_halt_a    <= id_is_halt_a;
                idex_is_trap_a    <= id_is_trap_a;
                idex_amo_type_a   <= id_is_lr_a  ? AMO_LR :
                                     id_is_sc_a  ? AMO_SC :
                                     id_is_amo_a ? AMO_RMW : AMO_NONE;
                idex_amo_funct5_a <= id_amo_funct5_a;
                idex_compressed_a <= if_compressed_a;

                idex_valid_b      <= can_dual_issue;
                idex_imm_b        <= id_imm_b;
                idex_rd_b         <= id_rd_b;
                idex_rs1_b        <= id_rs1_b;
                idex_rs2_b        <= id_rs2_b;
                idex_alu_op_b     <= id_alu_op_b;
                idex_alu_src_imm_b<= id_alu_src_imm_b;
                idex_rd_we_b      <= id_rd_we_b;
            end

            // ---- PC update ----
            // 3-stage front end: fetch+decode+issue all happen in this cycle,
            // so PC advances by exactly what was issued. A slot-B instruction
            // that cannot dual-issue is simply refetched next cycle as slot A
            // (no rotation state needed).
            if (redirect) begin
                pc_q <= redirect_target;
            end else if (!stall_pipe) begin
                pc_q <= can_dual_issue ? if_pc_after_b : if_next_pc;
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

    // ================================================================
    // EXMEM payload -- unconditional write (don't-care when valid==0)
    // Written every cycle so synthesizer can use plain DFF instead of DFFE.
    // ================================================================
    always_ff @(posedge clk) begin
        exmem_result_a    <= (idex_wb_sel_a == WB_PC4) ? ex_pc4_a :
                             (ex_phase ? ex_result_a_saved : ex_result_a);
        exmem_rs2_val_a   <= ex_phase ? ex_rs2_a_saved : fwd_rs2_a;
        exmem_rd_a        <= idex_rd_a;
        exmem_funct3_a    <= idex_funct3_a;
        exmem_amo_type_a  <= idex_amo_type_a;
        exmem_amo_funct5_a<= idex_amo_funct5_a;
    end
endmodule
