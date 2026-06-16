# RV32C shift test
# Tests: c.slli, c.srli, c.srai

.text
.globl _start

_start:
    # --- c.slli ---
    c.li  s0, 5            # s0 = 5 = 0b101
    c.slli s0, 2           # s0 = 0b10100 = 20
    addi  t0, x0, 20
    bne   s0, t0, fail_label

    # --- c.srli ---
    c.li  s0, 8            # s0 = 8 = 0b1000
    c.srli s0, 2           # s0 = 0b10 = 2
    addi  t0, x0, 2
    bne   s0, t0, fail_label

    # --- c.srai (arithmetic right shift) ---
    # Need a negative number that fits in 6 bits
    # -16 fits: c.li s0, -16
    c.li  s0, -16          # s0 = -16
    c.srai s0, 2           # s0 = -4
    addi  t0, x0, -4
    bne   s0, t0, fail_label

    c.j   pass_label

pass_label:
    addi  a0, x0, 1
    sw    a0, -16(x0)
    halt

fail_label:
    addi  a0, x0, 2
    sw    a0, -16(x0)
    halt
