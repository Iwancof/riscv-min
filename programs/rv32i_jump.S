.text
.globl _start

_start:
    li   sp, 0x400

    # Test 1: JAL forward
    jal  ra, func1
    j    t1_ok
func1:
    addi x10, x0, 1
    jalr x0, 0(ra)
t1_ok:
    addi x11, x0, 1
    bne  x10, x11, fail

    # Test 2: Nested calls using stack
    jal  ra, outer
    addi x5, x0, 77
    bne  x3, x5, fail
    j    pass

outer:
    addi sp, sp, -4
    sw   ra, 0(sp)
    jal  ra, inner
    lw   ra, 0(sp)
    addi sp, sp, 4
    jalr x0, 0(ra)

inner:
    addi x3, x0, 77
    jalr x0, 0(ra)

pass:
    addi a0, x0, 1
    sw   a0, -16(x0)
    halt

fail:
    addi a0, x0, 2
    sw   a0, -16(x0)
    halt
