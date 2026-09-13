; PS/2 keyboard -> Game Boy joypad.
;
; Polled, not interrupt-driven: there is still no IDT, and polling once per
; frame is plenty for a 60Hz console.
;
; Scancode set 1. Arrow keys arrive prefixed with E0, but their base codes
; don't collide with anything we map, so the prefix is simply skipped.
;
; gb_buttons / gb_dpad use "bit set = pressed"; the P1 read in mem.asm inverts
; them, since the hardware reports 0 for a pressed key.
;
;   buttons: bit0 A, bit1 B, bit2 Select, bit3 Start
;   dpad:    bit0 Right, bit1 Left, bit2 Up, bit3 Down

BITS 64
DEFAULT ABS

KBD_DATA   equ 0x60
KBD_STATUS equ 0x64

; Drain anything the firmware left in the buffer.
input_init:
    mov dx, KBD_STATUS
    in  al, dx
    test al, 0x01
    jz  .done
    mov dx, KBD_DATA
    in  al, dx
    jmp input_init
.done:
    ret

; Consume every pending scancode. Called once per frame.
poll_input:
    mov dx, KBD_STATUS
    in  al, dx
    test al, 0x01                  ; output buffer full?
    jz  .done

    mov dx, KBD_DATA
    in  al, dx

%ifdef INPUT_DEBUG
    push rax
    mov al, '['
    call serial_putc
    pop rax
    push rax
    call serial_hex8
    mov al, ']'
    call serial_putc
    pop rax
%endif

    cmp al, 0xE0                   ; extended prefix: ignore, take the next byte
    je  poll_input
    cmp al, 0xE1
    je  poll_input

    mov bl, al
    and bl, 0x7F                   ; make code
    xor bh, bh
    test al, 0x80                  ; high bit set = key release
    jnz .have_state
    mov bh, 1                      ; pressed
.have_state:

    mov rdi, gb_dpad
    cmp bl, 0x4D
    je  .k_right
    cmp bl, 0x4B
    je  .k_left
    cmp bl, 0x48
    je  .k_up
    cmp bl, 0x50
    je  .k_down

    cmp bl, 0x3F                   ; F5: flush SRAM to disk
    je  .k_save
    mov rdi, gb_buttons
    cmp bl, 0x2C
    je  .k_a                       ; Z
    cmp bl, 0x2D
    je  .k_b                       ; X
    cmp bl, 0x1C
    je  .k_start                   ; Enter
    cmp bl, 0x0E
    je  .k_select                  ; Backspace
    cmp bl, 0x2A
    je  .k_select                  ; Left Shift
    jmp poll_input                 ; unmapped key

.k_save:
    test bh, bh
    jz  poll_input                 ; act on press, not release
    call gb_save_sram
    jmp poll_input

.k_right:  mov cl, 0x01
           jmp .apply
.k_left:   mov cl, 0x02
           jmp .apply
.k_up:     mov cl, 0x04
           jmp .apply
.k_down:   mov cl, 0x08
           jmp .apply
.k_a:      mov cl, 0x01
           jmp .apply
.k_b:      mov cl, 0x02
           jmp .apply
.k_select: mov cl, 0x04
           jmp .apply
.k_start:  mov cl, 0x08

.apply:
    test bh, bh
    jz  .release
    or  [rdi], cl
    jmp poll_input
.release:
    not cl
    and [rdi], cl
    jmp poll_input

.done:
    ret
