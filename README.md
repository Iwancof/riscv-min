# RISC-V-min

Minimal RV32I CPU playground with a repeatable loop for:

1. Write SystemVerilog RTL.
2. Assemble small test programs.
3. Run functional tests with Verilator.
4. Synthesize with Yosys.
5. Combine cycle counts and a coarse cell-area estimate.

## Quick start

```bash
make test
make synth
make area
make report
```

Main outputs:

- `build/reports/tests.json`: Verilator test results.
- `build/synth/yosys.log`: Yosys synthesis log.
- `build/reports/area.json`: parsed area data.
- `build/reports/summary.md`: combined test and area report.
- `build/waves/*.vcd`: waveforms when using `make trace`.

## Useful commands

```bash
make sim       # Run programs/smoke.S
make test      # Assemble and run all programs/*.S
make trace     # Run smoke test and emit build/waves/smoke.vcd
make synth     # ASIC-style generic-cell synthesis
make area      # Parse Yosys area into JSON/Markdown
make fpga      # Yosys iCE40 LUT/FF-oriented synthesis
make clean
```

## Design status

`rtl/rv32i_core.sv` is a small single-cycle RV32I core with separate instruction
and data memory interfaces. The simulator provides memory and treats a store to
`0xfffffff0` as the program exit code. `1` means pass.

Implemented instruction groups:

- RV32I integer ALU: `lui`, `auipc`, `add/sub`, shifts, comparisons, logic ops.
- Control flow: `jal`, `jalr`, conditional branches.
- Loads/stores: byte, halfword, word with simple misalignment traps.
- `fence` as a no-op and `ebreak` as `halt`.

Not implemented yet:

- CSRs, interrupts, exceptions beyond a sticky `trap_o`.
- Compressed, multiply/divide, atomics, privileged ISA.
- Shared bus, real SRAM macros, cache, pipeline hazards, branch prediction.

## Area model

`synth/generic_cmos.lib` is an educational Liberty file. It is good enough to
make Yosys/ABC produce a stable mapped netlist and a comparable generic area
number, but it is not a real process library.

For more realistic ASIC work, replace `synth/generic_cmos.lib` and
`synth/synth_core.ys` with a real Liberty/PDK flow, or add OpenROAD/OpenLane.
For FPGA work, use `make fpga` as a first LUT/FF count, then move to the target
vendor flow for final resource and timing reports.

## Adding tests

Add a file under `programs/*.S`. The local assembler supports the instructions
used by the current tests plus simple pseudos such as `li`, `mv`, `j`, `ret`,
`beqz`, `bnez`, and `halt`.

A passing program should end with:

```asm
addi a0, x0, 1
sw   a0, -16(x0)
halt
```
