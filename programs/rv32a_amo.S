.text
.globl _start
_start:
    # Base address for atomic operations
    addi x20, x0, 512       # x20 = address

    # --- AMOSWAP.W ---
    addi x1, x0, 10
    sw   x1, 0(x20)
    addi x2, x0, 20
    amoswap.w x3, x2, 0(x20)  # x3 = old(10), mem = 20
    addi x4, x0, 10
    bne  x3, x4, fail
    lw   x5, 0(x20)
    addi x4, x0, 20
    bne  x5, x4, fail

    # --- AMOADD.W ---
    addi x1, x0, 100
    sw   x1, 0(x20)
    addi x2, x0, 50
    amoadd.w x3, x2, 0(x20)   # x3 = old(100), mem = 150
    addi x4, x0, 100
    bne  x3, x4, fail
    lw   x5, 0(x20)
    addi x4, x0, 150
    bne  x5, x4, fail

    # --- AMOXOR.W ---
    li   x1, 0xFF
    sw   x1, 0(x20)
    li   x2, 0x0F
    amoxor.w x3, x2, 0(x20)   # x3 = old(0xFF), mem = 0xF0
    li   x4, 0xFF
    bne  x3, x4, fail
    lw   x5, 0(x20)
    li   x4, 0xF0
    bne  x5, x4, fail

    # --- AMOAND.W ---
    li   x1, 0xFF
    sw   x1, 0(x20)
    li   x2, 0x0F
    amoand.w x3, x2, 0(x20)   # x3 = old(0xFF), mem = 0x0F
    li   x4, 0xFF
    bne  x3, x4, fail
    lw   x5, 0(x20)
    li   x4, 0x0F
    bne  x5, x4, fail

    # --- AMOOR.W ---
    li   x1, 0xF0
    sw   x1, 0(x20)
    li   x2, 0x0F
    amoor.w x3, x2, 0(x20)    # x3 = old(0xF0), mem = 0xFF
    li   x4, 0xF0
    bne  x3, x4, fail
    lw   x5, 0(x20)
    li   x4, 0xFF
    bne  x5, x4, fail

    # --- AMOMIN.W (signed) ---
    addi x1, x0, 10
    sw   x1, 0(x20)
    addi x2, x0, -5
    amomin.w x3, x2, 0(x20)   # x3 = old(10), mem = min(10, -5) = -5
    addi x4, x0, 10
    bne  x3, x4, fail
    lw   x5, 0(x20)
    addi x4, x0, -5
    bne  x5, x4, fail

    # --- AMOMAX.W (signed) ---
    addi x1, x0, -10
    sw   x1, 0(x20)
    addi x2, x0, 5
    amomax.w x3, x2, 0(x20)   # x3 = old(-10), mem = max(-10, 5) = 5
    addi x4, x0, -10
    bne  x3, x4, fail
    lw   x5, 0(x20)
    addi x4, x0, 5
    bne  x5, x4, fail

    # --- AMOMINU.W (unsigned) ---
    addi x1, x0, 10
    sw   x1, 0(x20)
    addi x2, x0, 5
    amominu.w x3, x2, 0(x20)  # x3 = old(10), mem = minu(10, 5) = 5
    addi x4, x0, 10
    bne  x3, x4, fail
    lw   x5, 0(x20)
    addi x4, x0, 5
    bne  x5, x4, fail

    # --- AMOMAXU.W (unsigned) ---
    addi x1, x0, 10
    sw   x1, 0(x20)
    addi x2, x0, 20
    amomaxu.w x3, x2, 0(x20)  # x3 = old(10), mem = maxu(10, 20) = 20
    addi x4, x0, 10
    bne  x3, x4, fail
    lw   x5, 0(x20)
    addi x4, x0, 20
    bne  x5, x4, fail

pass:
    addi a0, x0, 1
    sw   a0, -16(x0)
    halt

fail:
    addi a0, x0, 2
    sw   a0, -16(x0)
    halt
