; Frame pacing.
;
; Without this the emulator free-runs at whatever speed the host manages
; (measured at ~4650 fps, about 78x too fast), so the copyright screen flashes
; past in ~30ms and the intro animates absurdly quickly.
;
; There are no interrupts set up (we run with cli and no IDT), so timing is
; done by polling: calibrate the TSC against PIT channel 2, then spin on rdtsc
; until each frame's deadline.

BITS 64
DEFAULT ABS

PIT_FREQ  equ 1193182              ; Hz
CAL_MS    equ 10
CAL_COUNT equ (PIT_FREQ * CAL_MS) / 1000

; The Game Boy runs at 4194304 Hz with 70224 cycles per frame => 59.7275 fps.
GB_CPU_HZ        equ 4194304
GB_CYCLES_FRAME  equ 70224

; ---- read the TSC into rax ---------------------------------------------
read_tsc:
    rdtsc                          ; edx:eax
    shl rdx, 32
    or  rax, rdx
    ret

; ---- calibrate: TSC ticks per second -> [tsc_hz] ------------------------
calibrate_tsc:
    ; Gate channel 2 on, speaker output off (bit 1 clear) so nothing is heard.
    mov dx, 0x61
    in  al, dx
    and al, 0xFC
    or  al, 0x01                   ; gate on
    out dx, al

    ; Channel 2, lo/hi byte, mode 0 (interrupt on terminal count), binary.
    mov dx, 0x43
    mov al, 0xB0
    out dx, al

    mov dx, 0x42
    mov ax, CAL_COUNT
    out dx, al                     ; low byte
    mov al, ah
    out dx, al                     ; high byte

    ; Restart the count by toggling the gate low then high.
    mov dx, 0x61
    in  al, dx
    and al, 0xFE
    out dx, al
    or  al, 0x01
    out dx, al

    call read_tsc
    mov r14, rax                   ; start

.wait:
    mov dx, 0x61
    in  al, dx
    test al, 0x20                  ; bit 5 = OUT2, goes high at terminal count
    jz  .wait

    call read_tsc
    sub rax, r14                   ; elapsed ticks over CAL_MS
    mov rcx, 1000 / CAL_MS
    mul rcx                        ; -> ticks per second
    mov [tsc_hz], rax

    ; ticks_per_frame = tsc_hz * 70224 / 4194304
    mov rcx, GB_CYCLES_FRAME
    mul rcx                        ; rdx:rax
    mov rcx, GB_CPU_HZ
    div rcx
    mov [tsc_per_frame], rax

    call read_tsc
    add rax, [tsc_per_frame]
    mov [next_deadline], rax
    ret

; ---- spin until the current frame's deadline, then advance it ----------
pace_frame:
    call read_tsc
    mov r14, rax

    ; If we are more than one frame behind (e.g. after a slow scene), resync
    ; rather than sprinting to catch up.
    mov rax, [next_deadline]
    add rax, [tsc_per_frame]
    cmp r14, rax
    jb  .spin
    mov rax, r14
    add rax, [tsc_per_frame]
    mov [next_deadline], rax
    ret

.spin:
    call apu_spin

    mov rax, [next_deadline]
    add rax, [tsc_per_frame]
    mov [next_deadline], rax
    ret
