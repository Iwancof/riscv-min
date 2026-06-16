.text
.globl _start

_start:
    # --- ADD / SUB ---
    addi x1, x0, 10
    addi x2, x0, 3
    add  x3, x1, x2       # 13
    addi x4, x0, 13
    bne  x3, x4, fail

    sub  x3, x1, x2       # 7
    addi x4, x0, 7
    bne  x3, x4, fail

    # --- AND / OR / XOR ---
    li   x1, 0xFF
    li   x2, 0x0F
    and  x3, x1, x2       # 0x0F
    bne  x3, x2, fail

    or   x3, x1, x2       # 0xFF
    bne  x3, x1, fail

    xor  x3, x1, x2       # 0xF0
    addi x4, x0, 0
    ori  x4, x4, 0xF0     # not great but works for small imm
    li   x5, 0xF0
    bne  x3, x5, fail

    # --- SLT / SLTU ---
    addi x1, x0, -1       # 0xFFFFFFFF (signed: -1)
    addi x2, x0, 1
    slt  x3, x1, x2       # signed: -1 < 1 → 1
    addi x4, x0, 1
    bne  x3, x4, fail

    sltu x3, x1, x2       # unsigned: 0xFFFFFFFF < 1 → 0
    bne  x3, x0, fail

    sltu x3, x2, x1       # unsigned: 1 < 0xFFFFFFFF → 1
    bne  x3, x4, fail

    # --- SLTI / SLTIU ---
    addi x1, x0, 5
    slti x3, x1, 10       # 5 < 10 → 1
    bne  x3, x4, fail

    slti x3, x1, 3        # 5 < 3 → 0
    bne  x3, x0, fail

    sltiu x3, x1, 10      # 5 <u 10 → 1
    bne  x3, x4, fail

    # --- ANDI / ORI / XORI ---
    li   x1, 0xFF
    andi x3, x1, 0x0F     # 0x0F
    addi x4, x0, 0x0F
    bne  x3, x4, fail

    ori  x3, x0, 0x55     # 0x55
    addi x4, x0, 0x55
    bne  x3, x4, fail

    xori x3, x1, -1       # NOT 0xFF = 0xFFFFFF00
    li   x4, 0xFFFFFF00
    bne  x3, x4, fail

    # --- Shifts (register) ---
    addi x1, x0, 1
    addi x2, x0, 8
    sll  x3, x1, x2       # 1 << 8 = 256
    li   x4, 256
    bne  x3, x4, fail

    li   x1, 0x100
    addi x2, x0, 4
    srl  x3, x1, x2       # 0x100 >> 4 = 0x10
    addi x4, x0, 0x10
    bne  x3, x4, fail

    addi x1, x0, -8       # 0xFFFFFFF8
    addi x2, x0, 1
    sra  x3, x1, x2       # arith right shift: -4
    addi x4, x0, -4
    bne  x3, x4, fail

    # --- Shifts (immediate) ---
    addi x1, x0, 1
    slli x3, x1, 16       # 0x10000
    li   x4, 0x10000
    bne  x3, x4, fail

    srli x3, x4, 8        # 0x100
    li   x5, 0x100
    bne  x3, x5, fail

    addi x1, x0, -16
    srai x3, x1, 2        # -4
    addi x4, x0, -4
    bne  x3, x4, fail

    # --- LUI / AUIPC ---
    lui  x1, 0x12345000
    li   x2, 0x12345000
    bne  x1, x2, fail

    auipc x3, 0
    # x3 should be the PC of the auipc instruction

    # --- Forwarding stress test ---
    addi x1, x0, 1        # x1 = 1
    add  x2, x1, x1       # x2 = 2  (forward from EX/MEM)
    add  x3, x2, x1       # x3 = 3  (forward from EX/MEM for x2, MEM/WB for x1)
    add  x4, x3, x2       # x4 = 5
    addi x5, x0, 5
    bne  x4, x5, fail

    # --- Load-use forwarding ---
    addi x1, x0, 42
    sw   x1, 0(x0)
    lw   x2, 0(x0)        # load x2 = 42
    addi x3, x2, 1        # load-use hazard → stall 1 cycle, x3 = 43
    addi x4, x0, 43
    bne  x3, x4, fail

pass:
    addi a0, x0, 1
    sw   a0, -16(x0)
    halt

fail:
    addi a0, x0, 2
    sw   a0, -16(x0)
    halt
