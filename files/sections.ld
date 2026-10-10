MEMORY
{
    APPRAM (rwx) : ORIGIN = 0x10000000, LENGTH = 8K
}

SECTIONS
{
    . = 0x10000000;

    .text : {
        *(.text*)
    } > APPRAM

    .rodata : {
        *(.rodata*)
    } > APPRAM

    .data : {
        *(.data*)
    } > APPRAM

    .bss : {
        *(.bss*)
        *(COMMON)
    } > APPRAM
}
