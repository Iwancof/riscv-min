#!/usr/bin/env python3
import argparse
import re
import sys
from pathlib import Path


REGS = {f"x{i}": i for i in range(32)}
REGS.update(
    {
        "zero": 0,
        "ra": 1,
        "sp": 2,
        "gp": 3,
        "tp": 4,
        "t0": 5,
        "t1": 6,
        "t2": 7,
        "s0": 8,
        "fp": 8,
        "s1": 9,
        "a0": 10,
        "a1": 11,
        "a2": 12,
        "a3": 13,
        "a4": 14,
        "a5": 15,
        "a6": 16,
        "a7": 17,
        "s2": 18,
        "s3": 19,
        "s4": 20,
        "s5": 21,
        "s6": 22,
        "s7": 23,
        "s8": 24,
        "s9": 25,
        "s10": 26,
        "s11": 27,
        "t3": 28,
        "t4": 29,
        "t5": 30,
        "t6": 31,
    }
)

R_OPS = {
    "add": (0b000, 0b0000000),
    "sub": (0b000, 0b0100000),
    "sll": (0b001, 0b0000000),
    "slt": (0b010, 0b0000000),
    "sltu": (0b011, 0b0000000),
    "xor": (0b100, 0b0000000),
    "srl": (0b101, 0b0000000),
    "sra": (0b101, 0b0100000),
    "or": (0b110, 0b0000000),
    "and": (0b111, 0b0000000),
    # M extension
    "mul": (0b000, 0b0000001),
    "mulh": (0b001, 0b0000001),
    "mulhsu": (0b010, 0b0000001),
    "mulhu": (0b011, 0b0000001),
    "div": (0b100, 0b0000001),
    "divu": (0b101, 0b0000001),
    "rem": (0b110, 0b0000001),
    "remu": (0b111, 0b0000001),
}

I_OPS = {
    "addi": 0b000,
    "slti": 0b010,
    "sltiu": 0b011,
    "xori": 0b100,
    "ori": 0b110,
    "andi": 0b111,
}

SHIFT_I_OPS = {
    "slli": (0b001, 0b0000000),
    "srli": (0b101, 0b0000000),
    "srai": (0b101, 0b0100000),
}

LOAD_OPS = {"lb": 0b000, "lh": 0b001, "lw": 0b010, "lbu": 0b100, "lhu": 0b101}
STORE_OPS = {"sb": 0b000, "sh": 0b001, "sw": 0b010}
BRANCH_OPS = {
    "beq": 0b000,
    "bne": 0b001,
    "blt": 0b100,
    "bge": 0b101,
    "bltu": 0b110,
    "bgeu": 0b111,
}


class AsmError(Exception):
    pass


def strip_comment(line):
    for marker in ("#", "//", ";"):
        idx = line.find(marker)
        if idx >= 0:
            line = line[:idx]
    return line.strip()


def split_operands(text):
    return [part.strip() for part in text.split(",") if part.strip()]


def parse_int(token):
    token = token.replace("_", "")
    if token.startswith("-0x"):
        return -int(token[3:], 16)
    if token.startswith("0x"):
        return int(token, 16)
    if token.startswith("0b"):
        return int(token, 2)
    return int(token, 10)


def reg(token):
    key = token.strip().lower()
    if key not in REGS:
        raise AsmError(f"unknown register '{token}'")
    return REGS[key]


def check_range(value, bits, signed=True, what="immediate"):
    if signed:
        lo = -(1 << (bits - 1))
        hi = (1 << (bits - 1)) - 1
    else:
        lo = 0
        hi = (1 << bits) - 1
    if not (lo <= value <= hi):
        raise AsmError(f"{what} {value} does not fit in {bits} bits")


def encode_r(funct7, rs2, rs1, funct3, rd, opcode=0b0110011):
    return (
        ((funct7 & 0x7F) << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((rd & 0x1F) << 7)
        | (opcode & 0x7F)
    )


def encode_i(imm, rs1, funct3, rd, opcode):
    check_range(imm, 12, signed=True)
    imm &= 0xFFF
    return (
        (imm << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((rd & 0x1F) << 7)
        | (opcode & 0x7F)
    )


def encode_s(imm, rs2, rs1, funct3, opcode=0b0100011):
    check_range(imm, 12, signed=True)
    imm &= 0xFFF
    return (
        (((imm >> 5) & 0x7F) << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((imm & 0x1F) << 7)
        | (opcode & 0x7F)
    )


def encode_b(imm, rs2, rs1, funct3, opcode=0b1100011):
    check_range(imm, 13, signed=True, what="branch offset")
    if imm % 2 != 0:
        raise AsmError(f"branch offset {imm} is not 2-byte aligned")
    imm &= 0x1FFF
    return (
        (((imm >> 12) & 0x1) << 31)
        | (((imm >> 5) & 0x3F) << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | (((imm >> 1) & 0xF) << 8)
        | (((imm >> 11) & 0x1) << 7)
        | (opcode & 0x7F)
    )


def encode_u(imm, rd, opcode):
    if imm & 0xFFF:
        raise AsmError(f"U immediate 0x{imm:x} must have low 12 bits clear")
    return ((imm & 0xFFFFF000) | ((rd & 0x1F) << 7) | (opcode & 0x7F))


def encode_j(imm, rd, opcode=0b1101111):
    check_range(imm, 21, signed=True, what="jump offset")
    if imm % 2 != 0:
        raise AsmError(f"jump offset {imm} is not 2-byte aligned")
    imm &= 0x1FFFFF
    return (
        (((imm >> 20) & 0x1) << 31)
        | (((imm >> 1) & 0x3FF) << 21)
        | (((imm >> 11) & 0x1) << 20)
        | (((imm >> 12) & 0xFF) << 12)
        | ((rd & 0x1F) << 7)
        | (opcode & 0x7F)
    )


def parse_mem(operand):
    match = re.fullmatch(r"\s*([^()]+)\(([^()]+)\)\s*", operand)
    if not match:
        raise AsmError(f"expected memory operand offset(reg), got '{operand}'")
    return parse_int(match.group(1).strip()), reg(match.group(2).strip())


def parse_source(path):
    items = []
    pc = 0
    labels = {}

    for lineno, raw in enumerate(Path(path).read_text().splitlines(), 1):
        line = strip_comment(raw)
        if not line:
            continue

        while ":" in line:
            before, after = line.split(":", 1)
            label = before.strip()
            if not re.fullmatch(r"[A-Za-z_.$][A-Za-z0-9_.$]*", label):
                break
            if label in labels:
                raise AsmError(f"{path}:{lineno}: duplicate label '{label}'")
            labels[label] = pc
            line = after.strip()
            if not line:
                break
        if not line:
            continue

        if line.startswith("."):
            directive, *rest = line.split(None, 1)
            if directive == ".word":
                values = split_operands(rest[0] if rest else "")
                if not values:
                    raise AsmError(f"{path}:{lineno}: .word needs an operand")
                for value in values:
                    items.append((pc, lineno, ".word", [value]))
                    pc += 4
            elif directive in (".text", ".globl", ".global"):
                continue
            else:
                raise AsmError(f"{path}:{lineno}: unsupported directive {directive}")
            continue

        op, *rest = line.split(None, 1)
        operands = split_operands(rest[0] if rest else "")
        expanded = expand_pseudo(op.lower(), operands, pc)
        for exp_op, exp_operands in expanded:
            items.append((pc, lineno, exp_op, exp_operands))
            pc += 4

    return items, labels


def expand_pseudo(op, operands, pc):
    del pc
    if op == "nop":
        return [("addi", ["x0", "x0", "0"])]
    if op == "halt":
        return [(".word", ["0x00100073"])]
    if op == "j":
        expect(op, operands, 1)
        return [("jal", ["x0", operands[0]])]
    if op == "jr":
        expect(op, operands, 1)
        return [("jalr", ["x0", f"0({operands[0]})"])]
    if op == "ret":
        expect(op, operands, 0)
        return [("jalr", ["x0", "0(ra)"])]
    if op == "mv":
        expect(op, operands, 2)
        return [("addi", [operands[0], operands[1], "0"])]
    if op == "not":
        expect(op, operands, 2)
        return [("xori", [operands[0], operands[1], "-1"])]
    if op == "neg":
        expect(op, operands, 2)
        return [("sub", [operands[0], "x0", operands[1]])]
    if op == "beqz":
        expect(op, operands, 2)
        return [("beq", [operands[0], "x0", operands[1]])]
    if op == "bnez":
        expect(op, operands, 2)
        return [("bne", [operands[0], "x0", operands[1]])]
    if op == "li":
        expect(op, operands, 2)
        try:
            imm = parse_int(operands[1])
        except ValueError:
            return [("_li_hi", [operands[0], operands[1]]), ("_li_lo", [operands[0], operands[0], operands[1]])]
        if -(1 << 11) <= imm <= (1 << 11) - 1:
            return [("addi", [operands[0], "x0", str(imm)])]
        upper = (imm + 0x800) >> 12
        lower = imm - (upper << 12)
        return [("lui", [operands[0], str(upper << 12)]), ("addi", [operands[0], operands[0], str(lower)])]
    return [(op, operands)]


def expect(op, operands, count):
    if len(operands) != count:
        raise AsmError(f"{op} expects {count} operands, got {len(operands)}")


def resolve_imm(token, labels, pc):
    if token in labels:
        return labels[token] - pc
    return parse_int(token)


def resolve_abs(token, labels):
    if token in labels:
        return labels[token]
    return parse_int(token)


def split_li_value(value):
    upper = (value + 0x800) >> 12
    lower = value - (upper << 12)
    return upper << 12, lower


def encode_item(pc, op, operands, labels):
    if op == ".word":
        expect(op, operands, 1)
        return parse_int(operands[0]) & 0xFFFFFFFF

    if op in R_OPS:
        expect(op, operands, 3)
        funct3, funct7 = R_OPS[op]
        return encode_r(funct7, reg(operands[2]), reg(operands[1]), funct3, reg(operands[0]))

    if op in I_OPS:
        expect(op, operands, 3)
        return encode_i(parse_int(operands[2]), reg(operands[1]), I_OPS[op], reg(operands[0]), 0b0010011)

    if op in SHIFT_I_OPS:
        expect(op, operands, 3)
        shamt = parse_int(operands[2])
        if not 0 <= shamt <= 31:
            raise AsmError(f"shift amount {shamt} is out of range")
        funct3, funct7 = SHIFT_I_OPS[op]
        imm = (funct7 << 5) | shamt
        return encode_i(imm, reg(operands[1]), funct3, reg(operands[0]), 0b0010011)

    if op in LOAD_OPS:
        expect(op, operands, 2)
        imm, rs1 = parse_mem(operands[1])
        return encode_i(imm, rs1, LOAD_OPS[op], reg(operands[0]), 0b0000011)

    if op in STORE_OPS:
        expect(op, operands, 2)
        imm, rs1 = parse_mem(operands[1])
        return encode_s(imm, reg(operands[0]), rs1, STORE_OPS[op])

    if op in BRANCH_OPS:
        expect(op, operands, 3)
        imm = resolve_imm(operands[2], labels, pc)
        return encode_b(imm, reg(operands[1]), reg(operands[0]), BRANCH_OPS[op])

    if op == "lui":
        expect(op, operands, 2)
        imm = parse_int(operands[1])
        return encode_u(imm, reg(operands[0]), 0b0110111)

    if op == "_li_hi":
        expect(op, operands, 2)
        imm_hi, _ = split_li_value(resolve_abs(operands[1], labels))
        return encode_u(imm_hi, reg(operands[0]), 0b0110111)

    if op == "_li_lo":
        expect(op, operands, 3)
        _, imm_lo = split_li_value(resolve_abs(operands[2], labels))
        return encode_i(imm_lo, reg(operands[1]), 0b000, reg(operands[0]), 0b0010011)

    if op == "auipc":
        expect(op, operands, 2)
        imm = parse_int(operands[1])
        return encode_u(imm, reg(operands[0]), 0b0010111)

    if op == "jal":
        expect(op, operands, 2)
        imm = resolve_imm(operands[1], labels, pc)
        return encode_j(imm, reg(operands[0]))

    if op == "jalr":
        expect(op, operands, 2)
        imm, rs1 = parse_mem(operands[1])
        return encode_i(imm, rs1, 0b000, reg(operands[0]), 0b1100111)

    if op == "fence":
        expect(op, operands, 0)
        return 0x0000000F

    raise AsmError(f"unsupported instruction '{op}'")


def assemble(path):
    items, labels = parse_source(path)
    words = []
    listing = []
    for pc, lineno, op, operands in items:
        try:
            word = encode_item(pc, op, operands, labels)
        except AsmError as exc:
            raise AsmError(f"{path}:{lineno}: {exc}") from exc
        words.append(word)
        listing.append((pc, word, op, operands))
    return words, listing


def main():
    parser = argparse.ArgumentParser(description="Tiny RV32I assembler for repository tests")
    parser.add_argument("input", help="assembly input")
    parser.add_argument("-o", "--output", required=True, help="hex output, one 32-bit word per line")
    parser.add_argument("--listing", help="optional listing output")
    args = parser.parse_args()

    try:
        words, listing = assemble(args.input)
    except AsmError as exc:
        print(f"rv32asm: {exc}", file=sys.stderr)
        return 1

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("".join(f"{word:08x}\n" for word in words))

    if args.listing:
        lst = Path(args.listing)
        lst.parent.mkdir(parents=True, exist_ok=True)
        lst.write_text(
            "".join(f"{pc:08x}: {word:08x}    {op} {', '.join(operands)}\n" for pc, word, op, operands in listing)
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
