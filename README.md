# RISC-V-min

RV32IMAC CPU の面積最適化実験。Yosys + generic CMOS Liberty で合成面積を測定。

## Area Benchmark

| Branch | Architecture | Area | vs Base | Tests |
|--------|-------------|-----:|--------:|------:|
| `rv32imac-pipeline` | 2-wide superscalar 5-stage pipeline | 81,774 | 100% | 77/77 |
| `rv32imac-pipeline-opt` | same + iterative MUL/shift, DFFE, simplified B | 49,648 | 60.7% | 76/76 |
| `rv32imac-area-min` | multi-cycle FSM | 25,806 | 31.6% | 77/77 |
| (history) RV32IMAC single-issue pipeline | 5-stage, no superscalar | 55,378 | 67.7% | 77/77 |
| (history) RV32IM pipeline | 5-stage, no A/C ext | 51,390 | — | — |
| (history) RV32E multi-cycle | 16 regs, base integer only | 9,125 | — | — |

Cell library: `synth/generic_cmos.lib` (NAND2=1.5, DFF=6.0, DFFE=7.5, MUX2=4.0)

## Quick start

```bash
make test    # assemble + verilator sim (all programs/*.S)
make synth   # yosys generic CMOS synthesis
make area    # parse area into JSON/Markdown
make report  # test + synth + area
```
