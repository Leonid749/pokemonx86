; Volume envelopes for the pulse and noise channels.
;
; Actual sound generation now lives in apu.asm; this just tracks each channel's
; envelope once per frame and hands the result to the mixer.
;
; NRx2: bits 7-4 initial volume, bit 3 direction (1 = increase), bits 2-0
; period in 1/64s units (0 = hold). We step per frame; 1/64s is ~0.93 frames,
; so treating the period as a frame count runs ~7% fast -- inaudible here.

BITS 64
DEFAULT ABS

%macro ENV_STEP 4                  ; %1 trigger flag, %2 NRx2 offset, %3 vol, %4 count
    cmp byte [%1], 0
    je  %%no_trig
    mov byte [%1], 0
    movzx eax, byte [GB_IO + %2]
    mov ebx, eax
    shr ebx, 4
    mov [%3], bl
    and eax, 7
    mov [%4], al
    jmp %%done

%%no_trig:
    movzx eax, byte [GB_IO + %2]
    and eax, 7
    jz  %%done
    cmp byte [%4], 0
    jne %%have
    mov [%4], al
%%have:
    dec byte [%4]
    jnz %%done
    mov [%4], al
    movzx ebx, byte [GB_IO + %2]
    test ebx, 0x08
    jnz %%inc
    cmp byte [%3], 0
    je  %%done
    dec byte [%3]
    jmp %%done
%%inc:
    cmp byte [%3], 15
    jae %%done
    inc byte [%3]
%%done:
%endmacro

speaker_update:
    test byte [GB_IO + 0x26], 0x80   ; NR52 master enable
    jnz .on
    mov byte [env1_vol], 0
    mov byte [env2_vol], 0
    mov byte [env4_vol], 0
    ret
.on:
    ENV_STEP spk_trig1, 0x12, env1_vol, env1_cnt   ; NR12
    ENV_STEP spk_trig2, 0x17, env2_vol, env2_cnt   ; NR22
    ENV_STEP spk_trig4, 0x21, env4_vol, env4_cnt   ; NR42
%ifdef PWM_AUDIO
    call apu_prepare
%else
    call tone_update
%endif
    ret

; ---- PIT tone output (default) -----------------------------------------
; QEMU's pcspk device emulates the PIT *tone generator*, not the speaker cone,
; so it only responds to a programmed divisor -- bit-banging port 0x61 bit 1
; produces nothing. This path therefore works in QEMU; the PWM mixer in
; apu.asm needs real hardware and is selected with -dPWM_AUDIO.
DIV_MIN equ 60
DIV_MAX equ 30000

tone_update:
    cmp byte [env1_vol], 0
    jne .use1
    cmp byte [env2_vol], 0
    jne .use2
    jmp tone_off

.use1:
    movzx ebx, byte [GB_IO + 0x14]
    and ebx, 0x07
    shl ebx, 8
    movzx eax, byte [GB_IO + 0x13]
    or  ebx, eax
    jmp .have

.use2:
    movzx ebx, byte [GB_IO + 0x19]
    and ebx, 0x07
    shl ebx, 8
    movzx eax, byte [GB_IO + 0x18]
    or  ebx, eax

.have:
    cmp ebx, 2048
    jae tone_off
    mov ecx, 2048
    sub ecx, ebx
    mov rax, 1193182
    imul rax, rcx
    shr rax, 17                    ; 131072 = 2^17
    cmp rax, DIV_MIN
    jb  tone_off
    cmp rax, DIV_MAX
    ja  tone_off

    ; Reprogramming restarts the counter, so only do it on a note change.
    cmp eax, [spk_last_div]
    je  .ensure_on
    mov [spk_last_div], eax
    mov ebx, eax
    mov dx, 0x43
    mov al, 0xB6                   ; ch2, lo/hi, mode 3 square, binary
    out dx, al
    mov dx, 0x42
    mov eax, ebx
    out dx, al
    mov eax, ebx
    shr eax, 8
    out dx, al

.ensure_on:
    cmp byte [spk_on], 0
    jne .done
    mov dx, 0x61
    in  al, dx
    or  al, 0x03
    out dx, al
    mov byte [spk_on], 1
.done:
    ret

tone_off:
    cmp byte [spk_on], 0
    je  .already
    mov dx, 0x61
    in  al, dx
    and al, 0xFC
    out dx, al
    mov byte [spk_on], 0
    mov dword [spk_last_div], 0
.already:
    ret

align 4
spk_trig1: db 0
spk_trig2: db 0
spk_trig4: db 0
env1_vol:  db 0
env1_cnt:  db 0
env2_vol:  db 0
env2_cnt:  db 0
env4_vol:  db 0
env4_cnt:  db 0
