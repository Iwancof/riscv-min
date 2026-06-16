.text
.globl _start
_start:
    # Use addresses within 64KB dmem range
    li   s1, 0x100
    c.li s0, 31
    c.sw s0, 0(s1)
    c.li a3, 20
    c.sw a3, 4(s1)
    c.lw a5, 0(s1)
    addi t0, x0, 31
    bne a5, t0, fail
    c.lw a5, 4(s1)
    addi t0, x0, 20
    bne a5, t0, fail

    # C.LWSP / C.SWSP
    li   sp, 0x200
    c.li a0, 15
    c.swsp a0, 0(sp)
    c.li a1, 0
    c.lwsp a1, 0(sp)
    addi t0, x0, 15
    bne a1, t0, fail

    c.li a0, 1
    c.swsp a0, 4(sp)
    c.lwsp a5, 4(sp)
    sw a5, -16(x0)
    halt
fail:
    c.li a0, 2
    sw a0, -16(x0)
    halt
