; Serial console + CPU reset + instruction tracing.
;
; QEMU is launched with -serial file:trace.txt, so anything written to COM1
; lands in a file we can diff against the C# reference implementation.

BITS 64
DEFAULT ABS

COM1 equ 0x3F8

serial_init:
    mov dx, COM1 + 1
    xor al, al
    out dx, al                     ; no interrupts
    mov dx, COM1 + 3
    mov al, 0x80
    out dx, al                     ; DLAB on
    mov dx, COM1 + 0
    mov al, 1
    out dx, al                     ; divisor = 1 (115200)
    mov dx, COM1 + 1
    xor al, al
    out dx, al
    mov dx, COM1 + 3
    mov al, 0x03
    out dx, al                     ; 8N1, DLAB off
    mov dx, COM1 + 2
    mov al, 0xC7
    out dx, al                     ; enable + clear FIFOs
    mov dx, COM1 + 4
    mov al, 0x0B
    out dx, al
    ret

serial_putc:                       ; al = char
    push rax
.wait:
    mov dx, COM1 + 5
    in  al, dx
    test al, 0x20                  ; transmitter holding register empty
    jz  .wait
    pop rax
    mov dx, COM1
    out dx, al
    ret

serial_nib:                        ; al = 0..15
    and al, 0x0F
    cmp al, 10
    jb  .dig
    add al, 'a' - 10
    jmp serial_putc
.dig:
    add al, '0'
    jmp serial_putc

serial_hex8:                       ; al
    push rax
    shr al, 4
    call serial_nib
    pop rax
    call serial_nib
    ret

serial_hex16:                      ; ax
    push rax
    mov al, ah
    call serial_hex8
    pop rax
    call serial_hex8
    ret

serial_puts:                       ; rsi = zero-terminated string
    push rsi
.loop:
    mov al, [rsi]
    test al, al
    jz  .done
    inc rsi
    push rsi
    call serial_putc
    pop rsi
    jmp .loop
.done:
    pop rsi
    ret

; ---- post-boot-ROM state, matching the C# reference exactly -------------
gb_reset:
    mov byte [gb_a], 0x01
    mov byte [gb_f], 0xB0
    mov byte [gb_b], 0x00
    mov byte [gb_c], 0x13
    mov byte [gb_d], 0x00
    mov byte [gb_e], 0xD8
    mov byte [gb_h], 0x01
    mov byte [gb_l], 0x4D
    mov word [gb_sp], 0xFFFE
    mov word [gb_pc], 0x0100
    mov byte [gb_ime], 0
    mov byte [gb_halted], 0
    mov dword [gb_rombank], 1
    mov byte [GB_IO + 0x40], 0x91  ; LCDC on
    mov byte [GB_IO + 0x47], 0xFC  ; BGP
    ret

; ---- one trace line: PC A F B C D E H L SP -----------------------------
trace_line:
    mov ax, [gb_pc]
    call serial_hex16
    mov al, ' '
    call serial_putc
    mov al, [gb_a]
    call serial_hex8
    mov al, [gb_f]
    call serial_hex8
    mov al, ' '
    call serial_putc
    mov al, [gb_b]
    call serial_hex8
    mov al, [gb_c]
    call serial_hex8
    mov al, ' '
    call serial_putc
    mov al, [gb_d]
    call serial_hex8
    mov al, [gb_e]
    call serial_hex8
    mov al, ' '
    call serial_putc
    mov al, [gb_h]
    call serial_hex8
    mov al, [gb_l]
    call serial_hex8
    mov al, ' '
    call serial_putc
    mov ax, [gb_sp]
    call serial_hex16
    mov al, 13
    call serial_putc
    mov al, 10
    call serial_putc
    ret

; ---- run N instructions, tracing each ----------------------------------
; in: r9d = instruction count
gb_trace_run:
    xor ebp, ebp
.loop:
    cmp ebp, r9d
    jae .done
    push r9
    call trace_line
    call gb_step
    call ppu_tick                  ; eax = cycles from gb_step
    pop r9
    inc ebp
    jmp .loop
.done:
    ret

; ---- watchdog dump: where is it spinning? ------------------------------
dump_state:
    mov rsi, dbg_pc
    call serial_puts
    mov ax, [gb_pc]
    call serial_hex16
    mov rsi, dbg_ly
    call serial_puts
    mov al, [gb_ly]
    call serial_hex8
    mov rsi, dbg_lcdc
    call serial_puts
    mov al, [GB_IO + 0x40]
    call serial_hex8
    mov rsi, dbg_if
    call serial_puts
    mov al, [GB_IO + 0x0F]
    call serial_hex8
    mov rsi, dbg_ie
    call serial_puts
    mov al, [gb_ie]
    call serial_hex8
    mov rsi, dbg_ime
    call serial_puts
    mov al, [gb_ime]
    call serial_hex8
    mov rsi, dbg_halt
    call serial_puts
    mov al, [gb_halted]
    call serial_hex8
    mov rsi, dbg_frames
    call serial_puts
    mov eax, [gb_frames]
    call serial_hex16
    mov al, 13
    call serial_putc
    mov al, 10
    call serial_putc
    ret

dbg_pc:     db "PC=", 0
dbg_ly:     db " LY=", 0
dbg_lcdc:   db " LCDC=", 0
dbg_if:     db " IF=", 0
dbg_ie:     db " IE=", 0
dbg_ime:    db " IME=", 0
dbg_halt:   db " HALT=", 0
dbg_frames: db " F=", 0

; ---- run until gb_frames reaches gb_target_frames, then blit -----------
; The target lives in memory, not a register: render_scanline uses r9/r8 as
; scratch and would clobber a register-held loop bound.
gb_run_frames:
    mov eax, [gb_frames]
    cmp eax, [gb_target_frames]
    jae .done
    call gb_step
    mov [tmp_cycles], eax
    call ppu_tick
    mov eax, [tmp_cycles]
    call apu_step

    ; DIV ($FF04) ticks at 16384Hz, i.e. every 256 t-cycles. Pokemon Red reads
    ; it for its RNG, so without this randomness is degenerate.
    mov eax, [tmp_cycles]
    add [div_acc], eax
.div_loop:
    cmp dword [div_acc], 256
    jb  .div_done
    sub dword [div_acc], 256
    inc byte [GB_IO + 0x04]
    jmp .div_loop
.div_done:

    ; watchdog: dump state every 2^22 instructions so a spin is visible
    inc qword [gb_steps]
    mov rax, [gb_steps]
    and rax, 0x3FFFFF
    jnz .no_dump
    call dump_state
.no_dump:

    mov eax, [gb_frames]
    cmp eax, [gb_last_frame]
    je  gb_run_frames
    mov [gb_last_frame], eax       ; one dot per completed frame
    mov al, '.'
    call serial_putc
    call blit_frame                ; present every frame for live viewing
%ifdef TONE_AUDIO
    call tone_update
%endif
    call poll_input                ; once per frame is plenty at 60Hz
    call pace_frame                ; hold to 59.7 fps
    jmp gb_run_frames
.done:
    call blit_frame
    ret
