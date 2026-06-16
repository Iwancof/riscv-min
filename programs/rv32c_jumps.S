.text
.globl __start
_start:
    c.li s0, 5
    c.beqz s0, fail
    c.li s0, 0
    c.beqz s0, test_bnez
    j fail
test_bnez:
    c.li s0, 0
    c.bnez s0, fail
    c.li s0, 7
    c.bnez s0, test_j
    j fail
test_j:
    c.li s0, 10
    c.j after_j
    j fail
after_j:
    addi t0, x0, 10
    bne s0, t0, fail
    c.li s0, 0
    c.jal sub_call
    addi t0, x0, 1
    bne s0, t0, fail
    c.j pass
fail:
    addi a0, x0, 2
    sw a0, -16(x0)
    halt
pass:
    addi a0, x0, 1
    sw a0, -16(x0)
    halt
sub_call:
    addi s0, s0, 1
    ret
