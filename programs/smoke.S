.text
.globl _start

_start:
    addi x1, x0, 5
    addi x2, x0, 7
    add  x3, x1, x2
    addi x4, x0, 12
    bne  x3, x4, fail

    sw   x3, 0(x0)
    lw   x5, 0(x0)
    bne  x5, x3, fail

    sub  x6, x5, x1
    bne  x6, x2, fail

    jal  x8, after_jal
    j    fail

after_jal:
    li   x9, 0x12345678
    li   x10, 0x12345678
    bne  x9, x10, fail

pass:
    addi a0, x0, 1
    sw   a0, -16(x0)
    halt

fail:
    addi a0, x0, 2
    sw   a0, -16(x0)
    halt
