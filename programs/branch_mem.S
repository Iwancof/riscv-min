.text
.globl _start

_start:
    addi x1, x0, -1
    addi x2, x0, 1
    blt  x1, x2, signed_ok
    j    fail

signed_ok:
    bltu x2, x1, unsigned_ok
    j    fail

unsigned_ok:
    addi x3, x0, 127
    sb   x3, 4(x0)
    lb   x4, 4(x0)
    bne  x4, x3, fail

    addi x3, x0, -1
    sb   x3, 5(x0)
    lbu  x4, 5(x0)
    addi x5, x0, 255
    bne  x4, x5, fail

    li   x6, 0x1234
    sh   x6, 8(x0)
    lhu  x7, 8(x0)
    bne  x7, x6, fail

pass:
    addi a0, x0, 1
    sw   a0, -16(x0)
    halt

fail:
    addi a0, x0, 2
    sw   a0, -16(x0)
    halt
