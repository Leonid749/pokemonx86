; Bare-metal x86-64 boot stub for sharpemu.
;
; Loaded by QEMU's -kernel via multiboot1, which hands us 32-bit protected mode
; at 1MB with the GB ROM already in memory as a module. That avoids needing a
; disk driver, real mode, or GRUB.
;
; Video comes from QEMU's Bochs DISPI interface (ports 0x1CE/0x1CF) rather than
; VBE, because INT 10h is unreachable once we are past real mode. The framebuffer
; base is read out of the VGA device's PCI BAR0.

BITS 32
ORG 0x00100000

; ---- multiboot1 header (a.out kludge: we are a flat binary, not ELF) ----
MB_MAGIC  equ 0x1BADB002
MB_FLAGS  equ 0x00010003          ; align modules | meminfo | aout kludge
MB_CHECK  equ -(MB_MAGIC + MB_FLAGS)

mb_header:
    dd MB_MAGIC
    dd MB_FLAGS
    dd MB_CHECK
    dd mb_header                  ; header_addr
    dd 0x00100000                 ; load_addr
    dd 0                          ; load_end_addr (0 = whole file)
    dd bss_end                    ; bss_end_addr
    dd entry32                    ; entry_addr

; ---- constants ----
PML4    equ 0x70000
PDPT    equ 0x71000
PD0     equ 0x72000               ; 4 page directories => 4GB identity mapped
STACK   equ 0x00090000

DISPI_INDEX equ 0x01CE
DISPI_DATA  equ 0x01CF
DISPI_XRES     equ 1
DISPI_YRES     equ 2
DISPI_BPP      equ 3
DISPI_ENABLE   equ 4
DISPI_ENABLED  equ 0x01
DISPI_LFB_EN   equ 0x40

SCREEN_W equ 480                  ; 3x the Game Boy's 160x144
SCREEN_H equ 432

; ------------------------------------------------------------------------
BITS 32
entry32:
    cli
    mov esp, STACK
    mov [mb_info], ebx            ; multiboot info: holds the module list

    ; --- build identity page tables: 4GB using 2MB pages ---
    ; Zero PML4 and PDPT.
    xor eax, eax
    mov edi, PML4
    mov ecx, 2048 / 4             ; 2 pages worth of dwords
    rep stosd

    mov dword [PML4], PDPT | 3            ; present + writable
    mov dword [PML4 + 4], 0

    ; PDPT entries 0..3 -> the four page directories
    mov ecx, 4
    mov edi, PDPT
    mov eax, PD0 | 3
.pdpt_loop:
    mov [edi], eax
    mov dword [edi + 4], 0
    add eax, 0x1000
    add edi, 8
    loop .pdpt_loop

    ; Fill 4 PDs with 2MB pages covering 0..4GB.
    mov edi, PD0
    xor eax, eax                  ; physical address low
    xor edx, edx
    mov ecx, 2048                 ; 2048 * 2MB = 4GB
.pd_loop:
    mov ebx, eax
    or  ebx, 0x83                 ; present | rw | page-size(2MB)
    mov [edi], ebx
    mov [edi + 4], edx
    add eax, 0x200000
    adc edx, 0
    add edi, 8
    loop .pd_loop

    ; --- enter long mode ---
    mov eax, cr4
    or  eax, 1 << 5               ; PAE
    mov cr4, eax

    mov eax, PML4
    mov cr3, eax

    mov ecx, 0xC0000080           ; EFER
    rdmsr
    or  eax, 1 << 8               ; LME
    wrmsr

    mov eax, cr0
    or  eax, 1 << 31              ; PG
    mov cr0, eax

    lgdt [gdt64.ptr]
    jmp gdt64.code:entry64

; ------------------------------------------------------------------------
BITS 64
DEFAULT ABS                       ; flat binary at a fixed ORG: absolute, not RIP-relative
entry64:
    cld                           ; multiboot does not guarantee DF is clear, and a
                                  ; backwards rep stosd walks off the framebuffer
    mov ax, gdt64.data
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov rsp, STACK

    call find_lfb                 ; -> rax = framebuffer physical address
    mov [fb_addr], rax

    call set_video_mode

    call serial_init
    call input_init
    mov rsi, msg_boot
    call serial_puts

    call gb_find_rom
    mov rsi, msg_rom
    call serial_puts

    call gb_selftest
    mov rsi, msg_selftest
    call serial_puts

    call gb_reset
    mov rsi, msg_reset
    call serial_puts

    call calibrate_tsc
    mov rsi, msg_tsc
    call serial_puts
    mov rax, [tsc_hz]
    shr rax, 20                    ; report roughly in MHz
    call serial_hex16
    mov al, 13
    call serial_putc
    mov al, 10
    call serial_putc
    call apu_init
    call save_init
%ifdef SRAM_CHECK
    mov rsi, msg_sramchk
    call serial_puts
    mov al, [GB_SRAM]
    call serial_hex8
    mov al, [GB_SRAM + 0x7FFF]
    call serial_hex8
    mov al, 13
    call serial_putc
    mov al, 10
    call serial_putc
%endif
%ifdef SAVE_TEST
    ; Fill SRAM with a recognisable pattern and force one flush, so the whole
    ; long-mode -> real-mode -> INT 13h -> long-mode round trip is exercised
    ; without having to reach the in-game save menu.
    mov rdi, GB_SRAM
    mov ecx, 0x8000
    mov al, 0xA5
    cld
    rep stosb
    mov byte [gb_sram_dirty], 1
    mov rsi, msg_savego
    call serial_puts
    call gb_save_sram
    mov rsi, msg_saveok
    call serial_puts
%endif
    mov rsi, msg_pwmdiv
    call serial_puts
    mov rax, [tsc_per_pwm]
    call serial_hex16
    mov al, 13
    call serial_putc
    mov al, 10
    call serial_putc

    mov dword [gb_target_frames], 0xFFFFFFFF   ; run until the window is closed
    call gb_run_frames
    mov rsi, msg_done
    call serial_puts

.hang:
    hlt
    jmp .hang

; ---- fill the whole screen with eax; used as a bare-metal progress marker
fill_screen:
    push rdi
    push rcx
    mov rdi, [fb_addr]
    mov ecx, SCREEN_W * SCREEN_H
    cld
    rep stosd
    pop rcx
    pop rdi
    ret

; ---- locate the ROM that multiboot loaded as a module -------------------
; mb_info: +20 mods_count, +24 mods_addr; each module: +0 mod_start, +4 mod_end
gb_find_rom:
    mov r10, [mb_info]
    mov eax, [r10 + 20]           ; mods_count
    test eax, eax
    jz  .none
    mov r11d, [r10 + 24]          ; mods_addr
    mov eax, [r11]                ; mod_start
    mov [gb_rom_base], rax
    mov eax, [r11 + 4]            ; mod_end
    sub eax, [r11]
    mov [gb_rom_size], eax
    ret
.none:
    mov qword [gb_rom_base], 0
    ret

; ---- prove the ROM is mapped and MBC3 banking works ---------------------
; Three checks, drawn as three horizontal bands: green = pass, red = fail.
;   1. entry point at $0100 is "nop; jp" (00 C3)
;   2. the ROM header checksum over $0134-$014C matches the byte at $014D
;   3. a banked read through gb_read8 with bank 16 selected matches the raw
;      ROM offset 16*0x4000 -- i.e. MBC3 bank switching lands where it should
gb_selftest:
    ; --- check 1 ---
    mov esi, 0x0100
    call gb_read8
    cmp al, 0x00
    jne .f1
    mov esi, 0x0101
    call gb_read8
    cmp al, 0xC3
    jne .f1
    mov byte [test_res + 0], 1
    jmp .c2
.f1:
    mov byte [test_res + 0], 0

    ; --- check 2: header checksum ---
.c2:
    xor r12d, r12d                ; running sum
    mov r13d, 0x0134
.sum_loop:
    push r12
    push r13
    mov esi, r13d
    call gb_read8
    pop r13
    pop r12
    sub r12b, al
    dec r12b                      ; x = x - byte - 1
    inc r13d
    cmp r13d, 0x014D
    jb  .sum_loop

    mov esi, 0x014D
    push r12
    call gb_read8
    pop r12
    cmp al, r12b
    jne .f2
    mov byte [test_res + 1], 1
    jmp .c3
.f2:
    mov byte [test_res + 1], 0

    ; --- check 3: MBC3 banked read ---
.c3:
    mov esi, 0x2100               ; ROM bank select register
    mov dil, 16
    call gb_write8

    mov esi, 0x4000
    call gb_read8
    mov r12b, al                  ; value seen through the mapper

    mov r10, [gb_rom_base]
    add r10, 16 * 0x4000
    mov r13b, [r10]               ; value at the raw ROM offset

    cmp r12b, r13b
    jne .f3
    mov byte [test_res + 2], 1
    jmp .draw
.f3:
    mov byte [test_res + 2], 0

    ; --- draw the three result bands ---
.draw:
    xor r8, r8                    ; y
.row:
    cmp r8, SCREEN_H
    jae .done
    ; band index = y / (SCREEN_H/3), clamped to 0..2
    mov rax, r8
    xor rdx, rdx
    mov rcx, SCREEN_H / 3
    div rcx
    cmp rax, 2
    jbe .band_ok
    mov rax, 2
.band_ok:
    movzx ebx, byte [test_res + rax]
    mov eax, 0x00C02020           ; fail: red
    test ebx, ebx
    jz  .have_colour
    mov eax, 0x0020C040           ; pass: green
.have_colour:

    mov rdi, [fb_addr]
    mov rcx, r8
    imul rcx, SCREEN_W * 4
    add rdi, rcx
    mov ecx, SCREEN_W
    rep stosd

    inc r8
    jmp .row
.done:
    ret

; ---- locate the VGA framebuffer through PCI config space ----------------
; QEMU's std VGA is vendor 0x1234 / device 0x1111. Scan bus 0 for it and read
; BAR0, which is the linear framebuffer.
HANDOFF equ 0x00007000            ; stage2 leaves VBE info here

find_lfb:
    ; Booted from our own bootloader? Then stage2 already set a VBE mode and
    ; recorded the framebuffer, and there is no DISPI to talk to.
    cmp dword [HANDOFF], 0x53424556        ; "VESA"
    jne .scan_pci
    mov eax, [HANDOFF + 8]
    mov [fb_pitch], eax
    mov eax, [HANDOFF + 12]
    mov [fb_width], eax
    mov eax, [HANDOFF + 16]
    mov [fb_height], eax
    mov eax, [HANDOFF + 20]
    mov [fb_bpp], eax              ; bytes per pixel: 3 or 4
    mov byte [have_vbe], 1
    mov eax, [HANDOFF + 4]
    ret

.scan_pci:
    mov dword [fb_pitch], SCREEN_W * 4
    mov dword [fb_width], SCREEN_W
    mov dword [fb_height], SCREEN_H
    xor ecx, ecx                  ; device number
.next_dev:
    cmp ecx, 32
    jae .fallback

    ; config address: enable | bus 0 | dev | func 0 | offset 0
    mov eax, 0x80000000
    mov ebx, ecx
    shl ebx, 11
    or  eax, ebx
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    in  eax, dx

    cmp eax, 0x11111234           ; device<<16 | vendor
    je  .found

    inc ecx
    jmp .next_dev

.found:
    ; read BAR0 at config offset 0x10
    mov eax, 0x80000000
    mov ebx, ecx
    shl ebx, 11
    or  eax, ebx
    or  eax, 0x10
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    in  eax, dx
    and eax, 0xFFFFFFF0           ; mask the BAR type bits (writing eax zeroes rax's top half)
    ret

.fallback:
    mov eax, 0xE0000000           ; legacy Bochs LFB location
    ret

; ---- program the Bochs DISPI registers ---------------------------------
set_video_mode:
    cmp byte [have_vbe], 0         ; stage2 already set the mode via VBE
    jne .already
    ; disable while reprogramming
    mov dx, DISPI_INDEX
    mov ax, DISPI_ENABLE
    out dx, ax
    mov dx, DISPI_DATA
    xor ax, ax
    out dx, ax

    mov dx, DISPI_INDEX
    mov ax, DISPI_XRES
    out dx, ax
    mov dx, DISPI_DATA
    mov ax, SCREEN_W
    out dx, ax

    mov dx, DISPI_INDEX
    mov ax, DISPI_YRES
    out dx, ax
    mov dx, DISPI_DATA
    mov ax, SCREEN_H
    out dx, ax

    mov dx, DISPI_INDEX
    mov ax, DISPI_BPP
    out dx, ax
    mov dx, DISPI_DATA
    mov ax, 32
    out dx, ax

    mov dx, DISPI_INDEX
    mov ax, DISPI_ENABLE
    out dx, ax
    mov dx, DISPI_DATA
    mov ax, DISPI_ENABLED | DISPI_LFB_EN
    out dx, ax
.already:
    ret

; ---- test pattern: proves long mode, PCI, and the LFB all work ----------
; Draws the four DMG shades as horizontal bands, with a 3x-scaled checkerboard
; in the middle so pixel geometry is verifiable by eye.
draw_test_pattern:
    mov rdi, [fb_addr]
    xor r8, r8                    ; y
.row:
    cmp r8, SCREEN_H
    jae .done
    xor r9, r9                    ; x
.col:
    cmp r9, SCREEN_W
    jae .row_done

    ; shade index from y: 4 bands
    mov rax, r8
    mov rdx, 0
    mov rcx, SCREEN_H / 4
    div rcx                       ; rax = band 0..3
    and rax, 3

    ; checkerboard in the middle third toggles to the darkest shade
    cmp r8, SCREEN_H / 3
    jb  .no_check
    cmp r8, SCREEN_H * 2 / 3
    jae .no_check
    mov rbx, r9
    shr rbx, 4
    mov rcx, r8
    shr rcx, 4
    xor rbx, rcx
    test rbx, 1
    jz  .no_check
    mov rax, 3
.no_check:
    mov eax, [dmg_palette + rax * 4]
    mov [rdi], eax
    add rdi, 4
    inc r9
    jmp .col
.row_done:
    inc r8
    jmp .row
.done:
    ret

; ------------------------------------------------------------------------
align 8
gdt64:
    dq 0                                  ; null
.code equ $ - gdt64
    dq (1<<43) | (1<<44) | (1<<47) | (1<<53)   ; exec | code/data | present | 64-bit
.data equ $ - gdt64
    dq (1<<44) | (1<<47) | (1<<41)             ; code/data | present | writable
; Descriptors used only by the save thunk on its way down to real mode.
gdt32sel  equ $ - gdt64
    dq 0x00CF9A000000FFFF                      ; 32-bit code, flat
gdt32data equ $ - gdt64
    dq 0x00CF92000000FFFF                      ; 32-bit data, flat
gdt16sel  equ $ - gdt64
    dq 0x00009A000000FFFF                      ; 16-bit code, base 0, 64K
gdt16data equ $ - gdt64
    dq 0x00009200_0000FFFF                     ; 16-bit data, base 0, 64K
.ptr:
    dw $ - gdt64 - 1
    dq gdt64

align 4
dmg_palette:
    dd 0x009BBC0F
    dd 0x008BAC0F
    dd 0x00306230
    dd 0x000F380F

align 8
mb_info:  dq 0
fb_addr:  dq 0
align 4
fb_pitch:  dd 0
fb_width:  dd 0
fb_height: dd 0
fb_bpp:    dd 4
have_vbe:  db 0

; ---- Game Boy machine state --------------------------------------------
; Register pairs are laid out low-byte-first so a 16-bit load at the low
; member yields the pair: word [gb_f] = AF, word [gb_c] = BC, and so on.
align 8
gb_f:        db 0
gb_a:        db 0
gb_c:        db 0
gb_b:        db 0
gb_e:        db 0
gb_d:        db 0
gb_l:        db 0
gb_h:        db 0
gb_sp:       dw 0
gb_pc:       dw 0
gb_ime:      db 0
gb_halted:   db 0
gb_ie:       db 0

gb_rombank:  dd 1
gb_srambank: dd 0
gb_sramen:   db 0
gb_buttons:  db 0
gb_dpad:     db 0

gb_ly:       db 0
align 4
gb_dot:      dd 0
gb_frames:   dd 0
gb_win_line: dd 0

align 8
gb_rom_base: dq 0
gb_rom_size: dd 0

test_res:    times 4 db 0
align 4
gb_target_frames: dd 0
gb_last_frame:    dd 0
tmp_cycles:       dd 0
div_acc:          dd 0
align 8
tsc_hz:           dq 0
tsc_per_frame:    dq 0
next_deadline:    dq 0
spk_last_div:     dd 0
spk_on:           db 0
align 8
gb_steps:         dq 0

msg_boot:     db "boot", 13, 10, 0
msg_rom:      db "rom found", 13, 10, 0
msg_selftest: db "selftest ok", 13, 10, 0
msg_reset:    db "cpu reset", 13, 10, 0
msg_done:     db "frames done", 13, 10, 0
msg_tsc:      db "tsc ~MHz=", 0
msg_sramchk:  db "sram first/last=", 0
msg_savego:   db "save: descending", 13, 10, 0
msg_saveok:   db "save: returned OK", 13, 10, 0
msg_pwmdiv:   db "tsc_per_pwm=", 0

%include "mem.asm"
%include "cpu.asm"
%include "dispatch.asm"
%include "ppu.asm"
%include "timing.asm"
%include "input.asm"
%include "apu.asm"
%include "save.asm"
%include "debug.asm"

bss_end:
