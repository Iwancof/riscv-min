BUILD_DIR := build
RTL := rtl/rv32i_core.sv
SIM_EXE := $(BUILD_DIR)/obj_dir/Vrv32i_core
PROGRAM_SRCS := $(sort $(wildcard programs/*.S))
PROGRAM_HEX := $(patsubst programs/%.S,$(BUILD_DIR)/programs/%.hex,$(PROGRAM_SRCS))
RUN_TESTS = python3 scripts/run_tests.py --sim $(SIM_EXE) --out $(BUILD_DIR)/reports/tests.json $(PROGRAM_HEX)

.PHONY: all tools sim test trace synth area report fpga clean

all: report

tools:
	@command -v python3 >/dev/null || { echo "missing python3"; exit 1; }
	@command -v c++ >/dev/null || { echo "missing c++"; exit 1; }
	@command -v verilator >/dev/null || { echo "missing verilator"; exit 1; }
	@command -v yosys >/dev/null || { echo "missing yosys"; exit 1; }

$(BUILD_DIR) $(BUILD_DIR)/programs $(BUILD_DIR)/obj_dir $(BUILD_DIR)/reports $(BUILD_DIR)/synth $(BUILD_DIR)/waves:
	mkdir -p $@

$(BUILD_DIR)/programs/%.hex: programs/%.S scripts/rv32asm.py | $(BUILD_DIR)/programs
	python3 scripts/rv32asm.py $< -o $@ --listing $(BUILD_DIR)/programs/$*.lst

$(SIM_EXE): $(RTL) sim/tb_rv32i.cpp | $(BUILD_DIR)/obj_dir
	verilator -Wall --trace --cc --exe --build --Mdir $(BUILD_DIR)/obj_dir \
		--top-module rv32i_core $(RTL) sim/tb_rv32i.cpp \
		-CFLAGS "-std=c++17 -O2" -o Vrv32i_core

sim: tools $(SIM_EXE) $(BUILD_DIR)/programs/smoke.hex
	$(SIM_EXE) +program=$(BUILD_DIR)/programs/smoke.hex +max-cycles=1000

trace: tools $(SIM_EXE) $(BUILD_DIR)/programs/smoke.hex | $(BUILD_DIR)/waves
	$(SIM_EXE) +program=$(BUILD_DIR)/programs/smoke.hex +max-cycles=1000 +trace=$(BUILD_DIR)/waves/smoke.vcd

$(BUILD_DIR)/reports/tests.json: scripts/run_tests.py $(SIM_EXE) $(PROGRAM_HEX) | $(BUILD_DIR)/reports
	$(RUN_TESTS)

test: tools $(SIM_EXE) $(PROGRAM_HEX) | $(BUILD_DIR)/reports
	$(RUN_TESTS)

$(BUILD_DIR)/synth/yosys.log: $(RTL) synth/synth_core.ys synth/generic_cmos.lib | $(BUILD_DIR)/synth
	yosys -l $@ -s synth/synth_core.ys
	rm -f abc.history

synth: tools $(BUILD_DIR)/synth/yosys.log

$(BUILD_DIR)/synth/ice40.log: $(RTL) synth/synth_ice40.ys | $(BUILD_DIR)/synth
	yosys -l $@ -s synth/synth_ice40.ys
	rm -f abc.history

fpga: tools $(BUILD_DIR)/synth/ice40.log

$(BUILD_DIR)/reports/summary.md $(BUILD_DIR)/reports/area.json: $(BUILD_DIR)/synth/yosys.log $(BUILD_DIR)/reports/tests.json scripts/area_summary.py | $(BUILD_DIR)/reports
	python3 scripts/area_summary.py \
		--yosys-log $(BUILD_DIR)/synth/yosys.log \
		--tests-json $(BUILD_DIR)/reports/tests.json \
		--out-json $(BUILD_DIR)/reports/area.json \
		--out-md $(BUILD_DIR)/reports/summary.md

area: tools $(BUILD_DIR)/reports/summary.md

report: test synth area
	@echo "Report: $(BUILD_DIR)/reports/summary.md"

clean:
	rm -rf $(BUILD_DIR)
