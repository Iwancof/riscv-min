.text
.globl _start

_start:
    # Independent ALU ops — should dual-issue
    c.li  a0, 1          # slot A
    c.li  a1, 2          # slot B (no dependency)
    c.li  a2, 3          # slot A
    c.li  a3, 4          # slot B (no dependency)
    c.li  a4, 5          # slot A
    c.li  a5, 6          # slot B (no dependency)

    # Independent adds
    add   t0, a0, a1     # slot A: t0 = 3
    add   t1, a2, a3     # slot B: t1 = 7 (no dependency on t0)
    add   t2, a4, a5     # slot A: t2 = 11
    addi  t3, x0, 11     # slot B: t3 = 11

    bne   t2, t3, fail

    # Verify all results
    addi  t3, x0, 3
    bne   t0, t3, fail
    addi  t3, x0, 7
    bne   t1, t3, fail

    # Dependent chain — cannot dual-issue (serial)
    c.li  a0, 1
    add   a1, a0, a0     # depends on a0
    add   a2, a1, a1     # depends on a1
    add   a3, a2, a2     # depends on a2
    add   a4, a3, a3     # depends on a3
    addi  t3, x0, 16
    bne   a4, t3, fail

    # Mixed: load (slot A only) + independent ALU (slot B)
    addi  t0, x0, 42
    sw    t0, 256(x0)
    c.li  t1, 0
    lw    t1, 256(x0)    # slot A: load
    c.li  t2, 31         # slot B: independent ALU (can dual with load)
    nop
    addi  t3, x0, 42
    bne   t1, t3, fail
    addi  t3, x0, 31
    bne   t2, t3, fail

pass:
    addi a0, x0, 1
    sw   a0, -16(x0)
    halt

fail:
    addi a0, x0, 2
    sw   a0, -16(x0)
    halt
