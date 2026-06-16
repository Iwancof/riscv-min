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
    // ================================================================
    // Opcodes
    // ================================================================
    localparam [6:0] OP_LUI    = 7'b0110111, OP_AUIPC  = 7'b0010111,
                     OP_JAL    = 7'b1101111, OP_JALR   = 7'b1100111,
                     OP_BRANCH = 7'b1100011, OP_LOAD   = 7'b0000011,
                     OP_STORE  = 7'b0100011, OP_IMM    = 7'b0010011,
                     OP_REG    = 7'b0110011, OP_FENCE  = 7'b0001111,
                     OP_SYSTEM = 7'b1110011;

    localparam [1:0] WB_EX = 2'b00, WB_MEM = 2'b01, WB_PC4 = 2'b10;

    // ================================================================
    // Register file  (x0 hardwired to 0)
    // ================================================================
    logic [31:0] regs [1:31];

    // ================================================================
    // Pipeline registers
    // ================================================================
    // --- IF/ID ---
    logic [31:0] ifid_pc, ifid_instr;
    logic        ifid_valid;
    logic        ifid_compressed; // was this a compressed instruction? (PC+2 vs PC+4)

    // --- ID/EX ---
    logic [31:0] idex_pc, idex_rs1_val, idex_rs2_val, idex_imm;
    logic [4:0]  idex_rd, idex_rs1, idex_rs2;
    logic [3:0]  idex_alu_op;
    logic [2:0]  idex_funct3;
    logic        idex_alu_src_imm, idex_alu_src_pc;
    logic        idex_mem_read, idex_mem_write, idex_rd_we;
    logic        idex_is_branch, idex_is_jal, idex_is_jalr;
    logic        idex_is_muldiv, idex_is_halt, idex_is_trap;
    logic [1:0]  idex_wb_sel;
    logic        idex_valid;
    logic        idex_compressed;

    // --- EX/MEM ---
    logic [31:0] exmem_result, exmem_rs2_val, exmem_pc4;
    logic [4:0]  exmem_rd;
    logic [2:0]  exmem_funct3;
    logic        exmem_rd_we, exmem_mem_read, exmem_mem_write;
    logic [1:0]  exmem_wb_sel;
    logic        exmem_is_halt, exmem_is_trap, exmem_valid;

    // --- MEM/WB ---
    logic [31:0] memwb_rd_data;
    logic [4:0]  memwb_rd;
    logic        memwb_rd_we, memwb_is_halt, memwb_is_trap, memwb_valid;

    // ================================================================
    // Divider state
    // ================================================================
    logic        div_active;
    logic [5:0]  div_cnt;
    logic [31:0] div_quot, div_rem, div_dvsr;
    logic        div_nq, div_nr, div_bz;
    logic [31:0] div_raw_dividend;

    wire [32:0] div_trial = {div_rem, div_quot[31]} - {1'b0, div_dvsr};
    wire        div_ready = div_active && (div_cnt == 6'd0);

    // ================================================================
    // RV32C Decompressor — map 16-bit compressed instructions to 32-bit
    // ================================================================
    function automatic [31:0] decompress(input [15:0] ci);
        // Pre-declare all temporaries at function scope (Verilator-compatible)
        logic [31:0] out;
        logic [4:0]  rd_c, rs1_c, rs2_c;  // compact register decoded
        logic [4:0]  rd_f, rs2_f;          // full-range register
        logic [4:0]  shamt;
        logic [5:0]  imm6;
        logic [6:0]  off7;
        logic [7:0]  off8;
        logic [8:0]  off9;
        logic [9:0]  nzuimm10;
        logic [11:0] imm12;
        logic [10:0] joff11;   // C.J/C.JAL offset[11:1] (11 bits, bit 0 implicit)
        logic [12:0] bimm13;
        logic [20:0] jimm21;

        out = 32'h0000_0000; // default: illegal

        case (ci[1:0])
        // ============================================================
        // Quadrant 0
        // ============================================================
        2'b00: begin
            rd_c  = {2'b01, ci[4:2]};
            rs1_c = {2'b01, ci[9:7]};
            rs2_c = {2'b01, ci[4:2]};
            case (ci[15:13])
            3'b000: begin // C.ADDI4SPN
                nzuimm10 = {ci[10:7], ci[12:11], ci[5], ci[6], 2'b00};
                if (nzuimm10 != 10'd0) begin
                    imm12 = {2'b0, nzuimm10};
                    out = {imm12, 5'd2, 3'b000, rd_c, 7'b0010011};
                end
            end
            3'b010: begin // C.LW
                off7 = {ci[5], ci[12:10], ci[6], 2'b00};
                out = {5'b0, off7, rs1_c, 3'b010, rd_c, 7'b0000011};
            end
            3'b110: begin // C.SW
                off7 = {ci[5], ci[12:10], ci[6], 2'b00};
                out = {5'b0, off7[6:5], rs2_c, rs1_c, 3'b010, off7[4:0], 7'b0100011};
            end
            default: ;
            endcase
        end

        // ============================================================
        // Quadrant 1
        // ============================================================
        2'b01: begin
            rd_c  = {2'b01, ci[9:7]};
            rs2_c = {2'b01, ci[4:2]};
            rd_f  = ci[11:7];
            imm6  = {ci[12], ci[6:2]};

            case (ci[15:13])
            3'b000: begin // C.NOP / C.ADDI
                imm12 = {{6{imm6[5]}}, imm6};
                out = {imm12, rd_f, 3'b000, rd_f, 7'b0010011};
            end
            3'b001: begin // C.JAL (RV32)
                joff11 = {ci[12], ci[8], ci[10:9], ci[6], ci[7], ci[2], ci[11], ci[5:3]};
                jimm21 = {{9{joff11[10]}}, joff11, 1'b0};
                out = {jimm21[20], jimm21[10:1], jimm21[11], jimm21[19:12], 5'd1, 7'b1101111};
            end
            3'b010: begin // C.LI
                imm12 = {{6{imm6[5]}}, imm6};
                out = {imm12, 5'd0, 3'b000, rd_f, 7'b0010011};
            end
            3'b011: begin // C.ADDI16SP / C.LUI
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
            3'b100: begin // ALU group
                case (ci[11:10])
                2'b00: begin // C.SRLI
                    shamt = ci[6:2];
                    out = {7'b0000000, shamt, rd_c, 3'b101, rd_c, 7'b0010011};
                end
                2'b01: begin // C.SRAI
                    shamt = ci[6:2];
                    out = {7'b0100000, shamt, rd_c, 3'b101, rd_c, 7'b0010011};
                end
                2'b10: begin // C.ANDI
                    imm12 = {{6{imm6[5]}}, imm6};
                    out = {imm12, rd_c, 3'b111, rd_c, 7'b0010011};
                end
                2'b11: begin // register-register
                    case ({ci[12], ci[6:5]})
                    3'b000: out = {7'b0100000, rs2_c, rd_c, 3'b000, rd_c, 7'b0110011}; // SUB
                    3'b001: out = {7'b0000000, rs2_c, rd_c, 3'b100, rd_c, 7'b0110011}; // XOR
                    3'b010: out = {7'b0000000, rs2_c, rd_c, 3'b110, rd_c, 7'b0110011}; // OR
                    3'b011: out = {7'b0000000, rs2_c, rd_c, 3'b111, rd_c, 7'b0110011}; // AND
                    default: ;
                    endcase
                end
                endcase
            end
            3'b101: begin // C.J
                joff11 = {ci[12], ci[8], ci[10:9], ci[6], ci[7], ci[2], ci[11], ci[5:3]};
                jimm21 = {{9{joff11[10]}}, joff11, 1'b0};
                out = {jimm21[20], jimm21[10:1], jimm21[11], jimm21[19:12], 5'd0, 7'b1101111};
            end
            3'b110: begin // C.BEQZ
                off9 = {ci[12], ci[6:5], ci[2], ci[11:10], ci[4:3], 1'b0};
                bimm13 = {{4{off9[8]}}, off9};
                out = {bimm13[12], bimm13[10:5], 5'd0, rd_c, 3'b000, bimm13[4:1], bimm13[11], 7'b1100011};
            end
            3'b111: begin // C.BNEZ
                off9 = {ci[12], ci[6:5], ci[2], ci[11:10], ci[4:3], 1'b0};
                bimm13 = {{4{off9[8]}}, off9};
                out = {bimm13[12], bimm13[10:5], 5'd0, rd_c, 3'b001, bimm13[4:1], bimm13[11], 7'b1100011};
            end
            endcase
        end

        // ============================================================
        // Quadrant 2
        // ============================================================
        2'b10: begin
            rd_f  = ci[11:7];
            rs2_f = ci[6:2];
            case (ci[15:13])
            3'b000: begin // C.SLLI
                shamt = ci[6:2];
                if (rd_f != 5'd0)
                    out = {7'b0000000, shamt, rd_f, 3'b001, rd_f, 7'b0010011};
            end
            3'b010: begin // C.LWSP
                off8 = {ci[3:2], ci[12], ci[6:4], 2'b00};
                if (rd_f != 5'd0)
                    out = {4'b0, off8, 5'd2, 3'b010, rd_f, 7'b0000011};
            end
            3'b100: begin // C.JR / C.MV / C.EBREAK / C.JALR / C.ADD
                if (ci[12] == 1'b0) begin
                    if (rs2_f == 5'd0) begin // C.JR
                        if (rd_f != 5'd0)
                            out = {12'b0, rd_f, 3'b000, 5'd0, 7'b1100111};
                    end else begin // C.MV
                        out = {7'b0000000, rs2_f, 5'd0, 3'b000, rd_f, 7'b0110011};
                    end
                end else begin
                    if (rs2_f == 5'd0) begin
                        if (rd_f == 5'd0) // C.EBREAK
                            out = 32'h00100073;
                        else // C.JALR
                            out = {12'b0, rd_f, 3'b000, 5'd1, 7'b1100111};
                    end else begin // C.ADD
                        out = {7'b0000000, rs2_f, rd_f, 3'b000, rd_f, 7'b0110011};
                    end
                end
            end
            3'b110: begin // C.SWSP
                off8 = {ci[8:7], ci[12:9], 2'b00};
                out = {4'b0, off8[7:5], rs2_f, 5'd2, 3'b010, off8[4:0], 7'b0100011};
            end
            default: ;
            endcase
        end

        default: ; // ci[1:0]==11 should never be called
        endcase

        decompress = out;
    endfunction

    // ================================================================
    // IF stage — supports 2-byte aligned PC with half-word buffer
    // ================================================================
    logic [31:0] pc_q;
    logic [15:0] hwbuf;        // half-word buffer for cross-boundary 32-bit instrs
    logic        hwbuf_valid;  // hwbuf holds lower 16 bits of a spanning instr

    // Always word-aligned memory access
    assign imem_addr_o = {pc_q[31:2], 2'b00};
    assign pc_o        = pc_q;

    // IF stage fetch / decompress logic
    logic [31:0] if_instr;     // decoded 32-bit instruction
    logic        if_is_compressed;
    logic        if_stall_xword; // stall for cross-word-boundary fetch

    always_comb begin
        if_instr        = 32'h0000_0013; // NOP default
        if_is_compressed = 1'b0;
        if_stall_xword  = 1'b0;

        if (hwbuf_valid) begin
            // We have the lower 16 bits buffered from last cycle;
            // upper half of current word provides upper 16 bits
            if_instr = {imem_rdata_i[15:0], hwbuf};
            if_is_compressed = 1'b0; // it's a full 32-bit instruction
        end else if (pc_q[1] == 1'b0) begin
            // PC is word-aligned: instruction at bits [15:0] or [31:0]
            if (imem_rdata_i[1:0] != 2'b11) begin
                // Compressed instruction in lower half
                if_instr = decompress(imem_rdata_i[15:0]);
                if_is_compressed = 1'b1;
            end else begin
                // Full 32-bit instruction, entirely within this word
                if_instr = imem_rdata_i;
                if_is_compressed = 1'b0;
            end
        end else begin
            // PC is halfword-aligned: instruction at bits [31:16]
            if (imem_rdata_i[17:16] != 2'b11) begin
                // Compressed instruction in upper half
                if_instr = decompress(imem_rdata_i[31:16]);
                if_is_compressed = 1'b1;
            end else begin
                // 32-bit instruction crosses word boundary → need next word
                // Stall this cycle; buffer the lower 16 bits
                if_stall_xword = 1'b1;
                if_instr = 32'h0000_0013; // NOP placeholder (won't be used)
                if_is_compressed = 1'b0;
            end
        end
    end

    // ================================================================
    // ID stage — decode
    // ================================================================
    wire [6:0] id_opcode = ifid_instr[6:0];
    wire [4:0] id_rd     = ifid_instr[11:7];
    wire [2:0] id_funct3 = ifid_instr[14:12];
    wire       id_f7b5   = ifid_instr[30];
    wire [6:0] id_funct7 = ifid_instr[31:25];

    logic [4:0] id_rs1, id_rs2;
    always_comb begin
        id_rs1 = ifid_instr[19:15];
        id_rs2 = ifid_instr[24:20];
        case (id_opcode)
            OP_LUI, OP_AUIPC, OP_JAL: begin id_rs1 = 5'd0; id_rs2 = 5'd0; end
            OP_JALR, OP_LOAD, OP_IMM:  id_rs2 = 5'd0;
            default: ;
        endcase
    end

    // Immediates
    wire [31:0] imm_i = {{20{ifid_instr[31]}}, ifid_instr[31:20]};
    wire [31:0] imm_s = {{20{ifid_instr[31]}}, ifid_instr[31:25], ifid_instr[11:7]};
    wire [31:0] imm_b = {{19{ifid_instr[31]}}, ifid_instr[31], ifid_instr[7],
                          ifid_instr[30:25], ifid_instr[11:8], 1'b0};
    wire [31:0] imm_u = {ifid_instr[31:12], 12'b0};
    wire [31:0] imm_j = {{11{ifid_instr[31]}}, ifid_instr[31], ifid_instr[19:12],
                          ifid_instr[20], ifid_instr[30:21], 1'b0};

    logic [31:0] id_imm;
    always_comb begin
        case (id_opcode)
            OP_LUI, OP_AUIPC:         id_imm = imm_u;
            OP_JAL:                    id_imm = imm_j;
            OP_BRANCH:                 id_imm = imm_b;
            OP_STORE:                  id_imm = imm_s;
            default:                   id_imm = imm_i;
        endcase
    end

    // Control signals
    logic [3:0]  id_alu_op;
    logic        id_alu_src_imm, id_alu_src_pc;
    logic        id_mem_read, id_mem_write, id_rd_we;
    logic        id_is_branch, id_is_jal, id_is_jalr;
    logic        id_is_muldiv, id_is_halt, id_is_trap;
    logic [1:0]  id_wb_sel;

    always_comb begin
        id_alu_op      = 4'b0000;
        id_alu_src_imm = 1'b0;
        id_alu_src_pc  = 1'b0;
        id_mem_read    = 1'b0;
        id_mem_write   = 1'b0;
        id_rd_we       = 1'b0;
        id_is_branch   = 1'b0;
        id_is_jal      = 1'b0;
        id_is_jalr     = 1'b0;
        id_is_muldiv   = 1'b0;
        id_is_halt     = 1'b0;
        id_is_trap     = 1'b0;
        id_wb_sel      = WB_EX;

        case (id_opcode)
            OP_LUI: begin
                id_alu_src_imm = 1'b1;
                id_rd_we       = 1'b1;
            end
            OP_AUIPC: begin
                id_alu_src_imm = 1'b1;
                id_alu_src_pc  = 1'b1;
                id_rd_we       = 1'b1;
            end
            OP_JAL: begin
                id_is_jal = 1'b1;
                id_rd_we  = 1'b1;
                id_wb_sel = WB_PC4;
            end
            OP_JALR: begin
                id_alu_src_imm = 1'b1;
                id_is_jalr     = 1'b1;
                id_rd_we       = 1'b1;
                id_wb_sel      = WB_PC4;
            end
            OP_BRANCH: begin
                id_alu_op    = 4'b1000;
                id_is_branch = 1'b1;
            end
            OP_LOAD: begin
                id_alu_src_imm = 1'b1;
                id_mem_read    = 1'b1;
                id_rd_we       = 1'b1;
                id_wb_sel      = WB_MEM;
            end
            OP_STORE: begin
                id_alu_src_imm = 1'b1;
                id_mem_write   = 1'b1;
            end
            OP_IMM: begin
                id_alu_op      = (id_funct3 == 3'b101) ? {id_f7b5, id_funct3} : {1'b0, id_funct3};
                id_alu_src_imm = 1'b1;
                id_rd_we       = 1'b1;
            end
            OP_REG: begin
                if (id_funct7 == 7'b0000001) begin
                    id_is_muldiv = 1'b1;
                    id_rd_we     = 1'b1;
                end else begin
                    id_alu_op = {id_f7b5, id_funct3};
                    id_rd_we  = 1'b1;
                end
            end
            OP_FENCE: ; // NOP
            OP_SYSTEM: begin
                if (ifid_instr == 32'h00100073)
                    id_is_halt = 1'b1;
                else
                    id_is_trap = 1'b1;
            end
            default: id_is_trap = 1'b1;
        endcase
    end

    // Register file read with WB write-through
    wire [31:0] rf_rs1 = (id_rs1 == 5'd0) ? 32'b0 : regs[id_rs1];
    wire [31:0] rf_rs2 = (id_rs2 == 5'd0) ? 32'b0 : regs[id_rs2];

    wire wt_rs1 = memwb_valid && memwb_rd_we && (memwb_rd != 5'd0) && (memwb_rd == id_rs1);
    wire wt_rs2 = memwb_valid && memwb_rd_we && (memwb_rd != 5'd0) && (memwb_rd == id_rs2);
    wire [31:0] id_rs1_val = wt_rs1 ? memwb_rd_data : rf_rs1;
    wire [31:0] id_rs2_val = wt_rs2 ? memwb_rd_data : rf_rs2;

    // Hazard detection (load-use)
    wire id_uses_rs1 = (id_opcode == OP_REG || id_opcode == OP_IMM || id_opcode == OP_LOAD ||
                        id_opcode == OP_STORE || id_opcode == OP_BRANCH || id_opcode == OP_JALR);
    wire id_uses_rs2 = (id_opcode == OP_REG || id_opcode == OP_STORE || id_opcode == OP_BRANCH);

    wire load_use = idex_valid && idex_mem_read && (idex_rd != 5'd0) && ifid_valid &&
                    ((id_uses_rs1 && idex_rd == id_rs1) ||
                     (id_uses_rs2 && idex_rd == id_rs2));

    // ================================================================
    // Forwarding
    // ================================================================
    wire [31:0] exmem_fwd = (exmem_wb_sel == WB_PC4) ? exmem_pc4 : exmem_result;

    wire fwd_em_rs1 = exmem_valid && exmem_rd_we && (exmem_rd != 5'd0) && (exmem_rd == idex_rs1);
    wire fwd_em_rs2 = exmem_valid && exmem_rd_we && (exmem_rd != 5'd0) && (exmem_rd == idex_rs2);
    wire fwd_mw_rs1 = memwb_valid && memwb_rd_we && (memwb_rd != 5'd0) && (memwb_rd == idex_rs1) && !fwd_em_rs1;
    wire fwd_mw_rs2 = memwb_valid && memwb_rd_we && (memwb_rd != 5'd0) && (memwb_rd == idex_rs2) && !fwd_em_rs2;

    wire [31:0] fwd_rs1 = fwd_em_rs1 ? exmem_fwd : (fwd_mw_rs1 ? memwb_rd_data : idex_rs1_val);
    wire [31:0] fwd_rs2 = fwd_em_rs2 ? exmem_fwd : (fwd_mw_rs2 ? memwb_rd_data : idex_rs2_val);

    // ================================================================
    // EX stage — ALU
    // ================================================================
    wire [31:0] alu_a = idex_alu_src_pc ? idex_pc : fwd_rs1;
    wire [31:0] alu_b = idex_alu_src_imm ? idex_imm : fwd_rs2;

    wire        alu_do_sub = (idex_alu_op == 4'b1000) || (idex_alu_op == 4'b0010) || (idex_alu_op == 4'b0011);
    wire [32:0] alu_ext = {1'b0, alu_a} + {1'b0, alu_do_sub ? ~alu_b : alu_b} + {32'b0, alu_do_sub};
    wire [31:0] alu_sum   = alu_ext[31:0];
    wire        alu_carry = alu_ext[32];
    wire        alu_lt    = (alu_a[31] != alu_b[31]) ? alu_a[31] : alu_sum[31];
    wire        alu_ltu   = !alu_carry;

    logic [31:0] alu_result;
    always_comb begin
        case (idex_alu_op)
            4'b0000, 4'b1000: alu_result = alu_sum;
            4'b0001:          alu_result = alu_a << alu_b[4:0];
            4'b0010:          alu_result = {31'b0, alu_lt};
            4'b0011:          alu_result = {31'b0, alu_ltu};
            4'b0100:          alu_result = alu_a ^ alu_b;
            4'b0101:          alu_result = alu_a >> alu_b[4:0];
            4'b1101:          alu_result = $signed(alu_a) >>> alu_b[4:0];
            4'b0110:          alu_result = alu_a | alu_b;
            4'b0111:          alu_result = alu_a & alu_b;
            default:          alu_result = alu_sum;
        endcase
    end

    // Branch
    logic branch_taken;
    always_comb begin
        branch_taken = 1'b0;
        if (idex_is_branch) begin
            case (idex_funct3)
                3'b000:  branch_taken = (alu_sum == 32'b0);
                3'b001:  branch_taken = (alu_sum != 32'b0);
                3'b100:  branch_taken = alu_lt;
                3'b101:  branch_taken = !alu_lt;
                3'b110:  branch_taken = alu_ltu;
                3'b111:  branch_taken = !alu_ltu;
                default: ;
            endcase
        end
    end

    wire [31:0] branch_target = idex_pc + idex_imm;
    wire [31:0] ex_pc4 = idex_pc + (idex_compressed ? 32'd2 : 32'd4);

    wire redirect = idex_valid && !idex_is_trap && !idex_is_halt &&
                    (idex_is_jal || idex_is_jalr || branch_taken);
    wire [31:0] redirect_target = idex_is_jalr ? {alu_result[31:1], 1'b0} : branch_target;

    // M extension — multiply (combinational, single cycle)
    wire        mul_a_signed = (idex_funct3 == 3'b001 || idex_funct3 == 3'b010);
    wire        mul_b_signed = (idex_funct3 == 3'b001);
    wire signed [32:0] mul_op_a = {mul_a_signed ? fwd_rs1[31] : 1'b0, fwd_rs1};
    wire signed [32:0] mul_op_b = {mul_b_signed ? fwd_rs2[31] : 1'b0, fwd_rs2};
    wire signed [65:0] mul_prod = mul_op_a * mul_op_b;
    wire [31:0] mul_result = (idex_funct3[1:0] == 2'b00) ? mul_prod[31:0] : mul_prod[63:32];

    // M extension — divide
    wire idex_is_mul = idex_is_muldiv && !idex_funct3[2];
    wire idex_is_div = idex_is_muldiv && idex_funct3[2];
    wire start_div   = idex_valid && idex_is_div && !div_active;

    wire        div_signed = !idex_funct3[0];
    wire [31:0] div_abs_a  = (div_signed && fwd_rs1[31]) ? (~fwd_rs1 + 32'd1) : fwd_rs1;
    wire [31:0] div_abs_b  = (div_signed && fwd_rs2[31]) ? (~fwd_rs2 + 32'd1) : fwd_rs2;

    wire [31:0] div_q_final = div_bz ? 32'hFFFFFFFF : (div_nq ? (~div_quot + 32'd1) : div_quot);
    wire [31:0] div_r_final = div_bz ? div_raw_dividend : (div_nr ? (~div_rem + 32'd1) : div_rem);
    wire [31:0] div_result  = idex_funct3[1] ? div_r_final : div_q_final;

    // EX result mux
    wire [31:0] ex_result = idex_is_mul ? mul_result :
                            (idex_is_div && div_ready) ? div_result : alu_result;

    // ================================================================
    // Pipeline control
    // ================================================================
    wire stall_div  = idex_valid && idex_is_div && !div_ready;
    wire stall_load = load_use;
    wire stall_xword = if_stall_xword && !flush;
    wire stall_pipe = stall_div || stall_load;
    wire flush      = redirect || (idex_valid && (idex_is_trap || idex_is_halt));

    wire halted = halt_o || trap_o;

    // ================================================================
    // MEM stage — load/store alignment
    // ================================================================
    wire [1:0] mem_off = exmem_result[1:0];

    assign dmem_addr_o = {exmem_result[31:2], 2'b00};

    // Load data extraction
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
        case (exmem_funct3)
            3'b000:  load_data = {{24{load_byte[7]}}, load_byte};
            3'b001:  load_data = {{16{load_half[15]}}, load_half};
            3'b010:  load_data = dmem_rdata_i;
            3'b100:  load_data = {24'b0, load_byte};
            3'b101:  load_data = {16'b0, load_half};
            default: load_data = dmem_rdata_i;
        endcase
    end

    // Store data/strobe
    logic [31:0] store_data;
    always_comb begin
        case (mem_off)
            2'b00:   store_data = exmem_rs2_val;
            2'b01:   store_data = {exmem_rs2_val[23:0], 8'b0};
            2'b10:   store_data = {exmem_rs2_val[15:0], 16'b0};
            default: store_data = {exmem_rs2_val[7:0],  24'b0};
        endcase
    end

    logic [3:0] store_strobe;
    always_comb begin
        store_strobe = 4'b0000;
        if (exmem_valid && exmem_mem_write) begin
            case (exmem_funct3)
                3'b000:  store_strobe = 4'b0001 << mem_off;
                3'b001:  store_strobe = 4'b0011 << mem_off;
                3'b010:  store_strobe = 4'b1111;
                default: ;
            endcase
        end
    end

    assign dmem_wdata_o = store_data;
    assign dmem_wstrb_o = store_strobe;

    // MEM result mux
    wire [31:0] mem_rd_data = (exmem_wb_sel == WB_MEM) ? load_data :
                              (exmem_wb_sel == WB_PC4) ? exmem_pc4 : exmem_result;

    // ================================================================
    // Sequential logic
    // ================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pc_q        <= RESET_PC;
            ifid_valid  <= 1'b0;
            idex_valid  <= 1'b0;
            exmem_valid <= 1'b0;
            memwb_valid <= 1'b0;
            trap_o      <= 1'b0;
            halt_o      <= 1'b0;
            div_active  <= 1'b0;
            hwbuf_valid <= 1'b0;
            for (int i = 1; i < 32; i++) regs[i] <= 32'b0;
        end else if (halted) begin
            // frozen
        end else begin
            // ---- WB: register file write ----
            if (memwb_valid && memwb_rd_we && memwb_rd != 5'd0)
                regs[memwb_rd] <= memwb_rd_data;

            if (memwb_valid && memwb_is_trap) trap_o <= 1'b1;
            if (memwb_valid && memwb_is_halt) halt_o <= 1'b1;

            // ---- MEM/WB update (always) ----
            memwb_valid   <= exmem_valid && !exmem_is_trap && !exmem_is_halt ? 1'b1 :
                             exmem_valid;
            memwb_rd      <= exmem_rd;
            memwb_rd_we   <= exmem_valid ? exmem_rd_we : 1'b0;
            memwb_rd_data <= mem_rd_data;
            memwb_is_halt <= exmem_valid && exmem_is_halt;
            memwb_is_trap <= exmem_valid && exmem_is_trap;
            memwb_valid   <= exmem_valid;

            // ---- EX/MEM update ----
            if (stall_div) begin
                exmem_valid <= 1'b0;
            end else begin
                exmem_valid     <= idex_valid;
                exmem_result    <= ex_result;
                exmem_rs2_val   <= fwd_rs2;
                exmem_pc4       <= ex_pc4;
                exmem_rd        <= idex_rd;
                exmem_funct3    <= idex_funct3;
                exmem_rd_we     <= idex_rd_we && !idex_is_trap && !idex_is_halt;
                exmem_mem_read  <= idex_mem_read;
                exmem_mem_write <= idex_mem_write && !idex_is_trap && !idex_is_halt;
                exmem_wb_sel    <= idex_wb_sel;
                exmem_is_halt   <= idex_is_halt;
                exmem_is_trap   <= idex_is_trap;
            end

            // ---- ID/EX update ----
            if (stall_div) begin
                // hold
            end else if (flush || stall_load) begin
                idex_valid <= 1'b0;
            end else begin
                idex_valid      <= ifid_valid;
                idex_pc         <= ifid_pc;
                idex_rs1_val    <= id_rs1_val;
                idex_rs2_val    <= id_rs2_val;
                idex_imm        <= id_imm;
                idex_rd         <= id_rd;
                idex_rs1        <= id_rs1;
                idex_rs2        <= id_rs2;
                idex_alu_op     <= id_alu_op;
                idex_funct3     <= id_funct3;
                idex_alu_src_imm<= id_alu_src_imm;
                idex_alu_src_pc <= id_alu_src_pc;
                idex_mem_read   <= id_mem_read;
                idex_mem_write  <= id_mem_write;
                idex_rd_we      <= id_rd_we;
                idex_is_branch  <= id_is_branch;
                idex_is_jal     <= id_is_jal;
                idex_is_jalr    <= id_is_jalr;
                idex_is_muldiv  <= id_is_muldiv;
                idex_wb_sel     <= id_wb_sel;
                idex_is_halt    <= id_is_halt;
                idex_is_trap    <= id_is_trap;
                idex_compressed <= ifid_compressed;
            end

            // ---- IF/ID update ----
            if (stall_pipe) begin
                // hold
            end else if (flush) begin
                ifid_valid <= 1'b0;
                hwbuf_valid <= 1'b0;
            end else if (stall_xword) begin
                // Cross-word-boundary: buffer upper 16 bits, emit bubble
                hwbuf       <= imem_rdata_i[31:16];
                hwbuf_valid <= 1'b1;
                ifid_valid  <= 1'b0;
            end else begin
                ifid_valid      <= 1'b1;
                ifid_pc         <= pc_q;
                ifid_instr      <= if_instr;
                ifid_compressed <= if_is_compressed;
                if (hwbuf_valid)
                    hwbuf_valid <= 1'b0;
            end

            // ---- PC update ----
            if (redirect) begin
                pc_q <= redirect_target;
                hwbuf_valid <= 1'b0;
            end else if (!stall_pipe) begin
                if (stall_xword) begin
                    // Move PC to next word (the word containing upper half)
                    pc_q <= {pc_q[31:2] + 30'd1, 2'b00};
                end else if (hwbuf_valid) begin
                    // Cross-boundary instr started at prev_word+2, length 4.
                    // During stall we advanced PC to next word. Now advance +2
                    // to land at prev_word + 2 + 4 = next_word + 2.
                    pc_q <= pc_q + 32'd2;
                end else begin
                    pc_q <= pc_q + (if_is_compressed ? 32'd2 : 32'd4);
                end
            end

            // ---- Divider ----
            if (start_div) begin
                div_active       <= 1'b1;
                div_cnt          <= 6'd32;
                div_quot         <= div_abs_a;
                div_rem          <= 32'b0;
                div_dvsr         <= div_abs_b;
                div_nq           <= div_signed && (fwd_rs1[31] ^ fwd_rs2[31]) && (fwd_rs2 != 32'b0);
                div_nr           <= div_signed && fwd_rs1[31];
                div_bz           <= (fwd_rs2 == 32'b0);
                div_raw_dividend <= fwd_rs1;
            end else if (div_active && div_cnt != 6'd0) begin
                if (!div_trial[32]) begin
                    div_rem  <= div_trial[31:0];
                    div_quot <= {div_quot[30:0], 1'b1};
                end else begin
                    div_rem  <= {div_rem[30:0], div_quot[31]};
                    div_quot <= {div_quot[30:0], 1'b0};
                end
                div_cnt <= div_cnt - 6'd1;
            end else if (div_ready) begin
                div_active <= 1'b0;
            end
        end
    end
endmodule
