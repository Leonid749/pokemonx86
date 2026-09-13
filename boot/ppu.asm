; DMG PPU, x86-64. Ported from recomp/src/Emu/Ppu.cs.
;
; 456 t-cycles per scanline, 144 visible lines then 10 of VBlank. The VBlank
; interrupt at LY=144 is what releases DelayFrame's halt loop.
;
; Nothing here calls gb_read8: VRAM/OAM/IO are touched directly, so every
; register is free scratch.

BITS 64
DEFAULT ABS

; GB_FRAME is 160*144 = 0x5A00 bytes, so this must sit past 0x425A00. It was
; at 0x421000, which overlapped frame offsets 4096-4255 -- i.e. scanline 25
; from x=96 and scanline 26 to x=95, the faint line across the logo.
GB_BGCOL equ 0x00426000            ; 160 bytes: per-pixel BG colour index,
                                   ; kept so sprites can honour BG priority

; ---- STAT ($FF41) -------------------------------------------------------
ppu_stat:
    mov al, [GB_IO + 0x41]
    and al, 0xF8
    ; mode: 1 in vblank, else 2/3/0 by dot position
    cmp byte [gb_ly], 144
    jb  .visible
    or  al, 1
    jmp .lyc
.visible:
    mov edx, [gb_dot]
    cmp edx, 80
    jb  .lyc                       ; mode 2 -> bits already 00? set below
    cmp edx, 252
    jb  .mode3
    jmp .lyc                       ; mode 0
.mode3:
    or  al, 3
.lyc:
    mov dl, [GB_IO + 0x45]
    cmp dl, [gb_ly]
    jne .done
    or  al, 0x04
.done:
    ret

; ---- ppu_tick (eax = t-cycles elapsed) ---------------------------------
ppu_tick:
    test byte [GB_IO + 0x40], 0x80  ; LCD enabled?
    jnz .on
    mov byte [gb_ly], 0
    mov dword [gb_dot], 0
    ret
.on:
    add [gb_dot], eax
.lines:
    cmp dword [gb_dot], 456
    jb  .done
    sub dword [gb_dot], 456

    movzx r8d, byte [gb_ly]
    cmp r8d, 144
    jae .no_render
    call render_scanline
.no_render:
%ifdef AUDIO_INTERLEAVE
    test byte [gb_ly], 7
    jnz .no_svc_a
    call apu_service
.no_svc_a:
%endif

    inc byte [gb_ly]
    cmp byte [gb_ly], 144
    jne .not_vblank
    xor eax, eax                    ; IRQ 0 = VBlank
    call gb_request_irq
    inc dword [gb_frames]
.not_vblank:

    test byte [GB_IO + 0x41], 0x40  ; LY=LYC interrupt enabled?
    jz  .no_lyc
    mov al, [GB_IO + 0x45]
    cmp al, [gb_ly]
    jne .no_lyc
    mov eax, 1                      ; IRQ 1 = STAT
    call gb_request_irq
.no_lyc:

    cmp byte [gb_ly], 154
    jb  .lines
    mov byte [gb_ly], 0
    mov dword [gb_win_line], 0
    jmp .lines
.done:
    ret

; ---- render one scanline (r8d = ly) ------------------------------------
render_scanline:
    push rbx
    push rbp
    mov ebp, r8d
    imul ebp, 160                   ; frame row base

    ; ---------- background ----------
    test byte [GB_IO + 0x40], 0x01
    jnz .bg_on

    ; BG disabled: colour 0 across the line
    xor ecx, ecx
.bg_off_loop:
    cmp ecx, 160
    jae .window
    mov byte [GB_BGCOL + rcx], 0
    mov byte [GB_FRAME + rbp + rcx], 0
    inc ecx
    jmp .bg_off_loop

.bg_on:
    movzx eax, byte [GB_IO + 0x42]  ; SCY
    add eax, r8d
    and eax, 0xFF                   ; y within the 256px map
    mov r10d, eax
    shr r10d, 3
    shl r10d, 5                     ; (y/8)*32
    test byte [GB_IO + 0x40], 0x08
    jz  .bg_map0
    add r10d, 0x1C00
    jmp .bg_map_done
.bg_map0:
    add r10d, 0x1800
.bg_map_done:
    and eax, 7
    lea r12d, [rax*2]               ; row offset within the tile
    movzx r11d, byte [GB_IO + 0x43] ; SCX

    xor ecx, ecx
.bg_loop:
    cmp ecx, 160
    jae .window
    mov eax, ecx
    add eax, r11d
    and eax, 0xFF                   ; bx
    mov edx, eax
    shr edx, 3
    add edx, r10d
    movzx edx, byte [GB_VRAM + rdx] ; tile number
    call tile_data_addr             ; -> edx = byte offset in VRAM
    add edx, r12d
    movzx esi, byte [GB_VRAM + rdx]
    movzx edi, byte [GB_VRAM + rdx + 1]
    and eax, 7
    mov ebx, 7
    sub ebx, eax                    ; bit index
    call pack_colour                ; -> eax = colour 0..3
    mov [GB_BGCOL + rcx], al
    movzx edx, byte [GB_IO + 0x47]  ; BGP
    call apply_palette              ; -> al = shade
    mov [GB_FRAME + rbp + rcx], al
    inc ecx
    jmp .bg_loop

    ; ---------- window ----------
.window:
    test byte [GB_IO + 0x40], 0x20
    jz  .sprites
    movzx eax, byte [GB_IO + 0x4A]  ; WY
    cmp r8d, eax
    jb  .sprites
    movzx eax, byte [GB_IO + 0x4B]  ; WX
    cmp eax, 167
    jae .sprites

    mov r13d, eax
    sub r13d, 7                     ; window x origin (may be negative)

    mov eax, [gb_win_line]
    mov r10d, eax
    shr r10d, 3
    shl r10d, 5
    test byte [GB_IO + 0x40], 0x40
    jz  .win_map0
    add r10d, 0x1C00
    jmp .win_map_done
.win_map0:
    add r10d, 0x1800
.win_map_done:
    and eax, 7
    lea r12d, [rax*2]

    xor r14d, r14d                  ; "drew something" flag
    xor ecx, ecx
.win_loop:
    cmp ecx, 160
    jae .win_done
    mov eax, ecx
    sub eax, r13d                   ; x within the window
    js  .win_next
    mov r14d, 1
    mov edx, eax
    shr edx, 3
    add edx, r10d
    movzx edx, byte [GB_VRAM + rdx]
    call tile_data_addr
    add edx, r12d
    movzx esi, byte [GB_VRAM + rdx]
    movzx edi, byte [GB_VRAM + rdx + 1]
    and eax, 7
    mov ebx, 7
    sub ebx, eax
    call pack_colour
    mov [GB_BGCOL + rcx], al
    movzx edx, byte [GB_IO + 0x47]
    call apply_palette
    mov [GB_FRAME + rbp + rcx], al
.win_next:
    inc ecx
    jmp .win_loop
.win_done:
    test r14d, r14d
    jz  .sprites
    inc dword [gb_win_line]         ; only advances on lines that drew window

    ; ---------- sprites ----------
.sprites:
    test byte [GB_IO + 0x40], 0x02
    jz  .done

    mov r15d, 8
    test byte [GB_IO + 0x40], 0x04
    jz  .h8
    mov r15d, 16                    ; 8x16 mode
.h8:
    xor r13d, r13d                  ; OAM index
    xor r14d, r14d                  ; sprites drawn on this line
.spr_loop:
    cmp r13d, 40
    jae .done
    cmp r14d, 10                    ; hardware draws at most 10 per line
    jae .done

    mov eax, r13d
    shl eax, 2
    movzx r10d, byte [GB_OAM + rax] ; Y
    sub r10d, 16
    cmp r8d, r10d
    jl  .spr_next
    mov edx, r10d
    add edx, r15d
    cmp r8d, edx
    jge .spr_next

    inc r14d
    movzx r11d, byte [GB_OAM + rax + 1] ; X
    sub r11d, 8
    movzx r12d, byte [GB_OAM + rax + 2] ; tile
    movzx ebx, byte [GB_OAM + rax + 3]  ; attributes

    ; row within the sprite, honouring Y flip
    mov edx, r8d
    sub edx, r10d
    test ebx, 0x40
    jz  .no_yflip
    mov eax, r15d
    dec eax
    sub eax, edx
    mov edx, eax
.no_yflip:
    cmp r15d, 16
    jne .no_tall
    and r12d, 0xFE                  ; 8x16 ignores tile bit 0
.no_tall:
    shl r12d, 4
    add edx, edx                   ; row * 2 bytes per tile row
    add edx, r12d
    movzx esi, byte [GB_VRAM + rdx]
    movzx edi, byte [GB_VRAM + rdx + 1]

    xor r10d, r10d                  ; pixel within sprite
.spr_px:
    cmp r10d, 8
    jae .spr_next
    mov ecx, r11d
    add ecx, r10d
    cmp ecx, 0
    jl  .spr_px_next
    cmp ecx, 160
    jae .spr_px_next

    mov eax, r10d
    test ebx, 0x20                  ; X flip
    jnz .xflip
    mov eax, 7
    sub eax, r10d
.xflip:
    push rbx
    mov ebx, eax
    call pack_colour                ; -> eax colour
    pop rbx
    test eax, eax
    jz  .spr_px_next                ; colour 0 is transparent

    test ebx, 0x80                  ; behind background?
    jz  .spr_draw
    cmp byte [GB_BGCOL + rcx], 0
    jne .spr_px_next
.spr_draw:
    movzx edx, byte [GB_IO + 0x48]  ; OBP0
    test ebx, 0x10
    jz  .obp0
    movzx edx, byte [GB_IO + 0x49]  ; OBP1
.obp0:
    push rcx
    call apply_palette
    pop rcx
    mov [GB_FRAME + rbp + rcx], al

.spr_px_next:
    inc r10d
    jmp .spr_px

.spr_next:
    inc r13d
    jmp .spr_loop

.done:
    pop rbp
    pop rbx
    ret

; ---- helpers ------------------------------------------------------------
; edx = tile number -> edx = byte offset into VRAM of that tile's data
tile_data_addr:
    test byte [GB_IO + 0x40], 0x10
    jz  .signed
    shl edx, 4
    ret
.signed:
    movsx edx, dl                   ; $8800 addressing is signed
    shl edx, 4
    add edx, 0x1000
    ret

; esi = low plane byte, edi = high plane byte, ebx = bit index -> eax = 0..3
;
; Both helpers need cl for the variable shift, but callers hold their pixel
; loop counter in ecx -- so they save and restore it. Clobbering it silently
; reset the loop index and hung the renderer.
pack_colour:
    push rcx
    mov ecx, ebx
    mov eax, edi
    shr eax, cl
    and eax, 1
    add eax, eax
    mov edx, esi
    shr edx, cl
    and edx, 1
    or  eax, edx
    pop rcx
    ret

; eax = colour 0..3, edx = palette byte -> al = shade
apply_palette:
    push rcx
    mov ecx, eax
    add ecx, ecx
    shr edx, cl
    mov eax, edx
    and eax, 3
    pop rcx
    ret

; ---- blit the 160x144 shade buffer to the framebuffer at 3x -------------
blit_frame:
    push rbx
    push rbp
    mov rbp, [fb_addr]
    xor r8d, r8d                    ; gb y
.row:
    cmp r8d, 144
    jae .done
    mov r9d, r8d
    imul r9d, 160                   ; frame row base
    xor r10d, r10d                  ; scale y 0..2
.subrow:
    cmp r10d, 3
    jae .row_done
    ; destination = fb + ((y*3 + sy) * SCREEN_W) * 4
    ; Destination row: the framebuffer may be any VBE resolution, so use the
    ; runtime pitch and centre the 480x432 image inside it.
    mov eax, r8d
    imul eax, 3
    add eax, r10d
    mov edx, [fb_height]
    sub edx, SCREEN_H
    shr edx, 1
    add eax, edx                   ; + vertical offset
    imul eax, [fb_pitch]
    mov edx, [fb_width]
    sub edx, SCREEN_W
    shr edx, 1
    imul edx, [fb_bpp]             ; horizontal offset in bytes
    add eax, edx
    mov rdi, rbp
    add rdi, rax
    xor ecx, ecx
.col:
    cmp ecx, 160
    jae .subrow_done
    movzx eax, byte [GB_FRAME + r9 + rcx]
    and eax, 3
    mov ebx, [dmg_palette + rax*4]
    cmp dword [fb_bpp], 4
    jne .bpp3
    mov [rdi], ebx
    mov [rdi + 4], ebx
    mov [rdi + 8], ebx
    add rdi, 12
    inc ecx
    jmp .col

    ; 24bpp: three bytes per pixel, still 3x horizontal scale
.bpp3:
    mov edx, 3
.b3:
    mov [rdi], bl
    mov eax, ebx
    shr eax, 8
    mov [rdi + 1], al
    mov eax, ebx
    shr eax, 16
    mov [rdi + 2], al
    add rdi, 3
    dec edx
    jnz .b3
    inc ecx
    jmp .col
.subrow_done:
    inc r10d
    jmp .subrow
.row_done:
%ifdef AUDIO_INTERLEAVE
    test r8d, 7                    ; every 8th row is enough at 128 bits/call
    jnz .no_svc_b
    call apu_service
.no_svc_b:
%endif
    inc r8d
    jmp .row
.done:
    pop rbp
    pop rbx
    ret
