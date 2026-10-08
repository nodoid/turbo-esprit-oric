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
; before) is inlined: HL = $6400 + 32*y + x/8, shift = x & 7.

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
        ZIMPORT $DC5F           ; mission: object IY -> map record IX
        ZVIMPORT $9282          ; city block
        ZVIMPORT $8699          ; view: colour the attribute buffer is reset to
        ZVIMPORT $86D3          ; view: 6 wheel cell colours

T_9382  = ZV_9282 + $100
T_93A2  = ZV_9282 + $120

.macro IX_GLOBAL
        lda #$E1
        sta zixl
        lda #$75
        sta zixh
.endmacro

        .zeropage
rowp:   .res 2                  ; buffer address of the current cell (Z80 stack)
wp:     .res 2
rec:    .res 2                  ; IX in SE3EA

        .data
mt:     .res 1
kas:    .res 1
ncol:   .res 1
gly:    .res 1
offl:   .res 1                  ; glyph offset (L,H) / position
offh:   .res 1
bsx:    .res 1                  ; base position (C,B)
bsy:    .res 1
mpos:   .res 1
mcx:    .res 1
mcy:    .res 1
mgly:   .res 1                  ; D (marker glyph)
lval:   .res 1                  ; D (label value)
lcoord: .res 1                  ; E (label coordinate)
lflag:  .res 1                  ; L (number print flags)
mk:     .res 1

        .data
        ZLABEL $E3B9, 1         ; label letter 'N' / 'E' (SMC operand)
        .byte $4E

        .code

; ---------------------------------------------------------------------------
; SE0AA: M key handler (every main-loop pass)
        ZPROC $E0AA
        lda #<$7533
        sta zl
        lda #>$7533
        sta zh
        jsr Z_F37A
        beq @down
        lda $7610
        and #$FD
        sta $7610
        rts
@down:  lda $7610
        tax
        and #$02
        beq :+
        rts
:
        txa
        ora #$02
; SE0C0: A = D7610: toggle the map
        ZPROC $E0C0
        eor #$01
        sta $7610
        lsr a
        bcs @on
        lda #$38
        bne @set
@on:    lda $7504
        sec
        sbc #8
        sta $71D0
        lda $7505
        sec
        sbc #3
        sta $71D1
        lda #$30
@set:   jsr Z_E0F1
        IX_GLOBAL
        lda $760E
        and #$04
        bne @rts
        lda $760E
        ora #$04
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
        sta zl
        lda #>$752D
        sta zh
        jsr Z_98F4
        lda zd
        sta kas
        lda #<$7524             ; J/L scroll east/west
        sta zl
        lda #>$7524
        sta zh
        jsr Z_98F4
        ldx $71D0
        lda zd
        lsr a
        bcc @nx
        lsr a
        bcc @dl
        inx
        inx
@dl:    dex
@nx:    stx mt
        ldy $71D1
        lda kas
        lsr a
        bcc @ny
        lsr a
        bcc @dh
        iny
        iny
@dh:    dey
@ny:    tya
        ldx #$1A
        jsr se3cf
        sta $71D1
        sta $71D3
        lda mt
        ldx #$13
        jsr se3cf
        sta $71D0
        sta $71D2
        lda #$2C
        sta $71D4
        lda #$5A
        sta $71D5
        ; --- one column of cells
@col:   ldy $71D2
        lda #0
        cpy #$20
        bcs @t0
        lda T_9382,y
@t0:    sta $71D6
        ldx #$E0
        tay
        beq @p
        ldx #$C0
        and #$02
        beq @p
        ldx #$80
@p:     stx $71D8
        lda #0
        sta $71D9
        sta $71DC
        lda #$FF
        sta $71DA
        lda #$F8
        sta $71DB
        lda $71D5               ; SA638 (buffer)
        tax
        lsr a
        lsr a
        lsr a
        clc
        adc #$64
        sta rowp+1
        txa
        asl a
        asl a
        asl a
        asl a
        asl a
        sta rowp
        lda $71D4
        lsr a
        lsr a
        lsr a
        ora rowp
        sta rowp
        lda $71D4
        and #7
        beq @row
        tax
@sh:    lsr $71D8
        ror $71D9
        ror $71DA
        ror $71DB
        ror $71DC
        dex
        bne @sh
        ; --- one cell
@row:   lda $71D2
        sta zl
        lda $71D3
        sta zh
        jsr Z_9564
        lda ze
        sta $71DD
        ldy $71D3
        lda #0
        cpy #$20
        bcs @t1
        lda T_93A2,y
@t1:    sta $71D7
        lda $71DD
        lsr a
        bcs @e1d1               ; east blocked
        lda $71D7
        bpl @th
        lda #2
@th:    eor #$FF
        sec
        adc #3
        and #3
        tax
        lda #<$71DA
        ldy #3
        jsr se359
        lda $71D7
        bpl @e1d1
        and #$04
        cmp #$01                ; C = bit2
        lda #$1A
        adc #0
        ldx #$05
        ldy #$FC
        jsr se33d
@e1d1:  lda $71DD
        and #$02
        bne @e1f3               ; north blocked
        lda #<$71D8
        ldx #12
        ldy #2
        jsr se359
        lda $71D6
        bpl @e1f3
        and #$04
        cmp #$01
        lda #$1C
        adc #0
        ldx #$FD
        ldy #$F4
        jsr se33d
@e1f3:  lda $71DD
        bne @e219
        lda $71D6
        clc
        adc $71D7
        cmp #2
        bcs @e260
        ldx #$1E
        tay
        beq @g
        inx
        lda $71D7
        lsr a
        bcc @g
        inx
@g:     txa
        ldx #$FE
        ldy #$FB
        jsr se33d
        jmp @e260
@e219:  cmp #5
        bne @e23b
        lda $71D6
        cmp #1
        bne @e260
        lda $71D7
        and #$02
        beq @e260
        ldx #$FC
        ldy #$FA
        lda $71D2
        eor $71D3
        and #$04
        bne @e25b
        ldx #$03
        bne @e25b
@e23b:  cmp #$0A
        bne @e260
        lda $71D7
        cmp #1
        bne @e260
        lda $71D6
        and #$02
        beq @e260
        ldx #$FF
        ldy #$F6
        lda $71D2
        eor $71D3
        and #$04
        bne @e25b
        ldy #$FE
@e25b:  lda #$21
        jsr se33d
@e260:  inc $71D3
        lda rowp
        sec
        sbc #$80
        sta rowp
        lda rowp+1
        sbc #$01
        sta rowp+1
        lda $71D5
        sec
        sbc #$0C
        bcc @e278
        sta $71D5
        cmp #8
        bcc @e278
        jmp @row
@e278:  lda $71D1
        sta $71D3
        inc $71D2
        lda $71D4
        clc
        adc #$0C
        cmp #$D2
        bcs @markers
        sta $71D4
        lda #$5A
        sta $71D5
        jmp @col
        ; --- vehicle markers (every other pass)
@markers:
        lda #<$71D0
        sta zixl
        lda #>$71D0
        sta zixh
        lda $75F8
        lsr a
        bcs @e2ca
        lda #<$7792
        sta ziyl
        lda #>$7792
        sta ziyh
        lda #$17
        sta mgly
        jsr se3d8
        lda #0
        sta mk
@mc:    ldx mk
        lda cartab,x
        sta rec
        lda #$78
        sta rec+1
        ldy #0
        lda (rec),y
        bmi @mn
        ldx #$22
        stx mgly
        and #$04
        beq @me
        lda rec
        sta zixl
        lda rec+1
        sta zixh
        jsr Z_DA80
        jsr se3d8
        jmp @mn
@me:    jsr se3ea
@mn:    inc mk
        lda mk
        cmp #3
        bne @mc
        lda #<$787C             ; IX as the original leaves it
        sta zixl
        lda #>$787C
        sta zixh
@e2ca:  jsr Z_F9F2
        ; --- frame: clear rows 1-8 and 90-97, columns 5 and 26
        lda #<$6426
        ldy #>$6426
        ldx #8
        jsr clr0
        lda #<$6F46
        ldy #>$6F46
        ldx #8
        jsr clr0
        lda #<$6425
        jsr clrcol
        lda #<$643A
        jsr clrcol
        lda #<$7066             ; green paper behind the map
        sta wp
        lda #>$7066
        sta wp+1
        ldx #10
        lda #$20
        jsr fill20
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
        lda lval
        clc
        adc #5
        sta lval
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
        lda lval
        clc
        adc #5
        sta lval
        lda lcoord
        sec
        sbc #$3C
        bcc @rts
        sta lcoord
        cmp #5
        bcs @e31e
@rts:   rts

cartab: .byte $5E, $68, $72

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

; SE359: OR X rows of Y bytes from the pattern at ($71xx, low byte A) into
; the buffer at rowp, going up one row (-32) each time
se359:  sta pat
        sty ncol
        lda rowp
        sta wp
        lda rowp+1
        sta wp+1
s359r:  ldy #0
s359c:  lda $7100,y
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
        ldx $71D4
        stx bsx
        ldx $71D5
        stx bsy
; LE341: glyph A at (bsx + offl, bsy + offh)
le341:  sta gly
        lda offl
        clc
        adc bsx
        cmp #$28
        bcc @r
        cmp #$D2
        bcs @r
        sta zc
        lda offh
        clc
        adc bsy
        bmi @r
        cmp #$5A
        bcs @r
        sta zb
        jsr Z_A526
        lda gly
        jmp Z_A695
@r:     rts

; SE36E-like: clear X rows of 20 bytes (stride 32) from (A,Y)
clr0:   sta wp
        sty wp+1
        lda #0
; fill X rows of 20 bytes at wp with A (SE371)
fill20: sta mt
@r:     ldy #19
        lda mt
@c:     sta (wp),y
        dey
        bpl @c
        lda wp
        clc
        adc #32
        sta wp
        bcc @n
        inc wp+1
@n:     dex
        bne @r
        rts

; SE383: clear 96 bytes down the column $64xx (A = low byte)
clrcol: sta wp
        lda #$64
        sta wp+1
        ldx #96
        ldy #0
@l:     tya
        sta (wp),y
        lda wp
        clc
        adc #32
        sta wp
        bcc @n
        inc wp+1
@n:     dex
        bne @l
        rts

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
        sta lflag
        lda #$4E
        bne le3a9
se3ca:  sta zc
        lda lcoord
        sta zb
        lda #$A0
        sta lflag
        lda #$45
le3a9:  sta ZV_E3B9
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
        bpl @r
        lda #<$71DE
        sta zixl
        sta rec
        lda #>$71DE
        sta zixh
        sta rec+1
        jsr Z_DC5F
        lda #<$71DE
        sta zixl
        lda #>$71DE
        sta zixh
        jmp se3ea
@r:     rts

; SE3EA: marker for the map record rec (glyph mgly)
se3ea:  ldy #5
        lda (rec),y
        sta mpos
        ldy #1
        lda (rec),y
        sta mcx
        iny
        lda (rec),y
        sta mcy
        ldy #0
        lda (rec),y
        and #$02
        beq @e403
        ldy #3                  ; heading S/W: measure from the to-junction
        lda (rec),y
        sta mcx
        iny
        lda (rec),y
        sta mcy
        lda #$64
        sec
        sbc mpos
        sta mpos
@e403:  lda mcx
        sec
        sbc $71D0
        bcc @r
        cmp #14
        bcs @r
        jsr se43b
        sta offl
        lda mcy
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
        ldy #0
        lda (rec),y
        lsr a
        bcs @ew
        txa
        eor #$FF
        sec
        adc offh
        sta offh
        jmp @pr
@ew:    txa
        clc
        adc offl
        sta offl
@pr:    lda #$29
        sta bsx
        lda #$56
        sta bsy
        lda mgly
        jmp le341
@r:     rts
