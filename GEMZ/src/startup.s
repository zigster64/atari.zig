    .section .text._startup,"ax",@progbits
    .globl _startup
_startup:
    bra _start

/* Mark the stack non-executable so GNU ld doesn't warn about an
 * "executable stack" on this bare 68000 object. */
.section .note.GNU-stack,"",@progbits
