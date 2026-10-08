; objects.s - Spectrum $876F-$8F22 (sky/building fill, object-map scan,
; sprite drawing, traffic-light sequencer) and LBF72 (traffic-light sprite
; patcher) + the sprite bank (data/objects_data.s, tools/gen_objects.py).
;
; Spec: notes/R3.md and the verified model work_R3/model.py.  Everything that
; lands in the $6400 pixel buffer, the $7040 colour buffer, the object records
; and the variables is identical to the original (tests/test_objects.py).
; Not reproduced (no state): the temporary sprite buffers $71D0-$72CF (rows
; are built in zero page; $71D0 is only used for sprites with a light
; overlay), the scratch words D87F5 / D8D2D and the saved stack pointers
; D74F7 / D74F9.
;
; Sprite drawing (S893C), per row: fetch the W image bytes (mirrored through
; the $5B00 bit-reverse table when needed) into irow, shift them by X&7 (right
; for 1..3 bits, or left by 8-x into one more byte for 4..7: the same bits as
; the Z80's RRD/RR passes), build the mask row in mrow straight from the run
; data with two tables (also when mirrored), apply the junction-gap clip, then
; dst = (dst AND mask) OR image.  Rows are right-aligned in irow/mrow: byte j
; of the (W+1)-byte row is at irow+5-W+j, so the unrolled row routines are
; entered at an offset that depends on W (1 <= W <= 5, checked by the
; generator together with the other data properties the code relies on).

        .include "zx.inc"
        .include "snd.inc"

        ZIMPORT $B3B3           ; remove an object's markers from the map
        ZVIMPORT $FD60          ; cross-street grids $FD60-$FFFF (group slots)

; ---------------------------------------------------------------------------
        .zeropage
irow:   .res 6                  ; image row (right-aligned)
mrow:   .res 6                  ; mask row
gp:     .res 2                  ; group slot pointer (881F)
t_lo:   .res 1                  ; mask run [t_lo, t_hi) in bit positions 0..48
t_hi:   .res 1
t_len:  .res 1
t_bl:   .res 1
t_y:    .res 1
mi:     .res 1                  ; mask data offset
sy:     .res 1                  ; image row offset
t_end:  .res 1
k1:     .res 1                  ; mask origin (see setup)
base8:  .res 1                  ; 8 * (5-W)
rows:   .res 1
tmp:    .res 1
tmp2:   .res 1

; z-register file used as scratch pointers inside S893C
op      = zixl                  ; object record (then image) pointer
img     = zixl
persp   = ziyl                  ; perspective entry $78C2+12d
src     = zl                    ; image source
mp      = ze                    ; mask data pointer
dst     = zc                    ; buffer row pointer

        .segment "BSS"
s_C:    .res 1                  ; scan step C (Z80 A')
s_lag:  .res 1                  ; lane lag (E')
s_lat:  .res 1                  ; lateral byte (D')
s_K:    .res 1
s_i:    .res 1                  ; 881F scan index
s_code: .res 1
s_b:    .res 1
s_v:    .res 1
s_y:    .res 1
s_lsave:.res 1
xlo:    .res 1                  ; screen X (0x100 = view centre)
xhi:    .res 1
ybot:   .res 1
spr:    .res 1
g_col:  .res 1                  ; gap clip: column with a partial mask
g_and:  .res 1
g_or:   .res 1
g_lo:   .res 1                  ; columns [g_lo,g_hi) hidden
g_hi:   .res 1
lsave:  .res 1                  ; byte replaced by RTS in lchain

        .segment "DATA"
; S893C variables (IX = $8813), kept like the original's
        ZLABEL $880F, 16
v_objp:   .res 2                ; 880F
v_flags:  .res 1                ; 8811 bit0 group clip, bit1 gap clip pending
v_side:   .res 1                ; 8812
v_hdr:    .res 1                ; 8813
v_W:      .res 1                ; 8814
v_H:      .res 1                ; 8815
v_shift:  .res 1                ; 8816
v_clip:   .res 1                ; 8817
v_gap:    .res 1                ; 8818
v_y:      .res 1                ; 8819
v_col:    .res 1                ; 881A
v_colour: .res 1                ; 881B
v_oflags: .res 1                ; 881C
          .res 1                ; 881D
v_ax:     .res 1                ; 881E
; traffic-light sequence pointer (holds the Spectrum address $8F12+2n)
        ZLABEL $8F10, 2
v_8F10: .word $8F12

; ---------------------------------------------------------------------------
        .segment "RODATA"
LK:     .byte $00,$80,$C0,$E0,$F0,$F8,$FC,$FE     ; D87F7
RKEEP:  .byte $00,$01,$03,$07,$0F,$1F,$3F,$7F     ; D8807
; lane probes of 881F in scan order: (lag, lateral) and map offset
lagtab: .byte 0, 0, 3, 3, 6, 6, 9, 9
lattab: .byte $1C,$9C,$14,$94,$0C,$8C,$04,$84
proboff:.word $0000,$0700,$00FD,$05FD,$01FA,$04FA,$02F7,$03F7
; D8F12: traffic-light sequence (duration, state), $80 = restart
T_8F12: .byte $06,$88,$08,$89,$28,$82,$08,$8B,$08,$88,$08,$98,$28,$28,$08,$B8,$80

        .include "objects_data.s"

; ---------------------------------------------------------------------------
        .code

; ===========================================================================
; S876F: fill the buildings down from their roof lines and colour the top 4
; character rows (0x08 sky, 0x0F roof cell, 0x38 inside).  Y = column.
; ===========================================================================
; LN = buffer address of line l of cell k (column 0), AT = colour cell k
LN0 = $6422
AT0 = $7042

; one fill line: A = c in, c|v out; byte = c AND NOT v
.macro FLINE k, l
        ora LN0 + 256*k + 32*l,y
        tax
        eor LN0 + 256*k + 32*l,y
        sta LN0 + 256*k + 32*l,y
        txa
.endmacro

; fill cell k from line 0 with A = c (L87C1)
.macro FCELL k
        ora LN0 + 256*k,y
        cmp #$FF
        bne :+
        jmp .ident(.sprintf("t38_%d", k))
:       tax
        eor LN0 + 256*k,y
        sta LN0 + 256*k,y
        txa
        FLINE k, 1
        FLINE k, 2
        FLINE k, 3
        FLINE k, 4
        FLINE k, 5
        FLINE k, 6
        FLINE k, 7
        lda #$0F
        sta AT0 + 32*k,y
.if k < 3
        cpx #$FF
        bne :+
        jmp .ident(.sprintf("t38_%d", k+1))
:       txa
.else
        jmp next76
.endif
.endmacro

; sky cell k: lines 0..6 empty?  (L879B)
.macro SCELL k
        .local sf
        lda LN0 + 256*k,y
        bne sf
        lda LN0 + 256*k + 32,y
        bne sf
        lda LN0 + 256*k + 64,y
        bne sf
        lda LN0 + 256*k + 96,y
        bne sf
        lda LN0 + 256*k + 128,y
        bne sf
        lda LN0 + 256*k + 160,y
        bne sf
        lda LN0 + 256*k + 192,y
        bne sf
        lda #$08
        sta AT0 + 32*k,y
.if k < 3
        lda LN0 + 256*k + 224,y
        beq .ident(.sprintf("sky_%d", k+1))
        cmp #$FF
        bne :+
        jmp .ident(.sprintf("t38_%d", k+1))
:       jmp .ident(.sprintf("fill_%d", k+1))
.else
        jmp next76
.endif
sf:     lda #0
        jmp .ident(.sprintf("fill_%d", k))
.endmacro

        ZPROC $876F
        ldy #0
col76:  lda $6402,y
        beq sky_0
        cmp #$FF
        beq :+
        jmp fill_0
:       lda #0
        sta $6402,y
        jmp t38_0
sky_0:  SCELL 0
sky_1:  SCELL 1
sky_2:  SCELL 2
sky_3:  SCELL 3
fill_0: FCELL 0
fill_1: FCELL 1
fill_2: FCELL 2
fill_3: FCELL 3
t38_0:  lda #$38
        sta AT0,y
        bne t38x1
t38_1:  lda #$38
t38x1:  sta AT0+32,y
t38x2:  sta AT0+64,y
t38x3:  sta AT0+96,y
next76: iny
        cpy #28
        beq :+
        jmp col76
:       rts
t38_2:  lda #$38
        bne t38x2
t38_3:  lda #$38
        bne t38x3

; ===========================================================================
; S881F: scan the object map far to near and draw every object.
; ===========================================================================
PROBE_SIZE = 5
        ZPROC $881F
        ldx #7
@patch: txa
        asl
        tay
        lda proboff,y
        sta tmp
        lda proboff+1,y
        sta tmp2
        lda ptab,x
        tay
        clc
        lda $7502
        adc tmp
        sta probes+1,y
        lda $7503
        adc tmp2
        sta probes+2,y
        dex
        bpl @patch
        lda #73
        sta s_C
        ldx #0
probes:
p0:     lda $FFFF,x
        bne h0
p1:     lda $FFFF,x
        bne h1
p2:     lda $FFFF,x
        bne h2
p3:     lda $FFFF,x
        bne h3
p4:     lda $FFFF,x
        bne h4
p5:     lda $FFFF,x
        bne h5
p6:     lda $FFFF,x
        bne h6
p7:     lda $FFFF,x
        bne h7
p8:     inx
        dec s_C
        bne p0
        rts
h0:     ldy #0
        jsr hit
        jmp p1
h1:     ldy #1
        jsr hit
        jmp p2
h2:     ldy #2
        jsr hit
        jmp p3
h3:     ldy #3
        jsr hit
        jmp p4
h4:     ldy #4
        jsr hit
        jmp p5
h5:     ldy #5
        jsr hit
        jmp p6
h6:     ldy #6
        jsr hit
        jmp p7
h7:     ldy #7
        jsr hit
        jmp p8

        .segment "RODATA"
ptab:   .byte 0, 5, 10, 15, 20, 25, 30, 35
        .code

; A = map code, Y = probe number; X preserved
hit:    stx s_i
        tax
        lda lagtab,y
        sta s_lag
        lda lattab,y
        sta s_lat
        txa
        bmi @hi
        and #$1F
        beq @out
        jsr draw
        jmp @out
@hi:    cmp #$FD
        bcs @out
        cmp #$C0
        bcs group
        sta s_code              ; two objects: (code>>3)&7 then code&7
        lsr
        lsr
        lsr
        and #7
        beq :+
        jsr draw
:       lda s_code
        and #7
        beq @out
        jsr draw
@out:   ldx s_i
        rts

; L88AC: group code $C0..$FC: 12 slot bytes, lateral + 8*(b-1)
group:  sta s_code
        and #$1F
        asl
        asl
        sta tmp
        asl
        clc
        adc tmp                 ; 12*slot (slot < 32)
        ldx #0
        bcc :+
        inx
:       sta tmp
        stx tmp2
        lda #1
        sta v_flags
        lda s_code
        and #$20
        beq @inc
        ; DEC HL: slot bytes p, p-1 .. p-11 (p = $FEBB+12s), b = Y+1
        lda #<(ZV_FD60 + $FEBB - $FD60 - 11)
        clc
        adc tmp
        sta gp
        lda #>(ZV_FD60 + $FEBB - $FD60 - 11)
        adc tmp2
        sta gp+1
        ldy #11
@dl:    lda (gp),y
        bne @dhit
@dn:    dey
        bpl @dl
        bmi @end
@dhit:  sty s_y
        tax
        tya
        asl
        asl
        asl
        jsr gdraw
        ldy s_y
        jmp @dn
        ; INC HL: slot bytes p .. p+11 (p = $FD60+12s), b = 12-Y
@inc:   lda #<ZV_FD60
        clc
        adc tmp
        sta gp
        lda #>ZV_FD60
        adc tmp2
        sta gp+1
        ldy #0
@il:    lda (gp),y
        bne @ihit
@in:    iny
        cpy #12
        bne @il
@end:   lda #0
        sta v_flags
        ldx s_i
        rts
@ihit:  sty s_y
        tax
        tya
        eor #$FF
        clc
        adc #12                 ; 11-Y
        asl
        asl
        asl
        jsr gdraw
        ldy s_y
        jmp @in

; draw slot value X with lateral + A (restored afterwards)
gdraw:  stx s_v
        clc
        adc s_lat
        ldx s_lat
        stx s_lsave
        sta s_lat
        lda s_v
        bmi @pair
        jsr draw                ; full byte as K
        jmp @rest
@pair:  cmp #$FD
        bcs @rest
        and #7                  ; low nibble first here
        beq :+
        jsr draw
:       lda s_v
        lsr
        lsr
        lsr
        and #7
        beq @rest
        jsr draw
@rest:  lda s_lsave
        sta s_lat
        rts

; ===========================================================================
; S893C: draw one object.  A = K, za2 = C, ze2 = lag, zd2 = lateral.
; ===========================================================================
        ZPROC $893C
        tax
        lda za2
        sta s_C
        lda ze2
        sta s_lag
        lda zd2
        sta s_lat
        txa
draw:   sta s_K
        lda s_C
        sec
        sbc #9
        clc
        adc s_lag
        cmp #$3A
        bcc :+
        rts
:       asl                     ; persp = $78C2 + 12*d
        asl
        sta tmp
        asl
        ldx #>$78C2
        bcc :+
        inx
        clc
:       adc tmp
        bcc :+
        inx
        clc
:       adc #<$78C2
        sta persp
        bcc :+
        inx
:       stx persp+1
        lda s_K                 ; objp = $7702 + SB9D2(K)
        asl
        asl
        sta tmp
        asl
        clc
        adc tmp
        ldx #>$7702
        bcc :+
        inx
        clc
:       adc #<$7702
        sta op
        sta v_objp
        bcc :+
        inx
:       stx op+1
        stx v_objp+1
        ldy #0                  ; lateral
        lda s_lat
        sta v_side
        and #$7F
        sec
        sbc (op),y
        bpl :+
        eor #$FF
        clc
        adc #1
        tax
        lda v_side
        eor #$80
        sta v_side
        txa
:       sta v_ax
        and #$7F                ; S8C87: (a&7F) * persp[6]
        sta tmp
        ldy #6
        lda (persp),y
        sta tmp2
        lda #0
        .repeat 7
        lsr tmp
        bcc :+
        clc
        adc tmp2
:       ror
        ror t_y
        .endrep
        cmp #$12                ; A = prod>>7: prod >= $900 -> off >= $90
        bcc :+
        rts
:       asl
        asl
        asl
        sta tmp
        lda t_y
        lsr
        lsr
        lsr
        lsr
        lsr
        ora tmp                 ; off = prod >> 4
        cmp #$89
        bcc :+
        rts
:       ldx #1                  ; X = $100 +- off
        bit v_side
        bmi :+
        eor #$FF
        clc
        adc #1
        beq :+
        dex
:       sta xlo
        stx xhi
        ldy #1
        lda (op),y
        sta v_oflags
        ldy #0
        lda (persp),y
        sec
        sbc #1
        sta ybot
        ldy #3
        lda (op),y
        sta v_colour
        iny
        lda (op),y
        iny
        clc
        adc (op),y
        sta spr
        lda v_oflags
        and #2
        beq @img
        jsr explode
@img:   lda spr                 ; record = C581 + 8*spr
        ldx #0
        stx tmp
        asl
        rol tmp
        asl
        rol tmp
        asl
        rol tmp
        clc
        adc #<T_C581
        sta src
        lda tmp
        adc #>T_C581
        sta src+1
        ldy #5
        lda (persp),y
        tax
        jsr sizesum
        ldy #0
        lda (img),y
        and #$40
        beq @nocont
        lda v_ax                ; view angle
        cmp #$19
        bcc :+
        lda #$18
:       lsr
        lsr
        lsr
        and #3
        bit v_side
        bmi :+
        eor #3
        jmp :++
:       ora #4
:       tax
        lda img
        clc
        adc #1
        sta src
        lda img+1
        adc #0
        sta src+1
        jsr sizesum
@nocont:
        ldy #0                  ; header
        lda (img),y
        bpl @plain
        and #$20
        sta tmp
        iny
        lda (img),y
        tax
        iny
        lda (img),y
        sta img+1
        stx img
        ldy #0
        lda (img),y
        ldx tmp
        bne @plain
        ora #$80
@plain: sta v_hdr
        and #$0F
        sta v_W
        ldy #1
        lda (img),y
        sta tmp
        and #$40
        beq @nomir
        lda tmp
        eor v_side
        bpl @nomir
        lda v_hdr
        ora #$80
        sta v_hdr
@nomir: lda tmp
        and #$3F
        bit v_hdr
        bpl :+
        sta tmp
        lda v_W
        asl
        asl
        asl
        sec
        sbc tmp
:       sta tmp                 ; X -= hot (or 8W-hot when mirrored)
        lda xlo
        sec
        sbc tmp
        sta xlo
        bcs :+
        dec xhi
:       ldx #0                  ; vertical clip
        lda ybot
        cmp #$5F
        bcc :+
        sbc #$5F
        tax
        lda #$5F
:       stx v_clip
        sta v_y
        lda xlo
        and #7
        sta v_shift
        lda xhi
        lsr
        lda xlo
        ror
        lsr
        lsr
        and #$3F
        sta v_col
        lda v_y                 ; D7500 = $6410 + 32y + col
        lsr
        lsr
        lsr
        sta dst+1
        lda v_y
        asl
        asl
        asl
        asl
        asl
        clc
        adc v_col
        bcc :+
        inc dst+1
        clc
:       adc #$10
        sta dst
        sta $7500
        lda dst+1
        adc #$64
        sta dst+1
        sta $7501
        lda v_flags             ; junction-gap clip for group objects
        lsr
        bcc @hgt
        bit v_side
        bpl @left
        lda $7509
        lsr
        lsr
        lsr
        and #$1F
        clc
        adc #$21
        sec
        sbc v_col
        bcc @ret
        beq @ret
        sbc #1
        sec
        sbc v_W
        bcc @gset
        beq @gset
        bne @hgt
@ret:   rts
@left:  lda $750A
        lsr
        lsr
        lsr
        and #$1F
        eor #$FF
        clc
        adc #$21
        sec
        sbc v_col
        bcc @hgt
        beq @hgt
        sbc #1
        sec
        sbc v_W
        bcs @ret
@gset:  sta v_gap
        lda v_flags
        ora #2
        sta v_flags
@hgt:   ldy #2
        lda (img),y
        sec
        sbc v_clip
        bcc @ret
        beq @ret
        sta v_H
        bit v_colour
        bmi :+
        jsr colour
:       jmp render

; sizesum (S8D35): img = word(src) + sum of the X bytes after it
sizesum:
        ldy #0
        lda (src),y
        sta img
        iny
        lda (src),y
        sta img+1
        txa
        beq @done
        lda img
@l:     iny
        clc
        adc (src),y
        bcc :+
        inc img+1
:       dex
        bne @l
        sta img
@done:  rts

; exploding object (89BE): colour 3A, noise, advance frame, maybe remove
explode:
        lda #$3A
        sta v_colour
        ldy #2
        lda (op),y
        sta tmp2
        and #$C0
        bne :+
        lda #SND_CRASH          ; S8EBF with B = 20
        ldx #20
        jsr snd_fx
:       lda tmp2
        clc
        adc #$40
        ldy #2
        sta (op),y
        bcc :+
        dey
        lda (op),y
        and #$7F
        sta (op),y
        lda persp
        pha
        lda persp+1
        pha
        lda op
        sta ziyl
        lda op+1
        sta ziyh
        jsr call_b3b3
        pla
        sta persp+1
        pla
        sta persp
:       lda tmp2                ; spr = $24 + (c >> 6)
        rol
        rol
        rol
        and #3
        clc
        adc #$24
        sta spr
        rts

; S8EAB: B3B3(HL' = obj[6..7], C = obj[1], IY = record); HL BC DE preserved
        ZPROC $8EAB
        lda zl
        pha
        lda zh
        pha
        lda zc
        pha
        lda zb
        pha
        lda ze
        pha
        lda zd
        pha
        jsr call_b3b3
        pla
        sta zd
        pla
        sta ze
        pla
        sta zb
        pla
        sta zc
        pla
        sta zh
        pla
        sta zl
        rts
call_b3b3:
        ldy #6
        lda (ziyl),y
        sta zl2
        iny
        lda (ziyl),y
        sta zh2
        ldy #1
        lda (ziyl),y
        sta zc
        jmp Z_B3B3

; S8EBF: noise burst, B = length -> sound effect
        ZPROC $8EBF
        lda #SND_CRASH
        ldx zb
        jmp snd_fx

; S8C87: A = bits 3..10 of (A&7F)*E, C = bit 11, Z = product < $1000,
; L = product low, H = product >> 12, B = D = 0
        ZPROC $8C87
        and #$7F
        sta tmp
        lda #0
        ldx #8
:       lsr tmp
        bcc :+
        clc
        adc ze
:       ror
        ror zl
        dex
        bne :--
        sta zh
        stx zb
        stx zd
        lda zl
        lsr zh
        ror
        lsr zh
        ror
        lsr zh
        ror
        lsr zh
        rts

; ===========================================================================
; S8DE1: colour the sprite's cells (rows 4..11 only)
; ===========================================================================
colour:
        ldx v_y
        dex
        stx tmp                 ; c = y-1
        txa
        sec
        sbc v_H
        clc
        adc #2
        lsr
        lsr
        lsr
        and #$1F
        cmp #4
        bcs :+
        lda #4
:       sta tmp2                ; top
        lda tmp
        lsr
        lsr
        lsr
        and #$1F
        sec
        sbc tmp2
        bcs :+
        rts
:       adc #0                  ; +1 (C=1)
        sta rows
        lda tmp                 ; ptr = $7030 + (c&$78)*4 + col
        and #$78
        ldx #0
        stx tmp2
        asl
        rol tmp2
        asl
        rol tmp2
        clc
        adc v_col
        bcc :+
        inc tmp2
        clc
:       adc #<$7030
        sta src
        lda tmp2
        adc #>$7030
        sta src+1
        ldx v_W
        inx                     ; cols = W+1
        lda v_flags
        and #2
        beq @go
        lda #0
        sec
        sbc v_gap
        sta tmp                 ; e = -gap
        bit v_side
        bmi :+
        clc
        adc src
        sta src
        bcc :+
        inc src+1
:       txa
        sec
        sbc tmp
        tax
@go:    stx tmp
@row:   ldy #0
:       lda (src),y
        and #$38
        ora v_colour
        sta (src),y
        iny
        cpy tmp
        bne :-
        lda src
        sec
        sbc #32
        sta src
        bcs :+
        dec src+1
:       dec rows
        bne @row
        rts

; ===========================================================================
; render: image, mask, overlay, shift, gap clip, blit (8B02-8C86)
; ===========================================================================
render:
        lda img                 ; src = img+3 + W*clip
        clc
        adc #3
        sta src
        lda img+1
        adc #0
        sta src+1
        ldx v_clip
        beq @noclip
        lda src
:       clc
        adc v_W
        bcc :+
        inc src+1
:       dex
        bne :--
        sta src
@noclip:
        lda #0                  ; mask data = src + W*H
        ldx v_W
:       clc
        adc v_H
        dex
        bne :-
        clc
        adc src
        sta mp
        lda src+1
        adc #0
        sta mp+1
        lda #5                  ; base = 5-W
        sec
        sbc v_W
        sta tmp2
        asl
        asl
        asl
        sta base8
        ldx #0
        stx mi
        ; --- mask mode
        lda v_oflags
        and #2
        beq :+
        lda #<mnone
        ldx #>mnone
        jmp @mset
:       lda v_hdr
        and #$10
        bne @fmtb
        lda v_clip              ; format A: skip clip bytes
        sta mi
        lda base8               ; row builder entry
        clc
        adc #<mbset
        sta ma_j+1
        sta mam_j+1
        lda #>mbset
        adc #0
        sta ma_j+2
        sta mam_j+2
        lda #<maska
        ldx #>maska
        bit v_hdr
        bpl @mset
        lda #<maskam
        ldx #>maskam
        jmp @mset
@fmtb:  ldx v_clip              ; format B: skip clip rows
        beq @fb2
        ldy #0
:       iny
        lda (mp),y
        iny
        asl
        bcs :-
        dex
        bne :-
        sty mi
@fb2:   lda base8
        clc
        adc #<mbset
        sta mb_s+1
        sta mbm_s+1
        lda #>mbset
        adc #0
        sta mb_s+2
        sta mbm_s+2
        lda tmp2                ; mband + 10*base
        asl
        adc base8
        adc #<mband
        sta mb_a+1
        sta mbm_a+1
        lda #>mband
        adc #0
        sta mb_a+2
        sta mbm_a+2
        lda #<maskb
        ldx #>maskb
        bit v_hdr
        bpl @mset
        lda #<maskbm
        ldx #>maskbm
@mset:  sta mj+1
        stx mj+2
        ; --- mask origin
        lda v_shift
        bit v_hdr
        bmi :+
        clc
        adc base8
        bcc :++                 ; always
:       clc
        adc #40
:       sta k1
        ; --- image fetch: o = shift>=4
        lda v_hdr
        and #$20
        beq @noov
        lda v_oflags
        and #4
        beq @noov
        lda $75F8
        and #2
        beq @noov
        jsr overlay             ; builds $71D0, src -> buffer
        ldx v_W
        inx
        jmp @fnm
@noov:  ldx v_W
        bit v_hdr
        bpl @fnm
        stx stride+1            ; mirrored fetch: Y starts at W-1
        dex
        stx sy
        lda v_shift
        cmp #4
        lda tmp2
        bcs :+
        tay
        lda mul9,y
        adc #<fetchm0
        ldx #>fetchm0
        bcc @fset
        inx
        bne @fset
:       tay
        lda mul9,y
        clc
        adc #<fetchm1
        ldx #>fetchm1
        bcc @fset
        inx
        bne @fset
@fnm:   stx stride+1            ; plain fetch (X = stride)
        ldy #0
        sty sy
        lda v_shift
        cmp #4
        lda tmp2
        bcs :+
        tay
        lda mul5,y
        adc #<fetchn0
        ldx #>fetchn0
        bcc @fset
        inx
        bne @fset
:       tay
        lda mul5,y
        clc
        adc #<fetchn1
        ldx #>fetchn1
        bcc @fset
        inx
@fset:  sta fj+1
        stx fj+2
        ; --- shift: one call per row into repeated chains.  irow bytes
        ; left of the row are 0 and stay 0 (only zeros are shifted into
        ; them), so whole chain copies can run over them.
        lda #0
        ldx #5
:       sta irow,x
        dex
        bpl :-
        lda #<(irow+5)
        sta zst+1
        lda #$20                ; JSR
        sta sj
        lda v_shift
        beq @sh0
        cmp #4
        bcs @shl
        eor #3                  ; right by s=1..3: copy 3-s, at base
        tax
        lda mul12,x
        clc
        adc tmp2
        adc tmp2
        adc #<rchain
        ldx #>rchain
        bcc :+
        inx
:       sta sj+1
        stx sj+2
        jmp @shd
@sh0:   lda #$2C                ; no shift: BIT abs
        sta sj
        bne @shd
@shl:   sec                     ; left by 8-s: copy s-4
        sbc #4
        tax
        lda mul12,x
        clc
        adc #<lchain
        ldx #>lchain
        bcc :+
        inx
:       sta sj+1
        stx sj+2
        lda tmp2
        clc
        adc #<irow
        sta zst+1
        ldx v_W                 ; RTS after position base in the last copy
        lda lpos,x
        tax
        lda lchain+36,x
        sta lsave
        lda #$60
        sta lchain+36,x
@shd:   ; --- blit entry
        ldy tmp2
        lda mul9,y
        clc
        adc #<blit
        ldx #>blit
        bcc :+
        inx
:       sta bj+1
        stx bj+2
        ; --- junction gap clip
        lda #$2C                ; BIT abs = no gap op
        ldx v_flags
        cpx #2
        bcc :+
        jsr gapsetup
        lda #$20                ; JSR
:       sta gj
        lda v_H
        sta rows
        ; ------------------------------------------------- row loop
rowlp:  lda #0
zst:    sta irow+5              ; spare byte (zp operand patched)
        ldy sy
fj:     jsr $FFFF               ; fetch
        clc
sj:     jsr $FFFF               ; shift chains (or BIT)
mj:     jsr $FFFF               ; mask row
gj:     jsr gapop               ; (or BIT)
        ldy #0
bj:     jsr $FFFF               ; blit
        lda sy
        clc
stride: adc #0
        sta sy
        lda dst
        sec
        sbc #32
        sta dst
        bcs :+
        dec dst+1
:       dec rows
        bne rowlp
        lda v_shift             ; undo the RTS patch
        cmp #4
        bcc :+
        ldx v_W
        lda lpos,x
        tax
        lda lsave
        sta lchain+36,x
:       rts

        .segment "RODATA"
mul5:   .byte 0, 5, 10, 15, 20, 25
mul9:   .byte 0, 9, 18, 27, 36, 45
mul12:  .byte 0, 12, 24, 36
lpos:   .byte 2, 4, 6, 8, 10, 12        ; lchain offset after position 5-W
; mask row tables: byte j of a row with run [lo,hi) =
;   LT0[lo-8j] (bits left of lo kept) | RT0[hi-8j] (bits from hi on kept)
LTT:    .repeat 89, i
        .if i - 40 <= 0
        .byte 0
        .elseif i - 40 >= 8
        .byte $FF
        .else
        .byte ($FF << (8 - (i - 40))) & $FF
        .endif
        .endrep
LT0 = LTT + 40
RTT:    .repeat 89, i
        .if i - 40 <= 0
        .byte $FF
        .elseif i - 40 >= 8
        .byte 0
        .else
        .byte $FF >> (i - 40)
        .endif
        .endrep
RT0 = RTT + 40
        .code

; ---- row fetch routines (Y = row offset, +W-1 when mirrored)
fetchn0:
        .repeat 5, P
        lda (src),y
        sta irow+P
        iny
        .endrep
        rts
fetchn1:
        .repeat 5, P
        lda (src),y
        sta irow+P+1
        iny
        .endrep
        rts
fetchm0:
        .repeat 5, P
        lda (src),y
        tax
        lda $5B00,x
        sta irow+P
        dey
        .endrep
        rts
fetchm1:
        .repeat 5, P
        lda (src),y
        tax
        lda $5B00,x
        sta irow+P+1
        dey
        .endrep
        rts

; ---- shift chains (carry clear on entry)
rchain:                         ; 3 copies: enter copy 3-s at 2*base
        .repeat 3
        .repeat 6, P
        ror irow+P
        .endrep
        .endrep
        rts
lchain:                         ; 4 copies: enter copy s-4 (8-s copies run)
        .repeat 4
        asl irow+5
        .repeat 5, P
        rol irow+4-P
        .endrep
        .endrep
        rts

; ---- blit: (dst),y = (dst),y AND mask OR image
blit:
        .repeat 6, P
        lda (dst),y
        and mrow+P
        ora irow+P
        sta (dst),y
        iny
        .endrep
        rts

; ---- mask row from the run [X, Y) (entered at element 5-W)
mbset:
        .repeat 6, j
        lda LT0 - 8*j,x
        ora RT0 - 8*j,y
        sta mrow+j
        .endrep
        rts
mband:                          ; second run of the row
        .repeat 6, j
        lda LT0 - 8*j,x
        ora RT0 - 8*j,y
        and mrow+j
        sta mrow+j
        .endrep
        rts

; ---- mask rows.  Bit positions: row byte j = mrow+5-W+j.
; exploding: no mask
mnone:  lda #$FF
        sta mrow
        sta mrow+1
        sta mrow+2
        sta mrow+3
        sta mrow+4
        sta mrow+5
        rts
; format A, plain: run = [k1 + (m&7), + m>>3)
; (the data's runs end inside W*8 pixels, so no clipping is needed)
maska:  ldy mi
        lda (mp),y
        inc mi
        tay
        and #7
        clc
        adc k1
        sta t_lo
        tax
        tya
        lsr
        lsr
        lsr
        clc
        adc t_lo
        tay
ma_j:   jmp $FFFF
; format A, mirrored: run = [hi - len, hi), hi = k1 - (m&7)
maskam: ldy mi
        lda (mp),y
        inc mi
        tay
        and #7
        eor #$FF
        sec
        adc k1
        sta t_hi
        tya
        lsr
        lsr
        lsr
        eor #$FF
        sec
        adc t_hi
        tax
        ldy t_hi
mam_j:  jmp $FFFF
; format B, plain: [x0][len|more][gap][len]...
maskb:  ldy mi
        lda (mp),y
        clc
        adc k1
        sta t_lo
        iny
        lda (mp),y
        sty mi
        sta t_len
        and #$7F
        clc
        adc t_lo
        sta t_end
        cmp #49
        bcc :+
        lda #48
:       tay
        ldx t_lo
mb_s:   jsr $FFFF
mbmore: bit t_len
        bpl mbdone
        ldy mi
        iny
        lda (mp),y
        clc
        adc t_end
        sta t_lo
        iny
        lda (mp),y
        sty mi
        sta t_len
        and #$7F
        clc
        adc t_lo
        sta t_end
        cmp #49
        bcc :+
        lda #48
:       tay
        ldx t_lo
mb_a:   jsr $FFFF
        jmp mbmore
mbdone: inc mi
        rts
; format B, mirrored: runs go right to left
maskbm: ldy mi
        lda (mp),y
        eor #$FF
        sec
        adc k1
        sta t_hi
        iny
        lda (mp),y
        sty mi
        sta t_len
        and #$7F
        eor #$FF
        sec
        adc t_hi
        sta t_end
        bcs :+
        lda #0
:       tax
        ldy t_hi
mbm_s:  jsr $FFFF
mbmmore:
        bit t_len
        bpl mbmdone
        ldy mi
        iny
        lda (mp),y
        eor #$FF
        sec
        adc t_end
        sta t_hi
        iny
        lda (mp),y
        sty mi
        sta t_len
        and #$7F
        eor #$FF
        sec
        adc t_hi
        sta t_end
        bcs :+
        lda #0
:       tax
        ldy t_hi
mbm_a:  jsr $FFFF
        jmp mbmmore
mbmdone:
        inc mi
        rts

; junction gap clip of one row (S8D46 on the built row)
gapop:  ldx g_col
        lda irow,x
        and g_and
        sta irow,x
        lda mrow,x
        ora g_or
        sta mrow,x
        ldx g_lo
        cpx g_hi
        bcs @done
:       lda #0
        sta irow,x
        lda #$FF
        sta mrow,x
        inx
        cpx g_hi
        bcc :-
@done:  rts

; S8D46 set-up: clears 8811 bit1, computes the column operations
gapsetup:
        lda v_flags
        and #$FD
        sta v_flags
        bit v_side
        bpl @left
        lda v_W                 ; right: column W+gap gets LK[D7509&7]
        clc
        adc v_gap
        clc
        adc tmp2
        sta g_col
        tax
        inx
        stx g_lo
        lda #0
        sec
        sbc v_gap
        and #7
        clc
        adc g_lo
        sta g_hi
        lda $7509
        and #7
        tax
        lda LK,x
        jmp @val
@left:  lda v_gap               ; left: (W+gap)&7 columns hidden
        clc
        adc v_W
        and #7
        clc
        adc tmp2
        sta g_hi
        sta g_col
        lda tmp2
        sta g_lo
        lda $750A
        and #7
        tax
        lda RKEEP,x
@val:   sta g_and
        eor #$FF
        sta g_or
        rts

; S8E48 path: build the unshifted image in $71D0 (rows of W+1), patch the
; light overlay into it, then draw from there (plain fetch, stride W+1)
overlay:
        lda #<$71D0
        sta t_lo                ; t_lo/t_hi as a pointer into $71D0
        lda #>$71D0
        sta t_hi
        lda v_H
        sta rows
@row:   bit v_hdr
        bmi @mir
        ldy #0
:       lda (src),y
        sta (t_lo),y
        iny
        cpy v_W
        bne :-
        beq @z
@mir:   ldy v_W
        dey
        ldx #0
        stx t_y
:       lda (src),y
        tax
        lda $5B00,x
        sty t_bl
        ldy t_y
        sta (t_lo),y
        inc t_y
        ldy t_bl
        dey
        bpl :-
        ldy v_W
@z:     lda #0
        sta (t_lo),y
        iny
        tya
        clc
        adc t_lo
        sta t_lo
        bcc :+
        inc t_hi
:       lda src
        clc
        adc v_W
        sta src
        bcc :+
        inc src+1
:       dec rows
        bne @row
        ; find the end of the mask data (first row after clip at mp+mi)
        lda v_hdr
        and #$10
        bne @fb
        lda mi
        clc
        adc v_H
        tay
        jmp @fe
@fb:    ldx v_H
        ldy mi
:       iny
        lda (mp),y
        iny
        asl
        bcs :-
        dex
        bne :-
@fe:    tya
        clc
        adc mp
        sta src
        lda mp+1
        adc #0
        sta src+1
        ldy #0                  ; src = overlay block
        bit v_hdr
        bpl :+
        lda (src),y
        jsr @adv
:       lda #1
        jsr @adv
        lda v_oflags
        and #8
        beq :+
        lda (src),y
        jsr @adv
:       lda #1
        jsr @adv
        lda (src),y             ; n pairs (value, offset)
        sta rows
        lda #1
        jsr @adv
        lda v_clip
        bne @clip
@p0:    ldy #1
        lda (src),y
        tax
        dey
        lda (src),y
        sta $71D0,x
        lda #2
        jsr @adv
        dec rows
        bne @p0
        beq @done
@clip:  ldx v_W                 ; thr = clip*(W+1) & $FF
        inx
        lda #0
:       clc
        adc v_clip
        dex
        bne :-
        sta tmp
@p1:    ldy #1
        lda (src),y
        cmp tmp
        beq :+
        bcc :+
        sec
        sbc tmp
        tax
        dey
        lda (src),y
        sta $71D0,x
:       lda #2
        jsr @adv
        dec rows
        bne @p1
@done:  lda #<$71D0
        sta src
        lda #>$71D0
        sta src+1
        rts
@adv:   clc
        adc src
        sta src
        bcc :+
        inc src+1
:       ldy #0
        rts

; ===========================================================================
; S8EE2: next traffic-light state; S8F0B: re-apply the orientation
; ===========================================================================
        ZPROC $8EE2
        lda v_8F10
        sec
        sbc #<$8F12
        tax
        lda T_8F12,x
        bpl :+
        ldx #0
:       lda T_8F12,x
        sta $75F9
        lda T_8F12+1,x
        sta $7605
        txa
        clc
        adc #<($8F12+2)
        sta v_8F10
        lda #>$8F12
        sta v_8F10+1
        lda $7605
L8EF9:  tax
        lda $75F0
        lsr
        txa
        bcc :+
        asl                     ; swap nibbles
        adc #$80
        rol
        asl
        adc #$80
        rol
:       sta $75FA
        and #3
        jmp Z_BF72
        ZPROC $8F0B
        lda $7605
        jmp L8EF9

; LBF72: copy lamp frame A (0..3) into sprite 03, levels 3..6
        ZPROC $BF72
        asl
        tax
        lda T_BF9C,x
        sta zl
        lda T_BF9C+1,x
        sta zh
        ldy #0
:       lda (zl),y
        sta ZV_BDE2,y
        iny
        cpy #3
        bne :-
        ldx #0
:       lda (zl),y
        sta ZV_BE05,x
        iny
        inx
        cpx #5
        bne :-
        ldx #0
:       lda (zl),y
        sta ZV_BE45,x
        iny
        inx
        cpx #15
        bne :-
        ldx #0
:       lda (zl),y
        sta ZV_BEA3,x
        iny
        inx
        cpx #15
        bne :-
        rts
