.text
.globl _start

_start:
    # --- SW / LW ---
    li   x1, 0xDEADBEEF
    sw   x1, 0(x0)
    lw   x2, 0(x0)
    bne  x1, x2, fail

    # --- SB / LB / LBU ---
    addi x1, x0, 0x7F          # 127
    sb   x1, 16(x0)
    lb   x2, 16(x0)            # sign-extend → 127
    bne  x1, x2, fail

    addi x1, x0, -1            # 0xFF
    sb   x1, 17(x0)
    lb   x2, 17(x0)            # sign-extend → -1
    addi x3, x0, -1
    bne  x2, x3, fail

    lbu  x2, 17(x0)            # zero-extend → 255
    li   x3, 255
    bne  x2, x3, fail

    # --- SB to different byte offsets ---
    addi x1, x0, 0x11
    sb   x1, 32(x0)
    addi x1, x0, 0x22
    sb   x1, 33(x0)
    addi x1, x0, 0x33
    sb   x1, 34(x0)
    addi x1, x0, 0x44
    sb   x1, 35(x0)
    lw   x2, 32(x0)
    li   x3, 0x44332211
    bne  x2, x3, fail

    # --- SH / LH / LHU ---
    li   x1, 0x1234
    sh   x1, 48(x0)
    lh   x2, 48(x0)            # sign-extend → 0x1234
    bne  x1, x2, fail

    lhu  x2, 48(x0)            # zero-extend → 0x1234
    bne  x1, x2, fail

    li   x1, 0xFFFF8000
    sh   x1, 50(x0)            # store 0x8000
    lh   x2, 50(x0)            # sign-extend → 0xFFFF8000 = -32768
    bne  x2, x1, fail

    lhu  x2, 50(x0)            # zero-extend → 0x8000
    li   x3, 0x8000
    bne  x2, x3, fail

    # --- SH to upper half-word ---
    li   x1, 0xABCD
    sh   x1, 66(x0)            # offset 2 within word
    lhu  x2, 66(x0)
    li   x3, 0xABCD
    bne  x2, x3, fail

    # --- Load after store to same address (store-to-load forwarding via memory) ---
    li   x1, 0x12345678
    sw   x1, 80(x0)
    nop
    lw   x2, 80(x0)
    bne  x1, x2, fail

    # --- Multiple loads ---
    li   x1, 100
    sw   x1, 96(x0)
    li   x1, 200
    sw   x1, 100(x0)
    lw   x2, 96(x0)
    lw   x3, 100(x0)
    add  x4, x2, x3            # 300
    li   x5, 300
    bne  x4, x5, fail

pass:
    addi a0, x0, 1
    sw   a0, -16(x0)
    halt

fail:
    addi a0, x0, 2
    sw   a0, -16(x0)
    halt
