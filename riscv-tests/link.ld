OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
    . = 0x00000000;
    .text : { *(.text .text.*) }
    . = ALIGN(4);
    .data : { *(.data .data.* .rodata .rodata.*) }
    . = ALIGN(4);
    .bss : { *(.bss .bss.* COMMON) }
    _end = .;
}
