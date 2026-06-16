#!/usr/bin/env python3
import argparse
import json
import re
from pathlib import Path


AREA_RE = re.compile(r"Chip area for module\s+'?\\?(?P<module>[A-Za-z0-9_$]+)'?:\s+(?P<area>[0-9.]+)")
CELL_HEADER_RE = re.compile(r"^\s*Number of cells:\s+(?P<count>\d+)\s*$")
CELL_LINE_RE = re.compile(r"^\s+(?P<cell>[A-Za-z0-9_$]+)\s+(?P<count>\d+)\s*$")
STAT_CELLS_RE = re.compile(r"^\s*(?P<count>\d+)\s+[-0-9.]+\s+cells\s*$")
STAT_CELL_LINE_RE = re.compile(r"^\s*(?P<count>\d+)\s+[-0-9.]+\s+(?P<cell>[A-Za-z0-9_$]+)\s*$")


def parse_yosys_log(path):
    text = Path(path).read_text(errors="replace")
    area_matches = list(AREA_RE.finditer(text))
    area = None
    module = None
    if area_matches:
        module = area_matches[-1].group("module")
        area = float(area_matches[-1].group("area"))

    cell_count = None
    cells = {}
    lines = text.splitlines()
    for index, line in enumerate(lines):
        header = CELL_HEADER_RE.match(line)
        stat_header = STAT_CELLS_RE.match(line)
        if header:
            cell_count = int(header.group("count"))
            cells = {}
            for cell_line in lines[index + 1 :]:
                if not cell_line.strip():
                    break
                match = CELL_LINE_RE.match(cell_line)
                if match:
                    cells[match.group("cell")] = int(match.group("count"))
        elif stat_header:
            cell_count = int(stat_header.group("count"))
            cells = {}
            for cell_line in lines[index + 1 :]:
                if not cell_line.strip():
                    break
                match = STAT_CELL_LINE_RE.match(cell_line)
                if match:
                    cells[match.group("cell")] = int(match.group("count"))

    return {"module": module, "area": area, "cell_count": cell_count, "cells": cells}


def load_tests(path):
    if path is None or not Path(path).exists():
        return []
    return json.loads(Path(path).read_text())


def write_markdown(path, area, tests):
    lines = ["# RISC-V-min report", ""]
    lines.append("## ASIC cell estimate")
    lines.append("")
    if area["area"] is None:
        lines.append("Yosys did not report a Liberty area.")
    else:
        lines.append(f"- Module: `{area['module']}`")
        lines.append(f"- Cells: `{area['cell_count']}`")
        lines.append(f"- Generic cell area: `{area['area']:.2f}`")

    if tests:
        lines.extend(["", "## Simulation tests", "", "| Program | Status | Cycles | Area x cycles |", "| --- | ---: | ---: | ---: |"])
        for test in tests:
            cycles = test.get("cycles")
            axc = ""
            if area["area"] is not None and cycles is not None:
                axc = f"{area['area'] * cycles:.2f}"
            lines.append(f"| `{Path(test['program']).stem}` | {test.get('status')} | {cycles} | {axc} |")

    if area["cells"]:
        lines.extend(["", "## Mapped cells", "", "| Cell | Count |", "| --- | ---: |"])
        for cell, count in sorted(area["cells"].items()):
            lines.append(f"| `{cell}` | {count} |")

    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser(description="Summarize Yosys area and simulation results")
    parser.add_argument("--yosys-log", default="build/synth/yosys.log")
    parser.add_argument("--tests-json", default="build/reports/tests.json")
    parser.add_argument("--out-json", default="build/reports/area.json")
    parser.add_argument("--out-md", default="build/reports/summary.md")
    args = parser.parse_args()

    area = parse_yosys_log(args.yosys_log)
    tests = load_tests(args.tests_json)
    report = {"area": area, "tests": tests}

    Path(args.out_json).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out_json).write_text(json.dumps(report, indent=2) + "\n")
    write_markdown(args.out_md, area, tests)

    if area["area"] is None:
        print("AREA unavailable")
        return 1

    print(f"AREA module={area['module']} cells={area['cell_count']} generic_area={area['area']:.2f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
