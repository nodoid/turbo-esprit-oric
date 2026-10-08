; mapview.s - the map screen (key M): Spectrum E0AA-E440.
;
; SE0AA (M key), SE0C0 (toggle), SE0F1/SE0F2 (view clear colour / wheel cell
; colours, also used by the life-start flash) and SE0FF, which draws the
; street map with its labels and the vehicle markers into the Spectrum-format
; buffer at $6400 (and the green paper block in the colour buffer $7040).
; The view copy S862E (view.s) shows it.  Variables D71D0-D71DD are the
; original's (identity range), see notes R8 4.2.
;
; The pixel address helper SA638 (buffer mode, selected by SA8BF just
; before) is inlined: HL = $6400 + 32*y + x/8, shift = x & 7.  The street
; type lookups S952F drop the "index >= 32" case, which cannot happen here
; (the window origin is clamped to 0..18 / 0..25).  Vehicle records are read
; through mission.s's work record CR (SE3EA).

        .include "zx.inc"

        ZIMPORT $F37A           ; key test (hw.s)
        ZIMPORT $98F4           ; two-key test -> D
        ZIMPORT $9564           ; blocked-exit mask
        ZIMPORT $A80F           ; gfx: OR mode
        ZIMPORT $A8BF           ; gfx: draw into the buffer
        ZIMPORT $A8D3           ; gfx: custom font
        ZIMPORT $A8DB           ; gfx: ROM font
        ZIMPORT $A526           ; gfx: set cursor BC = (x,y)
        ZIMPORT $A695           ; gfx: print glyph A
        ZIMPORT $A911           ; gfx: print number HL (A = skip, E = flags)
        ZIMPORT $F9F2           ; delay
        ZIMPORT $DA80           ; mission: IY = object of car IX
        ZIMPORT $DC5F           ; mission: object IY -> map record IX (and CR)
        ZVIMPORT $9282          ; city block
        ZVIMPORT $8699          ; view: colour the attribute buffer is reset to
        ZVIMPORT $86D3          ; view: 6 wheel cell colours
        .importzp CR            ; mission.s work record
        .import getix, ixg, cartab

T_9382  = ZV_9282 + $100
T_93A2  = ZV_9282 + $120
M       = CR                    ; D71D0-D71DD while drawing (mission.s zero page)

        .zeropage
rowp:   .res 2                  ; buffer address of the current cell (Z80 stack)
wp:     .res 2

; scratch: mission.s zero page that is free while the map is drawn (none of
; these lives across a call into mission.s)
        .importzp lb, lc, ld_, le_, lpos, lt, ll, ldir, rnp, rdist, rcame, rd
mt      = lb
kas     = lc
ncol    = ld_
gly     = le_
offl    = lpos
offh    = lt
mpos    = ll
lval    = ldir
lcoord  = rnp
lflag   = rdist
mk      = rcame                 ; (these two live across calls of DC5F/DA80,
mgly    = rd                    ;  which do not use them)

        .data
        ZLABEL $E3B9, 1         ; label letter 'N' / 'E' (SMC operand)
        .byte $4E

        .rodata
; junction landmark 0x21 offsets: N-S case (x^y bit2 set / clear), E-W case
owgg:   .byte $1C, $1A
owgl:   .byte $FD, $05
owgh:   .byte $F4, $FC
joffl:  .byte $FC, $03, $FF, $FF
joffh:  .byte $FA, $FA, $F6, $FE
; frame clearing: address, rows, width, value
ftlo:   .byte <$6426, <$6F46, <$6425, <$643A, <$7066
fthi:   .byte >$6426, >$6F46, >$6425, >$643A, >$7066
ftn:    .byte 8, 8, 96, 96, 10
ftw:    .byte 20, 20, 1, 1, 20
ftv:    .byte 0, 0, 0, 0, $20

        .code

; key entry $75xx (A = low byte) -> zl/zh
setkp:  sta zl
        lda #$75
        sta zh
        rts

; ---------------------------------------------------------------------------
; SE0AA: M key handler (every main-loop pass)
        ZPROC $E0AA
        lda #<$7533
        jsr setkp
        jsr Z_F37A
        php
        lda $7610
        plp
        bne @up
        tax
        and #$02
        bne @rts
        txa
        ora #$02
        bne Z_E0C0              ; (always)
@up:    and #$FD
        sta $7610
@rts:   rts
; SE0C0: A = D7610: toggle the map
        ZPROC $E0C0
        eor #$01
        sta $7610
        lsr a
        lda #$38
        bcc @set
        lda $7504
        sbc #8                  ; (C set)
        sta $71D0
        lda $7505
        sec
        sbc #3
        sta $71D1
        lda #$30
@set:   jsr Z_E0F1
        jsr ixg
        lda #$04
        bit $760E
        bne @rts
        ora $760E
        sta $760E
        lda #1
        sta $760F
@rts:   rts

; SE0F1 (A) / SE0F2 (A, C): view clear colour = A, wheel cell colours = C
        ZPROC $E0F1
        sta zc
        ZPROC $E0F2
        sta ZV_8699
        lda zc
        ldx #5
@l:     sta ZV_86D3,x
        dex
        bpl @l
        rts

; ---------------------------------------------------------------------------
; SE0FF: draw the map (one call per main-loop pass while it is shown)
        ZPROC $E0FF
        jsr Z_A80F
        jsr Z_A8BF
        jsr Z_A8D3
        lda #<$752D             ; A/S scroll north/south
        jsr setkp
        jsr Z_98F4
        lda zd
        sta kas
        lda #<$7524             ; J/L scroll east/west
        jsr setkp
        jsr Z_98F4
        ldx $71D0
        lda zd
        jsr scroll
        stx mt
        ldx $71D1
        lda kas
        jsr scroll
        txa
        ldx #$1A
        jsr se3cf
        sta M+1
        sta M+3
        lda mt
        ldx #$13
        jsr se3cf
        sta M+0
        sta M+2
        lda #$2C
        ; --- one column of cells
@col:   sta M+4
        lda #$5A
        sta M+5
        ldy M+2
        lda T_9382,y
        sta M+6
        ldx #$E0
        tay
        beq @p
        ldx #$C0
        and #$02
        beq @p
        ldx #$80
@p:     stx M+8
        lda #0
        sta M+9
        sta M+12
        lda #$FF
        sta M+10
        lda #$F8
        sta M+11
        lda #$6F                ; SA638 (buffer): $6400 + 32*$5A + x/8
        sta rowp+1
        lda M+4
        lsr a
        lsr a
        lsr a
        ora #$40
        sta rowp
        lda M+4
        and #7
        beq @row
        tax
@sh:    lsr M+8
        ror M+9
        ror M+10
        ror M+11
        ror M+12
        dex
        bne @sh
        ; --- one cell
@row:   lda M+2
        sta zl
        lda M+3
        sta zh
        jsr Z_9564
        lda ze
        sta M+13
        ldy M+3
        lda T_93A2,y
        sta M+7
        lda M+13
        lsr a
        bcs @e1d1               ; east blocked
        lda M+7
        bpl @th
        lda #2
@th:    eor #3                  ; (3 - type) & 3
        and #3
        tax
        lda #M+10
        ldy #3
        jsr se359
        ldx #1                  ; row one-way arrow
        jsr owg
@e1d1:  lda M+13
        and #$02
        bne @e1f3               ; north blocked
        lda #M+8
        ldx #12
        ldy #2
        jsr se359
        ldx #0                  ; column one-way arrow
        jsr owg
@e1f3:  lda M+13
        bne @e219
        lda M+6
        clc
        adc M+7
        cmp #2
        bcs @e260
        ldx #$1E
        tay
        beq @g
        inx
        lda M+7
        lsr a
        bcc @g
        inx
@g:     txa
        ldx #$FE
        ldy #$FB
        jsr se33d
        jmp @e260
@e219:  ldx #0                  ; 5: N-S only, 10: E-W only
        cmp #5
        beq @j
        inx
        cmp #$0A
        bne @e260
@j:     lda M+6,x
        cmp #1
        bne @e260
        txa
        eor #1
        tay
        lda M+6,y
        and #$02
        beq @e260
        txa
        asl a
        tay
        lda M+2
        eor M+3
        and #$04
        bne @k
        iny
@k:     ldx joffl,y
        lda joffh,y
        tay
        lda #$21
        jsr se33d
@e260:  inc M+3
        lda rowp
        sec
        sbc #$80
        sta rowp
        lda rowp+1
        sbc #$01
        sta rowp+1
        lda M+5
        sec
        sbc #$0C
        bcc @e278
        sta M+5
        cmp #8
        bcc @e278
        jmp @row
@e278:  lda M+1
        sta M+3
        inc M+2
        lda M+4
        clc
        adc #$0C
        cmp #$D2
        bcs @markers
        jmp @col
        ; --- vehicle markers (every other pass)
@markers:
        ldx #13                 ; D71D0-D71DD back to memory
@fl:    lda M,x
        sta $71D0,x
        dex
        bpl @fl
        ldx #$D0
        jsr setix71
        lda $75F8
        lsr a
        bcs @e2ca
        lda #$92
        sta ziyl
        lda #$77
        sta ziyh
        lda #$17
        sta mgly
        jsr se3d8
        ldx #0
@mc:    stx mk
        lda cartab,x
        sta zixl
        lda #$78
        sta zixh
        jsr getix
        lda CR
        bmi @mn
        ldx #$22
        stx mgly
        and #$04
        beq @me
        jsr Z_DA80
        jsr se3d8
        jmp @mn
@me:    jsr se3ea
@mn:    ldx mk
        inx
        cpx #3
        bne @mc
        lda #$7C                ; IX as the original leaves it
        sta zixl
        lda #$78
        sta zixh
@e2ca:  jsr Z_F9F2
        ; --- frame: clear rows 1-8 and 90-97, columns 5 and 26, green paper
        ldx #4
@fc:    lda ftlo,x
        sta wp
        lda fthi,x
        sta wp+1
        lda ftw,x
        sta ncol
        lda ftn,x
        sta mk
        lda ftv,x
@fr:    ldy ncol
        dey
@fb:    sta (wp),y
        dey
        bpl @fb
        tay
        lda wp
        clc
        adc #32
        sta wp
        bcc @fn
        inc wp+1
@fn:    tya
        dec mk
        bne @fr
        dex
        bpl @fc
        jsr Z_A8DB
        ; --- labels "N<x>" top and bottom
        lda $71D0
        jsr se38e
        clc
        adc #$24
        sta lcoord
@e2fb:  lda #$01
        jsr se3a4
        lda #$5A
        jsr se3a4
        jsr lv5
        ldx lcoord
        txa
        clc
        adc #$3C
        sta lcoord
        cpx #$8C
        bcc @e2fb
        ; --- labels "E<y>" left and right
        lda $71D1
        jsr se38e
        eor #$FF
        sec
        adc #$56
        sta lcoord
@e31e:  lda #$10
        jsr se3ca
        lda #$D8
        jsr se3ca
        jsr lv5
        lda lcoord
        sec
        sbc #$3C
        bcc @rts
        sta lcoord
        cmp #5
        bcs @e31e
@rts:   rts

setix71:
        stx zixl
        lda #$71
        sta zixh
        rts

lv5:    lda lval
        clc
        adc #5
        sta lval
        rts

; J/L or A/S code A (S98F4: 3 = first key, 1 = second key) -> X +1 / -1
scroll: lsr a
        bcc @r
        lsr a
        bcc @d
        inx
        inx
@d:     dex
@r:     rts

; SE3CF: clamp A to 0..X-1 (A >= $80 -> 0)
se3cf:  stx ncol
        cmp ncol
        bcc @r
        tay
        bmi @z
        dex                     ; ;?
        txa
        rts
@z:     lda #0
@r:     rts

; one-way arrow (X = 0: column type D71D6, glyph 1C/1D at (-3,-12);
; X = 1: row type D71D7, glyph 1A/1B at (+5,-4)); +1 if the type has bit2
owg:    lda M+6,x
        bpl @r
        and #$04
        cmp #$01
        lda owgg,x
        adc #0
        ldy owgh,x
        pha
        lda owgl,x
        tax
        pla
        jmp se33d
@r:     rts

; SE359: OR X rows of Y bytes from the pattern at ($71xx, low byte A) into
; the buffer at rowp, going up one row (-32) each time
se359:  sta pat
        sty ncol
        lda rowp
        sta wp
        lda rowp+1
        sta wp+1
s359r:  ldy #0
s359c:  lda a:$0000,y
pat = * - 2
        ora (wp),y
        sta (wp),y
        iny
        cpy ncol
        bne s359c
        lda wp
        sec
        sbc #32
        sta wp
        bcs s359n
        dec wp+1
s359n:  dex
        bne s359r
        rts

; SE33D: glyph A at the current cell position (D71D4,D71D5) + (X,Y),
; clipped to the map window
se33d:  stx offl
        sty offh
        ldx M+4
        ldy M+5
; LE341: glyph A at (X + offl, Y + offh)
le341:  sta gly
        txa
        clc
        adc offl
        cmp #$28
        bcc @r
        cmp #$D2
        bcs @r
        sta zc
        tya
        clc
        adc offh
        bmi @r
        cmp #$5A
        bcs @r
        sta zb
        jsr Z_A526
        lda gly
        jmp Z_A695
@r:     rts

; SE38E: A = origin -> lval = first multiple of 5 above it, A = 12*(lval-origin)
se38e:  sta mt
        tax
        bpl @l
        sec                     ; ;?
        sbc #1
@l:     sec
        sbc #5
        bcs @l
        eor #$FF
        clc
        adc #1
        tax
        clc
        adc mt
        sta lval
        txa
; SE43B: A = 12*A
se43b:  asl a
        asl a
        sta mt
        asl a
        clc
        adc mt
        rts

; SE3A4: "N<lval>" at (lcoord, A)   SE3CA: "E<lval>" at (A, lcoord)
se3a4:  sta zb
        lda lcoord
        sta zc
        lda #$C0
        ldx #$4E
        bne le3a9
se3ca:  sta zc
        lda lcoord
        sta zb
        lda #$A0
        ldx #$45
le3a9:  stx ZV_E3B9
        sta lflag
        lda lval
        beq @r
        cmp #$20
        bcs @r
        jsr Z_A526
        lda ZV_E3B9
        jsr Z_A695
        lda lflag
        sta ze
        lda lval
        sta zl
        lda #0
        sta zh
        lda #$12
        jmp Z_A911
@r:     rts

; SE3D8: marker for the 3D object IY (glyph mgly) if it is active
se3d8:  ldy #1
        lda (ziyl),y
        bmi :+
        rts
:
        ldx #$DE
        jsr setix71
        jsr Z_DC5F              ; record -> D71DE and CR
        ldx #$DE
        jsr setix71
; SE3EA: marker for the map record in CR (glyph mgly)
se3ea:  ldx CR+1
        ldy CR+2
        lda CR+5
        sta mpos
        lda CR
        and #$02
        beq @e403
        ldx CR+3                ; heading S/W: measure from the to-junction
        ldy CR+4
        lda #$64
        sec
        sbc mpos
        sta mpos
@e403:  txa
        sec
        sbc $71D0
        bcc @r
        cmp #14
        bcs @r
        jsr se43b
        sta offl
        tya
        sec
        sbc $71D1
        bcc @r
        cmp #7
        bcs @r
        jsr se43b
        eor #$FF
        clc
        adc #1
        sta offh
        ldx #$FF                ; pos div 9
        lda mpos
        sec
@d:     inx
        sbc #9
        bcs @d
        lda CR
        lsr a
        txa
        bcc @ns
        clc
        adc offl
        sta offl
        bcc @pr                 ; (always)
@ns:    eor #$FF
        sec
        adc offh
        sta offh
@pr:    ldx #$29
        ldy #$56
        lda mgly
        jmp le341
@r:     rts
