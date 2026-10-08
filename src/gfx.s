; gfx.s - the inline graphics/text command engine of Turbo Esprit
; (Spectrum A4C9-A98D: GFX_TEXT/GFX_DRAW, lines, fill, glyphs, tokens,
; number printer, beeper entry points) and the Oric screen helpers.
;
; Two targets, selected like the original (8C, SA89B/SA8BF):
;  * buffer mode: the Spectrum-format linear bitmap at $6400 (32 bytes per
;    row), exactly like the original (bit-exact, same address quirks).
;  * screen mode: the Oric HIRES screen.  Spectrum (x,y) -> Oric pixel x+6 on
;    line y+4 (docs/PORTING.md section 5).  A pixel position is (line base
;    address, column 1..39, mask $20..$01); writes skip columns >= 40 and any
;    byte whose bit 6 is 0 (attributes) and keep bit 7.
;
; The engine's state lives in ZVARs at the Spectrum addresses and with the
; Spectrum encodings (A5C4 plot op, A6D7 screen flag, A6BC font, ...), so the
; test harness can load and compare it.  In screen mode A685/A687 hold Oric
; line base addresses instead of Spectrum screen addresses.
;
; None of these routines touch the zero-page Z80 register file except where
; the original returns a value there (Z_A638 -> HL), so callers' BC/DE/HL/IX
; survive (the Z80 versions destroyed them; nobody relied on that).

        .include "zx.inc"
        .include "snd.inc"

        .export gfx_cls, gfx_attr_lines, gfx_attr_rows, gfx_recolour
        .export gfx_rc_row, gfx_rc_n, gfx_linebase, gfx_curback
        .export gfx_lz, gfx_glyph, gfx_print, gfx_textinit
        .export TEXTROW0, TEXTROW1
        .exportzp lzs, lzd

TEXTROW0 = $BF68                ; Spectrum char row 22 (PENALTY/SCORE)
TEXTROW1 = $BF68 + 40           ; Spectrum char row 23 (messages)

; ---------------------------------------------------------------------------
        .zeropage
ptr:    .res 2          ; current byte = (ptr),y
msk:    .res 1          ; current pixel mask
strm:   .res 2          ; stream pointer
cnt:    .res 1
err:    .res 1
minor:  .res 1
major:  .res 1
t0:     .res 1
t1:     .res 1
t2:     .res 1
t3:     .res 1
fp:     .res 2          ; glyph pointer
tp:     .res 2          ; token pointer
gv:     .res 1          ; glyph row value / hi part
gl:     .res 1          ; lo part
sb0:    .res 1
sb1:    .res 1
lzs:    .res 2
lzd:    .res 2
lzc:    .res 2
strmb:  .res 2

; ---------------------------------------------------------------------------
        .segment "DATA"
        ZVAR $A4C2, 1           ; border colour (read by E4ED/E62B)
        ZVAR $A4C3, 2           ; number for FC / BA5F
        ZVAR $A4F9, 1           ; $00 line mode, $0F text mode
        ZLABEL $A5C4, 2         ; line plot op: 00 B6 or, 2F A6 erase, 00 AE xor, 18 1C dither
        .byte $00, $B6
        ZLABEL $A634, 2         ; point plot op (never dither)
        .byte $00, $B6
        ZVAR $A683, 1           ; text: x & 7
        ZLABEL $A684, 1         ; line: current mask
        .byte $01
        ZVAR $A685, 2           ; line: current address (screen: Oric line base)
        ZVAR $A687, 2           ; text: current address (screen: Oric line base)
        ZVAR $A691, 2           ; current x, y
        ZVAR $A693, 2           ; mirror x, mirror y (bit 7)
        ZLABEL $A6BC, 2         ; font: $3C00 ROM, $AA2F custom
        .word $3C00
        ZVAR $A6D7, 1           ; $00 buffer, $11 screen
        ZVAR $A6E0, 1           ; glyph op: 00 overwrite, B6 or, AE xor
        ZVAR $A850, 1           ; YOFF
        ZLABEL $A969, 1         ; beeper inner delay N
        .byte $20

pcol:   .byte 1                 ; screen mode: line column of A685
tcol:   .byte 1                 ; screen mode: text column (of x & $F8)
tr:     .byte 0                 ;   and pixel offset in it (0,2,4)
savesp: .byte 0
gopm:   .byte 0                 ; glyph op: 0 overwrite, 1 or, 2 xor
nval:   .word 0
nflg:   .byte 0
nidx:   .byte 0
dxv:    .byte 0
dyv:    .byte 0
addx:   .byte 0
addy:   .byte 0
fsp:    .byte 0                 ; fill seed stack pointer
fcnt:   .byte 0
fd:     .byte 0
fb:     .byte 0
fl_p:   .word 0                 ; fill span start (ptr, y, mask)
fl_y:   .byte 0
fl_m:   .byte 0
gfx_rc_row: .byte 0             ; gfx_recolour: first Spectrum pixel row
gfx_rc_n:   .byte 8             ;   number of pixel rows
rc_a:   .byte 0
rc_cs:  .byte 0
rc_ce:  .byte 0
rc_ia:  .byte 0
rc_pa:  .byte 0
rc_va:  .byte 0
rc_ib:  .byte 0
rc_pb:  .byte 0
rc_vb:  .byte 0
c0v:    .byte 0                 ; line attribute template (gfx_cls/attr)
c1v:    .byte 0
tmpl:   .byte 0

FSTK = 100
        .segment "HIBSS"
fs_pl:  .res FSTK
fs_ph:  .res FSTK
fs_y:   .res FSTK
fs_m:   .res FSTK

        .segment "RODATA"
; x>>1 -> (x>>1)/3 << 2 | (x>>1) mod 3  (Oric column / offset of pixel x+6)
divtab:
        .repeat 128, I
        .byte ((I / 3) << 2) | (I .mod 3)
        .endrepeat
omask:  .byte $20, $10, $08, $04, $02, $01
bmask:  .byte $80, $40, $20, $10, $08, $04, $02, $01
zx2oric:.byte 0, 4, 1, 5, 2, 6, 3, 7

        .import T_ROMFONT, T_AA2F, T_A98E, T_A0BF     ; data/gfx_data.s

        .code
; ===========================================================================
; Entry points with inline stream
; A4C9 GFX_TEXT: HL = number for FC; overwrite mode, screen, text mode
        ZPROC $A4C9
        lda zl
        sta ZV_A4C3
        lda zh
        sta ZV_A4C3+1
        jsr Z_A828
        jsr Z_A89B
        lda #$0F
        bne entry
; A4D6 GFX_DRAW: buffer, OR mode, line mode
        ZPROC $A4D6
        jsr Z_A8BF
        jsr Z_A80F
        lda #0
entry:  sta ZV_A4F9
        jsr Z_A8DB
        lda #0
        sta ZV_A850
        sta ZV_A693
        sta ZV_A693+1
        pla
        sta strm
        pla
        sta strm+1
        inc strm
        bne :+
        inc strm+1
:       tsx
        stx savesp
; ---- LA4EF main loop
next:   jsr getb
        beq endstr
        bpl :+
        jmp command
:       sta cnt
        lda ZV_A4F9
        beq next__ln
        jmp text
next__ln:    jsr getb
        sta dxv
        jsr getb
        sta dyv
        jsr line
        dec cnt
        bne next__ln
        beq next
endstr: ldx savesp
        txs
        jmp (strm)

; ---- text items (LA509)
text:
text__it:    jsr getb
        cmp #$FC
        bcs text__ctl
        jsr printc
        dec cnt
        bne text__it
        beq next
text__ctl:   cmp #$FE
        beq text__fe
        bcs text__ff
        cmp #$FD
        beq text__fd
        jsr getb                ; FC k e: number
        pha
        jsr getb
        sta nflg
        lda ZV_A4C3
        sta nval
        lda ZV_A4C3+1
        sta nval+1
        pla
        jsr number
        jmp text__it
text__ff:    jsr getb
        sta zc_t
        jsr getb
        tay
        ldx zc_t
        jsr setpos
        jmp text__it
text__fe:    jsr getb
        clc
        adc ZV_A691
        tax
        ldy ZV_A691+1
        jsr setpos
        jmp text__it
text__fd:    jsr getb
        clc
        adc ZV_A691+1
        tay
        ldx ZV_A691
        jsr setpos
        jmp text__it
zc_t:   .byte 0

; ---- commands 80-90
command:
        and #$7F
        beq gosub
        cmp #1
        beq retsub
        cmp #$11
        bcs command__bad                ; 91-FF: invalid in the original
        asl
        tax
        lda cmdtab+1,x
        pha
        lda cmdtab,x
        pha
        rts                     ; handler returns to next via rtsnext
command__bad:   jmp next
gosub:  jsr getb
        asl
        tax
        lda strm+1
        pha
        lda strm
        pha
        lda T_A0BF,x
        sta strm
        lda T_A0BF+1,x
        sta strm+1
        jmp next
retsub: pla
        sta strm
        pla
        sta strm+1
        jmp next

cmdtab: .word 0, 0
        .word c_or-1, c_erase-1, c_xor-1, c_fill-1, c_dither-1, c_move-1
        .word c_rmove-1, c_mirx-1, c_miry-1, c_text-1, c_scr-1, c_font-1
        .word next-1, c_cls-1, c_yoff-1

c_or:   jsr Z_A80F
        jmp next
c_erase:jsr Z_A828
        jmp next
c_xor:  jsr Z_A82E
        jmp next
c_dither:
        lda #$18
        sta ZV_A5C4
        lda #$1C
        sta ZV_A5C4+1
        jmp next
c_mirx: lda ZV_A693
        eor #$80
        sta ZV_A693
        jmp next
c_miry: lda ZV_A693+1
        eor #$80
        sta ZV_A693+1
        jmp next
c_text: lda ZV_A4F9
        eor #$0F
        sta ZV_A4F9
        jmp next
c_scr:  lda ZV_A6D7
        bne :+
        jsr Z_A89B
        jmp next
:       jsr Z_A8BF
        jmp next
c_font: lda ZV_A6BC
        bne :+
        jsr Z_A8D3
        jmp next
:       jsr Z_A8DB
        jmp next
c_yoff: jsr getb
        sta ZV_A850
        jmp next
c_cls:  jsr getb
        jsr gfx_cls
        jmp next
; 87 x y: move absolute + plot
c_move: jsr getb
        tax
        jsr getb
        clc
        adc ZV_A850
        tay
        jsr moveto
        jmp next
; 88 dx dy: move relative + plot
c_rmove:jsr relc
        tya
        clc
        adc ZV_A850
        tay
        jsr moveto
        jmp next
; 85 dx dy: flood fill (SA835)
c_fill: jsr relc
        stx fsx
        jsr addrmask            ; ptr/y/msk of (X,Y), A684 = mask
        jsr fill
        lda ZV_A6D7
        beq :+
        ; screen mode: the original keeps the line address (byte of the
        ; current x) and takes the seed's bit (SA672 sets DA684 only), so
        ; the next line starts at x' = (x & $F8) | (seed x & 7)
        lda fsx
        and #7
        sta t0
        lda ZV_A691
        and #$F8
        ora t0
        lsr
        tay
        lda divtab,y
        pha
        lsr
        lsr
        clc
        adc #1
        sta pcol
        pla
        and #3
        asl
        sta t0
        lda fsx
        and #1
        ora t0
        tay
        lda omask,y
        sta ZV_A684
:       jmp next
fsx:    .byte 0

; SA858: read (dx,dy) -> X = x+-dx, Y = y+-dy (mirrors)
relc:   jsr getb
        bit ZV_A693
        bpl :+
        eor #$FF
        clc
        adc #1
:       clc
        adc ZV_A691
        tax
        jsr getb
        bit ZV_A693+1
        bpl :+
        eor #$FF
        clc
        adc #1
:       clc
        adc ZV_A691+1
        tay
        rts

getb:   ldy #0
        lda (strm),y
        inc strm
        bne :+
        inc strm+1
:       ora #0
        rts

; ===========================================================================
; mode selectors
        ZPROC $A80F             ; OR mode
        lda #$B6
        ldx #$00
setop:  stx ZV_A634
        sta ZV_A634+1
        stx ZV_A5C4
        sta ZV_A5C4+1
        cpx #0
        beq :+
        lda #0                  ; erase: glyphs overwrite
:       sta ZV_A6E0
        rts
        ZPROC $A828             ; ERASE mode
        lda #$A6
        ldx #$2F
        bne setop
        ZPROC $A82E             ; XOR mode
        lda #$AE
        ldx #$00
        beq setop
        ZPROC $A89B             ; screen target
        lda #$11
        sta ZV_A6D7
        rts
        ZPROC $A8BF             ; buffer target
        lda #0
        sta ZV_A6D7
        rts
        ZPROC $A8D3             ; custom font
        lda #<$AA2F
        ldx #>$AA2F
        bne :+
        ZPROC $A8DB             ; ROM font
        lda #$00
        ldx #$3C
:       sta ZV_A6BC
        stx ZV_A6BC+1
        rts
        ZPROC $A903             ; border: A&7 -> DA4C2 (no border on the Oric)
        and #7
        sta ZV_A4C2
        rts

; ===========================================================================
; Addressing
; gfx_linebase: A = Spectrum y -> ptr = $A000 + (y+4)*40
gfx_linebase:
        clc
        adc #4
        sta t0
        lda #0
        rol
        sta t1
        asl t0
        rol t1
        asl t0
        rol t1
        asl t0
        rol t1                  ; *8
        lda t0
        sta ptr
        lda t1
        sta ptr+1
        asl t0
        rol t1
        asl t0
        rol t1                  ; *32
        lda t0
        clc
        adc ptr
        sta ptr
        lda t1
        adc ptr+1
        adc #$A0
        sta ptr+1
        rts

; buffer address of (X,Y): ptr hi / Y = lo of $6400 + y*32 + x>>3
; out: ptr+1 = hi, A = lo
bufaddr:
        tya
        sta t0
        lda #0
        sta t1
        lda t0
        asl
        rol t1
        asl
        rol t1
        asl
        rol t1
        asl
        rol t1
        asl
        rol t1
        sta t0
        txa
        lsr
        lsr
        lsr
        clc
        adc t0
        sta t0
        lda t1
        adc #$64
        sta ptr+1
        lda t0
        rts

; addrmask (SA672): X=x, Y=y -> ptr/Y(index)/msk set up for the current
; target, A684 = mask.  (Does not store A685.)
addrmask:
        lda ZV_A6D7
        beq addrmask__buf
        tya
        jsr gfx_linebase
        txa
        lsr
        tay
        lda divtab,y
        lsr
        lsr
        clc
        adc #1
        sta t2                  ; column
        lda divtab,y
        and #3
        asl
        sta t3
        txa
        and #1
        ora t3
        tay
        lda omask,y
        sta msk
        sta ZV_A684
        ldy t2
        rts
addrmask__buf:   jsr bufaddr
        pha
        lda #0
        sta ptr
        txa
        and #7
        tay
        lda bmask,y
        sta msk
        sta ZV_A684
        pla
        tay
        rts

; SA638: BC (zc=x, zb=y) -> HL, A = x&7 (buffer: Spectrum address, B=0).
; Screen mode (Oric): HL = byte address, A = pixel offset 0..5.
        ZPROC $A638
        ldx zc
        ldy zb
        lda ZV_A6D7
        bne addrmask__scr
        jsr bufaddr
        sta zl
        lda ptr+1
        sta zh
        lda #0
        sta zb
        lda zc
        and #7
        rts
addrmask__scr:   jsr addrmask
        tya
        clc
        adc ptr
        sta zl
        lda ptr+1
        adc #0
        sta zh
        ldx #5
:       lda omask,x
        cmp msk
        beq :+
        dex
        bne :-
:       txa
        rts

; SA62A moveto + point plot: X = x, Y = y
moveto: stx ZV_A691
        sty ZV_A691+1
        jsr addrmask
        sty pcol
        lda ZV_A6D7
        bne :+
        sty ZV_A685
        lda ptr+1
        sta ZV_A685+1
        jmp moveto__plot
:       lda ptr
        sta ZV_A685
        lda ptr+1
        sta ZV_A685+1
moveto__plot:  lda ZV_A634
        ldx ZV_A634+1
        jsr selplot
        jmp (plotv)

; SA526 set text cursor: X = x, Y = y
setpos: stx ZV_A691
        sty ZV_A691+1
        txa
        and #7
        sta ZV_A683
        lda ZV_A6D7
        beq setpos__buf
        tya
        jsr gfx_linebase
        lda ptr
        sta ZV_A687
        lda ptr+1
        sta ZV_A687+1
        txa
        and #$F8
        lsr
        tay
        lda divtab,y
        pha
        and #3
        asl
        sta tr
        pla
        lsr
        lsr
        clc
        adc #1
        sta tcol
        rts
setpos__buf:   jsr bufaddr
        sta ZV_A687
        lda ptr+1
        sta ZV_A687+1
        rts

        ZPROC $A526             ; BC = (x, y)
        ldx zc
        ldy zb
        jmp setpos

; gfx_curback: move the text cursor back one character (x -= 8)
gfx_curback:
        lda ZV_A691
        sec
        sbc #8
        sta ZV_A691
        lda ZV_A6D7
        beq gfx_curback__buf
        lda tr
        sec
        sbc #2
        bcs :+
        adc #6
        dec tcol
:       sta tr
        dec tcol
        rts
gfx_curback__buf:   dec ZV_A687
        rts

; ===========================================================================
; Plot routines (Y = index, ptr, msk).  selplot: A = op lo, X = op hi.
selplot:
        sty selsy
        ldy #0
        cmp #$18
        beq selplot__d
        cpx #$A6
        beq selplot__e
        cpx #$AE
        bne selplot__o
        ldy #4
        bne selplot__o
selplot__e:     ldy #2
        bne selplot__o
selplot__d:     ldy #6
selplot__o:     lda ZV_A6D7
        beq :+
        tya
        ora #8
        tay
:       lda plottab,y
        sta plotv
        lda plottab+1,y
        sta plotv+1
        ldy selsy
        rts
selsy:  .byte 0

plotv:  .word p_or_b
plottab:.word p_or_b, p_er_b, p_xo_b, p_di_b
        .word p_or_s, p_er_s, p_xo_s, p_di_s

p_or_b: lda (ptr),y
        ora msk
        sta (ptr),y
        rts
p_er_b: lda msk
        eor #$FF
        and (ptr),y
        sta (ptr),y
        rts
p_xo_b: lda (ptr),y
        eor msk
        sta (ptr),y
        rts
p_di_b: GET_R
        and #5
        bne :+
        lda (ptr),y
        ora msk
        sta (ptr),y
:       rts
p_di_s: GET_R
        and #5
        bne p_r
p_or_s: cpy #40
        bcs p_r
        lda (ptr),y
        asl
        bpl p_r
        ror
        ora msk
        sta (ptr),y
p_r:    rts
p_er_s: cpy #40
        bcs p_r
        lda (ptr),y
        asl
        bpl p_r
        lda msk
        eor #$FF
        and (ptr),y
        sta (ptr),y
        rts
p_xo_s: cpy #40
        bcs p_r
        lda (ptr),y
        asl
        bpl p_r
        ror
        eor msk
        sta (ptr),y
        rts

; ---- pixel steps
right_b:lsr msk
        bcc :+
        ror msk
        iny
:       rts
left_b: asl msk
        bcc :+
        rol msk
        dey
:       rts
down_b: tya
        clc
        adc #32
        tay
        bcc :+
        inc ptr+1
:       rts
up_b:   tya
        sec
        sbc #32
        tay
        bcs :+
        dec ptr+1
:       rts
right_s:lsr msk
        bne :+
        lda #$20
        sta msk
        iny
:       rts
left_s: lda msk
        asl
        cmp #$40
        bcc :+
        lda #1
        dey
:       sta msk
        rts
down_s: lda ptr
        clc
        adc #40
        sta ptr
        bcc :+
        inc ptr+1
:       rts
up_s:   lda ptr
        sec
        sbc #40
        sta ptr
        bcs :+
        dec ptr+1
:       rts

steptab:.word right_b, left_b, down_b, up_b
        .word right_s, left_s, down_s, up_s

; load the current line position into ptr / Y / msk (and step vectors)
ldpos:  jsr setvec
        lda ZV_A684
        sta msk
        lda ZV_A6D7
        bne ldpos__s
        lda #0
        sta ptr
        lda ZV_A685+1
        sta ptr+1
        ldy ZV_A685
        rts
ldpos__s:     lda ZV_A685
        sta ptr
        lda ZV_A685+1
        sta ptr+1
        ldy pcol
        rts
setvec: ldx #0
        lda ZV_A6D7
        beq :+
        ldx #8
:       lda steptab,x
        sta vright
        lda steptab+1,x
        sta vright+1
        lda steptab+2,x
        sta vleft
        lda steptab+3,x
        sta vleft+1
        lda steptab+4,x
        sta vdown
        lda steptab+5,x
        sta vdown+1
        lda steptab+6,x
        sta vup
        lda steptab+7,x
        sta vup+1
        rts
stpos:  lda msk
        sta ZV_A684
        lda ZV_A6D7
        bne stpos__s
        sty ZV_A685
        lda ptr+1
        sta ZV_A685+1
        rts
stpos__s:     sty pcol
        lda ptr
        sta ZV_A685
        lda ptr+1
        sta ZV_A685+1
        rts
vright: .word 0
vleft:  .word 0
vdown:  .word 0
vup:    .word 0

; ===========================================================================
; SA55E relative line: dxv, dyv sign-magnitude
line:   jsr ldpos
        sty ly
        lda ZV_A5C4
        ldx ZV_A5C4+1
        jsr selplot             ; plotv (Y restored from t2)
        lda plotv
        sta l_plt+1
        lda plotv+1
        sta l_plt+2
        ; x direction
        lda dxv
        eor ZV_A693
        tax
        and #$7F
        sta t0                  ; adx
        txa
        bmi line__xl
        lda t0
        sta addx
        lda vright
        ldx vright+1
        jmp line__xs
line__xl:    lda #0
        sec
        sbc t0
        sta addx
        lda vleft
        ldx vleft+1
line__xs:    sta t2
        stx t3                  ; xstep
        lda dyv
        eor ZV_A693+1
        tax
        and #$7F
        sta t1                  ; ady
        txa
        bmi line__yu
        lda t1
        sta addy
        lda vdown
        ldx vdown+1
        jmp line__ys
line__yu:    lda #0
        sec
        sbc t1
        sta addy
        lda vup
        ldx vup+1
line__ys:    ; A/X = ystep
        pha
        lda t1
        cmp t0
        pla
        bcs line__ymaj
        ; x major: major = xstep, minor = ystep
        sta l_mnr+1
        stx l_mnr+2
        lda t2
        sta l_mjr+1
        lda t3
        sta l_mjr+2
        lda t0
        sta major
        lda t1
        sta minor
        jmp line__go
line__ymaj:  sta l_mjr+1
        stx l_mjr+2
        lda t2
        sta l_mnr+1
        lda t3
        sta l_mnr+2
        lda t1
        sta major
        lda t0
        sta minor
line__go:    lda major
        sta cnt_l
        lsr
        sta err
        ldy ly
line__loop:  lda err
        clc
        adc minor
        bcs line__take
        cmp major
        bcc line__no
line__take:  sbc major
        sta err
l_mnr = *
       jsr $FFFF
        jmp line__maj
line__no:    sta err
line__maj:
l_mjr = *
       jsr $FFFF
l_plt = *
       jsr $FFFF
        dec cnt_l
        bne line__loop
        jsr stpos
        lda ZV_A691
        clc
        adc addx
        sta ZV_A691
        lda ZV_A691+1
        clc
        adc addy
        sta ZV_A691+1
        rts
cnt_l:  .byte 0
ly:     .byte 0

; ===========================================================================
; SA721 flood fill from ptr/Y/msk (always OR).  Pixel-wise version of the
; original scanline fill (same result: the 4-connected clear region, with
; the original's "seed on a set pixel fills the run to its left" quirk).
; Screen mode: attribute bytes, column 0 and columns >= 40 are boundaries.
fill:   lda ZV_A6D7
        beq :+
        jmp fill_s
:       sty t2
        jsr setvec
        lda vright
        sta f_r1+1
        sta f_r2+1
        lda vright+1
        sta f_r1+2
        sta f_r2+2
        lda vleft
        sta f_l1+1
        lda vleft+1
        sta f_l1+2
        lda vdown
        sta f_dn+1
        lda vdown+1
        sta f_dn+2
        lda vup
        sta f_up+1
        lda vup+1
        sta f_up+2
        lda #0
        sta fsp
        ldy t2
        jsr fpush
        ; position was set by addrmask: ptr / t2 / msk
fill__pop:   ldx fsp
        bne :+
        rts
:       dex
        stx fsp
        lda fs_pl,x
        sta ptr
        lda fs_ph,x
        sta ptr+1
        lda fs_m,x
        sta msk
        ldy fs_y,x
        ; scan left to the first set pixel
fill__lft:
f_l1 = *
       jsr $FFFF
        jsr ftest
        beq fill__lft
        lda ptr
        sta fl_p
        lda ptr+1
        sta fl_p+1
        sty fl_y
        lda msk
        sta fl_m
        lda #0
        sta fcnt
fill__rgt:
f_r1 = *
       jsr $FFFF
        jsr ftest
        bne fill__rend
        lda (ptr),y
        ora msk
        sta (ptr),y
        inc fcnt
        jmp fill__rgt
fill__rend:  lda fcnt
        beq fill__pop
        jsr frest
f_dn = *
       jsr $FFFF
        jsr fscan
        jsr frest
f_up = *
       jsr $FFFF
        jsr fscan
        jmp fill__pop

frest:  lda fl_p
        sta ptr
        lda fl_p+1
        sta ptr+1
        ldy fl_y
        lda fl_m
        sta msk
        rts
; SA787: scan fcnt pixels right of the span start, push run starts
fscan:  lda fcnt
        sta fb
        lda #1
        sta fd
fscan__l:
f_r2 = *
       jsr $FFFF
        jsr ftest
        beq fscan__clr
        lda #1
        sta fd
        bne fscan__n
fscan__clr:   lda fd
        beq fscan__n
        jsr fpush
        lda #0
        sta fd
fscan__n:     dec fb
        bne fscan__l
        rts
; ftest: Z clear (A<>0) if the pixel is set or a boundary
ftest:  lda ZV_A6D7
        beq ftest__b
        cpy #40
        bcs ftest__bd
        lda (ptr),y
        asl
        bpl ftest__bd
        lda (ptr),y
ftest__b:     lda (ptr),y
        and msk
        rts
ftest__bd:    lda #1
        rts
fpush:  ldx fsp
        cpx #FSTK
        bcs :+
        lda ptr
        sta fs_pl,x
        lda ptr+1
        sta fs_ph,x
        tya
        sta fs_y,x
        lda msk
        sta fs_m,x
        inc fsp
:       rts

; ===========================================================================
; Characters
; SA695 print char / token (A)
        ZPROC $A695
        ZPROC $A955
printc: cmp #$80
        bcc gfx_glyph
        and #$7F
        tax
        lda #<T_A98E
        sta tp
        lda #>T_A98E
        sta tp+1
        ldy #0
printc__w:     inc tp
        bne :+
        inc tp+1
:       lda (tp),y
        bpl printc__w
        dex
        bne printc__w
printc__c:     inc tp
        bne :+
        inc tp+1
:       ldy #0
        lda (tp),y
        and #$7F
        jsr gfx_glyph
        ldy #0
        lda (tp),y
        bpl printc__c
        rts

; gfx_print: print the 0-terminated string at (X lo, Y hi) as chars/tokens
gfx_print:
        stx tp
        sty tp+1
gfx_print__l:     ldy #0
        lda (tp),y
        beq gfx_print__e
        lda tp
        pha
        lda tp+1
        pha
        lda (tp),y
        jsr printc
        pla
        sta tp+1
        pla
        sta tp
        inc tp
        bne gfx_print__l
        inc tp+1
        bne gfx_print__l
gfx_print__e:     rts

; LA6B5 glyph A
gfx_glyph:
        sta gch
        sta fp
        lda #0
        sta fp+1
        asl fp
        rol fp+1
        asl fp
        rol fp+1
        asl fp
        rol fp+1
        lda ZV_A6BC+1
        cmp #$3C
        bne gfx_glyph__cus
        lda fp
        clc
        adc #<(T_ROMFONT-256)
        sta fp
        lda fp+1
        adc #>(T_ROMFONT-256)
        sta fp+1
        jmp gfx_glyph__f
gfx_glyph__cus:   lda fp
        clc
        adc #<T_AA2F
        sta fp
        lda fp+1
        adc #>T_AA2F
        sta fp+1
gfx_glyph__f:     lda ZV_A691
        clc
        adc #8
        sta ZV_A691
        ; glyph op
        lda ZV_A6E0
        ldx #$24                ; bit zp: overwrite
        cmp #$B6
        bne :+
        ldx #$11                ; ora (zp),y
:       cmp #$AE
        bne :+
        ldx #$51                ; eor (zp),y
:       stx g_op
        stx g_op2
        lda ZV_A6D7
        bne gscr
        ; ---- buffer
        lda #0
        sta ptr
        lda ZV_A687+1
        sta ptr+1
        ldy ZV_A687
        inc ZV_A687
        lda #8
        sta cnt_g
        ldx ZV_A683
        bne gfx_glyph__un
gfx_glyph__al:    sty t2
        ldy #0
        lda (fp),y
        ldy t2
g_op = *
       ora (ptr),y
        sta (ptr),y
        jsr g_nextfp
        tya
        clc
        adc #32
        tay
        bcc :+
        inc ptr+1
:       dec cnt_g
        bne gfx_glyph__al
        rts
gfx_glyph__un:    sty t2
        jsr g_split
        ldy t2
        lda gv
        jsr g_op2x
        iny
        lda gl
        jsr g_op2x
        dey
        jsr g_nextfp
        tya
        clc
        adc #32
        tay
        bcc :+
        inc ptr+1
:       dec cnt_g
        bne gfx_glyph__un
        rts
g_op2x:
g_op2:  ora (ptr),y
        sta (ptr),y
        rts
cnt_g:  .byte 0
gch:    .byte 0
g_nextfp:
        inc fp
        bne :+
        inc fp+1
:       rts
; g_split: gv = row >> bit, gl = row << (8-bit)  (X = bit, kept)
g_split:ldy #0
        lda (fp),y
        sta gv
        sty gl
        txa
        pha
:       lsr gv
        ror gl
        dex
        bne :-
        pla
        tax
        rts

        ; ---- screen
gscr:   lda ZV_A691+1
        cmp #176
        bcc gscr_h
        ; status lines -> Oric text rows (docs/PORTING.md section 5)
        cmp #192
        bcs gscr_x
        ldx #<TEXTROW0
        ldy #>TEXTROW0
        cmp #184
        bcc :+
        ldx #<TEXTROW1
        ldy #>TEXTROW1
:       stx ptr
        sty ptr+1
        lda ZV_A691
        sec
        sbc #8
        lsr
        lsr
        lsr
        clc
        adc #4
        tay
        cpy #40
        bcs gscr_x
        lda ZV_A6BC+1
        cmp #$3C
        bne gscr_x              ; custom-font glyphs have no character
        lda gch
        cmp #32                 ; (codes < 32 would be serial attributes)
        bcc gscr_x
        sta (ptr),y
gscr_x: rts
gscr_h: lda ZV_A687
        sta ptr
        lda ZV_A687+1
        sta ptr+1
        lda ZV_A6E0
        ldx #0
        cmp #$B6
        bne :+
        ldx #1
:       cmp #$AE
        bne :+
        ldx #2
:       stx gopm
        lda tcol
        sta t2
        lda tr
        sta t3
        ; advance the cursor by 8 pixels
        clc
        adc #2
        inc tcol
        cmp #6
        bcc :+
        sbc #6
        inc tcol
:       sta tr
        lda #8
        sta cnt_g
        lda ZV_A683
        bne gscr__row
        jmp gal                 ; aligned: fast path
gscr__row:   ldx ZV_A683
        bne gscr__u
        ldy #0
        lda (fp),y
        ldx t3
        ldy t2
        jsr sbyte
        jmp gscr__nx
gscr__u:     jsr g_split
        lda gl
        pha
        lda gv
        ldx t3
        ldy t2
        jsr sbyte
        ldy tcol
        ldx tr
        pla
        jsr sbyte
gscr__nx:    jsr g_nextfp
        lda ptr
        clc
        adc #40
        sta ptr
        bcc :+
        inc ptr+1
:       dec cnt_g
        bne gscr__row
        rts

; gal: aligned glyph (x & 7 = 0) on the screen: 8 rows, column t2, offset
; t3 (0,2,4), op gopm.  Per glyph: splitter, masks and the op opcode.
gal:    ldx t3
        lda galtab,x
        sta gal_j+1
        lda galtab+1,x
        sta gal_j+2
        lda #$FF
        sta gm0
        sta gm1
        ldy #$05                ; ora zp
        lda gopm
        bne :+
        lda gnm0,x              ; overwrite: clear the 8 pixels first
        sta gm0
        lda gnm1,x
        sta gm1
:       cmp #2
        bne :+
        ldy #$45                ; eor zp
:       sty gal_o0
        sty gal_o1
        lda #0
        sta gry
gal_r:  ldy gry
        lda (fp),y
gal_j:  jmp $FFFF
gal_0:  sta gv                  ; r = 0: 6 + 2 bits
        lsr
        lsr
        sta sb0
        lda gv
        asl
        asl
        asl
        asl
        and #$30
        jmp gal_a
gal_2:  sta gv                  ; r = 2: 4 + 4
        lsr
        lsr
        lsr
        lsr
        sta sb0
        lda gv
        asl
        asl
        and #$3C
        jmp gal_a
gal_4:  sta gv                  ; r = 4: 2 + 6
        rol
        rol
        rol
        and #3
        sta sb0
        lda gv
        and #$3F
gal_a:  sta sb1
        ldy t2
        cpy #40
        bcs gal_n
        lda (ptr),y
        asl
        bpl :+                  ; attribute: untouched
        ror
        and gm0
gal_o0 = *
        ora sb0
        sta (ptr),y
:       iny
        cpy #40
        bcs gal_n
        lda (ptr),y
        asl
        bpl gal_n
        ror
        and gm1
gal_o1 = *
        ora sb1
        sta (ptr),y
gal_n:  lda ptr
        clc
        adc #40
        sta ptr
        bcc :+
        inc ptr+1
:       inc gry
        lda gry
        cmp #8
        bne gal_r
        rts
galtab: .word gal_0, gal_2, gal_4
gnm0:   .byte $C0, 0, $F0, 0, $FC
gnm1:   .byte $CF, 0, $C3, 0, $C0
gm0:    .byte $FF
gm1:    .byte $FF
gry:    .byte 0

; sbyte: one Spectrum byte A at Oric column Y, offset X (0,2,4) on line ptr
sbyte:  sta gv
        cpx #2
        beq sbyte__r2
        bcs sbyte__r4
        lsr
        lsr
        sta sb0
        lda gv
        asl
        asl
        asl
        asl
        and #$30
        sta sb1
        lda #$3F
        ldx #$30
        bne sbyte__go
sbyte__r2:    lsr
        lsr
        lsr
        lsr
        sta sb0
        lda gv
        asl
        asl
        and #$3C
        sta sb1
        lda #$0F
        ldx #$3C
        bne sbyte__go
sbyte__r4:    rol
        rol
        rol
        and #3
        sta sb0
        lda gv
        and #$3F
        sta sb1
        lda #$03
        ldx #$3F
sbyte__go:    eor #$FF
        sta t0                  ; ~m0
        txa
        eor #$FF
        sta t1                  ; ~m1
        lda sb0
        ldx t0
        jsr sput
        iny
        lda sb1
        ldx t1
; sput: A = bits, X = ~mask, at (ptr),Y
sput:   cpy #40
        bcs sput__r
        sta gl
        lda (ptr),y
        asl
        bpl sput__r
        lda gopm
        beq sput__ow
        lsr
        lda gl
        bcs sput__or
        eor (ptr),y
        sta (ptr),y
sput__r:     rts
sput__or:    ora (ptr),y
        sta (ptr),y
        rts
sput__ow:    txa
        and (ptr),y
        ora gl
        sta (ptr),y
        rts

; ===========================================================================
; SA911 number printer: A = skip (0,6,..,24), HL = value, E = flags
        ZPROC $A911
        pha
        lda zl
        sta nval
        lda zh
        sta nval+1
        lda ze
        sta nflg
        pla
; number: A = skip, nval, nflg
number: ldx #0
:       cmp #6
        bcc :+
        sbc #6
        inx
        bne :-
:       stx nidx
number__dig:   ldx nidx
        cpx #5
        bcs number__done
        ldy #0
number__sub:   lda nval
        sec
        sbc divlo,x
        sta t0
        lda nval+1
        sbc divhi,x
        bcc number__q
        sta nval+1
        lda t0
        sta nval
        iny                     ; 8-bit digit counter, like the Z80's A
        jmp number__sub
number__q:     inc nidx
        tya
        bne number__nz
        lda nflg
        bpl number__zero
        and #$40
        bne number__dig
        lda nflg
        and #$3F
        jsr printc
        jmp number__dig
number__zero:  lda #$30
        jsr printc
        jmp number__dig
number__nz:    lda #0
        sta nflg
        tya
        clc
        adc #$30                ; (digits >= 208 print tokens, as the original)
        jsr printc
        jmp number__dig
number__done:  rts
divlo:  .byte <10000, <1000, <100, <10, <1
divhi:  .byte >10000, >1000, >100, >10, >1

; ===========================================================================
; Oric colour helpers
; attrtpl: A = Spectrum attribute -> c0v, c1v (0 = none), tmpl
attrtpl:pha
        and #7
        tax
        lda zx2oric,x
        sta t0                  ; ink K
        pla
        lsr
        lsr
        lsr
        and #7
        tax
        lda zx2oric,x
        sta t1                  ; paper P
        lda #0
        sta c1v
        lda #$40
        sta tmpl
        lda t0
        bne attrtpl__k
        lda #7
        sec
        sbc t1
        ora #$90
        sta c0v
        lda #$C0
        sta tmpl
        rts
attrtpl__k:     cmp #7
        beq attrtpl__p
        lda t1
        bne attrtpl__kp
        lda t0
        sta c0v
        rts
attrtpl__kp:    lda t0
        sta c1v
attrtpl__p:     lda t1
        ora #$10
        sta c0v
        rts

; gfx_cls: whole screen to Spectrum attribute A (command 8F; also the
; border variable DA4C2 = (A>>3)&7).  Lines 0-3 and 196-199 stay black.
gfx_cls:pha
        lsr
        lsr
        lsr
        jsr Z_A903
        pla
        jsr attrtpl
        lda #<$A000
        sta ptr
        lda #>$A000
        sta ptr+1
        ldx #0
gfx_cls__ln:    cpx #4
        bcc gfx_cls__blk
        cpx #196
        bcs gfx_cls__blk
        ldy #0
        lda c0v
        sta (ptr),y
        iny
        lda c1v
        bne :+
        lda tmpl
:       sta (ptr),y
        iny
        lda tmpl
:       sta (ptr),y
        iny
        cpy #40
        bne :-
        beq gfx_cls__nx
gfx_cls__blk:   ldy #0
        lda #$10
        sta (ptr),y
        iny
        lda #$40
:       sta (ptr),y
        iny
        cpy #40
        bne :-
gfx_cls__nx:    lda ptr
        clc
        adc #40
        sta ptr
        bcc :+
        inc ptr+1
:       inx
        cpx #200
        bne gfx_cls__ln
        ; the text rows (Spectrum rows 22-23): ink K, paper P, blank
        ldx #118
        lda #$20
:       sta TEXTROW0,x
        dex
        bpl :-
        lda t1
        ora #$10
        sta TEXTROW0+1
        sta TEXTROW0+41
        sta TEXTROW0+81
        lda t0
        sta TEXTROW0
        sta TEXTROW0+40
        sta TEXTROW0+80
        rts

; gfx_attr_rows: A = attribute, X = first char row, Y = number of rows
gfx_attr_rows:
        pha
        txa
        asl
        asl
        asl
        tax
        tya
        asl
        asl
        asl
        tay
        pla
; gfx_attr_lines: A = attribute, X = first Spectrum pixel row, Y = count.
; Rewrites column 0/1 and bit 7 of the pixel bytes (pixels kept).
gfx_attr_lines:
        sty t3
        stx t2
        jsr attrtpl
gfx_attr_lines__ln:    lda t3
        beq gfx_attr_lines__e
        lda t2
        jsr gfx_linebase
        ldy #0
        lda c0v
        sta (ptr),y
        iny
        lda c1v
        bne gfx_attr_lines__w1
        lda (ptr),y
        asl
        bmi :+
        lda #0                  ; was an attribute: becomes empty pixels
:       lsr
        and #$3F
        ora tmpl
gfx_attr_lines__w1:    sta (ptr),y
        iny
gfx_attr_lines__px:    lda (ptr),y
        asl
        bpl :+                  ; attribute: keep
        lsr
        and #$3F
        ora tmpl
        sta (ptr),y
:       iny
        cpy #40
        bne gfx_attr_lines__px
        inc t2
        dec t3
        bne gfx_attr_lines__ln
gfx_attr_lines__e:     rts

; gfx_recolour: A = attribute, X = first char column, Y = last char column,
; gfx_rc_row / gfx_rc_n = Spectrum pixel rows.  Puts serial attributes just
; before (1-2 columns) and after (1-2 columns) the area, restoring the line's
; base colours (read from columns 0/1), and sets the inverse bit of the
; pixel bytes inside.  Each attribute column blanks 6 pixels.
gfx_recolour:
        sta rc_a
        sty rc_ce
        txa
        asl
        asl
        tay                     ; (8*X)>>1
        lda divtab,y
        lsr
        lsr
        clc
        adc #1
        sta rc_cs
        lda rc_ce
        asl
        asl
        asl                     ; 8*Y
        ora #7
        lsr
        tay
        lda divtab,y
        lsr
        lsr
        clc
        adc #1
        sta rc_ce
        lda rc_a                ; area colours
        and #7
        tax
        lda zx2oric,x
        sta t0
        lda rc_a
        lsr
        lsr
        lsr
        and #7
        tax
        lda zx2oric,x
        ldx t0
        bne gfx_recolour__an
        eor #7
        sta rc_pa
        lda #7
        sta rc_ia
        lda #$80
        sta rc_va
        bne gfx_recolour__rows
gfx_recolour__an:    sta rc_pa
        stx rc_ia
        lda #0
        sta rc_va
gfx_recolour__rows:  lda gfx_rc_row
        sta t2
        lda gfx_rc_n
        sta t3
gfx_recolour__ln:    lda t3
        bne :+
        rts
:       lda t2
        jsr gfx_linebase
        ; base colours of the line
        ldy #0
        lda (ptr),y
        tax
        and #$80
        sta rc_vb
        txa
        and #$10
        beq gfx_recolour__inkat
        txa
        and #7
        sta rc_pb
        lda #7
        sta rc_ib
        lda rc_vb
        bne gfx_recolour__base
        iny
        lda (ptr),y
        cmp #8
        bcs gfx_recolour__base
        sta rc_ib
        bcc gfx_recolour__base
gfx_recolour__inkat: lda #0
        sta rc_pb
        txa
        and #7
        sta rc_ib
gfx_recolour__base:  lda rc_ia
        cmp rc_ib
        beq gfx_recolour__noink
        ora rc_vb
        ldx rc_cs
        dex
        dex
        jsr rcput
        lda rc_ib
        ora rc_vb
        ldx rc_ce
        inx
        inx
        jsr rcput
gfx_recolour__noink: lda rc_pa
        ora #$10
        ora rc_va
        ldx rc_cs
        dex
        jsr rcput
        lda rc_pb
        ora #$10
        ora rc_vb
        ldx rc_ce
        inx
        jsr rcput
        ldy rc_cs
gfx_recolour__px:    cpy #40
        bcs gfx_recolour__nl
        lda (ptr),y
        asl
        bpl :+
        lsr
        ora rc_va
        sta (ptr),y
:       cpy rc_ce
        iny
        bcc gfx_recolour__px
gfx_recolour__nl:    inc t2
        dec t3
        jmp gfx_recolour__ln
rcput:  cpx #40
        bcs :+
        cpx #0
        beq :+
        pha
        txa
        tay
        pla
        sta (ptr),y
:       rts

; gfx_lz: unpack the LZ data at (lzs) to (lzd)
gfx_lz: ldy #0
gfx_lz__tok:   jsr gfx_lz__get
        beq gfx_lz__e
        bmi gfx_lz__m
        tax
gfx_lz__lit:   jsr gfx_lz__get
        sta (lzd),y
        jsr gfx_lz__inc
        dex
        bne gfx_lz__lit
        beq gfx_lz__tok
gfx_lz__m:     and #$7F
        clc
        adc #3
        tax
        jsr gfx_lz__get
        sta t0
        jsr gfx_lz__get
        sta t1
        lda lzd
        sec
        sbc t0
        sta lzc
        lda lzd+1
        sbc t1
        sta lzc+1
gfx_lz__cp:    lda (lzc),y
        sta (lzd),y
        inc lzc
        bne :+
        inc lzc+1
:       jsr gfx_lz__inc
        dex
        bne gfx_lz__cp
        beq gfx_lz__tok
gfx_lz__e:     rts
gfx_lz__get:   lda (lzs),y
        inc lzs
        bne :+
        inc lzs+1
:       ora #0
        rts
gfx_lz__inc:   inc lzd
        bne :+
        inc lzd+1
:       rts

; ===========================================================================
; Beeper entry points -> sound effects (snd.inc).  The original played
; square waves on the beeper (blocking); the Oric starts an AY effect.
; A95F: B = half-cycles, C = delay (N = $20).  A964: same with N = (DA969)
        ZPROC $A95F
        lda #$20
        sta ZV_A969
        ZPROC $A964
        lda zb
        ldx zc
        ldy #SND_BADKEY
        cmp #$30
        beq gfx_lz__fx
        ldy #SND_TAPEERR
        cmp #$F0
        beq gfx_lz__fx
        ldy #SND_TICK
gfx_lz__fx:    tya
        jmp snd_fx
; A977: inline N, K, K x (C, B).  A97C: inline K, K x (C, B), N = $20
        ZPROC $A977
        pla
        sta strmb
        pla
        sta strmb+1
        jsr getbb
        jmp a97x
        ZPROC $A97C
        pla
        sta strmb
        pla
        sta strmb+1
        lda #$20
a97x:   sta ZV_A969
        jsr getbb
        sta t2                  ; K
        jsr getbb               ; first C
        sta t3
        ; skip the rest of the pairs
        lda t2
        asl
        tax
        dex
:       dex
        beq :+
        jsr getbb
        jmp :-
:       jsr getbb               ; (the last byte)
        ; choose the effect
        lda ZV_A969
        cmp #6
        bne :+
        lda #SND_REV
        ldx t3
        bne a97x__go
:       cmp #4
        bne :+
        lda #SND_CHIRP
        bne a97x__go
:       lda t2
        cmp #3
        bne :+
        lda #SND_KEYBLIP
        bne a97x__go
:       lda #SND_BEEP
a97x__go:    jsr snd_fx
        lda strmb
        clc
        adc #1
        sta strmb
        bcc :+
        inc strmb+1
:       jmp (strmb)
getbb:  inc strmb
        bne :+
        inc strmb+1
:       ldy #0
        lda (strmb),y
        rts

; gfx_textinit: Spectrum ROM font -> HIRES character set at $9800 (chars
; 32-127, pixel columns 1-6), text rows: ink yellow / green / black, blank.
gfx_textinit:
        lda #<T_ROMFONT
        sta lzs
        lda #>T_ROMFONT
        sta lzs+1
        lda #<($9800 + 32*8)
        sta lzd
        lda #>($9800 + 32*8)
        sta lzd+1
        ldx #3                  ; 768 bytes
        ldy #0
:       lda (lzs),y
        lsr
        and #$3F
        sta (lzd),y
        iny
        bne :-
        inc lzs+1
        inc lzd+1
        dex
        bne :-
        ldx #118                ; ($BFDF, the last byte, is the video mode)
        lda #$20
:       sta TEXTROW0,x
        dex
        bpl :-
        lda #3
        sta TEXTROW0
        lda #2
        sta TEXTROW1
        rts

; ===========================================================================
; fill_s: screen-mode flood fill from ptr (line base) / Y (column) / msk.
; Same result as the pixel-wise fill (4-connected clear region, the seed
; quirk), with whole-byte shortcuts like the original's: empty bytes are
; skipped / filled 6 pixels at a time.  Attribute bytes and columns 0 and
; >= 40 are boundaries; rows outside HIRES lines 4-179 are not entered.
FS_TOP = $A000 + 4*40
FS_BOT = $A000 + 180*40
fill_s: cpy #40
        bcs fs_ret
        lda #0
        sta fsp
        jsr fpush
fs_pop: ldx fsp
        bne :+
fs_ret: rts
:       dex
        stx fsp
        lda fs_pl,x
        sta ptr
        lda fs_ph,x
        sta ptr+1
        lda fs_m,x
        sta msk
        ldy fs_y,x
        ; ---- scan left to the first set pixel / boundary
fs_l:   asl msk
        lda msk
        cmp #$40
        bcc fs_lt
        lda #1
        sta msk
fs_lb:  dey
        cpy #40
        bcs fs_lstop
        lda (ptr),y
        asl
        bpl fs_lstop
        and #$7E                ; (bits 5-0 << 1)
        beq fs_lb               ; empty byte: skip it
        lsr
        and msk
        bne fs_lstop
        beq fs_l
fs_lt:  lda (ptr),y
        asl
        bpl fs_lstop
        lsr
        and msk
        beq fs_l
fs_lstop:
        lda ptr
        sta fl_p
        lda ptr+1
        sta fl_p+1
        sty fl_y
        lda msk
        sta fl_m
        lda #0
        sta fcnt
        ; ---- fill right up to the next set pixel / boundary
fs_r:   lsr msk
        bne fs_rt
        lda #$20
        sta msk
fs_rb:  iny
        cpy #40
        bcs fs_rend
        lda (ptr),y
        asl
        bpl fs_rend
        and #$7E
        bne fs_rt
        lda (ptr),y             ; empty byte: fill it whole
        ora #$3F
        sta (ptr),y
        lda fcnt
        clc
        adc #6
        sta fcnt
        jmp fs_rb
fs_rt:  lda (ptr),y
        and msk
        bne fs_rend
        lda (ptr),y
        ora msk
        sta (ptr),y
        inc fcnt
        jmp fs_r
fs_rend:lda fcnt
        bne :+
        jmp fs_pop
:       ; ---- row below
        jsr frest
        lda ptr
        clc
        adc #40
        sta ptr
        bcc :+
        inc ptr+1
:       lda ptr+1
        cmp #>FS_BOT
        bcc :+
        bne fs_up
        lda ptr
        cmp #<FS_BOT
        bcs fs_up
:       jsr fs_scan
fs_up:  jsr frest
        lda ptr
        sec
        sbc #40
        sta ptr
        bcs :+
        dec ptr+1
:       lda ptr+1
        cmp #>FS_TOP
        bcc fs_nx
        bne :+
        lda ptr
        cmp #<FS_TOP
        bcc fs_nx
:       jsr fs_scan
fs_nx:  jmp fs_pop

; scan fcnt pixels right of the span start on this row, push run starts
fs_scan:lda fcnt
        sta fb
        lda #1
        sta fd
fsc_l:  lsr msk
        bne fsc_t
        lda #$20
        sta msk
fsc_b:  iny
        cpy #40
        bcs fsc_ret
        lda (ptr),y
        asl
        bpl fsc_bound           ; attribute: 6 "set" pixels
        and #$7E
        beq fsc_e
        cmp #$7E
        bne fsc_t
        lda fd                  ; full byte after a set pixel: skip
        beq fsc_t
        bne fsc_skip
fsc_e:  lda fd                  ; empty byte after a clear pixel: skip
        bne fsc_t
fsc_skip:
        lda fb
        cmp #7
        bcc fsc_ret
        sbc #6
        sta fb
        jmp fsc_b
fsc_bound:
        lda #1
        sta fd
        bne fsc_skip
fsc_t:  lda (ptr),y
        asl
        bpl fsc_set
        lsr
        and msk
        beq fsc_clr
fsc_set:lda #1
        sta fd
        bne fsc_n
fsc_clr:lda fd
        beq fsc_n
        jsr fpush
        lda #0
        sta fd
fsc_n:  dec fb
        bne fsc_l
fsc_ret:rts
