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
;    byte whose bit 6 is 0 (attributes) and keep bit 7.  Text with y >= 176
;    goes to the Oric text rows at $BF68 as character codes.
;
; The engine's state lives in ZVARs at the Spectrum addresses and with the
; Spectrum encodings (A5C4 plot op, A6D7 screen flag, A6BC font, ...), so the
; test harness can load and compare it.  In screen mode A685/A687 hold Oric
; line base addresses instead of Spectrum screen addresses.
;
; The routines do not touch the zero-page Z80 register file, so callers'
; BC/DE/HL/IX survive (the Z80 versions destroyed them; nobody relied on it).

        .include "zx.inc"
        .include "snd.inc"
        .include "hw.inc"

        .export gfx_cls, gfx_attr_rows, gfx_recolour, gfx_rc_row, gfx_rc_n
        .export gfx_linebase, gfx_lz, gfx_glyph, gfx_textinit, gfx_arng, gfx_km
        .export TEXTROW0, TEXTROW1
        .exportzp lzs, lzd, lzc
        .import T_FEXC, T_FEXCC, T_AA2F, T_A98E, T_A0BF  ; data/gfx_data.s

TEXTROW0 = $BF68                ; Spectrum char row 22 (PENALTY/SCORE)
TEXTROW1 = $BF68 + 40           ; Spectrum char row 23 (messages)

; ---------------------------------------------------------------------------
        .zeropage
ptr:    .res 2          ; current byte = (ptr),y
msk:    .res 1          ; current pixel mask
strm:   .res 2          ; stream pointer
err:    .res 1
minor:  .res 1
major:  .res 1
t0:     .res 1
t1:     .res 1
t2:     .res 1
t3:     .res 1
fp:     .res 2          ; glyph pointer
tp:     .res 2          ; token pointer
gv:     .res 1
gl:     .res 1
sb0:    .res 1
sb1:    .res 1
lzs:    .res 2
lzd:    .res 2
lzc:    .res 2

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

        .segment "BSS"
pcol:   .res 1                  ; screen mode: line column of A685
tcol:   .res 1                  ; screen mode: text column (of x & $F8)
tr:     .res 1                  ;   and pixel offset in it (0,2,4)
savesp: .res 1
cnt:    .res 1                  ; stream item count
gopm:   .res 1                  ; glyph op: 0 overwrite, 1 or, 2 xor
nval:   .res 2
nflg:   .res 1
nidx:   .res 1
dxv:    .res 2                  ; line deltas x, y (sign-magnitude)
amag:   .res 2                  ; |dx|, |dy|
addv:   .res 2                  ; signed dx, dy
svl:    .res 2                  ; step routine x, y
svh:    .res 2
moff:   .res 1                  ; 0 buffer, 8 screen (step/plot tables)
fsp:    .res 1                  ; fill seed stack pointer
fcnt:   .res 1
fd:     .res 1
fb:     .res 1
fl_p:   .res 2                  ; fill span start (ptr, y, mask)
fl_y:   .res 1
fl_m:   .res 1
fsx:    .res 1
fscr:   .res 1
rc_cs:  .res 1                  ; gfx_recolour work
rc_ce:  .res 1
rc_ia:  .res 1
rc_pa:  .res 1
rc_va:  .res 1
rc_ib:  .res 1
rc_pb:  .res 1
rc_vb:  .res 1
c0v:    .res 1                  ; line colour template (gfx_cls / attr)
c1v:    .res 1
tmpl:   .res 1
km:     .res 1
kk:     .res 1                  ; ink / paper (Oric numbers) of the last attribute
pp:     .res 1
ly:     .res 1
cnt_l:  .res 1
gry:    .res 1
gch:    .res 1
gbufh:  .res 8
gbufl:  .res 8
plotv:  .res 2
lk0:    .res 1
lk1:    .res 1
lk2:    .res 1

        .segment "DATA"
gfx_rc_row: .byte 0             ; gfx_recolour: first Spectrum pixel row
gfx_rc_n:   .byte 8             ;   number of pixel rows

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
        jsr getb                ; (skip to the first stream byte)
        tsx
        stx savesp
; ---- LA4EF main loop
next:   jsr getb
        beq endstr
        bpl :+
        jmp command
:       sta cnt
        lda ZV_A4F9
        bne text
:       jsr getb
        sta dxv
        jsr getb
        sta dxv+1
        jsr line
        dec cnt
        bne :-
        beq next
endstr: ldx savesp
        txs
        jmp (strm)

; ---- text items (LA509): FF x y / FE dx / FD dy / FC k e
text:   jsr getb
        cmp #$FC
        bcs t_ctl
        jsr printc
        dec cnt
        bne text
        beq next
t_ctl:  cmp #$FD
        bcc t_fc
        beq t_fd
        lsr
        bcs t_ff
        jsr getb                ; FE dx
        clc
        adc ZV_A691
        tax
        ldy ZV_A691+1
        bcc t_set
        bcs t_set
t_fd:   jsr getb
        clc
        adc ZV_A691+1
        tay
        ldx ZV_A691
t_set:  jsr setpos
        jmp text
t_ff:   jsr getb
        pha
        jsr getb
        tay
        pla
        tax
        jmp t_set
t_fc:   jsr getb                ; FC k e: number DA4C3
        pha
        jsr getb
        sta nflg
        lda ZV_A4C3
        sta nval
        lda ZV_A4C3+1
        sta nval+1
        pla
        jsr number
        jmp text

; ---- commands 80-90 (handlers return to next)
command:and #$7F
        beq gosub
        cmp #1
        beq retsub
        cmp #$11
        bcc :+
        jmp next                ; 91-FF: invalid in the original
:
        asl
        tax
        lda #>(next-1)
        pha
        lda #<(next-1)
        pha
        lda cmdtab-3,x
        pha
        lda cmdtab-4,x
        pha
        rts
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
        bne :+
retsub: pla
        sta strm
        pla
:       sta strm+1
        jmp next

cmdtab: .word Z_A80F-1, Z_A828-1, Z_A82E-1, c_fill-1, c_dither-1, c_move-1
        .word c_rmove-1, c_mirx-1, c_miry-1, c_text-1, c_scr-1, c_font-1
        .word c_rts-1, c_cls-1, c_yoff-1

c_dither:
        lda #$18
        ldx #$1C
        sta ZV_A5C4
        stx ZV_A5C4+1
c_rts:  rts
c_mirx: ldx #0
        beq :+
c_miry: ldx #1
:       lda ZV_A693,x
        eor #$80
        sta ZV_A693,x
        rts
c_text: lda ZV_A4F9
        eor #$0F
        sta ZV_A4F9
        rts
c_scr:  lda ZV_A6D7
        beq :+
        jmp Z_A8BF
:       jmp Z_A89B
c_font: lda ZV_A6BC
        beq :+
        jmp Z_A8DB
:       jmp Z_A8D3
c_yoff: jsr getb
        sta ZV_A850
        rts
c_cls:  jsr getb
        jmp gfx_cls
; 87 x y: move absolute + plot
c_move: jsr getb
        pha
        jsr getb
        tay
        pla
        tax
        jmp :+
; 88 dx dy: move relative + plot
c_rmove:jsr relc
:       tya
        clc
        adc ZV_A850
        tay
        jmp moveto
; 85 dx dy: flood fill (SA835)
c_fill: jsr relc
        stx fsx
        jsr addrmask            ; ptr/y/msk of (X,Y), A684 = mask
        jsr fill
        lda ZV_A6D7
        beq c_rts
        ; screen mode: the original keeps the line address (byte of the
        ; current x) and takes the seed's bit (SA672 sets DA684 only), so
        ; the next line starts at x' = (x & $F8) | (seed x & 7)
        lda fsx
        and #7
        sta t0
        lda ZV_A691
        and #$F8
        ora t0
        jsr xcr
        sta pcol
        ldy t3
        lda omask,y
        sta ZV_A684
        rts

; SA858: read (dx,dy) -> X = x+-dx, Y = y+-dy (mirrors)
relc:   ldx #0
        jsr :+
        pha
        inx
        jsr :+
        tay
        pla
        tax
        rts
:       jsr getb
        ldy ZV_A693,x
        bpl :+
        eor #$FF
        clc
        adc #1
:       clc
        adc ZV_A691,x
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
        bne :+
        ZPROC $A8BF             ; buffer target
        lda #0
:       sta ZV_A6D7
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
; gfx_linebase: A = Spectrum y -> ptr = $A000 + (y+4)*40 (X, Y kept)
gfx_linebase:
        clc
        adc #4
; lbase: A = Oric line (with C = bit 8) -> ptr
lbase:  sta t0
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

; xcr: A = Spectrum x -> A = Oric column of pixel x+6, t3 = offset 0..5
; (X kept, Y destroyed)
xcr:    pha
        lsr
        tay
        lda divtab,y
        and #3
        asl
        sta t3
        pla
        and #1
        ora t3
        sta t3
        lda divtab,y
        lsr
        lsr
        clc
        adc #1
        rts

; addrmask (SA672): X=x, Y=y -> ptr/Y(index)/msk for the current target,
; A684 = mask.  (Does not store A685.)
addrmask:
        lda ZV_A6D7
        beq :+
        tya
        jsr gfx_linebase
        txa
        jsr xcr
        pha
        ldy t3
        lda omask,y
        bne am_m
:       tya                     ; buffer: $6400 + y*32 + x>>3
        sta t0
        lda #0
        sta ptr
        asl t0
        rol
        asl t0
        rol
        asl t0
        rol
        asl t0
        rol
        asl t0
        rol
        adc #$64
        sta ptr+1
        txa
        lsr
        lsr
        lsr
        ora t0
        pha
        txa
        and #7
        tay
        lda bmask,y
am_m:   sta msk
        sta ZV_A684
        pla
        tay
        rts

; SA62A moveto + point plot: X = x, Y = y
moveto: stx ZV_A691
        sty ZV_A691+1
        jsr addrmask
        jsr stpos
        lda ZV_A634
        ldx ZV_A634+1
        jsr selplot
        jmp (plotv)

; SA526 set text cursor: X = x, Y = y
        ZPROC $A526             ; (BC = x, y)
        ldx zc
        ldy zb
setpos: stx ZV_A691
        sty ZV_A691+1
        txa
        and #7
        sta ZV_A683
        lda ZV_A6D7
        beq :+
        tya
        jsr gfx_linebase
        lda ptr
        sta ZV_A687
        lda ptr+1
        sta ZV_A687+1
        txa
        and #$F8
        jsr xcr
        sta tcol
        lda t3
        sta tr
        rts
:       lda ZV_A684             ; (SA526 leaves the line mask alone)
        pha
        jsr addrmask
        sty ZV_A687
        lda ptr+1
        sta ZV_A687+1
        pla
        sta ZV_A684
        rts

; ===========================================================================
; selplot: A = op lo, X = op hi (A5C4 / A634 encoding) -> plotv.  Y kept.
selplot:
        sty t2
        ldy #6
        cmp #$18
        beq :+
        ldy #2
        cpx #$A6
        beq :+
        ldy #4
        cpx #$AE
        beq :+
        ldy #0
:       lda ZV_A6D7
        beq :+
        tya
        ora #8
        tay
:       lda plottab,y
        sta plotv
        lda plottab+1,y
        sta plotv+1
        ldy t2
        rts

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

; store ptr / Y / msk as the current line position
stpos:  lda msk
        sta ZV_A684
        lda ptr+1
        sta ZV_A685+1
        lda ZV_A6D7
        bne :+
        sty ZV_A685
        rts
:       sty pcol
        lda ptr
        sta ZV_A685
        rts

; ===========================================================================
; SA55E relative line: dxv, dxv+1 = dx, dy sign-magnitude
line:   lda ZV_A684             ; current position -> ptr / Y / msk; moff
        sta msk
        lda ZV_A685+1
        sta ptr+1
        ldx #0
        lda ZV_A6D7
        bne :+
        stx ptr
        stx moff
        ldy ZV_A685
        jmp :++
:       lda ZV_A685
        sta ptr
        ldy pcol
        lda #8
        sta moff
:       sty ly
        lda ZV_A5C4             ; plot routine (cached: op + target)
        ldx ZV_A5C4+1
        cmp lk0
        bne :+
        cpx lk1
        bne :+
        ldy moff
        cpy lk2
        beq :++
:       sta lk0
        stx lk1
        ldy moff
        sty lk2
        jsr selplot
        lda plotv
        sta l_plt+1
        lda plotv+1
        sta l_plt+2
:        ldx moff                ; x: right / left
        lda dxv
        eor ZV_A693
        bpl :+
        and #$7F
        sta amag
        eor #$FF
        clc
        adc #1
        sta addv
        inx
        inx
        bne :++
:       sta amag
        sta addv
:       lda steptab,x
        sta svl
        lda steptab+1,x
        sta svh
        ldx moff                ; y: down / up
        lda dxv+1
        eor ZV_A693+1
        bpl :+
        and #$7F
        sta amag+1
        eor #$FF
        clc
        adc #1
        sta addv+1
        inx
        inx
        bne :++
:       sta amag+1
        sta addv+1
:       lda steptab+4,x
        sta svl+1
        lda steptab+5,x
        sta svh+1
        ldx #0                  ; x major if |dy| < |dx|
        ldy #1
        lda amag+1
        cmp amag
        bcc :+
        inx
        dey
:       lda svl,x
        sta l_mjr+1
        lda svh,x
        sta l_mjr+2
        lda amag,x
        sta major
        lda svl,y
        sta l_mnr+1
        lda svh,y
        sta l_mnr+2
        lda amag,y
        sta minor
        lda major
        sta cnt_l
        lsr
        sta err
        ldy ly
line__loop:
        lda err
        clc
        adc minor
        bcs line__take
        cmp major
        bcc line__no
line__take:
        sbc major
        sta err
l_mnr = *
        jsr $FFFF
        jmp line__maj
line__no:
        sta err
line__maj:
l_mjr = *
        jsr $FFFF
l_plt = *
        jsr $FFFF
        dec cnt_l
        bne line__loop
        jsr stpos
        ldx #1
:       lda ZV_A691,x
        clc
        adc addv,x
        sta ZV_A691,x
        dex
        bpl :-
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

; LA6B5 glyph A.  ROM font glyphs come from the HIRES charset at $9900
; (6-bit copy, shifted back left) except the few that use pixel columns 0/7
; (T_FEXC); custom font from T_AA2F.
gfx_glyph:
        sta gch
        lda ZV_A6D7             ; screen mode, y >= 176: text rows
        beq :+
        lda ZV_A691+1
        cmp #176
        bcc :+
        jmp gtext
:       lda gch
        ldx #$EA                ; nop: no shift
        ldy ZV_A6BC+1
        cpy #$3C
        bne g_cus
        cmp #32                 ; 32-83 (space, digits, A-S): never exceptions
        bcc :+
        cmp #84
        bcc g_rom
:       ldy #5
:       cmp T_FEXCC,y
        beq g_exc
        dey
        bpl :-
g_rom:  lda #<CHARSET
        ldy #>CHARSET
        ldx #$0A                ; asl: charset rows are pixel columns 1-6
        bne g_b
g_exc:  lda #<T_FEXC
        sta t0
        lda #>T_FEXC
        sta t1
        tya
        jmp g_b2
g_cus:  lda #<T_AA2F
        ldy #>T_AA2F
g_b:    sta t0
        sty t1
        lda gch
g_b2:   stx gal_sh
        stx gb_sh
        stx gs_sh
        sta fp                  ; fp = base + 8 * index
        lda #0
        sta fp+1
        asl fp
        rol fp+1
        asl fp
        rol fp+1
        asl fp
        rol fp+1
        lda fp
        clc
        adc t0
        sta fp
        lda fp+1
        adc t1
        sta fp+1
        lda ZV_A691
        clc
        adc #8
        sta ZV_A691
        ; glyph op: gopm 0 overwrite / 1 or / 2 xor
        lda ZV_A6E0
        ldx #0
        ldy #$24                ; bit zp: overwrite
        cmp #$B6
        bne :+
        inx
        ldy #$11                ; ora (zp),y
:       cmp #$AE
        bne :+
        ldx #2
        ldy #$51                ; eor (zp),y
:       stx gopm
        sty g_op
        lda #0
        sta gry
        lda ZV_A6D7
        beq :+
        jmp gscr
        ; ---- buffer: the original's byte writes
:       sta ptr
        lda ZV_A687+1
        sta ptr+1
        ldy ZV_A687
        inc ZV_A687
gb_row: sty t2
        ldy gry
        lda (fp),y
gb_sh = *
        asl
        ldy t2
        ldx ZV_A683
        bne gb_un
        jsr gb_op
        jmp gb_nx
gb_un:  jsr gsplit
        lda gv
        jsr gb_op
        iny                     ; (L only, like inc l)
        lda gl
        jsr gb_op
        dey
gb_nx:  tya
        clc
        adc #32
        tay
        bcc :+
        inc ptr+1
:       inc gry
        lda gry
        cmp #8
        bne gb_row
        rts
; gsplit: A = glyph row -> gv = A >> (x&7), gl = A << (8 - x&7)
gsplit: sta gv
        lda #0
        sta gl
        ldx ZV_A683
:       lsr gv
        ror gl
        dex
        bne :-
        rts
gb_op:
g_op = *
        ora (ptr),y
        sta (ptr),y
        rts

        ; ---- screen
gtext:  lda ZV_A691              ; status lines -> Oric text rows
        tax                     ; (docs/PORTING.md section 5)
        clc
        adc #8
        sta ZV_A691
        lda ZV_A691+1
        cmp #192
        bcs gscr_x
        cmp #184
        lda #<TEXTROW0
        ldy #>TEXTROW0
        bcc :+
        lda #<TEXTROW1
        ldy #>TEXTROW1
:       sta ptr
        sty ptr+1
        txa
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
gscr:
gscr_h: lda ZV_A687
        sta ptr
        lda ZV_A687+1
        sta ptr+1
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
        ldx ZV_A683
        beq gal
        ; unaligned: two Spectrum bytes per row (glyph >> bit, glyph << 8-bit)
gs_l:   ldy gry
        lda (fp),y
gs_sh = *
        asl
        jsr gsplit
        ldy gry
        lda gv
        sta gbufh,y
        lda gl
        sta gbufl,y
        inc gry
        lda gry
        cmp #8
        bne gs_l
        lda #$EA
        sta gal_sh
        lda ptr
        pha
        lda ptr+1
        pha
        lda #<gbufh
        sta fp
        lda #>gbufh
        sta fp+1
        jsr gal
        pla
        sta ptr+1
        pla
        sta ptr
        lda tcol
        sta t2
        lda tr
        sta t3
        lda #<gbufl
        sta fp
        lda #>gbufl
        sta fp+1
; gal: 8 aligned Spectrum bytes (rows of (fp)) at column t2, offset t3
; (0,2,4) on the screen, op gopm
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
        ldx #0                  ; X = row
gal_r:  txa
        tay
        lda (fp),y
gal_sh = *
        asl
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
:       inx
        cpx #8
        bne gal_r
        rts
galtab: .word gal_0, gal_2, gal_4
gnm0:   .byte $C0, 0, $F0, 0, $FC
gnm1:   .byte $CF, 0, $C3, 0, $C0
gm0:    .byte $FF
gm1:    .byte $FF


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
; attrtpl: A = Spectrum attribute -> kk (ink), pp (paper), c0v, c1v (0 =
; none), tmpl (pixel byte bits 7-6)
attrtpl:pha
        and #7
        tax
        lda zx2oric,x
        sta kk
        pla
        lsr
        lsr
        lsr
        and #7
        tax
        lda zx2oric,x
        sta pp
        ldx #0
        stx c1v
        ldx #$40
        stx tmpl
        lda kk
        bne :+
        lda #$97                ; K black: inverse video, paper 7-P
        sec
        sbc pp
        sta c0v
        lda #$C0
        sta tmpl
        rts
:       cmp #7
        beq :++
        ldx pp
        bne :+
        sta c0v                 ; black paper: column 0 = ink
        rts
:       sta c1v                 ; column 1 = ink
:       lda pp
        ora #$10
        sta c0v
        rts

; arng: A = attribute, X = first Oric line, Y = count; km = 0 (clear the
; pixels) or $3F (keep them, and keep attribute bytes)
gfx_arng = arng
gfx_km = km
arng:   sty t2
        stx t3
        jsr attrtpl
ar_l:   lda t3
        clc
        jsr lbase
        ldy #0
        lda c0v
        sta (ptr),y
        iny
        lda c1v
        bne ar_w
        bit km
        bvs ar_px
        lda tmpl                ; clear: plain fill
:       sta (ptr),y
        iny
        cpy #40
        bne :-
        beq ar_nl
ar_px:  lda (ptr),y
        bit km
        bvc ar_s                ; (clear)
        asl
        bmi :+
        cpy #1                  ; column 1 attribute -> empty pixels
        bne ar_n
        lda #0
:       lsr
ar_s:   and km
        ora tmpl
ar_w:   sta (ptr),y
ar_n:   iny
        cpy #40
        bne ar_px
ar_nl:  inc t3
        dec t2
        bne ar_l
        rts

; gfx_cls: whole screen to Spectrum attribute A (command 8F; also the
; border variable DA4C2 = (A>>3)&7).  Lines 0-3 and 196-199 black; the text
; rows ink K / paper P, blank.
gfx_cls:pha
        lsr
        lsr
        lsr
        jsr Z_A903
        lda #0
        sta km
        tax
        ldy #4
        jsr arng                ; lines 0-3 (attribute 0: black)
        lda #0
        ldx #196
        ldy #4
        jsr arng
        pla
        ldx #4
        ldy #192
        jsr arng
        jsr trclr
        lda pp
        ora #$10
        sta TEXTROW0+1
        sta TEXTROW0+41
        sta TEXTROW0+81
        lda kk
        sta TEXTROW0
        sta TEXTROW0+40
        sta TEXTROW0+80
        rts

; gfx_attr_rows: A = attribute, X = first char row, Y = number of rows.
; Rewrites columns 0/1 and bit 7 of the pixel bytes (pixels kept).
gfx_attr_rows:
        pha
        lda #$3F
        sta km
        txa
        asl
        asl
        asl
        adc #4
        tax
        tya
        asl
        asl
        asl
        tay
        pla
        jmp arng

; gfx_recolour: A = attribute, X = first char column, Y = last char column,
; gfx_rc_row / gfx_rc_n = Spectrum pixel rows.  Puts serial attributes just
; before (1-2 columns) and after (1-2 columns) the area, restoring the line's
; base colours (read from columns 0/1), and sets the inverse bit of the
; pixel bytes inside.  Each attribute column blanks 6 pixels.
gfx_recolour:
        pha
        tya
        asl
        asl
        asl
        ora #7
        jsr xcr
        sta rc_ce
        txa
        asl
        asl
        asl
        jsr xcr
        sta rc_cs
        pla
        jsr attrtpl
        ldx #0                  ; area: inverse (black ink) or ink K
        lda kk
        bne :+
        lda #7
        sec
        sbc pp
        sta rc_pa
        lda #7
        ldx #$80
        bne :++
:       ldy pp
        sty rc_pa
:       sta rc_ia
        stx rc_va
        lda gfx_rc_row
        sta t2
        lda gfx_rc_n
        sta gry
rc_ln:  lda t2
        jsr gfx_linebase
        ldy #0                  ; base colours of the line
        lda (ptr),y
        tax
        and #$80
        sta rc_vb
        txa
        and #7
        sta rc_ib
        ldy #0
        sty rc_pb
        txa
        and #$10
        beq rc_b                ; column 0 = ink: paper black
        stx rc_pb               ; (bits 3-7 masked below)
        lda #7
        sta rc_ib
        lda rc_vb
        bne rc_b
        iny
        lda (ptr),y
        cmp #8
        bcs rc_b
        sta rc_ib
rc_b:   lda rc_pb
        and #7
        sta rc_pb
        lda rc_ia
        cmp rc_ib
        beq :+
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
:       lda rc_pa
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
:       cpy #40
        bcs :++
        lda (ptr),y
        asl
        bpl :+
        lsr
        ora rc_va
        sta (ptr),y
:       cpy rc_ce
        iny
        bcc :--
:       inc t2
        dec gry
        beq :+
        jmp rc_ln
:       rts
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

; gfx_textinit: text rows: ink yellow / green, blank.  (The ROM font is
; loaded with the program into the HIRES charset: segment CHARSET, chars
; 32-127 at $9900, pixel columns 1-6.)
gfx_textinit:
        jsr trclr
        lda #3
        sta TEXTROW0
        lda #2
        sta TEXTROW1
        rts
trclr:  ldx #118                ; ($BFDF, the last byte, is the video mode)
        lda #$20
:       sta TEXTROW0,x
        dex
        bpl :-
        rts

; gfx_lz: unpack the LZ data at (lzs) to (lzd) (tools/gen_gfx.py lz2:
; 00llllll literals, 01llllll d8 short copy, 1lllllll d16 copy, 0 end)
gfx_lz: ldy #0
lz_t:   jsr lz_g
        beq lz_r
        cmp #$40
        bcs lz_m
        tax                     ; literals
:       jsr lz_g
        jsr lz_p
        dex
        bne :-
        beq lz_t
lz_m:   cmp #$80
        bcs :+
        and #$3F                ; short: length l+2, distance d8+1
        adc #2
        tax
        jsr lz_g
        clc
        eor #$FF                ; lzc = lzd - d8 - 1
        adc lzd
        sta lzc
        lda lzd+1
        sbc #0
        bcs lz_c
:       and #$7F                ; long: length l+3, distance d16
        adc #2                  ; (C=1)
        tax
        jsr lz_g
        sta t0
        jsr lz_g
        sta t1
        lda lzd
        sec
        sbc t0
        sta lzc
        lda lzd+1
        sbc t1
lz_c:   sta lzc+1
:       lda (lzc),y
        jsr lz_p
        inc lzc
        bne :+
        inc lzc+1
:       dex
        bne :--
        beq lz_t
lz_g:   lda (lzs),y
        inc lzs
        bne lz_r
        inc lzs+1
lz_r:   ora #0
        rts
lz_p:   sta (lzd),y
        inc lzd
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
        beq :+
        ldy #SND_TAPEERR
        cmp #$F0
        beq :+
        ldy #SND_TICK
:       tya
        jmp snd_fx
; A977: inline N, K, K x (C, B).  A97C: inline K, K x (C, B), N = $20.
; N=6: engine blip (C), N=4: penalty chirp, K=3: key blip, else beep.
        ZPROC $A977
        pla
        sta strm
        pla
        sta strm+1
        jsr getb                ; (skip)
        jsr getb                ; N
        jmp :+
        ZPROC $A97C
        pla
        sta strm
        pla
        sta strm+1
        jsr getb                ; (skip)
        lda #$20
:       sta ZV_A969
        jsr getb                ; K
        sta t2
        asl
        tax
        jsr getb                ; first C
        sta t3
:       dex                     ; skip the other 2K-1 bytes
        beq :+
        jsr getb
        jmp :-
:       ldx t3
        lda ZV_A969
        ldy #SND_REV
        cmp #6
        beq :+
        ldy #SND_CHIRP
        cmp #4
        beq :+
        ldy #SND_KEYBLIP
        lda t2
        cmp #3
        beq :+
        ldy #SND_BEEP
:       tya
        jsr snd_fx
        jmp (strm)

; ===========================================================================
; SA721 flood fill (always OR) from ptr / Y / msk, both targets.
; Same result as the original's scanline fill: the 4-connected clear region
; (with its "seed on a set pixel fills the run to its left" quirk), with the
; original's whole-byte shortcuts (8-pixel bytes in buffer mode, 6-pixel
; bytes on the screen).  Buffer mode: no edges, L wraps inside its page
; like the original.  Screen mode: attribute bytes, columns 0 and >= 40 are
; boundaries and rows outside HIRES lines 4-179 are not entered.
FS_TOP = $A000 + 4*40
FS_BOT = $A000 + 180*40
fill:   ldx #0                  ; patch the per-target constants
        lda ZV_A6D7
        beq :+
        ldx #1
        cpy #40                 ; screen: seed must be in a pixel byte
        bcs fs_ret
        lda (ptr),y
        and #$40
        beq fs_ret
:       lda fk_scr,x
        sta fscr
        lda fk_lim,x
        sta fp_lim+1
        lda fk_top,x
        sta fp_top1+1
        sta fp_top2+1
        lda fk_full,x
        sta fp_full+1
        sta fp_fcmp+1
        lda fk_w,x
        sta fp_w1+1
        sta fp_w3+1
        lda fk_w1,x
        sta fp_w2+1
        lda fk_fbl,x
        sta fbj0+1
        sta fbj1+1
        sta fbj2+1
        lda fk_fbh,x
        sta fbj0+2
        sta fbj1+2
        sta fbj2+2
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
        bcs fs_lc               ; (buffer: $80 shifted out)
        lda msk
fp_lim: cmp #$40                ; (screen: $20 shifted to $40)
        bcc fs_lt
fs_lc:  lda #1
        sta msk
fs_lb:  dey
fbj0 = *
        jsr fbyte_s
        bcs fs_lstop
        beq fs_lb               ; empty byte: skip it
        and msk
        bne fs_lstop
        beq fs_l
fs_lt:  lda (ptr),y
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
fp_top1:lda #$20
        sta msk
fs_rb:  iny
fbj1 = *
        jsr fbyte_s
        bcs fs_rend
        bne fs_rt
        lda (ptr),y             ; empty byte: fill it whole
fp_full:ora #$3F
        sta (ptr),y
        lda fcnt
        clc
fp_w1:  adc #6
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
:       jsr frest               ; ---- row below
        bit fscr
        bmi fs_dn
        tya
        clc
        adc #32
        tay
        bcc fs_dsc
        inc ptr+1
        bcs fs_dsc
fs_dn:  lda ptr
        clc
        adc #40
        sta ptr
        bcc :+
        inc ptr+1
:       lda ptr+1
        cmp #>FS_BOT
        bcc fs_dsc
        bne fs_up
        lda ptr
        cmp #<FS_BOT
        bcs fs_up
fs_dsc: jsr fs_scan
fs_up:  jsr frest               ; ---- row above
        bit fscr
        bmi fs_us
        tya
        sec
        sbc #32
        tay
        bcs fs_usc
        dec ptr+1
        bcc fs_usc
fs_us:  lda ptr
        sec
        sbc #40
        sta ptr
        bcs :+
        dec ptr+1
:       lda ptr+1
        cmp #>FS_TOP
        bcc fs_nx
        bne fs_usc
        lda ptr
        cmp #<FS_TOP
        bcc fs_nx
fs_usc: jsr fs_scan
fs_nx:  jmp fs_pop

frest:  lda fl_p
        sta ptr
        lda fl_p+1
        sta ptr+1
        ldy fl_y
        lda fl_m
        sta msk
        rts

; fbyte: the byte at Y after a byte step: C=1 boundary (screen: column
; >= 40 or attribute), else A = its pixel bits, Z = empty
fbyte_b:lda (ptr),y
        clc
        rts
fbyte_s:cpy #40
        bcs fb_r
        lda (ptr),y
        asl
        bpl fb_b
        lsr
        and #$3F
        clc
fb_r:   rts
fb_b:   sec
        rts

; SA787: scan fcnt pixels right of the span start on this row, push the
; first clear pixel of every run
fs_scan:lda fcnt
        sta fb
        lda #1
        sta fd
        bit fscr                ; screen: the start byte of this row may be
        bpl fsc_l               ; an attribute: its pixels count as set
        cpy #40
        bcs fsc_ret
        lda (ptr),y
        and #$40
        bne fsc_l
:       lda msk
        lsr
        beq fsc_nb
        sta msk
        dec fb
        bne :-
        rts
fsc_nb: lda #$20
        sta msk
        bne fsc_b
fsc_l:  lsr msk
        bne fsc_t
fp_top2:lda #$20
        sta msk
fsc_b:  iny
fbj2 = *
        jsr fbyte_s
        bcs fsc_bound           ; boundary byte: all "set"
        beq fsc_e
fp_fcmp:cmp #$3F
        bne fsc_t
        lda fd                  ; full byte after a set pixel: skip
        beq fsc_t
        bne fsc_skip
fsc_e:  lda fd                  ; empty byte after a clear pixel: skip
        bne fsc_t
fsc_skip:
        lda fb
fp_w2:  cmp #7
        bcc fsc_ret
fp_w3:  sbc #6
        sta fb
        jmp fsc_b
fsc_bound:                      ; (screen only)
        lda #1
        sta fd
        bne fsc_skip
fsc_t:  lda (ptr),y
        and msk
        beq fsc_clr
        lda #1
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
fk_scr: .byte 0, $80
fk_fbl: .byte <fbyte_b, <fbyte_s
fk_fbh: .byte >fbyte_b, >fbyte_s
fk_lim: .byte $FF, $40
fk_top: .byte $80, $20
fk_full:.byte $FF, $3F
fk_w:   .byte 8, 6
fk_w1:  .byte 9, 7
