; GB address space + MBC3 banking, x86-64.
;
; Ported from the C# reference in recomp/src/Emu/Bus.cs, which is verified
; against the real ROM (it boots to the title screen).
;
; Convention: esi = GB address, dil = value on writes, al = result on reads.
; These are called constantly, so they clobber only rax/rsi/rdi/r10/r11.

BITS 64
DEFAULT ABS

; Fixed physical homes for the GB memory regions (identity mapped).
GB_VRAM   equ 0x00400000          ; 0x2000
GB_WRAM   equ 0x00402000          ; 0x2000
GB_OAM    equ 0x00404000          ; 0xA0
GB_HRAM   equ 0x00404100          ; 0x7F
GB_IO     equ 0x00404200          ; 0x80
GB_SRAM   equ 0x00410000          ; 0x8000
GB_FRAME  equ 0x00420000          ; 160*144 shade indices

; ---------------------------------------------------------------- read
; in:  esi = address
; out: al  = value
gb_read8:
    and esi, 0xFFFF

    cmp esi, 0x8000
    jb  .rom
    cmp esi, 0xA000
    jb  .vram
    cmp esi, 0xC000
    jb  .sram
    cmp esi, 0xE000
    jb  .wram
    cmp esi, 0xFE00
    jb  .echo
    cmp esi, 0xFEA0
    jb  .oam
    cmp esi, 0xFF00
    jb  .unused
    cmp esi, 0xFF80
    jb  .io
    cmp esi, 0xFFFF
    jb  .hram
    mov al, [gb_ie]
    ret

.rom:
    mov r10, [gb_rom_base]
    cmp esi, 0x4000
    jb  .rom0
    ; switchable bank at 0x4000-0x7FFF
    mov r11d, [gb_rombank]
    shl r11d, 14                  ; * 0x4000
    add r10, r11
    sub esi, 0x4000
.rom0:
    add r10, rsi
    mov al, [r10]
    ret

.vram:
    sub esi, 0x8000
    mov al, [GB_VRAM + rsi]
    ret

.sram:
    cmp byte [gb_sramen], 0
    jne .sram_ok
    mov al, 0xFF
    ret
.sram_ok:
    sub esi, 0xA000
    mov r11d, [gb_srambank]
    shl r11d, 13                  ; * 0x2000
    add esi, r11d
    mov al, [GB_SRAM + rsi]
    ret

.wram:
    sub esi, 0xC000
    mov al, [GB_WRAM + rsi]
    ret

.echo:
    sub esi, 0xE000
    mov al, [GB_WRAM + rsi]
    ret

.oam:
    sub esi, 0xFE00
    mov al, [GB_OAM + rsi]
    ret

.unused:
    mov al, 0xFF
    ret

.hram:
    sub esi, 0xFF80
    mov al, [GB_HRAM + rsi]
    ret

.io:
    cmp esi, 0xFF00
    je  .joypad
    cmp esi, 0xFF44
    je  .ly
    cmp esi, 0xFF41
    je  .stat
    sub esi, 0xFF00
    mov al, [GB_IO + rsi]
    ret
.ly:
    mov al, [gb_ly]
    ret
.stat:
    call ppu_stat                 ; -> al
    ret

; P1: bit4 selects dpad, bit5 selects buttons; a 0 bit means pressed.
.joypad:
    mov al, [GB_IO]               ; current select bits
    mov r10b, al
    and r10b, 0x30
    mov al, 0x0F
    test r10b, 0x10
    jnz .no_dpad
    mov r11b, [gb_dpad]
    not r11b
    and al, r11b
.no_dpad:
    test r10b, 0x20
    jnz .no_btn
    mov r11b, [gb_buttons]
    not r11b
    and al, r11b
.no_btn:
    and al, 0x0F
    or  al, r10b
    or  al, 0xC0
%ifdef INPUT_DEBUG
    ; Only trace while something is actually held, to keep the volume sane.
    push rax
    mov al, [gb_buttons]
    or  al, [gb_dpad]
    test al, al
    pop rax
    jz  .no_trace
    push rax
    mov al, '<'
    call serial_putc
    mov al, [GB_IO]
    call serial_hex8
    mov al, ':'
    call serial_putc
    pop rax
    push rax
    call serial_hex8
    mov al, '>'
    call serial_putc
    pop rax
.no_trace:
%endif
    ret

; --------------------------------------------------------------- write
; in: esi = address, dil = value
gb_write8:
    and esi, 0xFFFF

    cmp esi, 0x8000
    jb  .mbc
    cmp esi, 0xA000
    jb  .vram
    cmp esi, 0xC000
    jb  .sram
    cmp esi, 0xE000
    jb  .wram
    cmp esi, 0xFE00
    jb  .echo
    cmp esi, 0xFEA0
    jb  .oam
    cmp esi, 0xFF00
    jb  .ignore
    cmp esi, 0xFF80
    jb  .io
    cmp esi, 0xFFFF
    jb  .hram
    mov [gb_ie], dil
    ret

.vram:
    sub esi, 0x8000
    mov [GB_VRAM + rsi], dil
    ret
.wram:
    sub esi, 0xC000
    mov [GB_WRAM + rsi], dil
    ret
.echo:
    sub esi, 0xE000
    mov [GB_WRAM + rsi], dil
    ret
.oam:
    sub esi, 0xFE00
    mov [GB_OAM + rsi], dil
    ret
.hram:
    sub esi, 0xFF80
    mov [GB_HRAM + rsi], dil
    ret
.ignore:
    ret

.sram:
    cmp byte [gb_sramen], 0
    je  .ignore
    sub esi, 0xA000
    mov r11d, [gb_srambank]
    shl r11d, 13
    add esi, r11d
    mov [GB_SRAM + rsi], dil
    mov byte [gb_sram_dirty], 1
    ret

; MBC3 control registers live in what would be ROM space.
.mbc:
    cmp esi, 0x2000
    jb  .ram_enable
    cmp esi, 0x4000
    jb  .rom_bank
    cmp esi, 0x6000
    jb  .ram_bank
    ret                           ; 0x6000-0x7FFF: RTC latch, unused here

.ram_enable:
    mov al, dil
    and al, 0x0F
    cmp al, 0x0A
    sete byte [gb_sramen]
    ret

.rom_bank:
    movzx eax, dil
    and eax, 0x7F
    jnz .rb_ok
    mov eax, 1                    ; MBC3 remaps bank 0 to 1
.rb_ok:
    mov [gb_rombank], eax
    ret

.ram_bank:
    movzx eax, dil
    cmp eax, 0x03
    ja  .ignore                   ; >3 selects RTC registers
    mov [gb_srambank], eax
    ret

.io:
    cmp esi, 0xFF46
    je  .dma
    cmp esi, 0xFF44
    je  .ly_reset
    cmp esi, 0xFF10
    jb  .plain_io
    cmp esi, 0xFF3F
    jbe .sound
.plain_io:
    sub esi, 0xFF00
    mov [GB_IO + rsi], dil
    ret

; Sound registers: store, then let the APU see the write -- it needs the
; trigger bits, not just the final register value. Preserves the caller's
; rbx/rcx/rdx, which gb_write8's contract promises but apu_write uses.
.sound:
    sub esi, 0xFF00
    mov [GB_IO + rsi], dil
    add esi, 0xFF00
    push rbx
    push rcx
    push rdx
    call apu_write
    pop rdx
    pop rcx
    pop rbx
    ret

.ly_reset:
    mov byte [gb_ly], 0
    mov dword [gb_dot], 0
    ret

; OAM DMA: 160 bytes from (value << 8).
.dma:
    mov [GB_IO + 0x46], dil
    movzx r10d, dil
    shl r10d, 8                   ; source base
    xor r11d, r11d                ; index
.dma_loop:
    push r10
    push r11
    lea esi, [r10d + r11d]
    call gb_read8
    pop r11
    pop r10
    mov [GB_OAM + r11], al
    inc r11d
    cmp r11d, 0xA0
    jb  .dma_loop
    ret

; ------------------------------------------------------------ 16-bit
; in: esi = address; out: ax
gb_read16:
    push rsi
    call gb_read8
    movzx r11d, al
    pop rsi
    push r11
    inc esi
    call gb_read8
    pop r11
    mov ah, al
    mov al, r11b
    ret

; in: esi = address, di = value
gb_write16:
    push rsi
    push rdi
    ; low byte
    call gb_write8
    pop rdi
    pop rsi
    push rdi
    shr di, 8
    inc esi
    call gb_write8
    pop rdi
    ret

; --------------------------------------------------------- interrupts
; in: eax = interrupt bit number
gb_request_irq:
    mov r10d, 1
    mov ecx, eax
    shl r10d, cl
    or  byte [GB_IO + 0x0F], r10b
    ret
