.text
.globl _start

_start:
    # --- BEQ ---
    addi x1, x0, 5
    addi x2, x0, 5
    beq  x1, x2, beq_ok
    j    fail
beq_ok:

    addi x2, x0, 6
    beq  x1, x2, fail         # should NOT be taken

    # --- BNE ---
    bne  x1, x2, bne_ok
    j    fail
bne_ok:

    addi x2, x0, 5
    bne  x1, x2, fail         # should NOT be taken

    # --- BLT ---
    addi x1, x0, -5
    addi x2, x0, 5
    blt  x1, x2, blt_ok       # -5 < 5 → taken
    j    fail
blt_ok:

    blt  x2, x1, fail         # 5 < -5 → NOT taken

    # --- BGE ---
    addi x1, x0, 5
    addi x2, x0, 5
    bge  x1, x2, bge_ok       # 5 >= 5 → taken
    j    fail
bge_ok:

    addi x1, x0, -1
    bge  x1, x2, fail         # -1 >= 5 → NOT taken

    # --- BLTU ---
    addi x1, x0, 1
    addi x2, x0, -1           # 0xFFFFFFFF unsigned
    bltu x1, x2, bltu_ok      # 1 <u 0xFFFFFFFF → taken
    j    fail
bltu_ok:

    bltu x2, x1, fail         # 0xFFFFFFFF <u 1 → NOT taken

    # --- BGEU ---
    bgeu x2, x1, bgeu_ok      # 0xFFFFFFFF >=u 1 → taken
    j    fail
bgeu_ok:

    bgeu x1, x2, fail         # 1 >=u 0xFFFFFFFF → NOT taken

    # --- JAL ---
    jal  x1, jal_target
    j    fail
jal_target:
    # x1 should contain return address (PC of JAL + 4)

    # --- JALR ---
    li   x2, jalr_target
    jalr x3, 0(x2)
    j    fail
jalr_target:

    # --- Backward branch loop ---
    addi x1, x0, 0
    addi x2, x0, 10
loop:
    addi x1, x1, 1
    blt  x1, x2, loop         # loop 10 times
    addi x3, x0, 10
    bne  x1, x3, fail

    # --- Branch over store (ensure flushed instructions don't write) ---
    addi x1, x0, 0x42
    sw   x1, 128(x0)          # store 0x42
    j    skip_store
    li   x5, 0xFF
    sw   x5, 128(x0)          # should be flushed
skip_store:
    lw   x2, 128(x0)
    addi x3, x0, 0x42
    bne  x2, x3, fail

pass:
    addi a0, x0, 1
    sw   a0, -16(x0)
    halt

fail:
    addi a0, x0, 2
    sw   a0, -16(x0)
    halt
