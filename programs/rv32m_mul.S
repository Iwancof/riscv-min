.text
.globl _start

_start:
    # --- MUL: basic ---
    addi x1, x0, 6
    addi x2, x0, 7
    mul  x3, x1, x2           # 42
    addi x4, x0, 42
    bne  x3, x4, fail

    # --- MUL: negative ---
    addi x1, x0, -3
    addi x2, x0, 7
    mul  x3, x1, x2           # -21
    addi x4, x0, -21
    bne  x3, x4, fail

    # --- MUL: both negative ---
    addi x1, x0, -4
    addi x2, x0, -5
    mul  x3, x1, x2           # 20
    addi x4, x0, 20
    bne  x3, x4, fail

    # --- MUL: by zero ---
    addi x1, x0, 100
    mul  x3, x1, x0           # 0
    bne  x3, x0, fail

    # --- MUL: by one ---
    addi x1, x0, -7
    addi x2, x0, 1
    mul  x3, x1, x2           # -7
    addi x4, x0, -7
    bne  x3, x4, fail

    # --- MULH: signed × signed high bits ---
    li   x1, 0x7FFFFFFF       # INT_MAX = 2147483647
    addi x2, x0, 2
    mulh x3, x1, x2           # (2147483647 * 2) >> 32 = 0
    bne  x3, x0, fail

    # --- MULH: negative result ---
    addi x1, x0, -1           # 0xFFFFFFFF
    li   x2, 0x7FFFFFFF       # 2147483647
    mulh x3, x1, x2           # (-1 * 2147483647) >> 32 = -1
    addi x4, x0, -1
    bne  x3, x4, fail

    # --- MULHU: unsigned × unsigned high ---
    addi x1, x0, -1           # 0xFFFFFFFF
    addi x2, x0, -1           # 0xFFFFFFFF
    mulhu x3, x1, x2          # (0xFFFFFFFF * 0xFFFFFFFF) >> 32 = 0xFFFFFFFE
    li   x4, 0xFFFFFFFE
    bne  x3, x4, fail

    # --- MULHSU: signed × unsigned high ---
    addi x1, x0, -1           # signed -1
    addi x2, x0, -1           # unsigned 0xFFFFFFFF
    mulhsu x3, x1, x2         # (-1 * 0xFFFFFFFF) >> 32 = -1
    addi x4, x0, -1
    bne  x3, x4, fail

    # --- MUL forwarding test ---
    addi x1, x0, 3
    addi x2, x0, 4
    mul  x3, x1, x2           # 12
    add  x4, x3, x1           # 12 + 3 = 15 (forward from MUL result)
    addi x5, x0, 15
    bne  x4, x5, fail

pass:
    addi a0, x0, 1
    sw   a0, -16(x0)
    halt

fail:
    addi a0, x0, 2
    sw   a0, -16(x0)
    halt
