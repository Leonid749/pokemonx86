; 512-byte MBR boot sector.
;
; The BIOS loads only this one sector at 0x7C00 and jumps here with the boot
; drive number in dl. All it does is pull stage 2 off the disk and jump to it.
;
; Uses INT 13h AH=42h (extended/LBA read), which every BIOS that can boot from
; USB supports -- CHS addressing would not survive a USB stick's geometry.

BITS 16
ORG 0x7C00

STAGE2_SEG  equ 0x0000
STAGE2_OFF  equ 0x8000
STAGE2_LBA  equ 1
STAGE2_SECS equ 32                 ; 16KB is plenty for stage 2

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    mov [drive], dl                ; BIOS hands us the boot drive

    mov si, dap
    mov ah, 0x42
    mov dl, [drive]
    int 0x13
    jc  .fail

    mov dl, [drive]                ; stage 2 needs it too
    jmp STAGE2_SEG:STAGE2_OFF

.fail:
    mov si, msg_err
.print:
    lodsb
    test al, al
    jz  .hang
    mov ah, 0x0E
    mov bx, 0x0007
    int 0x10
    jmp .print
.hang:
    hlt
    jmp .hang

drive:   db 0
msg_err: db "sharpemu: disk read failed", 0

align 4
dap:
    db 0x10                        ; packet size
    db 0
    dw STAGE2_SECS
    dw STAGE2_OFF
    dw STAGE2_SEG
    dq STAGE2_LBA

times 510-($-$$) db 0
dw 0xAA55
