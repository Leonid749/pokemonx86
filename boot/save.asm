; SRAM persistence.
;
; Pokemon Red is MBC3+RAM+BATTERY: saves live in 32KB of cartridge SRAM. That
; already works in memory; this makes it survive a power cycle.
;
; The only disk interface that can reach a USB stick is the BIOS INT 13h, and
; that exists only in real mode -- so saving means walking all the way down
; from long mode to real mode and back:
;
;   long mode -> 32-bit compat -> paging off -> LME off -> 16-bit protected
;             -> PE off -> real mode -> INT 13h -> and back up again
;
; The page tables (0x70000) and GDT survive the trip untouched, so climbing
; back is just the original bring-up sequence minus the table building.
;
; Real mode can only execute below 1MB, so a small stub is copied to 0x1000.
; The 32KB payload is staged at 0x10000 (segment 0x1000), which INT 13h can
; address directly -- no unreal mode needed.

BITS 64
DEFAULT ABS

STUB_BASE  equ 0x1000              ; real-mode stub lives here
SAVE_DAP   equ 0x1400              ; disk address packet
SAVE_BUF   equ 0x10000             ; 32KB staging area, segment 0x1000
SRAM_LBA   equ 2176                ; immediately after the 1MB ROM
SRAM_SECS  equ 64                  ; 32KB

; ---- one-time setup ----------------------------------------------------
save_init:
    ; The stub runs in real mode but must reload a GDT whose base is above
    ; 1MB, so it needs the full 32-bit pointer (hence o32 lgdt below).
    mov ax, [gdt64.ptr]
    mov [stub_gdtptr], ax
    mov eax, gdt64
    mov [stub_gdtptr + 2], eax
    ; boot drive, handed over by stage2
    mov al, [HANDOFF + 24]
    mov [gb_boot_drive], al
    ret

; ---- public: flush SRAM to disk ----------------------------------------
gb_save_sram:
    cmp byte [gb_sram_dirty], 0
    je  .nothing
    cmp byte [gb_boot_drive], 0
    je  .nothing                   ; unknown drive: refuse rather than guess

    ; stage SRAM where real mode can see it
    mov rsi, GB_SRAM
    mov rdi, SAVE_BUF
    mov rcx, 0x8000 / 8
    cld
    rep movsq

    ; build the DAP
    mov word  [SAVE_DAP + 0], 0x0010
    mov word  [SAVE_DAP + 2], SRAM_SECS
    mov word  [SAVE_DAP + 4], 0x0000        ; offset
    mov word  [SAVE_DAP + 6], SAVE_BUF >> 4 ; segment
    mov qword [SAVE_DAP + 8], SRAM_LBA

    call copy_stub
    call go_real_and_back

    mov byte [gb_sram_dirty], 0
.nothing:
    ret

copy_stub:
    mov rsi, stub_start
    mov rdi, STUB_BASE
    mov rcx, stub_end - stub_start
    cld
    rep movsb
    ret

; ---- the descent -------------------------------------------------------
go_real_and_back:
    mov [saved_rsp], rsp
    mov al, [gb_boot_drive]
    mov [STUB_BASE + (stub_drive - stub_start)], al

    lgdt [gdt64.ptr]
    ; 64-bit mode has no immediate far jump; it must go through memory.
    jmp far dword [go32_ptr]

align 8
go32_ptr:
    dd save_compat32
    dw gdt32sel

BITS 32
save_compat32:
    mov eax, gdt32data
    mov ds, ax
    mov es, ax
    mov ss, ax

    mov eax, cr0                   ; paging off
    and eax, 0x7FFFFFFF
    mov cr0, eax

    mov ecx, 0xC0000080            ; EFER: long mode off
    rdmsr
    and eax, 0xFFFFFEFF
    wrmsr

    mov eax, cr4                   ; PAE off
    and eax, ~(1 << 5)
    mov cr4, eax

    jmp gdt16sel:STUB_BASE         ; 16-bit protected mode, in low memory

BITS 64
; ---- the stub, copied to 0x1000 and run in 16-bit / real mode ----------
; Only short relative jumps are used inside, so it is position independent
; apart from the far jumps, whose targets are computed against STUB_BASE.
stub_start:
BITS 16
    ; still 16-bit protected mode here; drop PE to reach real mode
    mov eax, cr0
    and al, 0xFE
    mov cr0, eax
    jmp 0x0000:(STUB_BASE + (.rm - stub_start))

.rm:
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7000

    mov si, SAVE_DAP
    mov ah, 0x43                   ; extended write
    xor al, al                     ; no verify
    mov dl, [STUB_BASE + (stub_drive - stub_start)]
    int 0x13
    ; carry = failure; nothing useful to do about it here, so climb back
    ; either way rather than stranding the emulator in real mode.

    ; --- climb back: real -> protected -> long ---
    cli
    o32 lgdt [STUB_BASE + (stub_gdtptr - stub_start)]
    mov eax, cr0
    or  al, 1
    mov cr0, eax
    jmp dword gdt32sel:(STUB_BASE + (.pm32 - stub_start))

BITS 32
.pm32:
    mov eax, gdt32data
    mov ds, ax
    mov es, ax
    mov ss, ax

    mov eax, cr4
    or  eax, 1 << 5                ; PAE
    mov cr4, eax
    mov eax, PML4                  ; tables were never touched
    mov cr3, eax
    mov ecx, 0xC0000080
    rdmsr
    or  eax, 1 << 8                ; LME
    wrmsr
    mov eax, cr0
    or  eax, 0x80000000            ; paging
    mov cr0, eax

    jmp gdt64.code:save_return     ; back to 64-bit, in the kernel proper

align 4
stub_drive:  db 0
             db 0
stub_gdtptr: dw 0
             dd 0
stub_end:

BITS 64
save_return:
    mov ax, gdt64.data
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov rsp, [saved_rsp]
    ret                            ; returns from go_real_and_back

align 8
saved_rsp:       dq 0
gb_sram_dirty:   db 0
gb_boot_drive:   db 0
