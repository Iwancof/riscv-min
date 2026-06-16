// Custom bare-metal environment for rv32imac-pipeline testbench.
// Replaces the official riscv-tests/env/p/riscv_test.h:
//   - No CSR, no machine mode, no trap vectors
//   - Pass: write 1 to EXIT_ADDR then ebreak
//   - Fail: write (testnum<<1)|1 to EXIT_ADDR then ebreak

#ifndef _RISCV_TEST_H
#define _RISCV_TEST_H

#define EXIT_ADDR 0xFFFFFFF0

#define TESTNUM gp

#define RVTEST_RV64U
#define RVTEST_RV32U

#define RVTEST_CODE_BEGIN \
        .section .text;   \
        .globl _start;    \
_start:

#define RVTEST_CODE_END

#define RVTEST_PASS       \
        li  t0, EXIT_ADDR; \
        li  t1, 1;        \
        sw  t1, 0(t0);    \
        ebreak

#define RVTEST_FAIL       \
        li  t0, EXIT_ADDR; \
        sll TESTNUM, TESTNUM, 1; \
        ori TESTNUM, TESTNUM, 1; \
        sw  TESTNUM, 0(t0); \
        ebreak

#define RVTEST_DATA_BEGIN .align 4; .global begin_signature; begin_signature:
#define RVTEST_DATA_END   .align 4; .global end_signature; end_signature:

#define TEST_PASSFAIL \
        bne x0, TESTNUM, pass; \
        j fail; \
pass:   RVTEST_PASS; \
fail:   RVTEST_FAIL;

#define EXTRA_DATA
#define EXTRA_INIT
#define EXTRA_INIT_TIMER

#endif
