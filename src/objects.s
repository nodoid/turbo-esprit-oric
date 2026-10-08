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
persp:  .res 2                  ; perspective entry $78C2+12d
lp:     .res 2                  ; 876F line pointer
ap:     .res 2                  ; 876F colour pointer
msk:    .res 1                  ; $FF when mirrored
k1b:    .res 1
t_e:    .res 1
t_f:    .res 1

; z-register file used as scratch pointers inside S893C
op      = zixl                  ; object record (then image) pointer
img     = zixl
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
col76:  .res 1
mrow2:  .res 6
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

        .segment "DATA3"
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
        .segment "RODATA3"
LK:     .byte $00,$80,$C0,$E0,$F0,$F8,$FC,$FE     ; D87F7
RKEEP:  .byte $00,$01,$03,$07,$0F,$1F,$3F,$7F     ; D8807
; lane probes of 881F in scan order: (lag, lateral) and map offset
lagtab: .byte 0, 0, 3, 3, 6, 6, 9, 9
lattab: .byte $1C,$9C,$14,$94,$0C,$8C,$04,$84
problo: .byte <$0000,<$0700,<$00FD,<$05FD,<$01FA,<$04FA,<$02F7,<$03F7
probhi: .byte >$0000,>$0700,>$00FD,>$05FD,>$01FA,>$04FA,>$02F7,>$03F7
; D8F12: traffic-light sequence (duration, state), $80 = restart
T_8F12: .byte $06,$88,$08,$89,$28,$82,$08,$8B,$08,$88,$08,$98,$28,$28,$08,$B8,$80

        .include "objects_data.s"

; ---------------------------------------------------------------------------
        .segment "CODE3"

; ===========================================================================
; S876F: fill the buildings down from their roof lines and colour the top 4
; character rows (0x08 sky, 0x0F roof cell, 0x38 inside).  Y = column.
; ===========================================================================
; Per column: lp -> line 0 of the current cell ($6422+col+256k, lines at
; Y = 32*l), ap -> its colour cell ($7042+col+32k, never crosses a page).
        ZPROC $876F
        lda #$70
        sta ap+1
        ldx #0
c76:    stx col76
        txa
        clc
        adc #$22
        sta lp
        adc #$20                ; $42+col
        sta ap
        lda #$64
        sta lp+1
        lda $6402,x
        beq sky76
        cmp #$FF
        bne fill76
        lda #0                  ; INC (HL) side effect
        sta $6402,x
        jmp t38                 ; all 4 cells 0x38
sky76:                          ; lines 0..6 of the cell empty?
        .repeat 7, l
        ldy #32*l
        lda (lp),y
        bne sf76
        .endrep
        ldy #0
        lda #$08
        sta (ap),y
        ldy #224                ; line 7
        lda (lp),y
        bne :+
        inc lp+1                ; next cell
        lda ap
        clc
        adc #32
        sta ap
        lda lp+1
        cmp #$68
        bne sky76
        beq done76
:       cmp #$FF
        beq t38n
        jsr next76
        bne fill76
        beq done76
sf76:   lda #0
fill76: ldy #0                  ; L87C1, A = c
        ora (lp),y
        cmp #$FF
        beq t38
        tax
        eor (lp),y
        sta (lp),y
        txa
        .repeat 7, l
        ldy #32*(l+1)
        ora (lp),y
        tax
        eor (lp),y
        sta (lp),y
        txa
        .endrep
        ldy #0
        lda #$0F
        sta (ap),y
        txa
        cmp #$FF
        beq t38n
        jsr next76
        beq done76
        jmp fill76
done76: ldx col76
        inx
        cpx #28
        beq :+
        jmp c76
:       rts
t38n:   jsr next76
        beq done76
t38:    ldy #0                  ; this and the remaining cells = 0x38
:       lda #$38
        sta (ap),y
        lda ap
        clc
        adc #32
        sta ap
        inc lp+1
        lda lp+1
        cmp #$68
        bcc :-
        bcs done76
; next cell; A preserved, Z set when the column is done
next76: inc lp+1
        tax
        lda ap
        clc
        adc #32
        sta ap
        txa
        ldy lp+1
        cpy #$68
        rts

; ===========================================================================
; S881F: scan the object map far to near and draw every object.
; ===========================================================================
        ZPROC $881F
        ldx #7
@patch: ldy ptab,x
        clc
        lda $7502
        adc problo,x
        sta probes+1,y
        lda $7503
        adc probhi,x
        sta probes+2,y
        dex
        bpl @patch
        lda #73
        sta s_C
        ldx #0
probes:
        .repeat 8, k
        lda $FFFF,x             ; operand patched: map + probe offset
        beq :+
        ldy #k
        jsr hit
:
        .endrep
        inx
        dec s_C
        bne probes
        rts

        .segment "RODATA3"
ptab:   .byte 0, 10, 20, 30, 40, 50, 60, 70
        .segment "CODE3"

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
        bne @dr
        beq @out
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
@dr:    jsr draw
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
:       stx tmp2
        sta tmp
        lda #$C8                ; INY: bytes p .. p+11, p = $FD60+12s
        sta gstep
        ldx #<ZV_FD60
        ldy #>ZV_FD60
        lda #0
        sta t_y                 ; first index
        lda s_code
        and #$20
        beq :+
        lda #$88                ; DEY: bytes p .. p-11, p = $FEBB+12s
        sta gstep
        lda #11
        sta t_y
        ldx #<(ZV_FD60 + $FEBB - $FD60 - 11)
        ldy #>(ZV_FD60 + $FEBB - $FD60 - 11)
:       txa
        clc
        adc tmp
        sta gp
        tya
        adc tmp2
        sta gp+1
        lda #1
        sta v_flags
        ldy t_y
        lda #12
        sta s_b
gloop:  lda (gp),y
        beq gstep
        sty s_y
        tax
        lda s_b
        asl
        asl
        asl
        adc #$F8                ; 8*(b-1)
        jsr gdraw
        ldy s_y
gstep:  iny                     ; patched INY/DEY
        dec s_b
        bne gloop
        lda #0
        sta v_flags
        ldx s_i
        rts

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
        ldx #7
@mul:   lsr tmp
        bcc :+
        clc
        adc tmp2
:       ror
        ror t_y
        dex
        bne @mul
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
        sta img
        lda tmp
        adc #>T_C581
        sta img+1
        ldy #5
        lda (persp),y
        tax
        ldy #0
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
        bpl :++
:       ora #4
:       tax
        ldy #1
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

; sizesum (S8D35): img = word(img+Y) + sum of the X bytes after it
sizesum:
        lda (img),y
        sta tmp
        iny
        lda (img),y
        sta tmp2
        lda tmp
        cpx #0
        beq @done
@l:     iny
        clc
        adc (img),y
        bcc :+
        inc tmp2
:       dex
        bne @l
@done:  sta img
        lda tmp2
        sta img+1
        rts

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
        lda op
        sta ziyl
        lda op+1
        sta ziyh
        jsr call_b3b3
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
        ZPROC $8EAB             ; (zc zb ze zd zl zh are consecutive, zx.s)
        ldx #5
:       lda zc,x
        pha
        dex
        bpl :-
        jsr call_b3b3
        ldx #0
:       pla
        sta zc,x
        inx
        cpx #6
        bne :-
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
        asl
        asl
        ldx #>$7030
        bcc :+
        inx
        clc
:       adc v_col
        bcc :+
        inx
        clc
:       adc #<$7030
        bcc :+
        inx
:       sta src
        stx src+1
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
        lda #3                  ; src = img+3 + W*clip (< 256)
        ldx v_clip
        beq @noclip
:       clc
        adc v_W
        dex
        bne :-
@noclip:
        clc
        adc img
        sta src
        lda img+1
        adc #0
        sta src+1
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
        adc #<mbset             ; mask row builders, entered at 5-W
        sta vset
        lda #>mbset
        adc #0
        sta vset+1
        ldx #0
        stx mi
        bit v_hdr               ; msk = $FF when mirrored
        bpl :+
        dex
:       stx msk
        lda v_shift             ; mask origin: 8*(5-W)+x or 40+x
        clc
        bit msk
        bmi :+
        adc base8
        jmp :++
:       adc #40
:       sta k1
        sec
        sbc msk                 ; k1b = k1 (+1 when mirrored)
        sta k1b
        ; --- mask mode
        lda v_oflags
        and #2
        beq :+
        lda #<mnone
        ldx #>mnone
        bne @mset
:       lda v_hdr
        and #$10
        bne @fmtb
        lda v_clip              ; format A: skip clip bytes
        sta mi
        lda #<maska
        ldx #>maska
        bit msk
        bpl @mset
        lda #<maskam
        ldx #>maskam
        bne @mset
@fmtb:  ldx v_clip              ; format B: skip clip rows
        beq :+
        ldy #0
        jsr skipb
        sty mi
:       lda #<maskb
        ldx #>maskb
@mset:  sta mj+1
        stx mj+2
        ; --- image fetch: variant = 2*mirrored + (shift >= 4)
        lda v_shift
        cmp #4
        lda #0
        rol
        sta tmp
        ldx v_W
        ldy #0
        lda v_hdr
        and #$20
        beq @noov
        lda v_oflags
        and #4
        beq @noov
        lda $75F8
        and #2
        beq @noov
        lda msk                 ; light overlay: unshifted rows into $71D0
        and #2
        jsr setfetch
        jsr overlay
        ldx v_W                 ; then draw from there: plain, stride W+1
        inx
        ldy #0
        lda tmp
        jmp @fs
@noov:  bit msk
        bpl :+
        dex                     ; mirrored: Y starts at W-1
        txa
        tay
        inx
        lda tmp
        ora #2
        bne @fs
:       lda tmp
@fs:    stx stride+1
        sty sy
        jsr setfetch
        ; --- shift: right by 1..3 (spare 0 at irow+5) or left by 8-x
        ; into the byte before the row (0 at irow+5-W)
        lda #<(irow+5)
        sta zst+1
        lda v_shift
        sta nb+1
        beq @shd
        cmp #4
        bcs @shl
        lda tmp2
        asl
        adc #<rchain
        ldx #>rchain
        bcc :+
        inx
:       sta sj+1
        stx sj+2
        bne @shd
@shl:   eor #7
        adc #0                  ; C=1: 8-shift
        sta nb+1
        lda #<lchain
        sta sj+1
        lda #>lchain
        sta sj+2
        lda tmp2
        clc
        adc #<irow
        sta zst+1
        ldx v_W                 ; RTS after position base
        lda lpos,x
        tax
        lda lchain,x
        sta lsave
        lda #$60
        sta lchain,x
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
rowlp:  ldy sy
        jsr jfetch              ; fetch
        lda #0
zst:    sta irow+5              ; spare byte (zp operand patched)
nb:     ldx #0
        beq nosh
shlp:   clc
sj:     jsr $FFFF               ; shift chain
        dex
        bne shlp
nosh:
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
        sta lchain,x
:       rts

        .segment "RODATA3"
mul5:   .byte 0, 5, 10, 15, 20, 25, 30
mul9:   .byte 0, 9, 18, 27, 36, 45, 54
lpos:   .byte 2, 4, 6, 8, 10, 12        ; lchain offset after position 5-W
flo:    .byte <fetchn0, <fetchm0
fhi:    .byte >fetchn0, >fetchm0
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
        .segment "CODE3"

; setfetch: A = fetch variant (0/1 plain o=0/1, 2/3 mirrored) -> fj, vfetch
setfetch:
        tay
        lsr                     ; X = 0 plain, 1 mirrored
        tax
        tya
        and #1
        clc
        adc tmp2                ; entry = position 5-W+o
        tay
        lda mul5,y
        cpx #1
        bcc :+
        lda mul9,y
        clc
:       adc flo,x
        sta vfetch
        lda fhi,x
        adc #0
        sta vfetch+1
        rts
jfetch: jmp $FFFF               ; patched jumps (no JMP (ind) page bug)
jset:   jmp $FFFF
vfetch = jfetch+1
vset   = jset+1


; skipb: skip X format-B mask rows from offset Y (Y = offset after)
skipb:  iny
        lda (mp),y
        iny
        asl
        bcs skipb
        dex
        bne skipb
        rts

; ---- row fetch routines (Y = row offset, +W-1 when mirrored)
; Entered at position 5-W+o, they always run to position 5; with o = 0 the
; last byte read is outside the row and is overwritten by the spare 0.
fetchn0:
        .repeat 6, P
        lda (src),y
        sta irow+P
        iny
        .endrep
        rts
fetchm0:
        .repeat 6, P
        lda (src),y
        tax
        lda $5B00,x
        sta irow+P
        dey
        .endrep
        rts

; ---- shift chains (carry clear on entry)
rchain:                         ; entered at 2*(5-W)
        .repeat 6, P
        ror irow+P
        .endrep
        rts
lchain:                         ; RTS patched after position 5-W
        .repeat 6, P
        rol irow+5-P
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
mband:  stx t_lo                 ; further runs: AND a second row in
        ldx #5
:       lda mrow,x
        sta mrow2,x
        dex
        bpl :-
        ldx t_lo
        jsr jset
        ldx #5
:       lda mrow,x
        and mrow2,x
        sta mrow,x
        dex
        bpl :-
        rts

; ---- mask rows.  Bit positions: row byte j = mrow+5-W+j.  (The data's
; runs end inside W*8 pixels, so no clipping is needed.)
; exploding: no mask
mnone:  ldx #0                  ; empty run: all $FF
        ldy #0
        jmp jset
; format A, plain: run = [k1 + (m&7), + m>>3)
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
        jmp jset
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
        jmp jset
; format B: [x0][len|more][gap][len]...  Plain runs go right from k1+x0,
; mirrored ones left from k1-x0 (msk = $FF negates the steps).
maskb:  ldy mi
        lda (mp),y
        eor msk
        clc
        adc k1b
        jsr mbrun
        jsr jset
mbmore: bit t_len
        bpl mbdone
        ldy mi
        iny
        lda (mp),y              ; gap from the end of the run
        jsr mbstep
        jsr mbrun
        jsr mband
        jmp mbmore
mbdone: inc mi
        rts
; A = run start (plain) / end (mirrored); reads the length -> X = lo, Y = hi
mbrun:  sta t_e
        iny
        lda (mp),y
        sty mi
        sta t_len
        and #$7F
        ldy t_e
        sty t_f
        jsr mbstep              ; t_f = far end of the run
        sta t_f
        bit msk
        bmi :+
        ldx t_e
        ldy t_f
        rts
:       ldx t_f
        ldy t_e
        rts
; A = t_f +- A
mbstep: sta t_y
        lda msk
        asl
        lda t_y
        eor msk
        adc t_f
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
        lda v_gap               ; right: column W+gap gets LK[D7509&7]
        clc
        adc #5                  ; (position base+W = 5)
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

; S8E48 path: build the unshifted image in $71D0 (rows of W+1) with the
; normal row fetch (variant already set), patch the light overlay into it
overlay:
        lda #<$71D0
        sta t_lo                ; t_lo/t_hi as a pointer into $71D0
        lda #>$71D0
        sta t_hi
        ldy #0
        bit msk
        bpl :+
        ldy v_W
        dey
:       sty sy
        lda v_H
        sta rows
@row:   ldy sy
        jsr jfetch
        lda #0
        sta irow+5
        ldx tmp2
        ldy #0
:       lda irow,x
        sta (t_lo),y
        iny
        inx
        cpx #6
        bne :-
        tya
        clc
        adc t_lo
        sta t_lo
        bcc :+
        inc t_hi
:       lda sy
        clc
        adc v_W
        sta sy
        dec rows
        bne @row
        ; end of the mask data (first row after clip at mp+mi)
        ldy mi
        lda v_hdr
        and #$10
        bne :+
        tya
        clc
        adc v_H
        tay
        jmp @fe
:       ldx v_H
        jsr skipb
@fe:    tya
        clc
        adc mp
        sta src
        lda mp+1
        adc #0
        sta src+1
        ldy #0                  ; src = overlay block (Y = offset)
        bit v_hdr
        bpl :+
        lda (src),y             ; mirrored: skip to its block
        tay
:       iny
        lda v_oflags
        and #8
        beq :+
        tya                     ; second list
        clc
        adc (src),y
        tay
:       iny
        lda (src),y             ; n pairs (value, offset)
        sta rows
        ldx v_W                 ; thr = clip*(W+1) & $FF (0: no clip;
        inx                     ; the data has no offset 0)
        lda #0
:       clc
        adc v_clip
        dex
        bne :-
        sta t_bl
@p1:    iny                     ; value
        iny                     ; offset
        lda (src),y
        cmp t_bl
        beq :+
        bcc :+
        sbc t_bl
        tax
        dey
        lda (src),y
        sta $71D0,x
        iny
:       dec rows
        bne @p1
        lda #<$71D0
        sta src
        lda #>$71D0
        sta src+1
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
        txa                     ; (the high byte stays $8F)
        clc
        adc #<($8F12+2)
        sta v_8F10
        lda T_8F12+1,x
        sta $7605
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
        ldx #0
        ldy #0
@seg:   lda lmp_lo,x            ; destination - source offset
        sta ze
        lda lmp_hi,x
        sta zd
:       lda (zl),y
        sta (ze),y
        iny
        tya
        cmp lmp_end,x
        bne :-
        inx
        cpx #4
        bne @seg
        rts
        .segment "RODATA3"
lmp_lo: .byte <(ZV_BDE2), <(ZV_BE05-3), <(ZV_BE45-8), <(ZV_BEA3-23)
lmp_hi: .byte >(ZV_BDE2), >(ZV_BE05-3), >(ZV_BE45-8), >(ZV_BEA3-23)
lmp_end:.byte 3, 8, 23, 38
        .segment "CODE3"
