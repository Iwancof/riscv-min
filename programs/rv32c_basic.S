# RV32C basic instruction test
# Tests: c.li, c.addi, c.mv, c.add, c.sub, c.and, c.or, c.xor
# Uses c.j for control flow, finishes with standard sw+halt for exit

.text
.globl _start

_start:
    # --- c.li: load immediates ---
    c.li  s0, 5          # s0 = 5
    c.li  s1, -3         # s1 = -3
    c.li  a0, 0          # a0 = 0 (will hold test bitmap)

    # --- c.addi ---
    c.addi s0, 7         # s0 = 5 + 7 = 12
    addi  t0, x0, 12
    bne   s0, t0, fail

    # --- c.mv ---
    c.mv  a1, s0         # a1 = 12
    bne   a1, t0, fail

    # --- c.add ---
    c.add s0, s1         # s0 = 12 + (-3) = 9
    addi  t0, x0, 9
    bne   s0, t0, fail

    # --- c.sub ---
    c.li  s0, 10
    c.li  s1, 3
    c.sub s0, s1         # s0 = 10 - 3 = 7
    addi  t0, x0, 7
    bne   s0, t0, fail

    # --- c.and ---
    c.li  s0, 15         # 0b1111
    c.li  s1, 6          # 0b0110
    c.and s0, s1         # s0 = 0b0110 = 6
    addi  t0, x0, 6
    bne   s0, t0, fail

    # --- c.or ---
    c.li  s0, 5          # 0b0101
    c.li  s1, 10         # 0b1010
    c.or  s0, s1         # s0 = 0b1111 = 15
    addi  t0, x0, 15
    bne   s0, t0, fail

    # --- c.xor ---
    c.li  s0, 15         # 0b1111
    c.li  s1, 6          # 0b0110
    c.xor s0, s1         # s0 = 0b1001 = 9
    addi  t0, x0, 9
    bne   s0, t0, fail

    # --- c.andi ---
    c.li  s0, 31         # 0b11111
    c.andi s0, 7         # s0 = 0b00111 = 7
    addi  t0, x0, 7
    bne   s0, t0, fail

    # All passed
    c.j pass

pass:
    addi a0, x0, 1
    sw   a0, -16(x0)
    halt

fail:
    addi a0, x0, 2
    sw   a0, -16(x0)
    halt
