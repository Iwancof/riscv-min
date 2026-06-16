#!/bin/bash
set -e

PROJ=$(cd "$(dirname "$0")/.." && pwd)
RISCV_TESTS=/tmp/riscv-tests
OUT=$PROJ/build/riscv-tests
ENV=$PROJ/riscv-tests/env
LINK=$PROJ/riscv-tests/link.ld
MACROS=$RISCV_TESTS/isa/macros/scalar

CC=riscv64-elf-gcc
OBJCOPY=riscv64-elf-objcopy

CFLAGS="-march=rv32imac -mabi=ilp32 -nostdlib -nostartfiles -I$ENV -I$MACROS -T$LINK"

mkdir -p "$OUT"

pass=0
fail=0
skip=0

# rv32ui tests
for src in "$RISCV_TESTS"/isa/rv32ui/*.S; do
    name=$(basename "$src" .S)
    [[ "$name" == "Makefrag" ]] && continue
    # Skip tests that need CSR/fence_i
    [[ "$name" == "fence_i" || "$name" == "ma_data" ]] && { skip=$((skip+1)); continue; }

    if $CC $CFLAGS -o "$OUT/$name.elf" "$src" \
        -I"$RISCV_TESTS/isa/rv32ui" \
        -I"$RISCV_TESTS/isa/rv64ui" 2>/dev/null; then
        $OBJCOPY -O binary "$OUT/$name.elf" "$OUT/$name.bin"
        # Convert binary to hex (32-bit words, little-endian)
        python3 -c "
import sys
with open('$OUT/$name.bin','rb') as f: data=f.read()
# Pad to multiple of 4
while len(data)%4: data+=b'\\x00'
for i in range(0,len(data),4):
    w=int.from_bytes(data[i:i+4],'little')
    print(f'{w:08x}')
" > "$OUT/$name.hex"
        pass=$((pass+1))
    else
        fail=$((fail+1))
        echo "BUILD FAIL: $name"
    fi
done

# rv32um tests
for src in "$RISCV_TESTS"/isa/rv32um/*.S; do
    name=$(basename "$src" .S)
    [[ "$name" == "Makefrag" ]] && continue

    if $CC $CFLAGS -o "$OUT/$name.elf" "$src" \
        -I"$RISCV_TESTS/isa/rv32um" \
        -I"$RISCV_TESTS/isa/rv64um" 2>/dev/null; then
        $OBJCOPY -O binary "$OUT/$name.elf" "$OUT/$name.bin"
        python3 -c "
import sys
with open('$OUT/$name.bin','rb') as f: data=f.read()
while len(data)%4: data+=b'\\x00'
for i in range(0,len(data),4):
    w=int.from_bytes(data[i:i+4],'little')
    print(f'{w:08x}')
" > "$OUT/$name.hex"
        pass=$((pass+1))
    else
        fail=$((fail+1))
        echo "BUILD FAIL: $name"
    fi
done

# rv32ua tests
for src in "$RISCV_TESTS"/isa/rv32ua/*.S; do
    name=$(basename "$src" .S)
    [[ "$name" == "Makefrag" ]] && continue

    if $CC $CFLAGS -o "$OUT/$name.elf" "$src" \
        -I"$RISCV_TESTS/isa/rv32ua" \
        -I"$RISCV_TESTS/isa/rv64ua" 2>/dev/null; then
        $OBJCOPY -O binary "$OUT/$name.elf" "$OUT/$name.bin"
        python3 -c "
import sys
with open('$OUT/$name.bin','rb') as f: data=f.read()
while len(data)%4: data+=b'\\x00'
for i in range(0,len(data),4):
    w=int.from_bytes(data[i:i+4],'little')
    print(f'{w:08x}')
" > "$OUT/$name.hex"
        pass=$((pass+1))
    else
        fail=$((fail+1))
        echo "BUILD FAIL: $name"
    fi
done

# rv32uc test
for src in "$RISCV_TESTS"/isa/rv32uc/*.S; do
    name=$(basename "$src" .S)
    [[ "$name" == "Makefrag" ]] && continue

    if $CC $CFLAGS -o "$OUT/$name.elf" "$src" \
        -I"$RISCV_TESTS/isa/rv32uc" \
        -I"$RISCV_TESTS/isa/rv64uc" 2>/dev/null; then
        $OBJCOPY -O binary "$OUT/$name.elf" "$OUT/$name.bin"
        python3 -c "
import sys
with open('$OUT/$name.bin','rb') as f: data=f.read()
while len(data)%4: data+=b'\\x00'
for i in range(0,len(data),4):
    w=int.from_bytes(data[i:i+4],'little')
    print(f'{w:08x}')
" > "$OUT/$name.hex"
        pass=$((pass+1))
    else
        fail=$((fail+1))
        echo "BUILD FAIL: $name"
    fi
done

echo "Built: $pass ok, $fail failed, $skip skipped"
