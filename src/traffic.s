; traffic.s - the traffic AI (computer cars): Spectrum $AB47-$BA55 and the
; turning code $E833-$E94C (+ its table $E94D).  Spec: notes R6.md / R7.md 2.
;
; Translation notes
; -----------------
; * IY (the car record, 12 bytes) stays in ziyl/ziyh.  For speed and size the
;   record is copied to zero page (rc0..rc11, rload) when a car's update
;   starts and written back (rstore) when it ends; the entry points other
;   modules call do the same around the shared internal code.  Before LDBFA
;   (which reads the record) the copy is written back first (todbfa).
;   IX is always $75E1 in this code, so (ix+n) is the absolute $75E1+n.
; * The original uses both Z80 register sets.  "P" (the set that is active
;   when SAB61 starts) lives in zb zc zd ze zh zl, the other set ("alt") in
;   zb2 zc2 zd2 ze2 zh2 zl2, A' in za2.  EXX is therefore just a change of
;   names; where one routine is reached from both contexts it is either
;   written for one context and called through exx_ (swaps the two sets), or
;   it takes its arguments in private zero-page variables.
; * The side-street tables live at Spectrum $FD60-$FFFF, owned by the world
;   module as ZV_FD60.  The car records hold the Spectrum addresses (they
;   are compared with the Spectrum), so every access through a pointer whose
;   high byte is >= $FD is relocated by ZV_FD60-$FD60 (mapy / rd2).
; * Self-modified operands that carry state are ZVARs holding the Spectrum
;   values: $B100 (inc l / dec l opcode of the look-ahead), $B61F/$B63E (the
;   scan routine CALL targets, as Spectrum addresses $B4A5/$B502/$B56D/$B5BB),
;   $B63B (LD DE operand), $B457 (LD BC operand), $B161 (object code found),
;   $B8F9 (12-byte record backup) and $BA4A (token of the SUBMITS message).
;
; Interfaces of the entry points other modules use (current set = zb..zh):
;   Z_AB47  update all 15 computer cars.
;   Z_B3B3  erase car IY: zc = flags, zl2/zh2 = position.  Out: za2 = old head
;           byte, zl2/zh2 kept.  (returns "in the other set")
;   Z_B412  draw car IY: za2 = code, zl2/zh2 = position.  Out: Z = drawn,
;           NZ = blocked (then zl2/zh2 = the ghost position).
;   Z_B49A  A = (HL)|(HL+BC)|(HL+2BC)|(HL+3BC), zl/zh, zc/zb.  Z = all free.
;   Z_B0AA  A = step, zh = lane H.  Out: zh (and A) = new H.
;   Z_B83A  A = new sub-position, C flag = moved below 0, zc = flags,
;           zl2/zh2 = position.  May JMP Z_DBFA after dropping its return.
;   Z_B905 / Z_B913  record IY -> ZV_B8F9 / back (A,Y clobbered).
;   Z_B91B  zl/zh = cell, zc = scan flags -> A = ZV_B161 = object code.
;   Z_B98D  A -> zl/zh = side-street record ($FD6B/$FEB0 + 12*(A&$1F)).
;   Z_B9D2  A -> ze/zd = "12*A" exactly as the original (A = ze on exit).
;   Z_B9DD  A -> zl/zh, ze/zd.   Z_B9EE  (IY) -> table mode; zl/zh, ze/zd.
;   Z_B241  choose the turn (IY) -> rec+10.   Z_B1BC  spawn on the main road.
;   Z_B12F  zl/zh = obstacle record+1.

        .include "zx.inc"

        ZIMPORT $953B           ; RNG step (seed ZV_9560)
        ZIMPORT $BA5F           ; temporary message, inline data
        ZIMPORT $DBFA           ; car leaves the block
        ZIMPORT $DBD7           ; IX = enemy-car record of IY
        ZIMPORT $DDD3
        ZIMPORT $F36A           ; add A to the score
        ZVIMPORT $9560          ; RNG seed (2 bytes)
        ZVIMPORT $FD60          ; side-street tables $FD60-$FFFF

OFS = ZV_FD60 - $FD60           ; Spectrum table address -> Oric address

        .zeropage
rc0:    .res 12         ; working copy of the car record (IY+0..11)
rc1 = rc0+1
rc2 = rc0+2
rc5 = rc0+5
rc6 = rc0+6
rc7 = rc0+7
rc8 = rc0+8
rc9 = rc0+9
rc10 = rc0+10
rc11 = rc0+11
mp:     .res 2          ; mapped (Oric) pointer
tp:     .res 2          ; obstacle record+1 for sb12f
gp:     .res 2          ; grid pointer, low byte always 0
gl:     .res 1          ; temp position (Spectrum address)
gh:     .res 1
o1:     .res 1          ; 4-cell offsets (stride 1 or 12)
o2:     .res 1
o3:     .res 1
t0:     .res 1
t1:     .res 1
t2:     .res 1
t5:     .res 1          ; mul12 scratch
t6:     .res 1
cnt:    .res 1          ; sb9a0 loop count (the original's A')
nsub:   .res 1          ; LB7D2 new sub-position
tent:   .res 1
dirf:   .res 1          ; rec5 bit1 -> bit7, bit0 -> bit6          ; sb387: DB3A3 entry
sd:     .res 1          ; scan direction +1/-1 (SB4A5/SB502)
svl:    .res 1          ; saved HL' around the transverse scans
svh:    .res 1
ent:    .res 1          ; LE833: DE94D entry

        .segment "DATA"
        ZVAR $B100, 1           ; opcode $2C/$2D (inc l/dec l) of LB0FF
        ZVAR $B161, 1           ; object code found by SB91B
        ZVAR $B457, 2           ; ld bc,nnnn operand in SB412
        ZVAR $B61F, 2           ; call target of scan #1 (Spectrum address)
        ZVAR $B63B, 2           ; ld de,nnnn operand of scan #2
        ZVAR $B63E, 2           ; call target of scan #2
        ZVAR $B8F9, 12          ; record backup (others read +1, +5, +6/7)

        .rodata
T_B3A3: .byte $04,$00,$02,$01,$01,$04,$02,$01,$01,$01,$06,$01,$01,$01,$04,$02
T_B265: .byte $00,$00,$D0,$80,$00,$00,$D0,$20,$80,$80,$80,$80,$D0,$00,$D0,$20
        .byte $00,$00,$80,$80,$00,$00,$D0,$20,$D0,$80,$D0,$80,$D0,$00,$D0,$20
; zone thresholds for LAD43: dir 0 / dir 2
T_ZN:   .byte $32,$3A,$68,$76,$24,$FF,$39
        .byte $26,$2E,$56,$61,$26,$06,$34
T_TB:   .byte <$FD6B,<$FEB0,>$FD6B,>$FEB0
T_E94D: .byte $01,$01,$24,$24,$03,$03,$04,$04,$01,$25,$24,$27,$03,$07,$04,$05
        .byte $25,$24,$27,$03,$07,$04,$05,$01

        .code


map_z2: ldy #zl2
        bne mapy
map_g:  ldy #gl
        bne mapy
map_z:  ldy #zl
mapy:   lda 1,y
        cmp #$FD
        bcc :+
        clc
        lda 0,y
        adc #<OFS
        sta mp
        lda 1,y
        adc #>OFS
        sta mp+1
        rts
:       sta mp+1
        lda 0,y
        sta mp
        rts

; rd2: A = (zh2:zl2), flags N/Z from the value.  Y = 0.
rd2:    jsr map_z2
        ldy #0
        lda (mp),y
        rts

; exx_: swap zc..zh with zc2..zh2 (A kept).
exx_:   pha
        ldx #5
:       lda zc,x
        ldy zc2,x
        sta zc2,x
        sty zc,x
        dex
        bpl :-
        pla
        rts

; p4base: X = low byte of the stride ($FF = -1, $F4 = -12).  mp = head
; pointer.  Sets o1/o2/o3 = s, 2s, 3s and mp -= 3s, so the 4 cells of an
; object are (mp),o3 (head) .. (mp),0.
p4base: cpx #$FF
        bne c_p4base_12
        lda #1
        sta o1
        lda #2
        sta o2
        lda #3
        bne c_p4base_s
c_p4base_12:    lda #12
        sta o1
        lda #24
        sta o2
        lda #36
c_p4base_s:     sta o3
        lda mp
        sec
        sbc o3
        sta mp
        bcs :+
        dec mp+1
:       rts

or4:    ldy #0
        lda (mp),y
        ldy o1
        ora (mp),y
        ldy o2
        ora (mp),y
        ldy o3
        ora (mp),y
        rts

clr4:   lda #0
        tay
        sta (mp),y
        ldy o1
        sta (mp),y
        ldy o2
        sta (mp),y
        ldy o3
        sta (mp),y
        rts

; mul12: the original SB9D2: A -> A = E, X = D.
mul12:  asl a
        asl a
        sta t5
        asl a
        ldx #0
        clc
        adc t5
        bcc :+
        inx
:       rts

; rload / rstore: (IY) <-> rc0..rc11
rload:
        ldy #11
        lda (ziyl),y            ;mem
        sta rc11
        dey
        lda (ziyl),y            ;mem
        sta rc10
        dey
        lda (ziyl),y            ;mem
        sta rc9
        dey
        lda (ziyl),y            ;mem
        sta rc8
        dey
        lda (ziyl),y            ;mem
        sta rc7
        dey
        lda (ziyl),y            ;mem
        sta rc6
        dey
        lda (ziyl),y            ;mem
        sta rc5
        ldy #2
        lda (ziyl),y            ;mem
        sta rc2
        dey
        lda (ziyl),y            ;mem
        sta rc1
        dey
        lda (ziyl),y            ;mem
        sta rc0
        sty gp                  ; (grid pointer low byte stays 0)
        rts
rstore:
        ldy #11
        lda rc11
        sta (ziyl),y            ;mem
        dey
        lda rc10
        sta (ziyl),y            ;mem
        dey
        lda rc9
        sta (ziyl),y            ;mem
        dey
        lda rc8
        sta (ziyl),y            ;mem
        dey
        lda rc7
        sta (ziyl),y            ;mem
        dey
        lda rc6
        sta (ziyl),y            ;mem
        dey
        lda rc5
        sta (ziyl),y            ;mem
        ldy #1
        lda rc1
        sta (ziyl),y            ;mem
        dey
        lda rc0
        sta (ziyl),y            ;mem
        rts
; leave the block: write the record back, drop SAB61's body frame, LDBFA
todbfa: jsr rstore
        pla
        pla
        jmp Z_DBFA

; ===========================================================================
; SAB47 - update all computer cars
        ZPROC $AB47
        lda #<$779E
        sta ziyl
        lda #>$779E
        sta ziyh
        lda #<$75E1
        sta zixl
        lda #>$75E1
        sta zixh
        lda #$0F
        sta $7603
c_AB47_l:     jsr Z_AB61
        clc
        lda ziyl
        adc #12
        sta ziyl
        bcc :+
        inc ziyh
:       dec $7603
        bne c_AB47_l
rt_317: rts

; ===========================================================================
; SAB61 - update one car (IY)
        ZPROC $AB61
        ldy #1
        lda (ziyl),y            ;mem
        sta zc
        bmi :+
        jmp LB16A
:       and #3
        bne rt_317
:       jsr rload
        jsr ab61
        jmp rstore
ab61:   lda rc10
        and #$20
        beq :+
        jsr sba04
:       lda #0
        sta $7604
        lda rc5
        sta zb
        ror a                   ; dirf: N = rec5 bit1 (sense), V = bit0 (axis)
        ror a
        ror a
        sta dirf
        lda rc7
        sta zh2
        lda rc6
        sta zl2
        ldx #$FF
        bit dirf
        bpl :+
        ldx #1
:       stx zd2
        bvs LAB90
        lda zh2
        sec
        sbc #$5C
        sta ze
        lda $7601
        jmp LABBA
LAB90:  lda rc6                 ; transverse: e = ((L - $66) >> 2) + 1 + t
        sec
        sbc #$66
        bit zc
        bvc :+
        lda rc9                 ; (rc9 + $64) - $66
        sec
        sbc #2
:       lsr a
        lsr a
        sec
        adc #0
        sta ze
        lda $7602
        and #3
        cmp #3
        bne :+
        lda #2
:       clc
        adc ze
        sta ze
        lda $7602
LABBA:  asl a
        asl a
        asl a
        and #$18
        ora ze
        asl a
        tax                     ; X = offset into D7575
        bit dirf
        bvs LABF2
        lda rc2
        and #2
        bne LABD2
        lda $7603
        and #7
        bne LABF2
        lda #8
        bne LABF3
LABD2:  lda rc10                ; special car
        and #$20
        eor #$20
        beq LABF3
        lda rc2                 ; bit2 ? D7510 : D7511
        lsr a
        lsr a
        and #1
        eor #1
        tay
        lda $7510,y
        jmp LABF3
LABF2:  lda $7575,x
LABF3:  sta $7600
        lda $7576,x
        bpl LAC02
        bit dirf
        bpl LAC02
        eor #3
LAC02:  sta ze2
        lda rc10
        lsr a
        bcc :+
        jmp LE833
:       bit dirf
        bvc :+
        jmp LB5D7
:       ldx #$2D
        bit dirf
        bpl :+
        dex
:       stx ZV_B100
        lda rc0
        beq LAC48
        ldx zh2                 ; ghost lane
        inx
        lda zc
        and #$20
        beq :+
        dex
        dex
:       jsr look
        beq LAC48
        jsr sb106
        bne LAC48
        jsr min1
LAC48:  ldx zh2
        jsr look
        bne LAC6D
        lda $7604
        and #2
        bne LAD43j
        GET_R                   ; ld a,r ; and 0 (never taken)
        lda rc10
        bmi LAC7D
LAD43j: jmp LAD43
LAC6D:  jsr sb106
        bne LAD43j
        jsr min1
        jmp LAC7D
; look ahead in lane X (SB0F8): d' = closeness, c'/b' = hit cell, Z = clear
look:   lda dirf
        and #$80
        ldy zl2
        jsr sb0f8
        stx zd2
        sty zc2
        ldx gp+1
        stx zb2
        tax
        rts
; D7600 = max(D7600, 1)
min1:   lda $7600
        bne :+
        inc $7600
:       rts

; --- lane change decision -------------------------------------------------
LACA9:  lda $7604               ; no lane change: just follow the obstacle
        and #2
        beq :+
        jsr sb12f_p
:       jmp LAD43
LAC7D:  lda rc0
        bne LAD43j
        lda rc2
        and #2
        beq LAC9E
        lda $75F2
        lsr a
        bcs LACC1
        lda $75EC
        and #$21
        bne LAC9E
        lda $75F1
        and #$0A
        beq LACC1
LAC9E:  lda zl2                 ; lane changes only in two zones
        cmp #$50
        bcs LACB3
        cmp #$14
        bcs LACC1
        bcc LACA9
LACB3:  sta ze
        lda $75F5
        clc
        adc #$78
        cmp ze
        bcs LACA9
        adc #$3C
        cmp ze
        bcc LACA9
LACC1:  lda $7604
        sta zd
        and #2
        bne LACDF
        lda #1                  ; turning: right -> centre side, left -> kerb
        bit rc10
        bvs :+
        lda #2
:       tax
        and ze2
        bne LAD43
        txa
        and #2
        bpl LACEE
LACDF:  lda ze2                 ; obstacle: prefer the centre side
        and #1
        beq LACEE
LACE6:  lda ze2
        and #2
        bne LACA9
        lda #2
LACEE:  sta ze
        eor zb
        sta za2                 ; side
        ldx zh2
        dex
        and #2
        bne :+
        inx
        inx
:       lda rc2
        and #2
        beq LAD08
        lda #4
        sta zb2
        lda rc11
        cmp #4
        ldy zl2
        bcs LAD16
LAD08:  lda #4
        bit dirf
        bpl :+
        lda #$14
:       clc
        adc zl2
        tay
        lda #$1C
        sta zb2
LAD16:  jsr sb162
        beq LAD2E
        lda rc2
        and #2
        beq jca9
        lda zd
        and #2
        beq jca9
        lda ze
        and #2
        beq LACE6
jca9:   jmp LACA9
LAD2E:  lda za2                 ; start the lane change
        and #2
        eor #2
        asl a
        asl a
        ora #4
        sta t0
        lda zc
        and #$F7
        ora t0
        sta zc
        sta rc1
        lda $7604
        ora #$10
        sta $7604
        jmp LB033
; --- zones along the lane: stop lines and the junction ----------------------
LAD43:  ldy #0
        bit dirf
        bpl :+
        ldy #7
:       lda zl2
        cmp T_ZN+0,y
        bcc j033
        cmp T_ZN+1,y
        bcc LAD75
        cmp T_ZN+2,y
        bcc j033
        sta ze
        lda $75F5
        clc
        adc T_ZN+3,y
        cmp ze
        bcs LAD5F
        adc T_ZN+4,y
        cmp ze
        bcs j033
        adc #8
        cmp ze
        bcc j033
        adc T_ZN+5,y            ; (C set)
        sta za2                 ; stop line B
        lda $75FB
        jmp LAD7C
LAD5F:  bit dirf
        bpl :+
        jmp LAF96
:       jmp LAE23
LAD75:  sta ze                  ; stop line A
        lda T_ZN+6,y
        sta za2
        lda $75FC
LAD7C:  ora #0
        bpl j033
        lda rc1
        and #4
        beq LAD90
        lda rc0
        bne LAD90
        lda rc1
        and #$FB
        sta rc1
LAD90:  lda za2
        sec
        sbc #7
        cmp ze
        bne LADA3
        lda rc11
        cmp #3
        bcs j033
        lda #0
        sta rc11
        rts
j033:   jmp LB033
; brake
LADA3:  ldx rc11
        dex
        bmi LADDF
        bne LADB5
        lda $7600
        beq LADBF
        bne j036
LADB5:  cpx #4
        bcc LADBF
        dec rc11
        dec rc11
LADBF:  dec rc11
        jmp LB036
; decelerate to a stop
LADC5:  lda rc11
        beq :+
        dec rc11
        beq :+
        dec rc11
        jmp LB036
:       rts
LADDF:  lda $7600
        beq j036
        inc rc11
j036:   jmp LB036
; --- junction approach, dir 0 (A = F5+$76, ze = L) --------------------------
LAE23:  sta t1
        lda rc10
        sta zl
        bpl LAE3B
        lda zc
        and #4
        bne LAE3B
        lda zc                  ; indicator on
        ora #4
        and #$F7
        bit zl
        bvc :+
        ora #8
:       sta zc
        sta rc1
LAE3B:  lda $75F2
        lsr a
        bcs jaf65
        lda $75EC
        lsr a
        bcc LAE49
        jmp LAEE8
LAE49:  lda zl
        and #$20
        bne jadc5
        bit zl
        bpl j033b
        jsr cap6
        lda $75F5
        sec
        sbc #4
        tax
        bit zl
        bvc LAE74
        bit $7602
        bmi :+
        txa
        lsr a
        tax
:       lda ze2
        and #1
        bpl LAE76
LAE74:  lda ze2
        and #2
LAE76:  bne LAEA6x
        lda $75F1
        and #2
        bne LAE98
LAE7F:  lda rc10                ; abort the turn
        and #$7F
        sta rc10
        lda rc1
        and #$FB
        sta rc1
        bit zl
        bvc j033b
        lda zl
        and #$10
        bne j033b
        lda $75FD
        and #$FE
        sta $75FD
j033b:  jmp LB033
jadc5:  jmp LADC5
jaf65:  jmp LAF65
LAE98:  lda $7602
        and #3
        cmp #2
        beq LAEA6x
        dex
        dex
        dex
        dex
LAEA6x: txa
        clc
        adc #$67
LAEA8:  sec
        sbc ze
        beq LAEC6
        tax
        lda zl
        and #$10
        beq LAEBE
        jsr token
        bcs jadc5
LAEBE:  cpx #$F8
        bcc j033b
jada3:  jmp LADA3
LAEC6:  lda rc0
        bne LAE7F
LAECC:  lda zc                  ; start the turn
        and #$F7
        ora #4
        bit zl
        bvc :+
        ora #8
:       sta zc
        sta rc1
        lda rc10
        ora #3
        sta rc10
        lda #0
        sta rc11
        jmp LE833
; give-way check (D75EC bit0; never seen in play)
LAEE8:  lda t1
        sec
        sbc #$0E
        cmp ze
        bcc jada3
        beq LAEF1
        jmp LAE49
LAEF1:  lda $75E7
        and #$1E
        bne LAF3E
        lda $75F5
        lsr a
        lsr a
        sec
        sbc #1
        bit rc10
        bpl LAF11
        bvs :+
        lda #1
        bne LAF11
:       lsr a
        clc
        adc #1
LAF11:  sta cnt
        lda zl2
        sta svl
        lda zh2
        sta svh
        lda #$67
        ldx #4
        bit dirf
        bmi :+
        lda $75F5
        clc
        adc #$61
        ldx #$FC
:       sta t2
        stx nsub
LAF26:  ldx #1
        ldy rc7
        dey
        jsr gwsc
        bne LAF60
        ldx #$FF
        ldy rc7
        iny
        jsr gwsc
        bne LAF60
        lda t2
        clc
        adc nsub
        sta t2
        dec cnt
        bne LAF26
        lda svl
        sta zl2
        lda svh
        sta zh2
LAF3E:  lda #2
        sta rc11
        lda rc10
        and #$10
        beq LAF56
        jsr token
        bcs LAF60
LAF56:  lda $7604
        and #$FE
        sta $7604
        jmp LB036
LAF60:  lda #0
        sta rc11
        rts
gwsc:   sty zh2                 ; scan across at (Y, t2): X = 1 (+H) / $FF (-H)
        lda t2
        sta zl2
        txa
        bmi :+
        jmp sb4a5
:       jmp sb502
cap6:   lda rc11
        cmp #7
        bcc :+
        lda #6
        sta rc11
:       rts
LAF65:  lda t1                  ; (ix+17) bit0 rule set, dir 0 (never seen)
        sec
        sbc #$0E
        sta t0
        lda rc2
        and #2
        bne LAF72
        lda $75FA
        and #8
        bne LAF80
LAF72:  lda zl
        and #$10
        beq jae49
        lda t0
        cmp ze
        bcc jada3b
        bcs jae49
LAF80:  lda t0
        cmp ze
        bcc jada3b
        bne jae49
stp3:   lda rc11
        cmp #3
        bcs jada3b
        lda #0
        sta rc11
        rts
jae49:  jmp LAE49
jada3b: jmp LADA3
jafa7:  jmp LAFA7
LB003:  lda rc2                 ; (ix+17) bit0 rule set, dir 2 (never seen)
        and #2
        bne LB00F
        lda $75FA
        and #8
        bne LB01D
LB00F:  lda zl
        and #$10
        beq jafa7
        lda #$62
        cmp ze
        bcc jafa7
        bcs jada3b
LB01D:  lda #$62
        cmp ze
        bcc jafa7
        bne jada3b
        beq stp3
LAFF8:  lda #$62
        cmp ze
        bcc jafa7
        bne jada3b
        jmp LAEF1
; --- junction approach, dir 2 (ze = L) ---------------------------------------
LAF96:  lda rc10
        sta zl
        lda $75F2
        lsr a
        bcs LB003
        lda $75EC
        and #$20
        bne LAFF8
LAFA7:  lda zl
        and #$20
        bne jadc5b
        bit zl
        bpl j033c
        jsr cap6
        lda $75F5
        sec
        sbc #4
        lsr a
        tax
        bit zl
        bvs LAFCD
        ldx #0
        lda ze2
        and #2
        bpl LAFD6
LAFCD:  bit $7602
        bpl :+
        ldx #0
:       lda ze2
        and #1
LAFD6:  bne LAFF0
        lda $75F1
        and #8
        bne :+
        jmp LAE7F
:       lda $7602
        and #3
        cmp #2
        beq LAFF0
        inx
        inx
        inx
        inx
LAFF0:  txa
        clc
        adc #$67
        ldx ze
        stx zd
        sta ze
        txa
        jmp LAEA8
jadc5b: jmp LADC5
j033c:  jmp LB033
; --- move along the lane ------------------------------------------------------
LB033:  jsr sb9b1
LB036:  lda rc11
        bne :+
        rts
:
        jsr b905
        lda rc1
        sta zc
        jsr b3b3
        ldx rc11
        lda rc2                 ; special cars never crawl at 1
        and #2
        beq :+
        cpx #1
        bne :+
        inx
:       stx zc2
        txa
        lsr a
        bcc LB05E
        tax
        lda $75F8               ; odd speed: +1 on every other pass
        lsr a
        txa
        adc #0
LB05E:  beq LB09E
        tax
        lda $7604
        lsr a
        bcc :+
        ldx #0
:       txa
        bit dirf
        bmi :+
        eor #$FF
        clc
        adc #1
:       clc
        adc zl2
        sta rc6
        sta zl2
        sec
        sbc #6
        sta zb2
        lda $75F5
        clc
        adc #$C2
        cmp zb2
        bcs LB084
        jmp todbfa
LB084:  lda $7604
        and #$10
        bne LB090
        lda rc0
        beq LB09E
LB090:  ldx zc2
        cpx #3
        lda #1
        adc #0
        ldx zh2
        jsr sb0aa
        stx zh2
        stx rc7
LB09E:  jsr owncode
        sta za2
; LB82C: draw the car at zl2/zh2; if blocked, restore the backup and redraw.
LB82C:  jsr b412
        beq mv2_r
        jsr b913
        lda ZV_B8F9+6
        sta zl2
        lda ZV_B8F9+7
        sta zh2
        jmp b412
mv2_r:  rts

; ===========================================================================
; SB0AA - one step of a lane change.  Internal: X = H, A = step.  Out: X = H.
        ZPROC $B0AA
        pha
        jsr rload
        pla
        ldx zh
        jsr sb0aa
        stx zh
        jsr rstore
        lda zh
        rts
sb0aa:  sta t0                  ; step
        lda rc1                 ; bit3 ^ bit5: towards the centre line
        lsr a
        lsr a
        eor rc1
        and #8
        bne LB0D2
        lda rc0
        bne LB0CB
        sec
        sbc t0
        and #7
        sta t2
        lda rc1
        and #$20
        beq :+
        inx
        inx
:       dex
        lda t2
        bpl LB0E8
LB0CB:  sec
        sbc t0
        beq LB0E3
        bcs LB0E8
        bcc LB0E3
LB0D2:  lda rc0
        clc
        adc t0
        cmp #8
        bcc LB0E8
        lda rc1
        and #$20
        beq :+
        dex
        dex
:       inx
LB0E3:  lda rc1
        and #$FB
        sta rc1
        lda #0
LB0E8:  sta rc0
        lda rc1
        and #$DF
        cpx #$60
        bcc :+
        ora #$20
:       sta rc1
        rts
; SB0F8 - look ahead 16 cells.  X = H, Y = L, A = 0 -> start at L-3.
; LB0FF: X = count, Y = L, gp+1 = H.  Out: Z = clear (A=0); NZ: A = cell,
; X = count left (the original B), Y = L of the hit, gp+1 = H.  (gp = 0)
sb0f8:  stx gp+1
        cmp #0
        bne :+
        dey
        dey
        dey
:       ldx #16
lb0ff:  lda ZV_B100
        cmp #$2D
        beq lbf_dec
        cmp #$2C
        beq lbf_inc
:       lda (gp),y
        bne lbf_r
        dex
        bne :-
        rts
lbf_dec:
        dey
        lda (gp),y
        bne lbf_r
        dex
        bne lbf_dec
lbf_r:  rts
lbf_inc:
        iny
        lda (gp),y
        bne lbf_r
        dex
        bne lbf_inc
        rts
; SB106 - identify the obstacle at (zb2,zc2), closeness zd2; adapt D7600.
; Out: zl/zh = obstacle record+1, Z/NZ as the original.
sb106:  lda $7604
        ora #2
        sta $7604
        lda zl2
        pha
        lda zh2
        pha
        lda zc2
        sta zl2
        lda zb2
        sta zh2
        lda #0
        sta zc2
        jsr sb91b
        jsr mul12
        clc
        adc #<$7703
        sta zl
        txa
        adc #>$7703
        sta zh
        pla
        sta zh2
        pla
        sta zl2
        lda #1
        ldx zd2
        cpx #$0E
        bcc :+
        ora $7604
        sta $7604
:       cpx #9
        bcs sb12f_p
        ldy #0
        lda (zl),y
        and #1
        bne sb12f_p
        rts
; SB12F - follow the obstacle (record+1 in zl/zh, or tp for sb12f)
sb12f_p:
        lda zl
        sta tp
        lda zh
        sta tp+1
sb12f:  ldy #4
        lda (tp),y
        cmp rc5
        bne LB159
        ldy #10
        lda (tp),y
        cmp $7600
        beq :+
        bcs fo_z                ; already slower
:       tax
        beq LB151
        dex
        bne :+
        inx
:       txa
LB151:  sta $7600
fo_z:   ldy #0
        lda (tp),y
        and #1
        rts
LB159:  lda #1
        sta $7600
        rts
; SB162 - are these cells free: X = H, Y = L, zb2 = count.  Z = free.
sb162:  stx gp+1
        ldx zb2
:       lda (gp),y
        bne :+
        dey
        dex
        bne :-
        lda #0
:       rts
; ===========================================================================
; LB16A - spawn a car into an empty slot
LB16A:  lda $75F8
        and #$0A
        bne sr00
        GET_R
        sta zd
        and #$0C
        bne sr00
        jsr rload
        jsr b16a
        jmp rstore
sr00:   rts
b16a:   lda zd
        lsr a
        lsr a
        lsr a
        lsr a
        and #3
        tax                     ; X = random direction
        lda rc2
        and #2
        beq LB198
        lda rc2                 ; special car: only the hit-car, rarely
        and #4
        bne sr00
        lda $75F2
        lsr a
        bcs sr0
        lda $7611
        beq sr0
        lda $75F8
        and #$1F
        bne sr0
        tax
LB198:  stx rc5
        ldy $7606
        sty zb
        txa
        lsr a
        bcc :+
        jmp LB2D8
:
        lsr a
        bcs LB2AC
        lda $75F5
        clc
        adc #$C7
        sta rc6
        sta zc
        tya
        and #8
        bne sr0
        lda $7607
        and #7
        cmp #7
        beq sr0
b1bc:   lda $7601
        jsr sb387
        bcs sr0
        tax
        lda #0
        cpx #3
        bne :+
        lda #$20
:       sta rc1
        txa
        clc
        adc #$5D
        sta rc7
        sta zh
        lda rc6
        sta zl
        lda rc2
        and #2
        beq LB1FA
        bit $7793               ; hit-car: just behind the player
        bvs sr0
        lda $7799
        sta zh
        lda $7798
        cmp #$8C
        bcc sr0
        adc #5                  ; (C set) +6
        sta zl
        lda zh
        sta rc7
        cmp $75D6
        beq sr0
        cmp #$60
        bcc LB1FA
sr0:    rts
; LB2AC - spawn an oncoming (dir 2) car
LB2AC:  lda zb
        and #2
        bne sr0
        lda rc5
        sta zc
        lda $7607
        and #$0D
        cmp #$0D
        beq sr0
        lda $7601
        jsr sb387
        bcs sr0
        tax
        lda #$A0
        cpx #3
        bne :+
        lda #$80
:       sta rc1
        txa
        eor #$FF
        sec
        adc #$62
        sta rc7
        sta zh
        lda #6
        sta zl
LB1FA:  lda zl
        sta rc6
        tay
        lda zh
        sta gp+1
        ldx #4
:       lda (gp),y
        bne sr0
        dey
        dex
        bne :-
        ldy rc6
        jsr owncode
        sta (gp),y
        lda #$FF
        dey
        sta (gp),y
        dey
        sta (gp),y
        dey
        sta (gp),y
        sty zl
        lda #0
        sta zb
        sta rc0
        sta rc10
        lda rc1
        ora #$80
        sta rc1
        lda #3
        sta rc11
        lda rc2
        and #2
        beq b241
        jsr Z_BA5F
        .byte $38,$0B,$8A,"CLOSING IN"
        lda $779D
        clc
        adc #1
        sta rc11
; SB241 - choose what to do at the next junction -> rec+10
b241:   ldx $7607
        ldy rc5
        beq LB257
:       txa                     ; rotate the low nibble into the car's frame
        asl a
        tax
        and #$10
        beq :+
        txa
        eor #$11
        tax
:       dey
        bne :--
LB257:  stx zb
        lda ZV_9560             ; SB265 (table)
        and #$0C
        asl a
        sta t0
        txa
        and #7
        ora t0
        tay
        lda T_B265,y
        sta rc10
        lda ZV_9560
sr2:    rts
; LB2D8 - spawn a car at the far end of a side street (dir 1/3)
LB2D8:  lda #0
        sta rc10
        lda rc5
        and #2
        bne LB36C
        lda zb
        and #4
        bne sr2
        jsr b241
        lda $7602
        jsr sb387
        bcs sr2
        ldx #$40
        stx rc1
        ldx #<$FD60
        ldy #>$FD60
        bne LB2F5
LB36C:  lda zb
        lsr a
        bcs sr2
        jsr b241
        lda $7602
        jsr sb387
        bcs sr2
        ldx #$60
        stx rc1
        eor #$FF
        sec
        adc #5
        ldx #<$FEBB
        ldy #>$FEBB
LB2F5:  stx ze
        sty zd
        sta t0
        lda rc10
        bpl LB309
        ldx #4                  ; left turn: lane bit2, right: bit1
        and #$40
        beq :+
        ldx #2
:       txa
        and tent
        beq sr1
LB309:  jsr tval
        sta t1
        lda t0
        sec
        sbc t1
        asl a
        asl a
        clc
        adc #5
        sta rc9
        jsr mul12
        clc
        adc ze
        sta zl
        sta rc6
        txa
        adc zd
        sta zh
        sta rc7
        jsr map_z
        ldx #$F4
        jsr p4base
        jsr or4
        bne sr1
        ldx #0                  ; the neighbouring column (+1 dir 1, -1 dir 3)
        lda #1
        ldy rc5
        cpy #2                  ; (rc5 is 1 or 3 here)
        bcc :+
        lda #$FF
        tax
:       clc
        adc mp
        sta mp
        txa
        adc mp+1
        sta mp+1
        jsr or4
        bne sr1
        jsr map_z
        ldx #$F4
        jsr p4base
        jsr owncode
        jsr put4
        lda rc1
        ora #$80
        sta rc1
        lda #$0B
        sta rc8
        lda #1
        sta rc11
        lda #0
        sta rc0
sr1:    rts
; SB387 - random lane for a spawn: A = road type.  Out: A = lane (0..3),
; C = lane not usable, tent = the DB3A3 entry.
sb387:  pha
        jsr Z_953B
        pla
        sta zc
        and #3
        asl a
        asl a
        sta zb
        lda ZV_9560
        and #3
        sta ze
        ora zb
        tax
        lda T_B3A3,x
        sta tent
        lsr a
        lda ze
        rts
; own code ($1C - D7603)
owncode:
        lda #$1C
        sec
        sbc $7603
        rts
; t = D7602 & 3 (3 -> 2)
tval:   lda $7602
        and #3
        cmp #3
        bne :+
        lda #2
:       rts
; put4: head A at (mp),o3, $FF at o2, o1, 0
put4:   ldy o3
        sta (mp),y
        lda #$FF
        ldy o2
        sta (mp),y
        ldy o1
        sta (mp),y
        ldy #0
        sta (mp),y
        rts

        ZPROC $B1BC
        jsr rload
        jsr b1bc
        jmp rstore
        ZPROC $B241
        jsr rload
        jsr b241
        jsr rstore
        lda ZV_9560
        rts

; ===========================================================================
; SB3B3 - erase car IY from the grid (zc = flags, zl2/zh2 = position)
        ZPROC $B3B3
        jsr rload
b3b3:   ldx #$FF
        lda zc
        and #$40
        beq :+
        ldx #$F4
:       stx ze2
        lda #$FF
        sta zd2
        jsr map_z2
        ldy #0
        lda (mp),y
        sta za2                 ; A' = old head byte
        jsr p4base
        jsr clr4
        lda #0
        sta zb2
        lda rc0
        beq :+
        ldx ze2
        jsr ghost
        stx ze2
        jsr map_g
        jsr p4base
        jsr clr4
        lda #0
:       rts

; ghost: position of the car's second image (rec0 != 0) -> gl/gh,
; X = its stride code (kept, or $FF beside the main road), Y = $FD/$FE.
ghost:  ldy #$FD
        lda rc1
        and #$20
        beq :+
        iny
:       bit rc1
        bvs gh_t
        lda zl2                 ; main road: lane H+1 / H-1
        sta gl
        lda zh2
gh_pm:  jsr pm1
        sta gh
        rts
gh_t:   lda rc8
        beq gh_0
        lda zl2                 ; side street: column +1 / -1
        jsr pm1
        sta gl
        lda rc1
        and #$20
        bne :+
        lda zh2
        adc #0
        sta gh
        rts
:       lda zh2
        sbc #0
        sta gh
        rts
gh_0:   lda rc9                 ; column 0: the outer main-road lane
        clc
        adc #$64
        sta gl
        ldx #$FF
        lda $75D6
        cpy #$FE
        bcc gh_pm
        lda $75D7
        bcs gh_pm
; A +1 (Y = $FD) or -1 (Y = $FE), carry out as adc/sbc
pm1:    cpy #$FE
        bcs :+
        adc #1
        rts
:       sbc #1
        rts

; ===========================================================================
; SB412 - draw car IY (za2 = code, zl2/zh2 = position).  Z = drawn.
        ZPROC $B412
        jsr rload
b412:   ldx #$FF
        bit rc1
        bvc :+
        ldx #$F4
:       stx zc2
        lda #$FF
        sta zb2
        jsr map_z2
        jsr p4base
        jsr or4
        bne dr_r
        lda za2
        jsr put4
        lda rc0
        beq dr_r
        lda zc2
        sta ZV_B457
        lda zb2
        sta ZV_B457+1
        ldx zc2
        jsr ghost
        stx zc2
        sty zd2
        jsr map_g
        jsr p4base
        jsr or4
        beq :+
        jsr map_z2              ; blocked: undo the main cells (stride DB457)
        ldx ZV_B457
        jsr p4base
        jsr clr4
        lda gl
        sta zl2
        lda gh
        sta zh2
        lda #1
        sta ze2
dr_r:   rts
:       lda zd2
        jsr put4
        lda #0
        sta ze2
        rts

; SB49A - A = (HL)|(HL+BC)|(HL+2BC)|(HL+3BC) (current set), Z = free
        ZPROC $B49A
        lda zl
        sta gl
        lda zh
        sta gh
        lda #0
        sta t0
        ldx #4
c_B49A_l:     jsr map_g
        ldy #0
        lda (mp),y
        ora t0
        sta t0
        clc
        lda gl
        adc zc
        sta gl
        lda gh
        adc zb
        sta gh
        dex
        bne c_B49A_l
        lda t0
        rts

; ===========================================================================
; Scanners for the transverse cars (alt set: zl2/zh2 = HL, zb2 = B, zc2 = C,
; ze2/zd2 = DE, za2 = A').  Out: Z = clear, NZ = blocked.

; DB5BB - side-street car moving away from the main road
db5bb:  lda #5
        sta zb2
        bne LB5C3
LB5BF:  jsr rd2
        bne LB5CD
LB5C3:  jsr addhd2
        inc zc2
        lda zc2
        cmp #12
        beq :+
        dec zb2
        bne LB5BF
        lda #0
:       rts
LB5CD:  tay
        ldx #$80
        lda ze2
        bmi :+
        ldx #$81
:       stx zc2
        tya
        rts

; DB56D - side-street car moving towards the main road
db56d:  ldx #5
        stx zb2
        lda rc0
        beq LB57C
        inc zb2
        bne LB57C
LB579:  jsr rd2
        bne LB585
LB57C:  jsr addhd2
        dec zc2
        bmi LB597
        dec zb2
        bne LB579
        lda #0
        rts
LB585:  lda zb2
        cmp #5
        bcs LB57C
        ldx #$80
        lda ze2
        bpl :+
        ldx #$81
:       stx zc2
        lda zb2
        rts
LB597:  ldx $75D6               ; reached the main road
        lda ze2
        bpl :+
        ldx $75D7
:       txa
        clc
        adc ze2
        sta zh2
        lda zb2
        cmp #6
        bcc :+
        lda zh2
        clc
        adc ze2
        sta zh2
        dec zb2
:       lda za2
        clc
        adc #$64
        sta zl2
        lda ze2
        bmi lb51c
        bpl lb4bf
; call the scan routine whose Spectrum address is A (lo) / X (hi)
scan_disp:
        cmp #<$B56D
        beq db56d
        cmp #<$B5BB
        bne :+
        jmp db5bb
:
        cmp #<$B502
        beq sb502
        bne sb4a5
; SB4A5 (towards +H) / SB502 (towards -H), merged: sd = +1 / -1
sb502:  ldx #$FF
        .byte $2C               ; (bit abs: skips the ldx #1)
sb4a5:  ldx #1
        stx sd
        lda #5
        sta zb2
        lda #0
        sta zc2
        jsr clamp
        lda zb2
        sta $7608
        lda rc1                 ; part-way out of the lane on the scan side: B+1
        ldx sd
        bpl :+
        eor #$20
:       and #$20
        bne LB4C8
        lda rc0
        beq LB4C8
        inc zb2
        bne LB4C8
lb51c:  ldx #$FF                ; LB51C / LB4BF: scan B cells from H itself
        .byte $2C
lb4bf:  ldx #1
        stx sd
        lda #0
        sta zc2
        jsr clamp
LB4C5:  lda zh2
        sta gp+1
        ldy zl2
        lda (gp),y
        bne LB4CD
LB4C8:  lda zh2
        clc
        adc sd
        sta zh2
        dec zb2
        bne LB4C5
        lda #0
        rts
LB4CD:  bpl sc_r
        tax
        and #$40
        bne LB4D4
        txa
sc_r:   rts
LB4D4:  lda zb2                 ; side-street mouth: ignore it near the start
        ldy sd
        bmi :+
        clc
        adc #1
:       cmp $7608
        bcs LB4C8
        cpx #$FD
        txa
        bcs sc_r
:       pha
        lda #$B0                ; scan B cells along that street's row
        ldx #$FE
        ldy #$81
        bit sd
        bpl :+
        lda #$6B
        ldx #$FD
        ldy #$80
:       sta zl2
        stx zh2
        sty zc2
        pla
        and #$1F
        jsr mul12
        sta ze2
        stx zd2
        jsr addhd2
        lda zc2
        lsr a
        lda #1
        ldx #0
        bcs :+
        lda #$FF
        tax
:       sta ze2
        stx zd2
:       jsr rd2
        bne sc_r
        jsr addhd2
        dec zb2
        bne :-
        lda #0
        rts
; SB548 / SB55B - stop the scan at a kerb without a side street
clamp:  bit sd
        bmi :+
        lda $75F1
        lsr a
        bcc cl_r
        lda $75D7
        sec
        sbc zh2
        jmp cl_2
:       lda $75F1
        and #4
        beq cl_r
        lda zh2
        sec
        sbc $75D6
cl_2:   sec
        sbc #1
        beq :+
        cmp zb2
        bcs cl_r
        .byte $2C
:       lda #1
        sta zb2
cl_r:   rts
; HL' += DE'
addhd2: clc
        lda zl2
        adc ze2
        sta zl2
        lda zh2
        adc zd2
        sta zh2
        rts
; ===========================================================================
; LB5D7 - transverse cars (dir 1/3); P: zb = dir, zc = flags
LB5D7:  bit zc
        bvc LB608
        lda rc8                 ; in a side street: scan along the table
        sta zc2
        ldx #<$B5BB
        jsr cdir
        bne :+
        lda rc9
        sta za2
        ldx #<$B56D
:       stx zl
        lda #>$B56D
        sta zh
        lda #1
        ldx #0
        bit dirf
        bpl :+
        lda #$FF
        tax
:       sta ze2
        stx zd2
        jmp LB612
LB608:  lda #<$B4A5             ; crossing the main road
        ldx #>$B4A5
        bit dirf
        bpl :+
        lda #<$B502
        ldx #>$B502
:       sta zl
        stx zh
LB612:  lda zl
        sta ZV_B61F
        sta ZV_B63E
        lda zh
        sta ZV_B61F+1
        sta ZV_B63E+1
        lda ze2
        sta ZV_B63B
        lda zd2
        sta ZV_B63B+1
        lda zl2
        sta svl
        lda zh2
        sta svh
        lda zl                  ; scan #1 (ahead)
        jsr scan_disp
        beq :+
        jsr sb96a
:       lda #$DC                ; scan #2 from 3 cells / 3 rows back
        bit rc1
        bvs :+
        lda #$FD
:       clc
        adc svl
        sta zl2
        lda svh
        adc #$FF
        sta zh2
        dec za2
        dec za2
        dec za2
        lda rc8
        sta zc2
        lda ZV_B63B
        sta ze2
        lda ZV_B63B+1
        sta zd2
        lda zl
        jsr scan_disp
        beq :+
        jsr sb96a
:       lda svl
        sta zl2
        lda svh
        sta zh2
        bit zc                  ; B644
        bvc LB65C
        lda rc8
        cmp #4
        bcs j7cf
        jsr cdir
        beq LB65C
j7cf:   jmp LB7CF
LB65C:  lda $75F2
        lsr a
        bcc :+
        jmp LB785
:
        lda #8                  ; red light on this axis
        bit dirf
        bpl :+
        lda #4
:       and $75E7
        beq LB673
LB6E9:  jsr t81                 ; red light
        bcc LB75A
        bne LB673
        jmp LB704
LB673:  bit rc10
        bpl j7cf
        lda $7600
        cmp #4
        bcc :+
        lda #4
        sta $7600
:       bit rc10
        bvs LB6A3
LB68C:  lda rc0
        cmp #4
        bne LB75A
        bit zc
        bvc jaecc
        lda rc8
        bne LB75A
jaecc:  jmp LAECC
LB6A3:  bit $7601
        bmi LB68C
        lda rc10
        and #$10
        beq LB6BE
        jsr token
        bcs LB6CE
LB6BE:  bit zc
        bvs j7cf
        lda rc7
        bit dirf
        bmi :+
        cmp #$5E
        beq LB75A
        bcc j7cf
        bcs LB6DE
:       cmp #$61
        beq LB75A
        bcs j7cf
LB6DE:  lda rc0
        cmp #4
        bne LB75A
        beq jaecc
LB6CE:  lda #0
        sta $7600
        beq j7cf
; brake
LB75A:  ldx rc11
        dex
        beq LB773
        bmi LB773
        cpx #3
        bcc :+
        dec rc11
        dec rc11
:       dec rc11
        jmp LB7D2
LB773:  lda $7600
        beq LB780
        lda #1
        sta rc11
        jmp LB7D2
LB780:  lda #0
        sta rc11
LB780x: rts
j673:   jmp LB673
LB785:  bit $75FA               ; (ix+17) bit0 rule set (never seen in play)
        bmi LB7AD
        lda rc10
        and #$10
        beq j673
        jsr t81
        bcs j673
        bcc LB75A
LB7AD:  jsr t81
        beq LB780
        bcs j673
        jmp LB75A
; wait for a gap in the cross traffic
LB704:  lda #$2D
        sta ZV_B100
        ldx #$FF
        ldy $75D7
        dey
        lda zc
        and #$20
        bne :+
        ldx #1
        ldy $75D6
        iny
:       sty zh
        stx ze
        lda rc9
        clc
        adc #$7C
        sta zl
        lda $75DF
        asl a
        bit rc10
        bpl LB737
        bvs :+
        lda #0
:       lsr a
        clc
        adc #1
LB737:  jsr sb9a0
        bne LB780
        lda #0
        sta rc11
        lda rc10
        and #$10
        beq LB753
        jsr token
        bcs LB780x
LB753:  lda #1
        sta rc11
        jmp LB75A
; t81: in a side street at column 1?  Returns to LB673 / LB75A itself, or
; with flags of "rc0 cmp #2"
t81:    bit zc
        bvc :+
        lda rc8
        beq :+
        cmp #1
        bne :++
        lda rc0
        cmp #2
        rts
:       pla
        pla
        jmp LB673
:       pla
        pla
        jmp LB75A
; token: right-turn token (D75FD bit0).  C = already taken; else take it and
; clear rec10 bit4.
token:  lda $75FD
        lsr a
        bcs :+
        inc $75FD
        lda rc10
        and #$EF
        sta rc10
:       rts
; cdir: A = (flags ^ (rec5 bit1 ? $FF : 0)) & $20  (Z = moving forward)
cdir:   lda zc
        bit dirf
        bpl :+
        eor #$FF
:       and #$20
        rts
; move by `speed' sub-steps
LB7CF:  jsr sb9b1
LB7D2:  lda rc11
        beq mv_r
        jsr cdir
        tax
        lda rc0
        sta ZV_B8F9
        cpx #0
        bne LB81B
        clc
        adc rc11
        cmp #8
        bcc LB7F0
        clc
        bcc LB820
LB7F0:  tax
        beq LB7FF
        lda rc0
        beq LB7FF
        stx rc0
mv_r:   rts
LB7FF:  stx nsub
        jsr b3b3
        lda nsub
        sta rc0
        jsr b412
        beq mv_r
        lda ZV_B8F9
        sta rc0
        lda rc6
        sta zl2
        lda rc7
        sta zh2
        jmp b412
LB81B:  sec
        sbc rc11
        bcs LB7F0
        sec
LB820:  php
        pha
        jsr b3b3
        jsr b905
        pla
        plp
        jsr b83a
        jmp LB82C
; ===========================================================================
; SB83A - step to the next cell (A = sub-position, C = direction of the
; overflow, zc = flags, zl2/zh2 = position)
        ZPROC $B83A
        pha
        jsr rload
        pla
        jsr b83a
        jmp rstore
b83a:   bit zc
        bvc LB894
        bcc LB863
        and #7
        sta rc0
        inc rc8
        lda rc8
        cmp #12
        bne LB853
        pla
        pla
        jmp todbfa
LB853:  lda zc
        and #$20
LB855:  beq :+
        inc zl2
        bne LB85B
        inc zh2
        bne LB85B
:       lda zl2
        bne :+
        dec zh2
:       dec zl2
LB85B:  lda zl2                 ; (also: rec6/7 = HL')
        sta rc6
        lda zh2
        sta rc7
b83_r:  rts
LB863:  and #7
        sta rc0
        lda rc8
        beq LB877
        dec rc8
        lda zc
        eor #$FF
        and #$20
        bpl LB855
LB877:  lda rc1
        and #$BF
        sta rc1
        lda zc
        and #$BF
        sta zc
        and #$20
        bne :+
        ldx $75D6
        inx
        bne :++
:       ldx $75D7
        dex
:       stx zh2
        lda rc9
        clc
        adc #$64
        sta zl2
        bne LB85B
LB894:  bcc LB8BE
        and #7
        sta rc0
        lda zc
        and #$20
        beq LB8A2
LB8A0:  inc zh2
        inc zh2
LB8A2:  dec zh2
LB8A3:  lda zh2
        sta rc7
        sta gp+1
        ldy zl2
        lda (gp),y
        cmp #$FD
        bcs b83_r
        tax
        and #$C0
        cmp #$C0
        bne b83_r
        lda rc1
        ora #$40
        sta rc1
        lda zc
        ora #$40
        sta zc
        txa
        jsr b9ee
        lda zl
        sta zl2
        lda zh
        sta zh2
        rts
LB8BE:  and #7
        sta rc0
        lda zc
        and #$20
        beq LB8E1
        lda zh2
        cmp #$60
        bne LB8A2
        lda rc1
        and #$DF
        sta rc1
        jsr negr0
        beq :+
        dec zh2
:       dec zh2
        jmp LB8A3
LB8E1:  lda zh2
        cmp #$5F
        bne LB8A0
        lda rc1
        ora #$20
        sta rc1
        jsr negr0
        beq :+
        inc zh2
:       inc zh2
        jmp LB8A3
; rc0 = (-rc0) & 7
negr0:  lda #0
        sec
        sbc rc0
        and #7
        sta rc0
        rts

; ===========================================================================
; SB905 / SB913 - back up / restore the record
        ZPROC $B905
        jsr rload
b905:   ldx #11
:       lda rc0,x
        sta ZV_B8F9,x
        dex
        bpl :-
        ldy #3                  ; (rc3/rc4 are not loaded: never used)
        lda (ziyl),y            ;mem
        sta ZV_B8F9+3
        iny
        lda (ziyl),y            ;mem
        sta ZV_B8F9+4
        rts
        ZPROC $B913
        ldy #11
:       lda ZV_B8F9,y
        sta (ziyl),y            ;mem
        dey
        bpl :-
        rts
b913:   ldx #11
:       lda ZV_B8F9,x
        sta rc0,x
        dex
        bpl :-
        rts

; SB91B - identify the object at a cell.  Internal: zl2/zh2 = cell, zc2.
        ZPROC $B91B
        jsr exx_
        jsr sb91b
        jsr exx_
        rts
sb91b:  jsr rd2
        bpl LB966
        cmp #$FF
        beq LB92F
        tax
        and #$40
        beq LB94E
        txa
        bit zc2
        bpl LB93C
        jmp LB95E
LB92F:  bit zc2
        bmi LB952
LB933:  inc zl2
        jsr rd2
        cmp #$FF
        beq LB933
        ora #0
        bpl LB966
LB93C:  lsr a
        bcc :+
        dec zh2
        dec zh2
:       inc zh2
        jsr rd2
        bpl LB966
        jsr sb98d
        sta zl2
        stx zh2
        jsr rd2
        jmp LB966
LB94E:  txa
        and #7
        bpl LB966
LB952:
:       clc
        lda zl2
        adc #12
        sta zl2
        bcc :+
        inc zh2
:       jsr rd2
        cmp #$FF
        beq :--
        ora #0
        bpl LB966
LB95E:  lda zc2
        lsr a
        bcs c_LB95E_i
        lda zl2
        bne :+
        dec zh2
:       dec zl2
        jmp :+
c_LB95E_i:     inc zl2
        bne :+
        inc zh2
:       jsr rd2
LB966:  sta ZV_B161
        rts

; SB96A - react to an obstacle found by a transverse scan (alt set)
sb96a:  jsr sb91b
        jsr mul12
        sta ze2
        stx zd2
        clc
        adc #<$7703
        sta zl2
        sta tp
        txa
        adc #>$7703
        sta zh2
        sta tp+1
        lda zb2
        cmp #4
        beq LB97E
        cmp #2
        bcs :+
        ldy #0
        lda (tp),y
        and #1
        beq rt_2488
:       jmp sb12f
LB97E:  lda #0
        sta $7600
        lda rc11
        cmp #3
        bcs :+
rt_2488:rts
:       lda #2
        sta rc11
        rts

; SB98D - A -> table record address.  Internal: A = lo, X = hi.
        ZPROC $B98D
        jsr sb98d
        sta zl
        stx zh
        rts
sb98d:  tay
        and #$1F
        pha
        tya
        and #$20
        tay
        pla
; tadd: A -> A/X = (Y ? $FEB0 : $FD6B) + "12*A" (SB9D2)
tadd:   jsr mul12
        stx t6
        ldx #0
        cpy #0
        beq :+
        inx
:       clc
        adc T_TB,x
        pha
        lda t6
        adc T_TB+2,x
        tax
        pla
        rts

; SB9A0 - test A rows of the cross traffic (P: zl/zh = cell, ze = step)
sb9a0:  sta cnt
c_sb9a0_l:     lda zh
        sta gp+1
        ldy zl
        ldx #$34
        jsr lb0ff
        bne c_sb9a0_r
        lda zh
        clc
        adc ze
        sta zh
        dec cnt
        bne c_sb9a0_l
c_sb9a0_r:     rts

; SB9B1 - ease the speed towards D7600
sb9b1:  lda $7600
        sec
        sbc rc11
        beq :+
        bcc LB9C8
        cmp #4
        lda #1
        adc #0
        clc
        adc rc11
        sta rc11
:       rts
LB9C8:  dec rc11
        cmp #$FE
        bcs :-
        dec rc11
        rts

; SB9D2 - "multiply by 12" (exact): A -> ze/zd
        ZPROC $B9D2
        jsr mul12
        sta ze
        stx zd
        rts

; SB9DD - A -> zl/zh = (rec1 bit5 ? $FEB0 : $FD6B) + 12*A
        ZPROC $B9DD
        pha
        jsr rload
        pla
        pha
        jsr mul12               ; (DE = 12*A as the original)
        sta ze
        stx zd
        pla
b9dd:   pha
        lda rc1
        and #$20
        tay
        pla
        jsr tadd
        sta zl
        stx zh
        rts

; SB9EE - convert the position to junction-table mode (row = rec+6 - $64)
        ZPROC $B9EE
        jsr rload
        jsr b9ee
        jmp rstore
b9ee:
        lda rc6
        sec
        sbc #$64
        sta rc9
        tax
        lda #0
        sta rc8
        txa
        jsr b9dd
        lda zl
        sta rc6
        lda zh
        sta rc7
rt_2603:rts

; SBA04 - a stopped criminal car "SUBMITS" (never seen in play)
sba04:
        lda rc11
        bne rt_2603
:
        lda rc1
        ora #1
        sta rc1
        lda rc2
        and #2
        beq rt_2603
:       lda #$8A                ; token: HIT-CAR / ARM'D CAR / DRUG CAR
        sta ZV_BA4A
        lda rc2
        and #4
        beq LBA37
        jsr Z_DBD7
        dec ZV_BA4A
        ldy #0
        lda (zixl),y
        ora #$40
        sta (zixl),y
        lda rc2
        and #8
        bne LBA34
        dec ZV_BA4A
        ldy #6
        lda (zixl),y
        and #8
        bne LBA37
        jsr Z_DDD3
        lda #$32
        bne LBA39
LBA34:  jsr Z_DDD3
LBA37:  lda #$C8
LBA39:  ldx #<$75E1
        stx zixl
        ldx #>$75E1
        stx zixh
        jsr Z_F36A
        jsr Z_BA5F
        .byte $30,$08
        ZLABEL $BA4A, 1
        .byte $00,"SUBMITS"
        lda rc1
        sta zc
        rts

; ===========================================================================
; LE833 - turn a car at a junction (P: zb = rec+5, zc = flags, zl2/zh2 = pos)
LE833:  jsr b3b3
        jsr b905
        lda zb
        sta zd
        lsr a
        lsr a
        and #3
        tax                     ; X = turn phase
        bit rc10
        bvc LE85F
        inx                     ; right turn: 0 -> 1 -> 2 -> done
        cpx #3
        bne LE876
        jsr e8clr
        lda $75FD
        and #$FE
        sta $75FD
        inc zd
        ldx #0
        beq LE876
LE85F:  dex                     ; left turn: 0 -> 2 (dir-1) -> 1 -> done
        bne :+
        jsr e8clr
        ldx #0
        beq LE876
:       bpl LE876
        ldx #2
        dec zd
LE876:  txa
        asl a
        asl a
        sta ze
        lda zd
        and #3
        ora ze
        sta rc5
        lda zb
        asl a
        tax
        bit rc10
        bvc :+
        inx
:       lda T_E94D,x
        sta ent
        lsr a
        bcc LE8A5
        and #1                  ; (bit1) position +1 / -1
        jsr LB855
LE8A5:  lda ent
        and #4
        beq j82c
        lda ent
        eor zc
        and #$20
        bne LE8F6
        lda rc0
        sec
        sbc #2
        bcs LE945
        lda #6
        sta zc2
        lda zc
        and #$20
        bne LE8E7
        dec zh2
        lda $75D6
        cmp zh2
        bne LE8DB
        ldx #<$FD6B
        ldy #>$FD6B
        bne LE8CA
LE8E7:  inc zh2
        lda $75D7
        cmp zh2
        bne LE8DB
        ldx #<$FEB0
        ldy #>$FEB0
LE8CA:  lda rc1                 ; enter the side-street table
        ora #$40
        sta rc1
        lda #0
        sta rc8
        lda zl2
        stx zl2
        sty zh2
        sec
        sbc #$64
        sta rc9
        jsr mul12
        sta ze2
        stx zd2
        jsr addhd2
LE8DB:  jsr LB85B
        lda zc2                 ; (6)
LE945:  and #7
        sta rc0
j82c:   jmp LB82C
LE8F6:  lda rc0
        clc
        adc #2
        cmp #8
        bcc LE945
        lda zc
        and #$20
        bne LE92E
        bit zc
        bvc LE921
        ldx $75D6
        inx
LE908:  stx zh2
        lda rc9
        clc
        adc #$64
        sta zl2
        lda rc1
        and #$BF
        sta rc1
LE914:  jsr LB85B
        lda #0
        beq LE945
LE921:  inc zh2
        lda zh2
        cmp #$60
        bne LE914
        lda rc1
        ora #$20
        sta rc1
        bne LE914
LE92E:  bit zc
        bvc LE938
        ldx $75D7
        dex
        bne LE908
LE938:  dec zh2
        lda zh2
        cmp #$5F
        bne LE914
        lda rc1
        and #$DF
        sta rc1
        jmp LE914

; rec+10 &= ~$81 ; rec+1 &= ~4
e8clr:
        lda rc10
        and #$7E
        sta rc10
        lda rc1
        and #$FB
        sta rc1
        rts
