#!/usr/bin/env python3
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


RESULT_RE = re.compile(
    r"RESULT\s+(?P<status>pass|fail)\s+program=(?P<program>\S+)\s+cycles=(?P<cycles>\d+)(?:\s+exit_code=(?P<exit_code>\d+))?(?:\s+reason=\"(?P<reason>.*)\")?"
)


def run_one(sim, program, max_cycles, trace_dir):
    cmd = [sim, f"+program={program}", f"+max-cycles={max_cycles}"]
    if trace_dir is not None:
        trace_path = Path(trace_dir) / (Path(program).stem + ".vcd")
        trace_path.parent.mkdir(parents=True, exist_ok=True)
        cmd.append(f"+trace={trace_path}")

    proc = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    output = (proc.stdout + proc.stderr).strip()
    match = RESULT_RE.search(output)

    result = {
        "program": program,
        "returncode": proc.returncode,
        "stdout": proc.stdout,
        "stderr": proc.stderr,
    }
    if match:
        result.update(
            {
                "status": match.group("status"),
                "cycles": int(match.group("cycles")),
                "exit_code": int(match.group("exit_code")) if match.group("exit_code") is not None else None,
                "reason": match.group("reason"),
            }
        )
    else:
        result.update({"status": "fail", "cycles": None, "exit_code": None, "reason": "missing RESULT line"})

    return result


def main():
    parser = argparse.ArgumentParser(description="Run rv32i_core Verilator tests")
    parser.add_argument("--sim", required=True, help="Verilator simulation executable")
    parser.add_argument("--max-cycles", type=int, default=1000)
    parser.add_argument("--out", default="build/reports/tests.json")
    parser.add_argument("--trace-dir", help="optional directory for VCD traces")
    parser.add_argument("programs", nargs="+", help="assembled hex programs")
    args = parser.parse_args()

    results = [run_one(args.sim, program, args.max_cycles, args.trace_dir) for program in args.programs]
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(json.dumps(results, indent=2) + "\n")

    failed = False
    for result in results:
        name = Path(result["program"]).stem
        if result["status"] == "pass" and result["returncode"] == 0:
            print(f"PASS {name} cycles={result['cycles']}")
        else:
            failed = True
            reason = result.get("reason") or f"returncode={result['returncode']}"
            print(f"FAIL {name} {reason}", file=sys.stderr)
            if result["stdout"].strip():
                print(result["stdout"].strip(), file=sys.stderr)
            if result["stderr"].strip():
                print(result["stderr"].strip(), file=sys.stderr)

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
