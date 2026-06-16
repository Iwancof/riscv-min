.text
.globl _start
_start:
    # --- LR.W / SC.W basic ---
    addi x1, x0, 42
    sw   x1, 256(x0)

    addi x5, x0, 256       # address
    lr.w x2, 0(x5)          # x2 = mem[256] = 42
    addi x3, x0, 42
    bne  x2, x3, fail

    addi x4, x0, 99
    sc.w x6, x4, 0(x5)      # store 99 to mem[256], x6 = 0 (success)
    bne  x6, x0, fail

    lw   x7, 256(x0)        # verify store
    addi x8, x0, 99
    bne  x7, x8, fail

    # --- SC.W without LR.W should fail ---
    addi x4, x0, 77
    sc.w x6, x4, 0(x5)      # no valid reservation → x6 = 1 (fail)
    addi x8, x0, 1
    bne  x6, x8, fail

    lw   x7, 256(x0)        # mem should still be 99
    addi x8, x0, 99
    bne  x7, x8, fail

    # --- LR.W / SC.W with intervening store invalidates reservation ---
    lr.w x2, 0(x5)           # reserve addr 256
    sw   x0, 256(x0)         # intervening store to same address
    addi x4, x0, 55
    sc.w x6, x4, 0(x5)      # should fail (reservation invalidated)
    addi x8, x0, 1
    bne  x6, x8, fail

pass:
    addi a0, x0, 1
    sw   a0, -16(x0)
    halt

fail:
    addi a0, x0, 2
    sw   a0, -16(x0)
    halt
