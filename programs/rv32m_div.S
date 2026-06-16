.text
.globl _start

_start:
    # --- DIV: basic ---
    addi x1, x0, 20
    addi x2, x0, 3
    div  x3, x1, x2           # 6
    addi x4, x0, 6
    bne  x3, x4, fail

    # --- REM: basic ---
    rem  x3, x1, x2           # 20 % 3 = 2
    addi x4, x0, 2
    bne  x3, x4, fail

    # --- DIV: negative dividend ---
    addi x1, x0, -20
    addi x2, x0, 3
    div  x3, x1, x2           # -6 (truncate toward zero)
    addi x4, x0, -6
    bne  x3, x4, fail

    rem  x3, x1, x2           # -20 % 3 = -2
    addi x4, x0, -2
    bne  x3, x4, fail

    # --- DIV: negative divisor ---
    addi x1, x0, 20
    addi x2, x0, -3
    div  x3, x1, x2           # -6
    addi x4, x0, -6
    bne  x3, x4, fail

    rem  x3, x1, x2           # 20 % -3 = 2
    addi x4, x0, 2
    bne  x3, x4, fail

    # --- DIV: both negative ---
    addi x1, x0, -20
    addi x2, x0, -3
    div  x3, x1, x2           # 6
    addi x4, x0, 6
    bne  x3, x4, fail

    rem  x3, x1, x2           # -20 % -3 = -2
    addi x4, x0, -2
    bne  x3, x4, fail

    # --- DIVU / REMU: unsigned ---
    addi x1, x0, -1           # 0xFFFFFFFF = 4294967295
    addi x2, x0, 10
    divu x3, x1, x2           # 429496729
    li   x4, 429496729
    bne  x3, x4, fail

    remu x3, x1, x2           # 4294967295 % 10 = 5
    addi x4, x0, 5
    bne  x3, x4, fail

    # --- Division by zero ---
    addi x1, x0, 42
    div  x3, x1, x0           # div by zero → -1 (0xFFFFFFFF)
    addi x4, x0, -1
    bne  x3, x4, fail

    rem  x3, x1, x0           # rem by zero → dividend (42)
    addi x4, x0, 42
    bne  x3, x4, fail

    divu x3, x1, x0           # 0xFFFFFFFF
    addi x4, x0, -1
    bne  x3, x4, fail

    remu x3, x1, x0           # dividend (42)
    addi x4, x0, 42
    bne  x3, x4, fail

    # --- DIV forwarding test ---
    addi x1, x0, 100
    addi x2, x0, 10
    div  x3, x1, x2           # 10
    add  x4, x3, x2           # 10 + 10 = 20 (forward from DIV result)
    addi x5, x0, 20
    bne  x4, x5, fail

pass:
    addi a0, x0, 1
    sw   a0, -16(x0)
    halt

fail:
    addi a0, x0, 2
    sw   a0, -16(x0)
    halt
