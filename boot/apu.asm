; Game Boy APU, x86-64. Ported from recomp/src/Emu/Apu.cs, which was verified
; by ear via rendered WAV before any of this was written.
;
; Structure mirrors the C# exactly so the two can be compared:
;   frame sequencer at 512Hz -> length (256Hz), sweep (128Hz), envelope (64Hz)
;   per-T-cycle channel timers
;   bipolar DACs (digital 0..15 -> -15..+15) and a high-pass, which is what
;   keeps channel start/stop from producing DC clicks
;
; Output is 1-bit delta-sigma on the PC speaker. Samples are generated during
; emulation into a ring buffer, then clocked out during pace_frame's idle spin
; at PWM_HZ -- several bits per sample, which is what makes 1-bit bearable.
;
; No IDT needed: emulating a frame costs ~1% of the frame budget, so the spin
; covers nearly the whole audio timeline.

BITS 64
DEFAULT ABS

; Each sample is held for PWM_HZ/SAMPLE_HZ slots, so the modulation pattern
; repeats at SAMPLE_HZ. That rate must sit ABOVE hearing or you listen to the
; carrier instead of the music -- 16kHz was audible as a constant chirring.
; 32kHz is inaudible; the cost is fewer slots per sample (8 = 3 bits), which
; matters far less than getting the carrier out of the band.
SAMPLE_HZ equ 32000
PWM_HZ    equ 256000               ; 8 slots per sample, carrier at 32kHz
SNDBUF    equ 1024                 ; samples; one frame needs ~534

; per-channel block
CH_ENABLED equ 0
CH_TIMER   equ 4
CH_DUTYPOS equ 8
CH_LENGTH  equ 12
CH_LENEN   equ 16
CH_VOLUME  equ 20
CH_ENVPER  equ 24
CH_ENVTIM  equ 28
CH_ENVUP   equ 32
CH_FREQ    equ 36
CH_SIZE    equ 40

%ifdef TONE_AUDIO
; ---- QEMU-audible fallback ---------------------------------------------
; QEMU's pcspk models the PIT tone generator, not the cone, so it only reacts
; to a programmed divisor. This drives it from the real APU channel state
; (envelope + length aware) so QEMU gives a usable sanity check. Monophonic:
; melody only, no bass or percussion. Real hardware uses the PWM path.
TONE_DIV_MIN equ 60
TONE_DIV_MAX equ 30000

tone_update:
    cmp byte [apu_power], 0
    je  tone_off

    mov rbx, ch1
    cmp dword [ch1 + CH_ENABLED], 0
    je  .try2
    cmp dword [ch1 + CH_VOLUME], 0
    jne .have
.try2:
    mov rbx, ch2
    cmp dword [ch2 + CH_ENABLED], 0
    je  tone_off
    cmp dword [ch2 + CH_VOLUME], 0
    je  tone_off
.have:
    mov ecx, 2048
    sub ecx, [rbx + CH_FREQ]
    jle tone_off
    mov rax, 1193182
    imul rax, rcx
    shr rax, 17                    ; 131072 = 2^17
    cmp rax, TONE_DIV_MIN
    jb  tone_off
    cmp rax, TONE_DIV_MAX
    ja  tone_off

    cmp eax, [tone_last]
    je  .ensure_on                 ; reprogramming restarts the counter
    mov [tone_last], eax
    mov ebx, eax
    mov dx, 0x43
    mov al, 0xB6                   ; ch2, lo/hi, mode 3 square, binary
    out dx, al
    mov dx, 0x42
    mov eax, ebx
    out dx, al
    shr ebx, 8
    mov eax, ebx
    out dx, al
.ensure_on:
    cmp byte [tone_on], 0
    jne .done
    mov dx, 0x61
    in  al, dx
    or  al, 0x03
    out dx, al
    mov byte [tone_on], 1
.done:
    ret

tone_off:
    cmp byte [tone_on], 0
    je  .already
    mov dx, 0x61
    in  al, dx
    and al, 0xFC
    out dx, al
    mov byte [tone_on], 0
    mov dword [tone_last], 0
.already:
    ret

align 4
tone_last: dd 0
tone_on:   db 0
%endif

; ---- one-time setup ----------------------------------------------------
apu_init:
%ifdef TONE_AUDIO
    mov rax, [tsc_hz]
    xor rdx, rdx
    mov rcx, PWM_HZ
    div rcx
    mov [tsc_per_pwm], rax
    mov dword [lfsr], 0x7FFF
    mov dword [cyc_per_sample], 4194304 / SAMPLE_HZ
    ret
%endif
    ; PIT ch2 mode 0 with a count that expires immediately leaves OUT2 high,
    ; so port 0x61 bit 1 drives the cone directly (the RealSound technique).
    mov dx, 0x43
    mov al, 0xB0
    out dx, al
    mov dx, 0x42
    mov al, 1
    out dx, al
    xor al, al
    out dx, al

    mov dx, 0x61
    in  al, dx
    or  al, 0x01                   ; gate on
    and al, 0xFD                   ; data low
    out dx, al
    mov [spk_shadow], al

    mov rax, [tsc_hz]
    xor rdx, rdx
    mov rcx, PWM_HZ
    div rcx
    mov [tsc_per_pwm], rax

    mov dword [lfsr], 0x7FFF
    mov dword [cyc_per_sample], 4194304 / SAMPLE_HZ
    ret

; ---- register writes (esi = addr, dil = value) -------------------------
apu_write:
    cmp esi, 0xFF26
    je  .nr52
    cmp byte [apu_power], 0
    jne .powered
    cmp esi, 0xFF30                ; wave RAM stays writable while powered off
    jb  .done
.powered:
    cmp esi, 0xFF11
    je  .len1
    cmp esi, 0xFF16
    je  .len2
    cmp esi, 0xFF1B
    je  .len3
    cmp esi, 0xFF20
    je  .len4
    cmp esi, 0xFF13
    je  .flo1
    cmp esi, 0xFF18
    je  .flo2
    cmp esi, 0xFF1D
    je  .flo3
    cmp esi, 0xFF14
    je  .hi1
    cmp esi, 0xFF19
    je  .hi2
    cmp esi, 0xFF1E
    je  .hi3
    cmp esi, 0xFF23
    je  .hi4
.done:
    ret

.nr52:
    test dil, 0x80
    jnz .power_on
    mov byte [apu_power], 0
    mov dword [ch1 + CH_ENABLED], 0
    mov dword [ch2 + CH_ENABLED], 0
    mov dword [ch3 + CH_ENABLED], 0
    mov dword [ch4 + CH_ENABLED], 0
    ret
.power_on:
    mov byte [apu_power], 1
    ret

.len1:
    movzx eax, dil
    and eax, 0x3F
    mov ecx, 64
    sub ecx, eax
    mov [ch1 + CH_LENGTH], ecx
    ret
.len2:
    movzx eax, dil
    and eax, 0x3F
    mov ecx, 64
    sub ecx, eax
    mov [ch2 + CH_LENGTH], ecx
    ret
.len3:
    movzx eax, dil
    mov ecx, 256
    sub ecx, eax
    mov [ch3 + CH_LENGTH], ecx
    ret
.len4:
    movzx eax, dil
    and eax, 0x3F
    mov ecx, 64
    sub ecx, eax
    mov [ch4 + CH_LENGTH], ecx
    ret

.flo1:
    mov eax, [ch1 + CH_FREQ]
    and eax, 0x700
    movzx ecx, dil
    or  eax, ecx
    mov [ch1 + CH_FREQ], eax
    ret
.flo2:
    mov eax, [ch2 + CH_FREQ]
    and eax, 0x700
    movzx ecx, dil
    or  eax, ecx
    mov [ch2 + CH_FREQ], eax
    ret
.flo3:
    mov eax, [ch3 + CH_FREQ]
    and eax, 0x700
    movzx ecx, dil
    or  eax, ecx
    mov [ch3 + CH_FREQ], eax
    ret

%macro FREQ_HI 1
    mov eax, [%1 + CH_FREQ]
    and eax, 0xFF
    movzx ecx, dil
    and ecx, 7
    shl ecx, 8
    or  eax, ecx
    mov [%1 + CH_FREQ], eax
    xor eax, eax
    test dil, 0x40
    jz  %%nolen
    mov eax, 1
%%nolen:
    mov [%1 + CH_LENEN], eax
%endmacro

.hi1:
    FREQ_HI ch1
    test dil, 0x80
    jz  .done
    jmp trigger1
.hi2:
    FREQ_HI ch2
    test dil, 0x80
    jz  .done
    mov rbx, ch2
    mov ecx, 0xFF17
    jmp trigger_sq
.hi3:
    FREQ_HI ch3
    test dil, 0x80
    jz  .done
    jmp trigger3
.hi4:
    xor eax, eax
    test dil, 0x40
    jz  .h4n
    mov eax, 1
.h4n:
    mov [ch4 + CH_LENEN], eax
    test dil, 0x80
    jz  .done
    jmp trigger4

; ---- triggers ----------------------------------------------------------
; rbx = channel block, ecx = NRx2 address
trigger_sq:
    mov dword [rbx + CH_ENABLED], 1
    cmp dword [rbx + CH_LENGTH], 0
    jne .haslen
    mov dword [rbx + CH_LENGTH], 64
.haslen:
    mov eax, 2048
    sub eax, [rbx + CH_FREQ]
    shl eax, 2
    mov [rbx + CH_TIMER], eax
    call load_env                  ; uses ecx
    ret

; ecx = NRx2 address, rbx = channel
load_env:
    mov esi, ecx
    sub esi, 0xFF00
    movzx eax, byte [GB_IO + rsi]
    mov edx, eax
    shr edx, 4
    mov [rbx + CH_VOLUME], edx
    mov edx, eax
    and edx, 7
    mov [rbx + CH_ENVPER], edx
    mov [rbx + CH_ENVTIM], edx
    xor edx, edx
    test eax, 0x08
    jz  .nodir
    mov edx, 1
.nodir:
    mov [rbx + CH_ENVUP], edx
    ; DAC off (upper 5 bits clear) disables the channel outright
    test eax, 0xF8
    jnz .dacok
    mov dword [rbx + CH_ENABLED], 0
.dacok:
    ret

trigger1:
    mov rbx, ch1
    mov ecx, 0xFF12
    call trigger_sq

    movzx eax, byte [GB_IO + 0x10]  ; NR10
    mov ecx, [ch1 + CH_FREQ]
    mov [sweep_shadow], ecx
    mov ecx, eax
    shr ecx, 4
    and ecx, 7
    mov [sweep_period], ecx
    test eax, 0x08
    setnz cl
    movzx ecx, cl
    mov [sweep_negate], ecx
    mov ecx, eax
    and ecx, 7
    mov [sweep_shift], ecx
    mov ecx, [sweep_period]
    test ecx, ecx
    jnz .per_ok
    mov ecx, 8
.per_ok:
    mov [sweep_timer], ecx
    xor ecx, ecx
    cmp dword [sweep_period], 0
    jne .en
    cmp dword [sweep_shift], 0
    je  .noen
.en:
    mov ecx, 1
.noen:
    mov [sweep_enabled], ecx
    ret

trigger3:
    xor eax, eax
    test byte [GB_IO + 0x1A], 0x80
    jz  .off
    mov eax, 1
.off:
    mov [ch3 + CH_ENABLED], eax
    cmp dword [ch3 + CH_LENGTH], 0
    jne .haslen
    mov dword [ch3 + CH_LENGTH], 256
.haslen:
    mov eax, 2048
    sub eax, [ch3 + CH_FREQ]
    add eax, eax
    mov [ch3 + CH_TIMER], eax
    mov dword [wave_pos], 0
    ret

trigger4:
    mov dword [ch4 + CH_ENABLED], 1
    cmp dword [ch4 + CH_LENGTH], 0
    jne .haslen
    mov dword [ch4 + CH_LENGTH], 64
.haslen:
    mov rbx, ch4
    mov ecx, 0xFF21
    call load_env
    mov dword [lfsr], 0x7FFF
    call noise_period
    mov [ch4 + CH_TIMER], eax
    ret

; -> eax = noise timer period
noise_period:
    movzx eax, byte [GB_IO + 0x22]  ; NR43
    mov ecx, eax
    and ecx, 7
    movzx ecx, byte [noise_div + rcx]
    shr eax, 4
    and eax, 0x0F
    mov edx, ecx
    mov ecx, eax
    shl edx, cl
    mov eax, edx
    test eax, eax
    jnz .ok
    mov eax, 8
.ok:
    ret

noise_div: db 8, 16, 32, 48, 64, 80, 96, 112

; ---- step the APU by eax T-cycles --------------------------------------
apu_step:
    mov r15d, eax
.loop:
    test r15d, r15d
    jz  .done
    dec r15d

    ; --- frame sequencer, every 8192 cycles ---
    inc dword [fs_counter]
    cmp dword [fs_counter], 8192
    jb  .no_fs
    mov dword [fs_counter], 0
    mov eax, [fs_step]
    cmp eax, 7
    je  .fs_env
    test eax, 1
    jnz .fs_next                   ; odd steps do nothing
    call clock_length
    cmp eax, 2
    je  .fs_sweep
    cmp eax, 6
    jne .fs_next
.fs_sweep:
    call clock_sweep
    jmp .fs_next
.fs_env:
    call clock_envelope
.fs_next:
    inc dword [fs_step]
    and dword [fs_step], 7
.no_fs:

    ; --- channel timers ---
    dec dword [ch1 + CH_TIMER]
    jg  .t2
    mov eax, 2048
    sub eax, [ch1 + CH_FREQ]
    shl eax, 2
    mov [ch1 + CH_TIMER], eax
    inc dword [ch1 + CH_DUTYPOS]
    and dword [ch1 + CH_DUTYPOS], 7
.t2:
    dec dword [ch2 + CH_TIMER]
    jg  .t3
    mov eax, 2048
    sub eax, [ch2 + CH_FREQ]
    shl eax, 2
    mov [ch2 + CH_TIMER], eax
    inc dword [ch2 + CH_DUTYPOS]
    and dword [ch2 + CH_DUTYPOS], 7
.t3:
    dec dword [ch3 + CH_TIMER]
    jg  .t4
    mov eax, 2048
    sub eax, [ch3 + CH_FREQ]
    add eax, eax
    mov [ch3 + CH_TIMER], eax
    inc dword [wave_pos]
    and dword [wave_pos], 31
.t4:
    dec dword [ch4 + CH_TIMER]
    jg  .sample
    call noise_period
    mov [ch4 + CH_TIMER], eax
    mov eax, [lfsr]
    mov ecx, eax
    shr ecx, 1
    xor ecx, eax
    and ecx, 1                     ; bit0 xor bit1
    shr eax, 1
    mov edx, ecx
    shl edx, 14
    or  eax, edx
    test byte [GB_IO + 0x22], 0x08 ; 7-bit width mode
    jz  .w15
    and eax, 0xFFFFFFBF
    mov edx, ecx
    shl edx, 6
    or  eax, edx
.w15:
    mov [lfsr], eax

.sample:
    inc dword [sample_acc]
    mov eax, [sample_acc]
    cmp eax, [cyc_per_sample]
    jb  .loop
    sub eax, [cyc_per_sample]
    mov [sample_acc], eax
    call emit_sample
    jmp .loop
.done:
    ret

; ---- frame sequencer helpers -------------------------------------------
%macro CLOCK_LEN 1
    cmp dword [%1 + CH_LENEN], 0
    je  %%skip
    cmp dword [%1 + CH_LENGTH], 0
    je  %%skip
    dec dword [%1 + CH_LENGTH]
    jnz %%skip
    mov dword [%1 + CH_ENABLED], 0
%%skip:
%endmacro

clock_length:
    push rax
    CLOCK_LEN ch1
    CLOCK_LEN ch2
    CLOCK_LEN ch3
    CLOCK_LEN ch4
    pop rax
    ret

%macro CLOCK_ENV 1
    cmp dword [%1 + CH_ENVPER], 0
    je  %%skip
    dec dword [%1 + CH_ENVTIM]
    jg  %%skip
    mov ecx, [%1 + CH_ENVPER]
    mov [%1 + CH_ENVTIM], ecx
    cmp dword [%1 + CH_ENVUP], 0
    jne %%up
    cmp dword [%1 + CH_VOLUME], 0
    je  %%skip
    dec dword [%1 + CH_VOLUME]
    jmp %%skip
%%up:
    cmp dword [%1 + CH_VOLUME], 15
    jae %%skip
    inc dword [%1 + CH_VOLUME]
%%skip:
%endmacro

clock_envelope:
    push rax
    CLOCK_ENV ch1
    CLOCK_ENV ch2
    CLOCK_ENV ch4
    pop rax
    ret

clock_sweep:
    push rax
    dec dword [sweep_timer]
    jg  .out
    mov ecx, [sweep_period]
    test ecx, ecx
    jnz .rel
    mov ecx, 8
.rel:
    mov [sweep_timer], ecx
    cmp dword [sweep_enabled], 0
    je  .out
    cmp dword [sweep_period], 0
    je  .out
    call sweep_calc                ; -> eax = new frequency
    cmp eax, 2047
    ja  .out
    cmp dword [sweep_shift], 0
    je  .out
    mov [sweep_shadow], eax
    mov [ch1 + CH_FREQ], eax
.out:
    pop rax
    ret

sweep_calc:
    mov eax, [sweep_shadow]
    mov ecx, [sweep_shift]
    shr eax, cl
    cmp dword [sweep_negate], 0
    je  .add
    mov ecx, [sweep_shadow]
    sub ecx, eax
    mov eax, ecx
    ret
.add:
    add eax, [sweep_shadow]
    cmp eax, 2047
    jbe .ok
    mov dword [ch1 + CH_ENABLED], 0
.ok:
    ret

; ---- channel outputs (0..15) -------------------------------------------
duty_tab:
    db 0,0,0,0,0,0,0,1
    db 1,0,0,0,0,0,0,1
    db 1,0,0,0,0,1,1,1
    db 0,1,1,1,1,1,1,0

; rbx = channel, esi = NRx1 address -> eax = 0..15
square_out:
    cmp dword [rbx + CH_ENABLED], 0
    je  .zero
    sub esi, 0xFF00
    movzx eax, byte [GB_IO + rsi]
    shr eax, 6                     ; duty select
    shl eax, 3
    add eax, [rbx + CH_DUTYPOS]
    movzx eax, byte [duty_tab + rax]
    test eax, eax
    jz  .zero
    mov eax, [rbx + CH_VOLUME]
    ret
.zero:
    xor eax, eax
    ret

wave_out:
    cmp dword [ch3 + CH_ENABLED], 0
    je  .zero
    test byte [GB_IO + 0x1A], 0x80
    jz  .zero
    mov eax, [wave_pos]
    mov edx, eax
    shr edx, 1
    movzx edx, byte [GB_IO + 0x30 + rdx]
    test eax, 1
    jnz .lo
    shr edx, 4
.lo:
    and edx, 0x0F
    movzx ecx, byte [GB_IO + 0x1C]  ; NR32 level
    shr ecx, 5
    and ecx, 3
    test ecx, ecx
    jz  .zero
    dec ecx
    shr edx, cl
    mov eax, edx
    ret
.zero:
    xor eax, eax
    ret

noise_out:
    cmp dword [ch4 + CH_ENABLED], 0
    je  .zero
    mov eax, [lfsr]
    not eax
    and eax, 1
    jz  .zero
    mov eax, [ch4 + CH_VOLUME]
    ret
.zero:
    xor eax, eax
    ret

; ---- mix one sample into the ring buffer -------------------------------
; Bipolar DAC: digital 0..15 maps to -15..+15 (i.e. 2*d - 15). Summing raw
; unipolar values instead leaves DC that clicks on every channel start/stop.
%macro DAC 2                       ; %1 = digital value in eax, %2 = DAC-on test
    ; caller sets eax and a flag; see use below
%endmacro

emit_sample:
    push rbx
    push r15

    xor r15d, r15d                 ; running sum, scaled

    ; --- channel 1 ---
    test byte [GB_IO + 0x12], 0xF8  ; DAC on?
    jz  .c2
    mov rbx, ch1
    mov esi, 0xFF11
    call square_out
    lea eax, [rax + rax - 15]
    add r15d, eax
.c2:
    test byte [GB_IO + 0x17], 0xF8
    jz  .c3
    mov rbx, ch2
    mov esi, 0xFF16
    call square_out
    lea eax, [rax + rax - 15]
    add r15d, eax
.c3:
    test byte [GB_IO + 0x1A], 0x80
    jz  .c4
    call wave_out
    lea eax, [rax + rax - 15]
    add r15d, eax
.c4:
    test byte [GB_IO + 0x21], 0xF8
    jz  .mix
    call noise_out
    lea eax, [rax + rax - 15]
    add r15d, eax

.mix:
    ; master volume: use the left channel's NR50 level (mono output)
    movzx ecx, byte [GB_IO + 0x24]
    shr ecx, 4
    and ecx, 7
    inc ecx
    imul r15d, ecx
    shr r15d, 3                    ; -> roughly -60..+60

    ; high-pass, 8.8 fixed point: out = in - cap; cap = in - out*0.996
    mov eax, r15d
    shl eax, 8
    mov edx, eax
    sub edx, [hp_cap]              ; out
    mov ecx, edx
    imul ecx, 255
    sar ecx, 8
    sub eax, ecx
    mov [hp_cap], eax
    mov eax, edx

    ; Scale to 0..255. Measured: at >>5 the signal railed to 00/FF constantly
    ; (mean deviation 80 of a possible 128), i.e. clipped into a square wave.
    ; >>7 keeps the full +/-60 channel sum inside range without clamping.
    sar eax, 7
    add eax, 128
    cmp eax, 0
    jge .lo_ok
    xor eax, eax
.lo_ok:
    cmp eax, 255
    jle .hi_ok
    mov eax, 255
.hi_ok:

%ifdef TEST_TONE
    ; 440Hz sine through the identical output path. If this is clean, the PWM
    ; stage works and the fault is upstream in the mixer or buffering. If it
    ; buzzes, the output stage itself is broken.
    mov eax, [tone_phase]
    add eax, TONE_STEP
    and eax, 0xFFFFFF
    mov [tone_phase], eax
    shr eax, 16
    and eax, 0xFF
    movzx eax, byte [sine_tab + rax]
%endif
    mov ecx, [snd_head]
    mov [snd_buf + rcx], al
    inc ecx
    and ecx, SNDBUF - 1
    mov [snd_head], ecx

%ifdef APU_DUMP
    ; Report min/max/deviation once per second of game time. A signal pinned
    ; near 128 means the mixer is flat and the output stage is not the problem.
    cmp eax, [dbg_min]
    jge .nmin
    mov [dbg_min], eax
.nmin:
    cmp eax, [dbg_max]
    jle .nmax
    mov [dbg_max], eax
.nmax:
    mov ecx, eax
    sub ecx, 128
    jge .pos
    neg ecx
.pos:
    add [dbg_devsum], ecx
    inc dword [dbg_count]
    cmp dword [dbg_count], SAMPLE_HZ
    jb  .nodump
    call apu_dump_stats
.nodump:
%endif

    pop r15
    pop rbx
    ret

%ifdef APU_DUMP
apu_dump_stats:
    push rax
    push rbx
    mov rsi, dbg_lo
    call serial_puts
    mov eax, [dbg_min]
    call serial_hex8
    mov rsi, dbg_hi
    call serial_puts
    mov eax, [dbg_max]
    call serial_hex8
    mov rsi, dbg_dev
    call serial_puts
    mov eax, [dbg_devsum]
    xor edx, edx
    mov ecx, [dbg_count]
    div ecx                        ; mean absolute deviation from centre
    call serial_hex8
    mov al, 13
    call serial_putc
    mov al, 10
    call serial_putc
    mov rsi, dbg_pwm
    call serial_puts
    mov eax, [pwm_count]
    shr eax, 8                     ; bits/sec >> 8
    call serial_hex16
    mov dword [pwm_count], 0
    mov al, 13
    call serial_putc
    mov al, 10
    call serial_putc
    mov dword [dbg_min], 255
    mov dword [dbg_max], 0
    mov dword [dbg_devsum], 0
    mov dword [dbg_count], 0
    pop rbx
    pop rax
    ret

dbg_pwm: db " pwm/256=", 0
dbg_lo:  db "apu min=", 0
dbg_hi:  db " max=", 0
dbg_dev: db " meandev=", 0
align 4
pwm_count:  dd 0
dbg_min:    dd 255
dbg_max:    dd 0
dbg_devsum: dd 0
dbg_count:  dd 0
%endif

; ---- emit any PWM bits that are due, then return -----------------------
; Non-blocking, and safe to call from anywhere. The bitstream must be
; continuous: any stretch of code that runs without emitting leaves the cone
; stuck, which is heard as buzzing. blit_frame on real hardware writes to
; uncached video memory and is slow enough to starve it, so this gets called
; from inside the blit and per scanline as well as from the idle spin.
; Bounded on purpose. If a single `out` costs more than one PWM period -- which
; it does under virtualisation, where port I/O traps -- then advancing the
; deadline by one period per iteration can never catch up, and an unbounded
; loop here never returns. Emitting a fixed budget per call guarantees
; progress; on real hardware `out` is well under the period, so the budget is
; never reached and timing stays exact.
APU_BUDGET equ 128             ; ~500us of audio, enough to cover a slow blit

apu_service:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    mov esi, APU_BUDGET
.loop:
    test esi, esi
    jz  .catchup
    call read_tsc
    cmp rax, [next_pwm_tsc]
    jb  .done

    mov rbx, [next_pwm_tsc]
    add rbx, [tsc_per_pwm]
    cmp rbx, rax                   ; resync if we fell far behind
    ja  .sched
    mov rbx, rax
    add rbx, [tsc_per_pwm]
.sched:
    mov [next_pwm_tsc], rbx
    call pwm_emit_one
    dec esi
    jmp .loop

.catchup:
    ; Budget exhausted: we are not keeping up, so drop the backlog rather than
    ; spiral. Audio degrades; the emulator keeps running.
    call read_tsc
    add rax, [tsc_per_pwm]
    mov [next_pwm_tsc], rax
.done:
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

pwm_emit_one:
    ; advance to the next sample every PWM_HZ/SAMPLE_HZ slots
    mov ecx, [snd_tail]
    cmp ecx, [snd_head]
    je  .have                      ; buffer empty: hold the last value
    inc dword [pwm_sub]
    cmp dword [pwm_sub], PWM_HZ / SAMPLE_HZ
    jb  .have
    mov dword [pwm_sub], 0
    movzx eax, byte [snd_buf + rcx]
    mov [cur_sample], eax
    inc ecx
    and ecx, SNDBUF - 1
    mov [snd_tail], ecx
.have:
    mov eax, [dsig_acc]
    add eax, [cur_sample]
    mov ecx, [spk_shadow]
    and cl, 0xFD
    cmp eax, 256
    jb  .emit
    sub eax, 256
    or  cl, 0x02
.emit:
    mov [dsig_acc], eax
    mov [spk_shadow], ecx
%ifdef APU_DUMP
    inc dword [pwm_count]
%endif
    mov al, cl
    mov dx, 0x61
    out dx, al
    ret

; ---- play the buffer while waiting for the frame deadline --------------
apu_spin:
%ifdef TONE_AUDIO
.wait:
    call read_tsc
    cmp rax, [next_deadline]
    jb  .wait
    ret
%else
.loop:
    call apu_service
    call read_tsc
    cmp rax, [next_deadline]
    jb  .loop
    ret
%endif

%ifdef TEST_TONE
; 440Hz at SAMPLE_HZ: step = 440 * 2^24 / 32000
TONE_STEP equ (440 * 16777216) / SAMPLE_HZ
align 4
tone_phase: dd 0
sine_tab:
    db 128, 130, 133, 135, 138, 140, 143, 145, 148, 150, 152, 155, 157, 159, 162, 164
    db 166, 169, 171, 173, 175, 177, 179, 181, 184, 186, 188, 190, 191, 193, 195, 197
    db 199, 200, 202, 204, 205, 207, 208, 210, 211, 212, 214, 215, 216, 217, 218, 219
    db 220, 221, 222, 223, 224, 224, 225, 226, 226, 227, 227, 227, 228, 228, 228, 228
    db 228, 228, 228, 228, 228, 227, 227, 227, 226, 226, 225, 224, 224, 223, 222, 221
    db 220, 219, 218, 217, 216, 215, 214, 212, 211, 210, 208, 207, 205, 204, 202, 200
    db 199, 197, 195, 193, 191, 190, 188, 186, 184, 181, 179, 177, 175, 173, 171, 169
    db 166, 164, 162, 159, 157, 155, 152, 150, 148, 145, 143, 140, 138, 135, 133, 130
    db 128, 126, 123, 121, 118, 116, 113, 111, 108, 106, 104, 101, 99, 97, 94, 92
    db 90, 87, 85, 83, 81, 79, 77, 75, 72, 70, 68, 66, 65, 63, 61, 59
    db 57, 56, 54, 52, 51, 49, 48, 46, 45, 44, 42, 41, 40, 39, 38, 37
    db 36, 35, 34, 33, 32, 32, 31, 30, 30, 29, 29, 29, 28, 28, 28, 28
    db 28, 28, 28, 28, 28, 29, 29, 29, 30, 30, 31, 32, 32, 33, 34, 35
    db 36, 37, 38, 39, 40, 41, 42, 44, 45, 46, 48, 49, 51, 52, 54, 56
    db 57, 59, 61, 63, 65, 66, 68, 70, 72, 75, 77, 79, 81, 83, 85, 87
    db 90, 92, 94, 97, 99, 101, 104, 106, 108, 111, 113, 116, 118, 121, 123, 126
%endif

; ---- state -------------------------------------------------------------
align 8
tsc_per_pwm:   dq 0
next_pwm_tsc:  dq 0
align 4
apu_power:     db 0
align 4
fs_counter:    dd 0
fs_step:       dd 0
sample_acc:    dd 0
cyc_per_sample: dd 190
wave_pos:      dd 0
lfsr:          dd 0x7FFF
hp_cap:        dd 0
sweep_timer:   dd 0
sweep_period:  dd 0
sweep_shift:   dd 0
sweep_shadow:  dd 0
sweep_negate:  dd 0
sweep_enabled: dd 0
snd_head:      dd 0
snd_tail:      dd 0
pwm_sub:       dd 0
cur_sample:    dd 128
dsig_acc:      dd 0
spk_shadow:    dd 0

align 8
ch1: times CH_SIZE db 0
ch2: times CH_SIZE db 0
ch3: times CH_SIZE db 0
ch4: times CH_SIZE db 0

align 16
snd_buf: times SNDBUF db 128
