# C extension incremental test - adding shift ops
.text
.globl _start

_start:
    c.li  s0, 5          # s0 = 5
    c.li  s1, 7          # s1 = 7
    c.add s0, s1         # s0 = 12
    addi  t0, x0, 12
    bne   s0, t0, fail

    # c.sub
    c.li  s0, 10
    c.li  s1, 3
    c.sub s0, s1         # s0 = 7
    addi  t0, x0, 7
    bne   s0, t0, fail

    # c.and c.or c.xor
    c.li  s0, 15
    c.li  s1, 6
    c.and s0, s1         # 6
    addi  t0, x0, 6
    bne   s0, t0, fail

    c.li  s0, 5
    c.li  s1, 10
    c.or  s0, s1         # 15
    addi  t0, x0, 15
    bne   s0, t0, fail

    c.li  s0, 15
    c.li  s1, 6
    c.xor s0, s1         # 9
    addi  t0, x0, 9
    bne   s0, t0, fail

    # c.andi
    c.li  s0, 31
    c.andi s0, 7         # 7
    addi  t0, x0, 7
    bne   s0, t0, fail

    # c.mv
    c.li  s0, 22
    c.mv  s1, s0         # s1 = 22
    addi  t0, x0, 22
    bne   s1, t0, fail

    # c.addi
    c.li  s0, 5
    c.addi s0, 7         # 12
    addi  t0, x0, 12
    bne   s0, t0, fail

    c.j   pass

pass:
    addi  a0, x0, 1
    sw    a0, -16(x0)
    halt

fail:
    addi  a0, x0, 2
    sw    a0, -16(x0)
    halt
