.text
.globl _start

_start:
    addi x1, x0, 1
    slli x2, x1, 8
    srli x3, x2, 4
    addi x4, x0, 16
    bne  x3, x4, fail

    addi x5, x0, -8
    srai x6, x5, 1
    addi x7, x0, -4
    bne  x6, x7, fail

    auipc x8, 0
    jal  ra, check_jalr
    j    fail

check_jalr:
    li   t0, return_from_jalr
    jalr x0, 0(t0)
    j    fail

return_from_jalr:
    addi a0, x0, 1
    sw   a0, -16(x0)
    halt

fail:
    addi a0, x0, 2
    sw   a0, -16(x0)
    halt
