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

# Set of C extension instruction mnemonics
C_OPS = {
    "c.addi4spn", "c.lw", "c.sw",
    "c.nop", "c.addi", "c.jal", "c.li", "c.addi16sp", "c.lui",
    "c.srli", "c.srai", "c.andi", "c.sub", "c.xor", "c.or", "c.and",
    "c.j", "c.beqz", "c.bnez",
    "c.slli", "c.lwsp", "c.jr", "c.mv", "c.ebreak", "c.jalr", "c.add",
    "c.swsp",
}

# A extension instructions: funct5 values
A_OPS = {
    "lr.w":      0b00010,
    "sc.w":      0b00011,
    "amoswap.w": 0b00001,
    "amoadd.w":  0b00000,
    "amoxor.w":  0b00100,
    "amoand.w":  0b01100,
    "amoor.w":   0b01000,
    "amomin.w":  0b10000,
    "amomax.w":  0b10100,
    "amominu.w": 0b11000,
    "amomaxu.w": 0b11100,
}


def encode_amo(funct5, rs2, rs1, funct3, rd):
    aq = 0
    rl = 0
    return (
        ((funct5 & 0x1F) << 27)
        | ((aq & 1) << 26)
        | ((rl & 1) << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((rd & 0x1F) << 7)
        | 0b0101111
    )


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


# ================================================================
# C extension encoding helpers
# ================================================================

def _is_creg(r):
    """Return True if register number r maps to a compact register (x8-x15)."""
    return 8 <= r <= 15


def _creg(r):
    """Return 3-bit compact register index (0-7)."""
    return r - 8


def _bits(val, hi, lo):
    """Extract bits [hi:lo] from val."""
    return (val >> lo) & ((1 << (hi - lo + 1)) - 1)


def encode_c_addi4spn(rd, nzuimm):
    """C.ADDI4SPN: rd' = x2 + nzuimm; nzuimm is multiple of 4, 4..1020"""
    if nzuimm == 0 or nzuimm % 4 != 0 or nzuimm > 1020:
        raise AsmError(f"c.addi4spn nzuimm {nzuimm} invalid (must be 4..1020, multiple of 4)")
    if not _is_creg(rd):
        raise AsmError(f"c.addi4spn rd must be x8-x15, got x{rd}")
    # Encoding: [15:13]=000 [12:5]=nzuimm[5:4|9:6|2|3] [4:2]=rd' [1:0]=00
    u = nzuimm
    return (
        (0b000 << 13)
        | (_bits(u, 5, 4) << 11)
        | (_bits(u, 9, 6) << 7)
        | (_bits(u, 2, 2) << 6)
        | (_bits(u, 3, 3) << 5)
        | (_creg(rd) << 2)
        | 0b00
    )


def encode_c_lw(rd, rs1, offset):
    """C.LW: rd' = mem[rs1' + offset]; offset multiple of 4, 0..124"""
    if offset < 0 or offset > 124 or offset % 4 != 0:
        raise AsmError(f"c.lw offset {offset} invalid (must be 0..124, multiple of 4)")
    if not _is_creg(rd) or not _is_creg(rs1):
        raise AsmError(f"c.lw registers must be x8-x15")
    # [15:13]=010 [12:10]=offset[5:3] [9:7]=rs1' [6]=offset[2] [5]=offset[6] [4:2]=rd' [1:0]=00
    o = offset
    return (
        (0b010 << 13)
        | (_bits(o, 5, 3) << 10)
        | (_creg(rs1) << 7)
        | (_bits(o, 2, 2) << 6)
        | (_bits(o, 6, 6) << 5)
        | (_creg(rd) << 2)
        | 0b00
    )


def encode_c_sw(rs2, rs1, offset):
    """C.SW: mem[rs1' + offset] = rs2'; offset multiple of 4, 0..124"""
    if offset < 0 or offset > 124 or offset % 4 != 0:
        raise AsmError(f"c.sw offset {offset} invalid (must be 0..124, multiple of 4)")
    if not _is_creg(rs2) or not _is_creg(rs1):
        raise AsmError(f"c.sw registers must be x8-x15")
    o = offset
    return (
        (0b110 << 13)
        | (_bits(o, 5, 3) << 10)
        | (_creg(rs1) << 7)
        | (_bits(o, 2, 2) << 6)
        | (_bits(o, 6, 6) << 5)
        | (_creg(rs2) << 2)
        | 0b00
    )


def encode_c_nop():
    """C.NOP"""
    return (0b000 << 13) | 0b01


def encode_c_addi(rd, nzimm):
    """C.ADDI: rd = rd + nzimm; nzimm is sign-extended 6-bit"""
    check_range(nzimm, 6, signed=True, what="c.addi immediate")
    nzimm &= 0x3F
    return (
        (0b000 << 13)
        | (_bits(nzimm, 5, 5) << 12)
        | ((rd & 0x1F) << 7)
        | (_bits(nzimm, 4, 0) << 2)
        | 0b01
    )


def encode_c_jal(imm):
    """C.JAL: jal x1, imm; imm is sign-extended 12-bit, multiple of 2"""
    check_range(imm, 12, signed=True, what="c.jal offset")
    if imm % 2 != 0:
        raise AsmError(f"c.jal offset {imm} not 2-byte aligned")
    imm &= 0xFFF
    # offset[11|4|9:8|10|6|7|3:1|5] → ci[12|11:2]
    return (
        (0b001 << 13)
        | (_bits(imm, 11, 11) << 12)
        | (_bits(imm, 4, 4) << 11)
        | (_bits(imm, 9, 8) << 9)
        | (_bits(imm, 10, 10) << 8)
        | (_bits(imm, 6, 6) << 7)
        | (_bits(imm, 7, 7) << 6)
        | (_bits(imm, 3, 1) << 3)
        | (_bits(imm, 5, 5) << 2)
        | 0b01
    )


def encode_c_li(rd, imm):
    """C.LI: rd = sign-extend(imm)"""
    check_range(imm, 6, signed=True, what="c.li immediate")
    imm &= 0x3F
    return (
        (0b010 << 13)
        | (_bits(imm, 5, 5) << 12)
        | ((rd & 0x1F) << 7)
        | (_bits(imm, 4, 0) << 2)
        | 0b01
    )


def encode_c_addi16sp(nzimm):
    """C.ADDI16SP: sp = sp + nzimm; nzimm multiple of 16, -512..496"""
    if nzimm == 0 or nzimm % 16 != 0:
        raise AsmError(f"c.addi16sp nzimm {nzimm} invalid (must be non-zero multiple of 16)")
    check_range(nzimm, 10, signed=True, what="c.addi16sp immediate")
    nzimm &= 0x3FF
    # nzimm[9|4|6|8:7|5] → ci[12|6:2]
    return (
        (0b011 << 13)
        | (_bits(nzimm, 9, 9) << 12)
        | (2 << 7)  # rd=x2
        | (_bits(nzimm, 4, 4) << 6)
        | (_bits(nzimm, 6, 6) << 5)
        | (_bits(nzimm, 8, 7) << 3)
        | (_bits(nzimm, 5, 5) << 2)
        | 0b01
    )


def encode_c_lui(rd, nzimm):
    """C.LUI: rd = nzimm << 12; nzimm is sign-extended 6-bit (upper 20 bits)"""
    # nzimm represents the value in units of the upper immediate
    # The 6-bit immediate is sign-extended: nzimm[17:12]
    if nzimm == 0:
        raise AsmError("c.lui nzimm must be non-zero")
    check_range(nzimm, 6, signed=True, what="c.lui immediate (nzimm[17:12])")
    nzimm &= 0x3F
    if rd == 0 or rd == 2:
        raise AsmError(f"c.lui rd cannot be x0 or x2")
    return (
        (0b011 << 13)
        | (_bits(nzimm, 5, 5) << 12)
        | ((rd & 0x1F) << 7)
        | (_bits(nzimm, 4, 0) << 2)
        | 0b01
    )


def encode_c_srli(rd, shamt):
    """C.SRLI: rd' = rd' >> shamt"""
    if not _is_creg(rd):
        raise AsmError(f"c.srli rd must be x8-x15")
    if shamt == 0 or shamt > 31:
        raise AsmError(f"c.srli shamt {shamt} invalid (must be 1..31)")
    return (
        (0b100 << 13)
        | (0 << 12)  # shamt[5]=0 for RV32
        | (0b00 << 10)
        | (_creg(rd) << 7)
        | ((shamt & 0x1F) << 2)
        | 0b01
    )


def encode_c_srai(rd, shamt):
    """C.SRAI: rd' = rd' >>> shamt"""
    if not _is_creg(rd):
        raise AsmError(f"c.srai rd must be x8-x15")
    if shamt == 0 or shamt > 31:
        raise AsmError(f"c.srai shamt {shamt} invalid (must be 1..31)")
    return (
        (0b100 << 13)
        | (0 << 12)
        | (0b01 << 10)
        | (_creg(rd) << 7)
        | ((shamt & 0x1F) << 2)
        | 0b01
    )


def encode_c_andi(rd, imm):
    """C.ANDI: rd' = rd' & sign-extend(imm)"""
    if not _is_creg(rd):
        raise AsmError(f"c.andi rd must be x8-x15")
    check_range(imm, 6, signed=True, what="c.andi immediate")
    imm &= 0x3F
    return (
        (0b100 << 13)
        | (_bits(imm, 5, 5) << 12)
        | (0b10 << 10)
        | (_creg(rd) << 7)
        | (_bits(imm, 4, 0) << 2)
        | 0b01
    )


def encode_c_sub(rd, rs2):
    if not _is_creg(rd) or not _is_creg(rs2):
        raise AsmError("c.sub registers must be x8-x15")
    return (0b100 << 13) | (0b0 << 12) | (0b11 << 10) | (_creg(rd) << 7) | (0b00 << 5) | (_creg(rs2) << 2) | 0b01


def encode_c_xor(rd, rs2):
    if not _is_creg(rd) or not _is_creg(rs2):
        raise AsmError("c.xor registers must be x8-x15")
    return (0b100 << 13) | (0b0 << 12) | (0b11 << 10) | (_creg(rd) << 7) | (0b01 << 5) | (_creg(rs2) << 2) | 0b01


def encode_c_or(rd, rs2):
    if not _is_creg(rd) or not _is_creg(rs2):
        raise AsmError("c.or registers must be x8-x15")
    return (0b100 << 13) | (0b0 << 12) | (0b11 << 10) | (_creg(rd) << 7) | (0b10 << 5) | (_creg(rs2) << 2) | 0b01


def encode_c_and(rd, rs2):
    if not _is_creg(rd) or not _is_creg(rs2):
        raise AsmError("c.and registers must be x8-x15")
    return (0b100 << 13) | (0b0 << 12) | (0b11 << 10) | (_creg(rd) << 7) | (0b11 << 5) | (_creg(rs2) << 2) | 0b01


def encode_c_j(imm):
    """C.J: jal x0, imm"""
    check_range(imm, 12, signed=True, what="c.j offset")
    if imm % 2 != 0:
        raise AsmError(f"c.j offset {imm} not 2-byte aligned")
    imm &= 0xFFF
    return (
        (0b101 << 13)
        | (_bits(imm, 11, 11) << 12)
        | (_bits(imm, 4, 4) << 11)
        | (_bits(imm, 9, 8) << 9)
        | (_bits(imm, 10, 10) << 8)
        | (_bits(imm, 6, 6) << 7)
        | (_bits(imm, 7, 7) << 6)
        | (_bits(imm, 3, 1) << 3)
        | (_bits(imm, 5, 5) << 2)
        | 0b01
    )


def encode_c_beqz(rs1, imm):
    """C.BEQZ: beq rs1', x0, imm"""
    if not _is_creg(rs1):
        raise AsmError("c.beqz rs1 must be x8-x15")
    check_range(imm, 9, signed=True, what="c.beqz offset")
    if imm % 2 != 0:
        raise AsmError(f"c.beqz offset {imm} not 2-byte aligned")
    imm &= 0x1FF
    # offset[8|4:3|7:6|2:1|5] → ci[12|11:10|6:5|4:3|2]
    return (
        (0b110 << 13)
        | (_bits(imm, 8, 8) << 12)
        | (_bits(imm, 4, 3) << 10)
        | (_creg(rs1) << 7)
        | (_bits(imm, 7, 6) << 5)
        | (_bits(imm, 2, 1) << 3)
        | (_bits(imm, 5, 5) << 2)
        | 0b01
    )


def encode_c_bnez(rs1, imm):
    """C.BNEZ: bne rs1', x0, imm"""
    if not _is_creg(rs1):
        raise AsmError("c.bnez rs1 must be x8-x15")
    check_range(imm, 9, signed=True, what="c.bnez offset")
    if imm % 2 != 0:
        raise AsmError(f"c.bnez offset {imm} not 2-byte aligned")
    imm &= 0x1FF
    return (
        (0b111 << 13)
        | (_bits(imm, 8, 8) << 12)
        | (_bits(imm, 4, 3) << 10)
        | (_creg(rs1) << 7)
        | (_bits(imm, 7, 6) << 5)
        | (_bits(imm, 2, 1) << 3)
        | (_bits(imm, 5, 5) << 2)
        | 0b01
    )


def encode_c_slli(rd, shamt):
    """C.SLLI: rd = rd << shamt"""
    if rd == 0:
        raise AsmError("c.slli rd cannot be x0")
    if shamt == 0 or shamt > 31:
        raise AsmError(f"c.slli shamt {shamt} invalid (must be 1..31)")
    return (
        (0b000 << 13)
        | (0 << 12)  # shamt[5]=0 for RV32
        | ((rd & 0x1F) << 7)
        | ((shamt & 0x1F) << 2)
        | 0b10
    )


def encode_c_lwsp(rd, offset):
    """C.LWSP: rd = mem[sp + offset]; offset multiple of 4, 0..252"""
    if rd == 0:
        raise AsmError("c.lwsp rd cannot be x0")
    if offset < 0 or offset > 252 or offset % 4 != 0:
        raise AsmError(f"c.lwsp offset {offset} invalid (must be 0..252, multiple of 4)")
    o = offset
    # offset[5|4:2|7:6] → ci[12|6:4|3:2]
    return (
        (0b010 << 13)
        | (_bits(o, 5, 5) << 12)
        | ((rd & 0x1F) << 7)
        | (_bits(o, 4, 2) << 4)
        | (_bits(o, 7, 6) << 2)
        | 0b10
    )


def encode_c_jr(rs1):
    """C.JR: jalr x0, 0(rs1)"""
    if rs1 == 0:
        raise AsmError("c.jr rs1 cannot be x0")
    return (0b100 << 13) | (0 << 12) | ((rs1 & 0x1F) << 7) | (0 << 2) | 0b10


def encode_c_mv(rd, rs2):
    """C.MV: add rd, x0, rs2"""
    if rs2 == 0:
        raise AsmError("c.mv rs2 cannot be x0")
    return (0b100 << 13) | (0 << 12) | ((rd & 0x1F) << 7) | ((rs2 & 0x1F) << 2) | 0b10


def encode_c_ebreak():
    """C.EBREAK"""
    return (0b100 << 13) | (1 << 12) | (0 << 7) | (0 << 2) | 0b10


def encode_c_jalr(rs1):
    """C.JALR: jalr x1, 0(rs1)"""
    if rs1 == 0:
        raise AsmError("c.jalr rs1 cannot be x0")
    return (0b100 << 13) | (1 << 12) | ((rs1 & 0x1F) << 7) | (0 << 2) | 0b10


def encode_c_add(rd, rs2):
    """C.ADD: add rd, rd, rs2"""
    if rs2 == 0:
        raise AsmError("c.add rs2 cannot be x0")
    return (0b100 << 13) | (1 << 12) | ((rd & 0x1F) << 7) | ((rs2 & 0x1F) << 2) | 0b10


def encode_c_swsp(rs2, offset):
    """C.SWSP: mem[sp + offset] = rs2; offset multiple of 4, 0..252"""
    if offset < 0 or offset > 252 or offset % 4 != 0:
        raise AsmError(f"c.swsp offset {offset} invalid (must be 0..252, multiple of 4)")
    o = offset
    # offset[5:2|7:6] → ci[12:9|8:7]
    return (
        (0b110 << 13)
        | (_bits(o, 5, 2) << 9)
        | (_bits(o, 7, 6) << 7)
        | ((rs2 & 0x1F) << 2)
        | 0b10
    )


# ================================================================
# Instruction size helper
# ================================================================

def instr_size(op):
    """Return instruction size in bytes: 2 for C extension, 4 for normal/word."""
    if op.startswith("c.") or op == ".half":
        return 2
    return 4


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
            elif directive == ".half":
                values = split_operands(rest[0] if rest else "")
                if not values:
                    raise AsmError(f"{path}:{lineno}: .half needs an operand")
                for value in values:
                    items.append((pc, lineno, ".half", [value]))
                    pc += 2
            elif directive == ".align":
                align_val = int(rest[0].strip()) if rest else 4
                align_bytes = 1 << align_val if align_val < 16 else align_val
                while pc % align_bytes != 0:
                    items.append((pc, lineno, ".half", ["0"]))
                    pc += 2
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
            pc += instr_size(exp_op)

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
    """Encode a single instruction. Returns (value, size_in_bytes)."""

    if op == ".word":
        expect(op, operands, 1)
        return parse_int(operands[0]) & 0xFFFFFFFF, 4

    if op == ".half":
        expect(op, operands, 1)
        return parse_int(operands[0]) & 0xFFFF, 2

    # ---- C extension instructions ----
    if op == "c.addi4spn":
        expect(op, operands, 2)
        return encode_c_addi4spn(reg(operands[0]), parse_int(operands[1])), 2

    if op == "c.lw":
        expect(op, operands, 2)
        off, rs1 = parse_mem(operands[1])
        return encode_c_lw(reg(operands[0]), rs1, off), 2

    if op == "c.sw":
        expect(op, operands, 2)
        off, rs1 = parse_mem(operands[1])
        return encode_c_sw(reg(operands[0]), rs1, off), 2

    if op == "c.nop":
        expect(op, operands, 0)
        return encode_c_nop(), 2

    if op == "c.addi":
        expect(op, operands, 2)
        return encode_c_addi(reg(operands[0]), parse_int(operands[1])), 2

    if op == "c.jal":
        expect(op, operands, 1)
        imm = resolve_imm(operands[0], labels, pc)
        return encode_c_jal(imm), 2

    if op == "c.li":
        expect(op, operands, 2)
        return encode_c_li(reg(operands[0]), parse_int(operands[1])), 2

    if op == "c.addi16sp":
        expect(op, operands, 1)
        return encode_c_addi16sp(parse_int(operands[0])), 2

    if op == "c.lui":
        expect(op, operands, 2)
        return encode_c_lui(reg(operands[0]), parse_int(operands[1])), 2

    if op == "c.srli":
        expect(op, operands, 2)
        return encode_c_srli(reg(operands[0]), parse_int(operands[1])), 2

    if op == "c.srai":
        expect(op, operands, 2)
        return encode_c_srai(reg(operands[0]), parse_int(operands[1])), 2

    if op == "c.andi":
        expect(op, operands, 2)
        return encode_c_andi(reg(operands[0]), parse_int(operands[1])), 2

    if op == "c.sub":
        expect(op, operands, 2)
        return encode_c_sub(reg(operands[0]), reg(operands[1])), 2

    if op == "c.xor":
        expect(op, operands, 2)
        return encode_c_xor(reg(operands[0]), reg(operands[1])), 2

    if op == "c.or":
        expect(op, operands, 2)
        return encode_c_or(reg(operands[0]), reg(operands[1])), 2

    if op == "c.and":
        expect(op, operands, 2)
        return encode_c_and(reg(operands[0]), reg(operands[1])), 2

    if op == "c.j":
        expect(op, operands, 1)
        imm = resolve_imm(operands[0], labels, pc)
        return encode_c_j(imm), 2

    if op == "c.beqz":
        expect(op, operands, 2)
        imm = resolve_imm(operands[1], labels, pc)
        return encode_c_beqz(reg(operands[0]), imm), 2

    if op == "c.bnez":
        expect(op, operands, 2)
        imm = resolve_imm(operands[1], labels, pc)
        return encode_c_bnez(reg(operands[0]), imm), 2

    if op == "c.slli":
        expect(op, operands, 2)
        return encode_c_slli(reg(operands[0]), parse_int(operands[1])), 2

    if op == "c.lwsp":
        expect(op, operands, 2)
        off, rs1 = parse_mem(operands[1])
        if rs1 != 2:
            raise AsmError("c.lwsp base must be x2/sp")
        return encode_c_lwsp(reg(operands[0]), off), 2

    if op == "c.jr":
        expect(op, operands, 1)
        return encode_c_jr(reg(operands[0])), 2

    if op == "c.mv":
        expect(op, operands, 2)
        return encode_c_mv(reg(operands[0]), reg(operands[1])), 2

    if op == "c.ebreak":
        expect(op, operands, 0)
        return encode_c_ebreak(), 2

    if op == "c.jalr":
        expect(op, operands, 1)
        return encode_c_jalr(reg(operands[0])), 2

    if op == "c.add":
        expect(op, operands, 2)
        return encode_c_add(reg(operands[0]), reg(operands[1])), 2

    if op == "c.swsp":
        expect(op, operands, 2)
        off, rs1 = parse_mem(operands[1])
        if rs1 != 2:
            raise AsmError("c.swsp base must be x2/sp")
        return encode_c_swsp(reg(operands[0]), off), 2

    # ---- A extension instructions ----
    if op == "lr.w":
        expect(op, operands, 2)
        imm, rs1 = parse_mem(operands[1])
        if imm != 0:
            raise AsmError("lr.w offset must be 0")
        return encode_amo(A_OPS["lr.w"], 0, rs1, 0b010, reg(operands[0])), 4

    if op in A_OPS and op != "lr.w":
        expect(op, operands, 3)
        imm, rs1 = parse_mem(operands[2])
        if imm != 0:
            raise AsmError(f"{op} offset must be 0")
        return encode_amo(A_OPS[op], reg(operands[1]), rs1, 0b010, reg(operands[0])), 4

    # ---- Standard 32-bit instructions ----
    if op in R_OPS:
        expect(op, operands, 3)
        funct3, funct7 = R_OPS[op]
        return encode_r(funct7, reg(operands[2]), reg(operands[1]), funct3, reg(operands[0])), 4

    if op in I_OPS:
        expect(op, operands, 3)
        return encode_i(parse_int(operands[2]), reg(operands[1]), I_OPS[op], reg(operands[0]), 0b0010011), 4

    if op in SHIFT_I_OPS:
        expect(op, operands, 3)
        shamt = parse_int(operands[2])
        if not 0 <= shamt <= 31:
            raise AsmError(f"shift amount {shamt} is out of range")
        funct3, funct7 = SHIFT_I_OPS[op]
        imm = (funct7 << 5) | shamt
        return encode_i(imm, reg(operands[1]), funct3, reg(operands[0]), 0b0010011), 4

    if op in LOAD_OPS:
        expect(op, operands, 2)
        imm, rs1 = parse_mem(operands[1])
        return encode_i(imm, rs1, LOAD_OPS[op], reg(operands[0]), 0b0000011), 4

    if op in STORE_OPS:
        expect(op, operands, 2)
        imm, rs1 = parse_mem(operands[1])
        return encode_s(imm, reg(operands[0]), rs1, STORE_OPS[op]), 4

    if op in BRANCH_OPS:
        expect(op, operands, 3)
        imm = resolve_imm(operands[2], labels, pc)
        return encode_b(imm, reg(operands[1]), reg(operands[0]), BRANCH_OPS[op]), 4

    if op == "lui":
        expect(op, operands, 2)
        imm = parse_int(operands[1])
        return encode_u(imm, reg(operands[0]), 0b0110111), 4

    if op == "_li_hi":
        expect(op, operands, 2)
        imm_hi, _ = split_li_value(resolve_abs(operands[1], labels))
        return encode_u(imm_hi, reg(operands[0]), 0b0110111), 4

    if op == "_li_lo":
        expect(op, operands, 3)
        _, imm_lo = split_li_value(resolve_abs(operands[2], labels))
        return encode_i(imm_lo, reg(operands[1]), 0b000, reg(operands[0]), 0b0010011), 4

    if op == "auipc":
        expect(op, operands, 2)
        imm = parse_int(operands[1])
        return encode_u(imm, reg(operands[0]), 0b0010111), 4

    if op == "jal":
        expect(op, operands, 2)
        imm = resolve_imm(operands[1], labels, pc)
        return encode_j(imm, reg(operands[0])), 4

    if op == "jalr":
        expect(op, operands, 2)
        imm, rs1 = parse_mem(operands[1])
        return encode_i(imm, rs1, 0b000, reg(operands[0]), 0b1100111), 4

    if op == "fence":
        expect(op, operands, 0)
        return 0x0000000F, 4

    raise AsmError(f"unsupported instruction '{op}'")


def assemble(path):
    items, labels = parse_source(path)

    # Build a byte-level representation, then pack into 32-bit words
    # Collect (pc, value, size) tuples
    encoded = []
    listing = []
    for pc, lineno, op, operands in items:
        try:
            val, size = encode_item(pc, op, operands, labels)
        except AsmError as exc:
            raise AsmError(f"{path}:{lineno}: {exc}") from exc
        encoded.append((pc, val, size))
        listing.append((pc, val, size, op, operands))

    # Find total size in bytes
    if not encoded:
        return [], listing

    max_addr = max(pc + sz for pc, _, sz in encoded)
    # Round up to word boundary
    total_words = (max_addr + 3) // 4
    byte_mem = bytearray(total_words * 4)

    for pc, val, size in encoded:
        if size == 2:
            byte_mem[pc] = val & 0xFF
            byte_mem[pc + 1] = (val >> 8) & 0xFF
        else:  # size == 4
            byte_mem[pc] = val & 0xFF
            byte_mem[pc + 1] = (val >> 8) & 0xFF
            byte_mem[pc + 2] = (val >> 16) & 0xFF
            byte_mem[pc + 3] = (val >> 24) & 0xFF

    # Extract 32-bit words (little-endian)
    words = []
    for i in range(total_words):
        base = i * 4
        w = (byte_mem[base]
             | (byte_mem[base + 1] << 8)
             | (byte_mem[base + 2] << 16)
             | (byte_mem[base + 3] << 24))
        words.append(w)

    return words, listing


def main():
    parser = argparse.ArgumentParser(description="Tiny RV32IMAC assembler for repository tests")
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
        lines = []
        for pc, val, size, op, operands in listing:
            if size == 2:
                lines.append(f"{pc:08x}:     {val:04x}    {op} {', '.join(operands)}\n")
            else:
                lines.append(f"{pc:08x}: {val:08x}    {op} {', '.join(operands)}\n")
        lst.write_text("".join(lines))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
