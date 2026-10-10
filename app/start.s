.section .text
.global _start

_start:
    la   sp, 0x10001ffc   /* stack pointer at top of 8 KB App RAM */
    call main
hang:
    j    hang
