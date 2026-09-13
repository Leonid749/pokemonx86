; Stage 2: real-mode setup, then hand off to the existing 32-bit kernel entry.
;
; Does the three things QEMU's -kernel was doing for us:
;   1. sets a video mode  -- via VBE, because INT 10h only exists in real mode
;                            and Bochs DISPI is not real hardware
;   2. loads kernel + ROM -- via INT 13h LBA, copying above 1MB in unreal mode
;   3. fakes a multiboot info block, so boot.asm's entry32 works unchanged
;
; Disk layout (LBA, 512-byte sectors):
;   0        boot sector
;   1..32    this stage
;   33..96   kernel  (32KB)
;   128..    ROM     (1MB = 2048 sectors)

BITS 16
ORG 0x8000

KERNEL_LBA   equ 33
KERNEL_SECS  equ 64                ; 32KB
KERNEL_DEST  equ 0x00100000

SRAM_LBA     equ 2176            ; 64 sectors of saved SRAM, after the ROM
SRAM_SECS    equ 64
SRAM_DEST    equ 0x00410000      ; must match GB_SRAM in mem.asm

ROM_LBA      equ 128
ROM_SECS     equ 2048              ; 1MB
ROM_DEST     equ 0x02000000        ; 32MB, clear of everything else

BUF_SEG      equ 0x1000            ; 0x10000, 32KB staging buffer
BUF_SECS     equ 64

HANDOFF      equ 0x00007000        ; video info for the kernel
MBI          equ 0x00006000        ; fake multiboot info block
MB_MOD       equ 0x00006100

VBE_MODE     equ 0x0112            ; 640x480x32; +0x4000 requests LFB

stage2:
    mov [drive], dl
    xor ax, ax
    mov ds, ax
    mov es, ax

    call s_init
    mov al, '1'
    call s_putc

    call enable_a20
    mov al, 'A'
    call s_putc

    call set_vbe
    mov al, 'V'
    call s_putc

    call unreal
    mov al, 'U'
    call s_putc

    ; --- kernel ---
    mov eax, KERNEL_LBA
    mov ecx, KERNEL_SECS
    mov edi, KERNEL_DEST
    call load_high
    mov al, 'K'
    call s_putc

    ; --- ROM ---
    mov eax, ROM_LBA
    mov ecx, ROM_SECS
    mov edi, ROM_DEST
    call load_high
    mov al, 'R'
    call s_putc

    ; --- saved SRAM (harmless if never written: reads back as zeros) ---
    mov eax, SRAM_LBA
    mov ecx, SRAM_SECS
    mov edi, SRAM_DEST
    call load_high
    mov al, 'S'
    call s_putc

    mov al, [drive]                ; the save thunk needs this later
    mov [HANDOFF + 24], al

    call build_mbi
    mov al, 'M'
    call s_putc
    jmp  enter_pmode

; ---- 16-bit serial, so stage 2 is observable before the kernel starts ----
s_init:
    mov dx, 0x3F9
    xor al, al
    out dx, al
    mov dx, 0x3FB
    mov al, 0x80
    out dx, al
    mov dx, 0x3F8
    mov al, 1
    out dx, al
    mov dx, 0x3F9
    xor al, al
    out dx, al
    mov dx, 0x3FB
    mov al, 0x03
    out dx, al
    ret

s_putc:                            ; al = char
    push ax
    push dx
.wait:
    mov dx, 0x3FD
    in  al, dx
    test al, 0x20
    jz  .wait
    pop dx
    pop ax
    push dx
    mov dx, 0x3F8
    out dx, al
    pop dx
    ret

; ---------------------------------------------------------------- A20
enable_a20:
    in  al, 0x92
    test al, 2
    jnz .done
    or  al, 2
    and al, 0xFE                   ; never write bit0: that is a fast reset
    out 0x92, al
.done:
    ret

; ---------------------------------------------------------------- VBE
; Query the mode, confirm it has a linear framebuffer, set it, and record the
; framebuffer address and pitch for the kernel.
set_vbe:
    mov ax, 0x4F01
    mov cx, VBE_MODE
    mov di, vbe_info
    int 0x10
    cmp ax, 0x004F
    jne .fail
    test word [vbe_info], 0x80     ; ModeAttributes bit 7 = LFB available
    jz  .fail

    mov ax, 0x4F02
    mov bx, VBE_MODE | 0x4000      ; bit 14 = use LFB
    int 0x10
    cmp ax, 0x004F
    jne .fail

    mov eax, [vbe_info + 40]       ; PhysBasePtr
    mov [HANDOFF + 4], eax
    movzx eax, word [vbe_info + 16] ; BytesPerScanLine
    mov [HANDOFF + 8], eax
    movzx eax, word [vbe_info + 18] ; XResolution
    mov [HANDOFF + 12], eax
    movzx eax, word [vbe_info + 20] ; YResolution
    mov [HANDOFF + 16], eax
    movzx eax, byte [vbe_info + 25] ; BitsPerPixel -- 0x112 is 24bpp, not 32
    add eax, 7
    shr eax, 3                      ; -> bytes per pixel
    mov [HANDOFF + 20], eax
    mov dword [HANDOFF], 0x5342_4556 ; "VESA" magic: kernel checks for this
    ret
.fail:
    mov si, msg_vbe
    jmp fatal

; ------------------------------------------------------- unreal mode
; Give es a 4GB limit so 32-bit offsets work while still in real mode. The
; hidden descriptor cache keeps that limit after we drop back to real mode, as
; long as nothing reloads es -- BIOS calls can, so this is re-run before each
; copy rather than once at startup.
; Preserves eax and ebx: load_high keeps the LBA in eax and the sector count in
; bx across this call, and this routine needs both internally.
unreal:
    cli
    push eax
    push ebx
    push ds
    lgdt [gdt_ptr]
    mov eax, cr0
    or  al, 1
    mov cr0, eax
    jmp $+2
    mov bx, 0x08                   ; flat data descriptor
    mov es, bx
    mov eax, cr0
    and al, 0xFE
    mov cr0, eax
    jmp $+2
    pop ds
    pop ebx
    pop eax
    sti
    ret

; ---------------------------------------------------- disk -> high memory
; eax = start LBA, ecx = sector count, edi = destination physical address
load_high:
    push ds
.next:
    test ecx, ecx
    jz  .done

    mov ebx, ecx
    cmp ebx, BUF_SECS
    jbe .have
    mov ebx, BUF_SECS
.have:
    ; read ebx sectors at LBA eax into BUF_SEG:0
    mov [dap_lba], eax
    mov [dap_cnt], bx
    push eax
    push ecx
    push edi
    mov al, 'r'
    call s_putc
    mov si, dap
    mov ah, 0x42
    mov dl, [drive]
    int 0x13
    jc  .rd_fail
    mov al, 'd'
    call s_putc
    pop edi
    pop ecx
    pop eax

    ; Copy the staging buffer up. The source is addressed through a normal
    ; real-mode ds (offsets stay under 32KB) and only the destination needs the
    ; unreal 4GB es -- so ds never needs a large limit.
    push eax                       ; the LBA: `mov ax, BUF_SEG` below would eat it
    push ecx
    push esi
    call unreal                    ; BIOS may have reloaded es
    push ds
    mov ax, BUF_SEG
    mov ds, ax
    xor si, si
    movzx ecx, bx
    shl ecx, 9                     ; sectors -> bytes
    shr ecx, 2                     ; -> dwords
.copy:
    mov edx, [si]
    mov [es:edi], edx
    add si, 4
    add edi, 4
    dec ecx
    jnz .copy
    pop ds
    pop esi
    pop ecx
    pop eax

    movzx edx, bx
    add eax, edx
    sub ecx, edx
    jmp .next

.done:
    pop ds
    ret
.rd_fail:
    mov bl, ah                     ; INT 13h error code
    mov al, 'x'
    call s_putc
    mov al, bl
    call s_hex
    mov al, '@'
    call s_putc
    mov eax, [dap_lba]
    call s_hex32
    jmp $

s_hex:                             ; al = byte
    push ax
    shr al, 4
    call s_nib
    pop ax
    call s_nib
    ret
s_nib:
    and al, 0x0F
    add al, '0'
    cmp al, '9'
    jbe .p
    add al, 7
.p:
    call s_putc
    ret
s_hex32:                           ; eax = dword
    push eax
    shr eax, 24
    call s_hex
    pop eax
    push eax
    shr eax, 16
    call s_hex
    pop eax
    push eax
    shr eax, 8
    call s_hex
    pop eax
    call s_hex
    ret
.fail:
    mov si, msg_disk
    jmp fatal

; --------------------------------------------- fake multiboot info block
; boot.asm reads mods_count at +20 and mods_addr at +24, then mod_start at +0.
build_mbi:
    push es
    xor ax, ax
    mov es, ax

    mov di, MBI
    mov cx, 128
    xor ax, ax
    rep stosb

    mov dword [es:MBI + 0],  1 << 3      ; flags: modules present
    mov dword [es:MBI + 20], 1           ; mods_count
    mov dword [es:MBI + 24], MB_MOD      ; mods_addr
    mov dword [es:MB_MOD + 0], ROM_DEST
    mov dword [es:MB_MOD + 4], ROM_DEST + (ROM_SECS * 512)
    pop es
    ret

; ------------------------------------------------------- into the kernel
enter_pmode:
    cli
    lgdt [gdt_ptr]
    mov eax, cr0
    or  al, 1
    mov cr0, eax
    jmp 0x10:pm_entry

BITS 32
pm_entry:
    mov ax, 0x08
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov esp, 0x7000

    ; The kernel image starts with its multiboot header, not code. Take the
    ; real entry point from the header's entry_addr field (offset 28), which is
    ; what QEMU's -kernel loader does.
    mov ecx, [KERNEL_DEST + 28]
    mov eax, 0x2BADB002            ; multiboot magic, as a loader would pass
    mov ebx, MBI
    jmp ecx

BITS 16
fatal:
    lodsb
    test al, al
    jz  .hang
    mov ah, 0x0E
    mov bx, 7
    int 0x10
    jmp fatal
.hang:
    hlt
    jmp .hang

drive:    db 0
msg_vbe:  db "no VBE linear mode", 0
msg_disk: db "disk error", 0

align 4
dap:
    db 0x10
    db 0
dap_cnt: dw 0
    dw 0                           ; offset
    dw BUF_SEG                     ; segment
dap_lba: dq 0

align 8
gdt:
    dq 0
    dq 0x00CF92000000FFFF          ; 0x08: flat 4GB data
    dq 0x00CF9A000000FFFF          ; 0x10: flat 4GB code
gdt_ptr:
    dw gdt_ptr - gdt - 1
    dd gdt

align 4
vbe_info: times 256 db 0
