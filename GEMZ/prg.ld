ENTRY(_startup)

SECTIONS
{
    .text : ALIGN(4) {
        KEEP(*(.text._startup))
        *(.text._start)
        *(.text)
        *(.text.*)
        . = ALIGN(16);
    }

    .data : ALIGN(4) {
        *(.data)
        *(.data.*)
        *(.rodata)
        *(.rodata.*)
        . = ALIGN(4);
    }

    .bss : ALIGN(4) {
        *(.bss)
        *(.bss.*)
        . = ALIGN(4);
    }

    /DISCARD/ : {
        *(.comment)
        *(.note.*)
        *(.eh_frame*)
        *(.debug*)
    }
}
