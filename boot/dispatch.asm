; SM83 opcode dispatch.
;
; The regular regions of the map are collapsed: 0x40-0x7F is one handler with
; arithmetic register decode, 0x80-0xBF is one, and the whole CB page is one.
; That leaves roughly 80 hand-written cases instead of 512.

BITS 64
DEFAULT ABS

; ------------------------------------------------------------- gb_step
; Executes one instruction (or services an interrupt). Returns t-cycles in eax.
gb_step:
    ; --- interrupt dispatch ---
    mov al, [gb_ie]
    and al, [GB_IO + 0x0F]
    and al, 0x1F
    jz  .no_irq

    mov byte [gb_halted], 0        ; HALT wakes even when IME is clear
    cmp byte [gb_ime], 0
    je  .no_irq

    movzx ecx, al
    xor edx, edx
.find_bit:
    test cl, 1
    jnz .found
    shr cl, 1
    inc edx
    jmp .find_bit
.found:
    mov r10d, 1
    mov ecx, edx
    shl r10d, cl
    not r10b
    and byte [GB_IO + 0x0F], r10b
    mov byte [gb_ime], 0

    movzx r14d, word [gb_pc]
    push rdx
    call push16
    pop rdx

    mov eax, edx
    shl eax, 3
    add eax, 0x40
    mov [gb_pc], ax
    mov eax, 20
    ret

.no_irq:
    cmp byte [gb_halted], 0
    je  .exec
    mov eax, 4
    ret

.exec:
    movzx r13d, word [gb_pc]
    call fetch8
    movzx ebx, al
    movzx r12d, byte [cycles_tab + rbx]
    jmp [op_tab + rbx*8]

step_done:
    mov [gb_pc], r13w
    mov eax, r12d
    ret

; --------------------------------------------------------- regular blocks
op_ld_r_r:                         ; 0x40-0x7F except 0x76
    movzx ecx, bl
    shr ecx, 3
    and ecx, 7
    mov r15d, ecx                  ; dst
    movzx ecx, bl
    and ecx, 7
    call get_r8
    mov ecx, r15d
    call set_r8
    jmp step_done

op_alu:                            ; 0x80-0xBF
    movzx ecx, bl
    and ecx, 7
    call get_r8
    movzx edx, bl
    shr edx, 3
    and edx, 7
    call [alu_tab + rdx*8]
    jmp step_done

op_alu_n:                          ; C6 CE D6 DE E6 EE F6 FE
    movzx edx, bl
    shr edx, 3
    and edx, 7
    mov r15d, edx
    call fetch8
    mov edx, r15d
    call [alu_tab + rdx*8]
    jmp step_done

; ------------------------------------------------------------- CB page
op_cb:
    call fetch8
    movzx ebx, al
    mov r15d, ebx
    and r15d, 7                    ; register index
    mov r14d, ebx
    shr r14d, 3
    and r14d, 7                    ; bit index / shift selector
    mov edx, ebx
    shr edx, 6                     ; group

    mov r12d, 8
    cmp r15d, 6
    jne .cyc_done
    mov r12d, 16
    cmp edx, 1
    jne .cyc_done
    mov r12d, 12                   ; BIT n,[HL] is 12, not 16
.cyc_done:

    test edx, edx
    jz  .shift
    cmp edx, 1
    je  .do_bit
    cmp edx, 2
    je  .do_res

.do_set:
    mov ecx, r15d
    call get_r8
    mov ecx, r14d
    mov dl, 1
    shl dl, cl
    or  al, dl
    mov ecx, r15d
    call set_r8
    jmp step_done

.do_res:
    mov ecx, r15d
    call get_r8
    mov ecx, r14d
    mov dl, 1
    shl dl, cl
    not dl
    and al, dl
    mov ecx, r15d
    call set_r8
    jmp step_done

.do_bit:
    mov ecx, r15d
    call get_r8
    mov ecx, r14d
    mov dl, 1
    shl dl, cl
    and dl, al                     ; compute first: the flag stores below clobber ZF
    mov cl, [gb_f]
    and cl, F_C                    ; BIT preserves C
    or  cl, F_H
    test dl, dl
    jnz .bit_nz
    or  cl, F_Z
.bit_nz:
    mov [gb_f], cl
    jmp step_done

.shift:
    mov ecx, r15d
    call get_r8
    mov edx, r14d
    call cb_shift
    mov ecx, r15d
    call set_r8
    jmp step_done

; ------------------------------------------------------------- 8-bit ld
op_ld_r_n:                         ; 06 0E 16 1E 26 2E 36 3E
    movzx r15d, bl
    shr r15d, 3
    and r15d, 7
    call fetch8
    mov ecx, r15d
    call set_r8
    jmp step_done

op_inc_r:                          ; 04 0C 14 1C 24 2C 34 3C
    movzx r15d, bl
    shr r15d, 3
    and r15d, 7
    mov ecx, r15d
    call get_r8
    call inc8
    mov ecx, r15d
    call set_r8
    jmp step_done

op_dec_r:                          ; 05 0D 15 1D 25 2D 35 3D
    movzx r15d, bl
    shr r15d, 3
    and r15d, 7
    mov ecx, r15d
    call get_r8
    call dec8
    mov ecx, r15d
    call set_r8
    jmp step_done

; ------------------------------------------------------------ 16-bit ld
op_ld_rr_nn:                       ; 01 11 21 31
    movzx r15d, bl
    shr r15d, 4
    and r15d, 3
    call fetch16
    mov ecx, r15d
    call set_r16
    jmp step_done

op_inc_rr:                         ; 03 13 23 33
    movzx ecx, bl
    shr ecx, 4
    and ecx, 3
    mov r10d, [r16_addr + rcx*4]
    inc word [r10]
    jmp step_done

op_dec_rr:                         ; 0B 1B 2B 3B
    movzx ecx, bl
    shr ecx, 4
    and ecx, 3
    mov r10d, [r16_addr + rcx*4]
    dec word [r10]
    jmp step_done

; ADD HL, rr -- Z is preserved; H from bit 11, C from bit 15
op_add_hl_rr:                      ; 09 19 29 39
    movzx ecx, bl
    shr ecx, 4
    and ecx, 3
    call get_r16
    movzx r15d, ax
    movzx r14d, word [gb_l]        ; HL

    mov cl, [gb_f]
    and cl, F_Z                    ; keep Z, clear N

    mov r10d, r14d
    and r10d, 0x0FFF
    mov r11d, r15d
    and r11d, 0x0FFF
    add r10d, r11d
    cmp r10d, 0x0FFF
    jbe .noh
    or  cl, F_H
.noh:
    add r14d, r15d
    cmp r14d, 0xFFFF
    jbe .noc
    or  cl, F_C
.noc:
    mov [gb_f], cl
    mov [gb_l], r14w
    jmp step_done

; ---------------------------------------------------------- indirect ld
op_ld_bc_a:                        ; 02
    mov dil, [gb_a]
    movzx esi, word [gb_c]
    call gb_write8
    jmp step_done

op_ld_de_a:                        ; 12
    mov dil, [gb_a]
    movzx esi, word [gb_e]
    call gb_write8
    jmp step_done

op_ld_a_bc:                        ; 0A
    movzx esi, word [gb_c]
    call gb_read8
    mov [gb_a], al
    jmp step_done

op_ld_a_de:                        ; 1A
    movzx esi, word [gb_e]
    call gb_read8
    mov [gb_a], al
    jmp step_done

op_ld_hli_a:                       ; 22
    mov dil, [gb_a]
    movzx esi, word [gb_l]
    call gb_write8
    inc word [gb_l]
    jmp step_done

op_ld_hld_a:                       ; 32
    mov dil, [gb_a]
    movzx esi, word [gb_l]
    call gb_write8
    dec word [gb_l]
    jmp step_done

op_ld_a_hli:                       ; 2A
    movzx esi, word [gb_l]
    call gb_read8
    mov [gb_a], al
    inc word [gb_l]
    jmp step_done

op_ld_a_hld:                       ; 3A
    movzx esi, word [gb_l]
    call gb_read8
    mov [gb_a], al
    dec word [gb_l]
    jmp step_done

op_ld_nn_sp:                       ; 08
    call fetch16
    movzx esi, ax
    mov di, [gb_sp]
    call gb_write16
    jmp step_done

op_ld_nn_a:                        ; EA
    call fetch16
    movzx esi, ax
    mov dil, [gb_a]
    call gb_write8
    jmp step_done

op_ld_a_nn:                        ; FA
    call fetch16
    movzx esi, ax
    call gb_read8
    mov [gb_a], al
    jmp step_done

; ------------------------------------------------------------- high page
op_ldh_n_a:                        ; E0
    call fetch8
    movzx esi, al
    or  esi, 0xFF00
    mov dil, [gb_a]
    call gb_write8
    jmp step_done

op_ldh_a_n:                        ; F0
    call fetch8
    movzx esi, al
    or  esi, 0xFF00
    call gb_read8
    mov [gb_a], al
    jmp step_done

op_ldh_c_a:                        ; E2
    movzx esi, byte [gb_c]
    or  esi, 0xFF00
    mov dil, [gb_a]
    call gb_write8
    jmp step_done

op_ldh_a_c:                        ; F2
    movzx esi, byte [gb_c]
    or  esi, 0xFF00
    call gb_read8
    mov [gb_a], al
    jmp step_done

; ------------------------------------------------------------ stack ops
; push/pop index: 0=BC 1=DE 2=HL 3=AF
r16stk_addr:
    dd gb_c, gb_e, gb_l, gb_f

op_push:                           ; C5 D5 E5 F5
    movzx ecx, bl
    shr ecx, 4
    and ecx, 3
    mov r10d, [r16stk_addr + rcx*4]
    mov r14w, [r10]
    call push16
    jmp step_done

op_pop:                            ; C1 D1 E1 F1
    movzx ecx, bl
    shr ecx, 4
    and ecx, 3
    mov r15d, ecx
    call pop16
    mov ecx, r15d
    cmp ecx, 3
    jne .plain
    and ax, 0xFFF0                 ; F's low nibble is always zero
.plain:
    mov r10d, [r16stk_addr + rcx*4]
    mov [r10], ax
    jmp step_done

; ------------------------------------------------------------ jumps
op_jr:                             ; 18
    call fetch8
    movsx eax, al
    add r13w, ax
    jmp step_done

op_jr_cc:                          ; 20 28 30 38
    movzx edx, bl
    shr edx, 3
    and edx, 3
    mov r15d, edx
    call fetch8
    movsx r14d, al
    mov edx, r15d
    call test_cond
    jz  .not_taken
    add r13w, r14w
    jmp step_done
.not_taken:
    mov r12d, 8
    jmp step_done

op_jp:                             ; C3
    call fetch16
    mov r13w, ax
    jmp step_done

op_jp_cc:                          ; C2 CA D2 DA
    movzx edx, bl
    shr edx, 3
    and edx, 3
    mov r15d, edx
    call fetch16
    mov r14w, ax
    mov edx, r15d
    call test_cond
    jz  .not_taken
    mov r13w, r14w
    jmp step_done
.not_taken:
    mov r12d, 12
    jmp step_done

op_jp_hl:                          ; E9
    mov r13w, [gb_l]
    jmp step_done

op_call:                           ; CD
    call fetch16
    mov r15d, eax                  ; target
    mov r14w, r13w                 ; return address
    call push16
    mov r13w, r15w
    jmp step_done

op_call_cc:                        ; C4 CC D4 DC
    movzx edx, bl
    shr edx, 3
    and edx, 3
    mov r15d, edx
    call fetch16
    movzx r14d, ax
    mov edx, r15d
    mov r15d, r14d                 ; keep target
    call test_cond
    jz  .not_taken
    mov r14w, r13w                 ; return address
    call push16
    mov r13w, r15w
    jmp step_done
.not_taken:
    mov r12d, 12
    jmp step_done

op_ret:                            ; C9
    call pop16
    mov r13w, ax
    jmp step_done

op_ret_cc:                         ; C0 C8 D0 D8
    movzx edx, bl
    shr edx, 3
    and edx, 3
    call test_cond
    jz  .not_taken
    call pop16
    mov r13w, ax
    jmp step_done
.not_taken:
    mov r12d, 8
    jmp step_done

op_reti:                           ; D9
    call pop16
    mov r13w, ax
    mov byte [gb_ime], 1
    jmp step_done

op_rst:                            ; C7 CF D7 DF E7 EF F7 FF
    mov r14w, r13w
    call push16
    movzx r13d, bl
    and r13d, 0x38
    jmp step_done

; ------------------------------------------------------- misc / control
op_nop:
    jmp step_done

op_stop:
    call fetch8                    ; STOP is two bytes
    jmp step_done

op_halt:
    mov byte [gb_halted], 1
    jmp step_done

op_di:
    mov byte [gb_ime], 0
    jmp step_done

op_ei:
    mov byte [gb_ime], 1
    jmp step_done

op_invalid:
    jmp step_done                  ; real hardware locks up; just burn a cycle

; --------------------------------------------------------- accumulator ops
op_rlca:
    mov al, [gb_a]
    xor ecx, ecx
    test al, 0x80
    jz  .nc
    or  cl, F_C
.nc:
    rol al, 1
    mov [gb_a], al
    mov [gb_f], cl                 ; RLCA always clears Z
    jmp step_done

op_rrca:
    mov al, [gb_a]
    xor ecx, ecx
    test al, 0x01
    jz  .nc
    or  cl, F_C
.nc:
    ror al, 1
    mov [gb_a], al
    mov [gb_f], cl
    jmp step_done

op_rla:
    mov al, [gb_a]
    mov dl, [gb_f]
    and dl, F_C
    xor ecx, ecx
    test al, 0x80
    jz  .nc
    or  cl, F_C
.nc:
    shl al, 1
    test dl, dl
    jz  .noin
    or  al, 1
.noin:
    mov [gb_a], al
    mov [gb_f], cl
    jmp step_done

op_rra:
    mov al, [gb_a]
    mov dl, [gb_f]
    and dl, F_C
    xor ecx, ecx
    test al, 0x01
    jz  .nc
    or  cl, F_C
.nc:
    shr al, 1
    test dl, dl
    jz  .noin
    or  al, 0x80
.noin:
    mov [gb_a], al
    mov [gb_f], cl
    jmp step_done

op_cpl:
    mov al, [gb_a]
    not al
    mov [gb_a], al
    mov cl, [gb_f]
    and cl, F_Z | F_C
    or  cl, F_N | F_H
    mov [gb_f], cl
    jmp step_done

op_scf:
    mov cl, [gb_f]
    and cl, F_Z
    or  cl, F_C
    mov [gb_f], cl
    jmp step_done

op_ccf:
    mov cl, [gb_f]
    mov dl, cl
    and cl, F_Z
    test dl, F_C
    jnz .clear
    or  cl, F_C
.clear:
    mov [gb_f], cl
    jmp step_done

; DAA: the only instruction that reads N.
op_daa:
    movzx eax, byte [gb_a]
    mov dl, [gb_f]
    mov cl, dl
    and cl, F_C                    ; carry survives unless we set it
    test dl, F_N
    jnz .sub

    test dl, F_H
    jnz .add6
    mov r10d, eax
    and r10d, 0x0F
    cmp r10d, 9
    jbe .no6
.add6:
    add eax, 0x06
.no6:
    test dl, F_C
    jnz .add60
    cmp eax, 0x9F
    jbe .no60
.add60:
    add eax, 0x60
    or  cl, F_C
.no60:
    jmp .fin

.sub:
    or  cl, F_N
    test dl, F_H
    jz  .nosub6
    sub eax, 0x06
    and eax, 0xFF
.nosub6:
    test dl, F_C
    jz  .fin
    sub eax, 0x60

.fin:
    and eax, 0xFF
    mov [gb_a], al
    test al, al
    jnz .nz
    or  cl, F_Z
.nz:
    mov [gb_f], cl
    jmp step_done

; ------------------------------------------------------------ SP quirks
; ADD SP,e8 and LD HL,SP+e8 take their flags from the *low byte* addition.
op_add_sp_e:                       ; E8
    call fetch8
    movsx r14d, al
    movzx r15d, word [gb_sp]
    call sp_offset_flags
    add r15d, r14d
    mov [gb_sp], r15w
    jmp step_done

op_ld_hl_sp_e:                     ; F8
    call fetch8
    movsx r14d, al
    movzx r15d, word [gb_sp]
    call sp_offset_flags
    add r15d, r14d
    mov [gb_l], r15w
    jmp step_done

; in: r15d = SP, r14d = signed offset
sp_offset_flags:
    xor ecx, ecx                   ; Z and N are always cleared
    mov r10d, r15d
    and r10d, 0x0F
    mov r11d, r14d
    and r11d, 0x0F
    add r10d, r11d
    cmp r10d, 0x0F
    jbe .noh
    or  cl, F_H
.noh:
    mov r10d, r15d
    and r10d, 0xFF
    mov r11d, r14d
    and r11d, 0xFF
    add r10d, r11d
    cmp r10d, 0xFF
    jbe .noc
    or  cl, F_C
.noc:
    mov [gb_f], cl
    ret

op_ld_sp_hl:                       ; F9
    mov ax, [gb_l]
    mov [gb_sp], ax
    jmp step_done

; ---------------------------------------------------------------- tables
align 8
; Order is fixed by the opcode map: 0x80 ADD, 0x88 ADC, 0x90 SUB, 0x98 SBC,
; 0xA0 AND, 0xA8 XOR, 0xB0 OR, 0xB8 CP. XOR comes before OR.
alu_tab:
    dq alu_add, alu_adc, alu_sub, alu_sbc, alu_and, alu_xor, alu_or, alu_cp

align 8
op_tab:
    ; 0x00
    dq op_nop, op_ld_rr_nn, op_ld_bc_a, op_inc_rr, op_inc_r, op_dec_r, op_ld_r_n, op_rlca
    dq op_ld_nn_sp, op_add_hl_rr, op_ld_a_bc, op_dec_rr, op_inc_r, op_dec_r, op_ld_r_n, op_rrca
    ; 0x10
    dq op_stop, op_ld_rr_nn, op_ld_de_a, op_inc_rr, op_inc_r, op_dec_r, op_ld_r_n, op_rla
    dq op_jr, op_add_hl_rr, op_ld_a_de, op_dec_rr, op_inc_r, op_dec_r, op_ld_r_n, op_rra
    ; 0x20
    dq op_jr_cc, op_ld_rr_nn, op_ld_hli_a, op_inc_rr, op_inc_r, op_dec_r, op_ld_r_n, op_daa
    dq op_jr_cc, op_add_hl_rr, op_ld_a_hli, op_dec_rr, op_inc_r, op_dec_r, op_ld_r_n, op_cpl
    ; 0x30
    dq op_jr_cc, op_ld_rr_nn, op_ld_hld_a, op_inc_rr, op_inc_r, op_dec_r, op_ld_r_n, op_scf
    dq op_jr_cc, op_add_hl_rr, op_ld_a_hld, op_dec_rr, op_inc_r, op_dec_r, op_ld_r_n, op_ccf
    ; 0x40-0x75: LD r,r
%rep 54
    dq op_ld_r_r
%endrep
    dq op_halt                     ; 0x76
%rep 9                             ; 0x77-0x7F
    dq op_ld_r_r
%endrep
    ; 0x80-0xBF: ALU A,r
%rep 64
    dq op_alu
%endrep
    ; 0xC0
    dq op_ret_cc, op_pop, op_jp_cc, op_jp, op_call_cc, op_push, op_alu_n, op_rst
    dq op_ret_cc, op_ret, op_jp_cc, op_cb, op_call_cc, op_call, op_alu_n, op_rst
    ; 0xD0
    dq op_ret_cc, op_pop, op_jp_cc, op_invalid, op_call_cc, op_push, op_alu_n, op_rst
    dq op_ret_cc, op_reti, op_jp_cc, op_invalid, op_call_cc, op_invalid, op_alu_n, op_rst
    ; 0xE0
    dq op_ldh_n_a, op_pop, op_ldh_c_a, op_invalid, op_invalid, op_push, op_alu_n, op_rst
    dq op_add_sp_e, op_jp_hl, op_ld_nn_a, op_invalid, op_invalid, op_invalid, op_alu_n, op_rst
    ; 0xF0
    dq op_ldh_a_n, op_pop, op_ldh_a_c, op_di, op_invalid, op_push, op_alu_n, op_rst
    dq op_ld_hl_sp_e, op_ld_sp_hl, op_ld_a_nn, op_ei, op_invalid, op_invalid, op_alu_n, op_rst

; t-cycles, branch taken. Transcribed from the same reference table the C#
; decoder self-test checks against.
cycles_tab:
    db  4,12, 8, 8, 4, 4, 8, 4,20, 8, 8, 8, 4, 4, 8, 4
    db  4,12, 8, 8, 4, 4, 8, 4,12, 8, 8, 8, 4, 4, 8, 4
    db 12,12, 8, 8, 4, 4, 8, 4,12, 8, 8, 8, 4, 4, 8, 4
    db 12,12, 8, 8,12,12,12, 4,12, 8, 8, 8, 4, 4, 8, 4
    db  4, 4, 4, 4, 4, 4, 8, 4, 4, 4, 4, 4, 4, 4, 8, 4
    db  4, 4, 4, 4, 4, 4, 8, 4, 4, 4, 4, 4, 4, 4, 8, 4
    db  4, 4, 4, 4, 4, 4, 8, 4, 4, 4, 4, 4, 4, 4, 8, 4
    db  8, 8, 8, 8, 8, 8, 4, 8, 4, 4, 4, 4, 4, 4, 8, 4
    db  4, 4, 4, 4, 4, 4, 8, 4, 4, 4, 4, 4, 4, 4, 8, 4
    db  4, 4, 4, 4, 4, 4, 8, 4, 4, 4, 4, 4, 4, 4, 8, 4
    db  4, 4, 4, 4, 4, 4, 8, 4, 4, 4, 4, 4, 4, 4, 8, 4
    db  4, 4, 4, 4, 4, 4, 8, 4, 4, 4, 4, 4, 4, 4, 8, 4
    db 20,12,16,16,24,16, 8,16,20,16,16, 8,24,24, 8,16
    db 20,12,16, 4,24,16, 8,16,20,16,16, 4,24, 4, 8,16
    db 12,12, 8, 4, 4,16, 8,16,16, 4,16, 4, 4, 4, 8,16
    db 12,12, 8, 4, 4,16, 8,16,12, 8,16, 4, 4, 4, 8,16
