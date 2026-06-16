# RISC-V-min

RV32IMAC CPU の面積最適化実験。Yosys + generic CMOS Liberty で合成面積を測定。

## Area Benchmark

Cell library: `synth/generic_cmos.lib` (NAND2=1.5, DFF=6.0, DFFE=7.5, MUX2=4.0)

### Branches

| Branch | Architecture | Area | vs Base | Tests |
|--------|-------------|-----:|--------:|------:|
| `rv32imac-pipeline` | 2-wide superscalar 5-stage pipeline | 81,774 | 100.0% | 77/77 |
| `rv32imac-pipeline-opt` | same + 下記の最適化を全適用 | 39,889 | 48.8% | 76/76 |
| `rv32imac-area-min` | multi-cycle FSM (パイプラインなし) | 25,806 | 31.6% | 77/77 |

### Optimization History (`rv32imac-pipeline-opt`)

Base = 81,774 (2-wide superscalar 5-stage pipeline)

| # | Optimization | Area | vs Base | Delta | Description |
|--:|-------------|-----:|--------:|------:|-------------|
| 0 | (base) | 81,774 | 100.0% | — | 2-wide in-order superscalar, 5-stage, combinational 33×33 MUL |
| 1 | Iterative MUL + DFFE cell | 60,394 | 73.9% | -21,380 | 33×33 combinational → 32-cycle shift-add; DFFE (area 7.5) added to liberty |
| 2 | Iterative shifts | 57,523 | 70.3% | -2,871 | Barrel shifter → 1-bit/cycle iterative; shifts restricted to slot A |
| 3 | Slot B EXMEM precompute | 57,276 | 70.0% | -247 | exmem_result_b + exmem_pc4_b → single exmem_fwd_b |
| 4 | Bypass-free B + EX RF read | 54,214 | 66.3% | -3,062 | B forwarding network removed; RF read moved from ID to EX stage |
| 5 | B ALU-only + decompress unify | 51,415 | 62.9% | -2,799 | Slot B restricted to LUI/OP-IMM/OP-REG; single B decompress() call |
| 6 | Early B WB + held buffer removal | 49,648 | 60.7% | -1,767 | MEMWB_B eliminated; held buffer replaced by B→A rotation |
| 7 | MEMWB removal + compact encoding | 48,867 | 59.8% | -781 | MEMWB_A eliminated (4-stage pipeline); CF/AMO fields compacted |
| 8 | Shared ALU (time-multiplex) | 48,491 | 59.3% | -376 | Slot B ALU removed; A's ALU shared via phase 0/1 |
| 9 | EXMEM payload DFF split | 48,399 | 59.2% | -92 | Unconditional payload → plain DFF (6.0) instead of DFFE (7.5) |
| 10 | Shared RF read ports (4→2) | 39,889 | 48.8% | -8,510 | RF mux trees halved; read index time-multiplexed with ALU phase |

### Other configurations (historical commits)

| Commit | Configuration | Area |
|--------|--------------|-----:|
| `b50947e` | RV32IM 5-stage pipeline (no A/C extension) | 51,390 |
| `ae4f13f` | RV32IMAC 5-stage single-issue pipeline | 55,378 |
| `8387f4b` | RV32E multi-cycle (16 regs, base integer only) | 9,125 |

## Quick start

```bash
make test    # assemble + verilator sim (all programs/*.S)
make synth   # yosys generic CMOS synthesis
make area    # parse area into JSON/Markdown
make report  # test + synth + area
```
