; SM83 interpreter, x86-64.
;
; Ported from recomp/src/Emu/Cpu.cs, which is verified against the real ROM.
;
; Conventions:
;   r13w = working PC        r12d = cycle count for this instruction
;   bl   = current opcode    rcx/rdx/r14/r15 = scratch that survives gb_read8
;   GB flags live packed in gb_f (bit7 Z, 6 N, 5 H, 4 C), so the x86 flags
;   register is free scratch throughout.

BITS 64
DEFAULT ABS

F_Z equ 0x80
F_N equ 0x40
F_H equ 0x20
F_C equ 0x10

; ------------------------------------------------------------ fetch
fetch8:                            ; -> al, advances PC
    movzx esi, r13w
    add r13w, 1
    call gb_read8
    ret

; Clobber contract for fetch8/fetch16: rax, rsi, rdi, rdx, r10, r11 (rdx and
; r10/r11 go via gb_read8 and ppu_stat). Callers may rely on rbx, rcx, r12,
; r14, r15 surviving -- which is why the low byte is parked in r11, already
; inside the clobber set, rather than r15.
fetch16:                           ; -> ax (little endian)
    call fetch8
    movzx eax, al
    push rax
    call fetch8
    movzx eax, al
    shl eax, 8
    pop r11
    or  eax, r11d
    ret

; ------------------------------------------------ 8-bit register file
; index: 0=B 1=C 2=D 3=E 4=H 5=L 6=[HL] 7=A
r8_addr:
    dd gb_b, gb_c, gb_d, gb_e, gb_h, gb_l, 0, gb_a

get_r8:                            ; ecx = index -> al
    cmp ecx, 6
    je  .memhl
    mov r10d, [r8_addr + rcx*4]
    mov al, [r10]
    ret
.memhl:
    movzx esi, word [gb_l]         ; word at gb_l is HL (l low, h high)
    call gb_read8
    ret

set_r8:                            ; ecx = index, al = value
    cmp ecx, 6
    je  .memhl
    mov r10d, [r8_addr + rcx*4]
    mov [r10], al
    ret
.memhl:
    mov dil, al
    movzx esi, word [gb_l]
    call gb_write8
    ret

; ------------------------------------------------- 16-bit pairs / stack
; index: 0=BC 1=DE 2=HL 3=SP
r16_addr:
    dd gb_c, gb_e, gb_l, gb_sp

get_r16:                           ; ecx = index -> ax
    mov r10d, [r16_addr + rcx*4]
    mov ax, [r10]
    ret

set_r16:                           ; ecx = index, ax = value
    mov r10d, [r16_addr + rcx*4]
    mov [r10], ax
    ret

push16:                            ; r14w = value
    sub word [gb_sp], 2
    movzx esi, word [gb_sp]
    mov di, r14w
    call gb_write16
    ret

pop16:                             ; -> ax
    movzx esi, word [gb_sp]
    call gb_read16
    add word [gb_sp], 2
    ret

; ---------------------------------------------------------- ALU core
; Each takes the operand in al and updates gb_a / gb_f.

alu_add:
    movzx r14d, byte [gb_a]
    movzx r15d, al
    mov r10d, r14d
    and r10d, 0x0F
    mov r11d, r15d
    and r11d, 0x0F
    add r10d, r11d                 ; low-nibble sum -> half carry
    add r14d, r15d
    xor ecx, ecx
    cmp r10d, 0x0F
    jbe .noh
    or  cl, F_H
.noh:
    cmp r14d, 0xFF
    jbe .noc
    or  cl, F_C
.noc:
    mov [gb_a], r14b
    test r14b, r14b
    jnz .nz
    or  cl, F_Z
.nz:
    mov [gb_f], cl
    ret

alu_adc:
    movzx r14d, byte [gb_a]
    movzx r15d, al
    xor edx, edx
    test byte [gb_f], F_C
    jz  .nocarry
    mov edx, 1
.nocarry:
    mov r10d, r14d
    and r10d, 0x0F
    mov r11d, r15d
    and r11d, 0x0F
    add r10d, r11d
    add r10d, edx
    add r14d, r15d
    add r14d, edx
    xor ecx, ecx
    cmp r10d, 0x0F
    jbe .noh
    or  cl, F_H
.noh:
    cmp r14d, 0xFF
    jbe .noc
    or  cl, F_C
.noc:
    mov [gb_a], r14b
    test r14b, r14b
    jnz .nz
    or  cl, F_Z
.nz:
    mov [gb_f], cl
    ret

alu_sub:
    call sub_flags                 ; sets gb_f, result in r14b
    mov [gb_a], r14b
    ret

alu_cp:                            ; like sub but discards the result
    call sub_flags
    ret

; in: al = operand; out: r14b = a-n, gb_f set (N always)
sub_flags:
    movzx r14d, byte [gb_a]
    movzx r15d, al
    mov ecx, F_N
    mov r10d, r14d
    and r10d, 0x0F
    mov r11d, r15d
    and r11d, 0x0F
    cmp r10d, r11d
    jae .noh
    or  cl, F_H
.noh:
    cmp r14d, r15d
    jae .noc
    or  cl, F_C
.noc:
    sub r14d, r15d
    and r14d, 0xFF
    test r14b, r14b
    jnz .nz
    or  cl, F_Z
.nz:
    mov [gb_f], cl
    ret

alu_sbc:
    movzx r14d, byte [gb_a]
    movzx r15d, al
    xor edx, edx
    test byte [gb_f], F_C
    jz  .nocarry
    mov edx, 1
.nocarry:
    mov ecx, F_N
    mov r10d, r14d
    and r10d, 0x0F
    mov r11d, r15d
    and r11d, 0x0F
    add r11d, edx                  ; (n & 0xF) + carry
    cmp r10d, r11d
    jae .noh
    or  cl, F_H
.noh:
    mov r10d, r15d
    add r10d, edx
    cmp r14d, r10d
    jae .noc
    or  cl, F_C
.noc:
    sub r14d, r15d
    sub r14d, edx
    and r14d, 0xFF
    mov [gb_a], r14b
    test r14b, r14b
    jnz .nz
    or  cl, F_Z
.nz:
    mov [gb_f], cl
    ret

alu_and:
    and al, [gb_a]
    mov [gb_a], al
    mov cl, F_H                    ; GB defines H=1 for AND
    test al, al
    jnz .nz
    or  cl, F_Z
.nz:
    mov [gb_f], cl
    ret

alu_or:
    or  al, [gb_a]
    mov [gb_a], al
    xor ecx, ecx
    test al, al
    jnz .nz
    or  cl, F_Z
.nz:
    mov [gb_f], cl
    ret

alu_xor:
    xor al, [gb_a]
    mov [gb_a], al
    xor ecx, ecx
    test al, al
    jnz .nz
    or  cl, F_Z
.nz:
    mov [gb_f], cl
    ret

; ---------------------------------------------------------- inc / dec
; in: al = value -> al = result, flags set (C preserved)
inc8:
    mov cl, [gb_f]
    and cl, F_C                    ; GB INC leaves C alone
    mov dl, al
    and dl, 0x0F
    cmp dl, 0x0F
    jne .noh
    or  cl, F_H
.noh:
    inc al
    test al, al
    jnz .nz
    or  cl, F_Z
.nz:
    mov [gb_f], cl
    ret

dec8:
    mov cl, [gb_f]
    and cl, F_C
    or  cl, F_N
    mov dl, al
    and dl, 0x0F
    jnz .noh
    or  cl, F_H
.noh:
    dec al
    test al, al
    jnz .nz
    or  cl, F_Z
.nz:
    mov [gb_f], cl
    ret

; ---------------------------------------------------------- CB shifts
; in: al = value, edx = op index 0..7 -> al = result, gb_f set
cb_shift:
    xor ecx, ecx
    cmp edx, 0
    je  .rlc
    cmp edx, 1
    je  .rrc
    cmp edx, 2
    je  .rl
    cmp edx, 3
    je  .rr
    cmp edx, 4
    je  .sla
    cmp edx, 5
    je  .sra
    cmp edx, 6
    je  .swap
    jmp .srl

.rlc:
    test al, 0x80
    jz  .rlc_n
    or  cl, F_C
.rlc_n:
    rol al, 1
    jmp .done
.rrc:
    test al, 0x01
    jz  .rrc_n
    or  cl, F_C
.rrc_n:
    ror al, 1
    jmp .done
.rl:
    mov dl, [gb_f]
    and dl, F_C
    test al, 0x80
    jz  .rl_n
    or  cl, F_C
.rl_n:
    shl al, 1
    test dl, dl
    jz  .done
    or  al, 1
    jmp .done
.rr:
    mov dl, [gb_f]
    and dl, F_C
    test al, 0x01
    jz  .rr_n
    or  cl, F_C
.rr_n:
    shr al, 1
    test dl, dl
    jz  .done
    or  al, 0x80
    jmp .done
.sla:
    test al, 0x80
    jz  .sla_n
    or  cl, F_C
.sla_n:
    shl al, 1
    jmp .done
.sra:
    test al, 0x01
    jz  .sra_n
    or  cl, F_C
.sra_n:
    sar al, 1                      ; arithmetic: bit 7 preserved
    jmp .done
.swap:
    rol al, 4
    jmp .done
.srl:
    test al, 0x01
    jz  .srl_n
    or  cl, F_C
.srl_n:
    shr al, 1
.done:
    test al, al
    jnz .nz
    or  cl, F_Z
.nz:
    mov [gb_f], cl
    ret

; ------------------------------------------------------- condition test
; in: edx = cond 0=NZ 1=Z 2=NC 3=C ; out: ZF set if condition FAILS
test_cond:
    mov al, [gb_f]
    cmp edx, 0
    je  .nz
    cmp edx, 1
    je  .z
    cmp edx, 2
    je  .nc
    and al, F_C
    ret
.nz:
    and al, F_Z
    xor al, F_Z
    ret
.z:
    and al, F_Z
    ret
.nc:
    and al, F_C
    xor al, F_C
    ret
