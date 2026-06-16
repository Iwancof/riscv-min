.text
.globl _start
_start:
    lui sp, 0x10000
    addi sp, sp, 0
    c.addi16sp 16
    li  t0, 0x10010
    bne sp, t0, fail
    c.addi16sp -16
    li  t0, 0x10000
    bne sp, t0, fail
    c.addi4spn s0, 4
    li  t0, 0x10004
    bne s0, t0, fail
    c.addi4spn s1, 8
    li  t0, 0x10008
    bne s1, t0, fail
    c.lui s0, 1
    li  t0, 0x1000
    bne s0, t0, fail
    c.lui s0, -16
    li  t0, 0xFFFF0000
    bne s0, t0, fail
    c.j pass
pass:
    addi a0, x0, 1
    sw a0, -16(x0)
    halt
fail:
    addi a0, x0, 2
    sw a0, -16(x0)
    halt
