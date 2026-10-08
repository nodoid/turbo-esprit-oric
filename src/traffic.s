; traffic.s - the traffic AI (computer cars): Spectrum $AB47-$BA55 and the
; turning code $E833-$E94C (+ its table $E94D).  Spec: notes R6.md / R7.md 2.
;
; Translation notes
; -----------------
; * IY (the car record, 12 bytes) stays in ziyl/ziyh and is used as (ziyl),y.
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
;   high byte is >= $FD is relocated by ZV_FD60-$FD60 (MAP / rd2).
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
tent:   .res 1          ; sb387: DB3A3 entry
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
T_E94D: .byte $01,$01,$24,$24,$03,$03,$04,$04,$01,$25,$24,$27,$03,$07,$04,$05
        .byte $25,$24,$27,$03,$07,$04,$05,$01

        .code

; MAP lo,hi : mp = Oric address of the Spectrum address hi:lo.
.macro MAP lo, hi
        .local ok, done
        lda hi
        cmp #$FD
        bcc ok
        clc
        lda lo
        adc #<OFS
        sta mp
        lda hi
        adc #>OFS
        sta mp+1
        jmp done
ok:     sta mp+1
        lda lo
        sta mp
done:
.endmacro

map_z2: MAP zl2, zh2
        rts
map_g:  MAP gl, gh
        rts
map_z:  MAP zl, zh
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
        bne @12
        lda #1
        sta o1
        lda #2
        sta o2
        lda #3
        bne @s
@12:    lda #12
        sta o1
        lda #24
        sta o2
        lda #36
@s:     sta o3
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
@l:     jsr Z_AB61
        clc
        lda ziyl
        adc #12
        sta ziyl
        bcc :+
        inc ziyh
:       dec $7603
        bne @l
        rts

; ===========================================================================
; SAB61 - update one car (IY)
        ZPROC $AB61
        ldy #1
        lda (ziyl),y
        sta zc
        bmi :+
        jmp LB16A
:       and #3
        beq :+
        rts
:       ldy #10
        lda (ziyl),y
        and #$20
        beq :+
        jsr Z_BA04
:       lda #0
        sta $7604
        ldy #5
        lda (ziyl),y
        sta zb
        ldy #7
        lda (ziyl),y
        sta zh2
        ldy #6
        lda (ziyl),y
        sta zl2
        ldx #$FF
        lda zb
        and #2
        beq :+
        ldx #1
:       stx zd2
        lda zb
        lsr a
        bcc LABB4
        ldy #6                  ; transverse car
        lda (ziyl),y
        bit zc
        bvc LAB9C
        ldy #9
        lda (ziyl),y
        clc
        adc #$64
LAB9C:  sec
        sbc #$66
        lsr a
        lsr a
        clc
        adc #1
        sta ze
        lda $7602
        sta zd
        and #3
        cmp #3
        bne :+
        lda #2
:       clc
        adc ze
        sta ze
        lda zd
        jmp LABBA
LABB4:  lda zh2
        sec
        sbc #$5C
        sta ze
        lda $7601
LABBA:  asl a
        asl a
        asl a
        and #$18
        ora ze
        asl a
        tax                     ; X = offset into D7575
        sta ze
        lda #0
        sta zd
        lda zb
        lsr a
        bcs LABF2
        ldy #2
        lda (ziyl),y
        and #2
        beq LABE7
        ldy #10
        lda (ziyl),y
        and #$20
        beq :+
        lda #0
        beq LABF3
:       ldy #2
        lda (ziyl),y
        and #4
        beq :+
        lda $7510
        jmp LABF3
:       lda $7511
        jmp LABF3
LABE7:  lda $7603
        and #7
        bne LABF2
        lda #8
        bne LABF3
LABF2:  lda $7575,x
LABF3:  sta $7600
        ldy $7576,x
        tya
        bpl LAC02
        lda zb
        and #2
        beq :+
        tya
        eor #3
        tay
:       tya
LAC02:  sta ze2
        ldy #10
        lda (ziyl),y
        lsr a
        bcc :+
        jmp LE833
:       lda zb
        lsr a
        bcc :+
        jmp LB5D7
:       ldx #$2D
        lda zb
        and #2
        beq :+
        ldx #$2C
:       stx ZV_B100
        ldy #0
        lda (ziyl),y
        beq LAC48
        ldx zh2                 ; ghost lane
        inx
        lda zc
        and #$20
        beq :+
        dex
        dex
:       lda zb
        and #2
        ldy zl2
        jsr sb0f8
        stx zd2
        sty zc2
        ldx gp+1
        stx zb2
        tax
        beq LAC48
        jsr sb106
        bne LAC48
        lda $7600
        bne LAC48
        lda #1
        sta $7600
LAC48:  lda zb
        and #2
        ldx zh2
        ldy zl2
        jsr sb0f8
        stx zd2
        sty zc2
        ldx gp+1
        stx zb2
        tax
        bne LAC6D
        lda $7604
        and #2
        beq :+
        jmp LAD43
:       GET_R                   ; ld a,r ; and 0 (never taken)
        ldy #10
        lda (ziyl),y
        bmi LAC7D
        jmp LAD43
LAC6D:  jsr sb106
        beq :+
        jmp LAD43
:       lda $7600
        bne LAC7D
        lda #1
        sta $7600

; --- lane change decision -------------------------------------------------
LAC7D:  ldy #0
        lda (ziyl),y
        beq :+
        jmp LAD43
:       ldy #2
        lda (ziyl),y
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
LAC9E:  lda zl2
        cmp #$50
        bcs LACB3
        cmp #$14
        bcs LACC1
LACA9:  lda $7604
        and #2
        beq :+
        jsr sb12f_p
:       jmp LAD43
LACB3:  sta ze
        lda $75F5
        clc
        adc #$78
        cmp ze
        bcs LACA9
        clc
        adc #$3C
        cmp ze
        bcc LACA9
LACC1:  lda $7604
        sta zd
        and #2
        bne LACDF
        ldy #10
        lda (ziyl),y
        and #$40
        bne LACD6
        lda ze2
        and #2
        bne LACDn
        lda #2
        bne LACEE
LACD6:  lda ze2
        and #1
        bne LACDn
        lda #0
        beq LACEE
LACDn:  jmp LAD43
LACDF:  lda ze2
        and #1
        beq LACEE
LACE6:  lda ze2
        and #2
        beq :+
        jmp LACA9
:       lda #2
LACEE:  sta ze
        eor zb
        sta za2                 ; A' = side
        ldx zh2
        dex
        and #2
        bne :+
        inx
        inx
:       ldy #2
        lda (ziyl),y
        and #2
        beq LAD08
        lda #4
        sta zb2
        ldy #11
        lda (ziyl),y
        cmp #4
        ldy zl2
        bcs LAD16
LAD08:  ldy #5
        lda (ziyl),y
        and #2
        beq :+
        lda #$14
        bne :++
:       lda #4
:       clc
        adc zl2
        tay
        lda #$1C
        sta zb2
LAD16:  jsr sb162
        beq LAD2E
        ldy #2
        lda (ziyl),y
        and #2
        bne :+
        jmp LACA9
:       lda zd
        and #2
        bne :+
        jmp LACA9
:       lda ze
        and #2
        bne :+
        jmp LACE6
:       jmp LACA9
LAD2E:  lda za2
        sta t0
        lda #0
        sta za2
        lda zc
        ora #$0C
        sta zc
        lda t0
        and #2
        beq :+
        lda zc
        and #$F7
        sta zc
:       lda zc
        ldy #1
        sta (ziyl),y
        lda $7604
        ora #$10
        sta $7604
        jmp LB033

; --- zones along the lane: stop lines and the junction ----------------------
LAD43:  ldx zl2
        lda zb
        and #2
        beq :+
        jmp LADEC
:       txa
        cmp #$32
        bcs :+
        jmp LB033
:       cmp #$3A
        bcc LAD75
        cmp #$68
        bcs :+
        jmp LB033
:       sta ze
        lda $75F5
        clc
        adc #$76
        cmp ze
        bcc :+
        jmp LAE23
:       clc
        adc #$24
        cmp ze
        bcc :+
        jmp LB033
:       clc
        adc #8
        cmp ze
        bcs :+
        jmp LB033
:       sta za2
        lda $75FB
        jmp LAD7C
LAD75:  sta ze
        lda #$39
        sta za2
        lda $75FC
LAD7C:  ora #0
        bmi :+
        jmp LB033
:       ldy #1
        lda (ziyl),y
        and #4
        beq LAD90
        ldy #0
        lda (ziyl),y
        bne LAD90
        ldy #1
        lda (ziyl),y
        and #$FB
        sta (ziyl),y
LAD90:  lda za2
        sec
        sbc #7
        cmp ze
        bne LADA3
        ldy #11
        lda (ziyl),y
        cmp #3
        bcc :+
        jmp LB033
:       lda #0
        sta (ziyl),y
        rts
; brake
LADA3:  ldy #11
        lda (ziyl),y
        sec
        sbc #1
        bmi LADDF
        bne LADB5
        lda $7600
        beq LADBF
        jmp LB036
LADB5:  cmp #4
        bcc LADBF
        lda (ziyl),y
        sec
        sbc #2
        sta (ziyl),y
LADBF:  ldy #11
        lda (ziyl),y
        sec
        sbc #1
        sta (ziyl),y
        jmp LB036
; decelerate to a stop
LADC5:  ldy #11
        lda (ziyl),y
        bne :+
        rts
:       sec
        sbc #1
        sta (ziyl),y
        bne :+
        rts
:       sec
        sbc #1
        sta (ziyl),y
        jmp LB036
LADDF:  lda $7600
        beq :+
        ldy #11
        lda (ziyl),y
        clc
        adc #1
        sta (ziyl),y
:       jmp LB036

LADEC:  txa
        cmp #$26
        bcs :+
        jmp LB033
:       cmp #$2E
        bcc LAE19
        cmp #$56
        bcs :+
        jmp LB033
:       sta ze
        lda $75F5
        clc
        adc #$61
        cmp ze
        bcc :+
        jmp LAF96
:       clc
        adc #$26
        cmp ze
        bcc :+
        jmp LB033
:       clc
        adc #8
        cmp ze
        bcs :+
        jmp LB033
:       clc
        adc #7
        sta za2
        lda $75FB
        jmp LAD7C
LAE19:  sta ze
        lda #$34
        sta za2
        lda $75FC
        jmp LAD7C

; --- junction approach, dir 0 (A = F5+$76, ze = L) --------------------------
LAE23:  sta t1
        ldy #10
        lda (ziyl),y
        sta zl
        bpl LAE3B
        lda zc
        and #4
        bne LAE3B
        lda zc
        ora #4
        and #$F7
        bit zl
        bvc :+
        ora #8
:       sta zc
        ldy #1
        sta (ziyl),y
LAE3B:  lda $75F2
        lsr a
        bcc :+
        jmp LAF65
:       lda $75EC
        lsr a
        bcc LAE49
        jmp LAEE8
LAE49:  lda zl
        and #$20
        beq :+
        jmp LADC5
:       bit zl
        bmi :+
        jmp LB033
:       ldy #11
        lda (ziyl),y
        cmp #7
        bcc :+
        lda #6
        sta (ziyl),y
:       lda $75F5
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
        jmp LAE76
LAE74:  lda ze2
        and #2
LAE76:  bne LAEA6x
        lda $75F1
        and #2
        bne LAE98
LAE7F:  ldy #10
        lda (ziyl),y
        and #$7F
        sta (ziyl),y
        ldy #1
        lda (ziyl),y
        and #$FB
        sta (ziyl),y
        bit zl
        bvs :+
        jmp LB033
:       lda zl
        and #$10
        beq :+
        jmp LB033
:       lda $75FD
        and #$FE
        sta $75FD
        jmp LB033
LAE98:  lda $7602
        and #2
        beq LAEA4
        lda $7602
        lsr a
        bcc LAEA6x
LAEA4:  txa
        sec
        sbc #4
        tax
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
        lda $75FD
        lsr a
        bcc :+
        jmp LADC5
:       ldy #10
        lda (ziyl),y
        and #$EF
        sta (ziyl),y
        lda $75FD
        ora #1
        sta $75FD
LAEBE:  cpx #$F8
        bcc :+
        jmp LADA3
:       jmp LB033
LAEC6:  ldy #0
        lda (ziyl),y
        beq LAECC
        jmp LAE7F
LAECC:  lda zc
        ora #4
        and #$F7
        sta zc
        ldy #10
        lda (ziyl),y
        ora #3
        sta (ziyl),y
        ldy #11
        lda #0
        sta (ziyl),y
        bit zl
        bvc :+
        lda zc
        ora #8
        sta zc
:       lda zc
        ldy #1
        sta (ziyl),y
        jmp LE833

; give-way check (D75EC bit0; never seen in play)
LAEE8:  lda t1
        sec
        sbc #$0E
        cmp ze
        bcs :+
        jmp LADA3
:       beq LAEF1
        jmp LAE49
LAEF1:  lda $75E7
        and #$1E
        beq :+
        jmp LAF3E
:       lda $75F5
        lsr a
        lsr a
        sec
        sbc #1
        tax
        ldy #10
        lda (ziyl),y
        bpl LAF11
        txa
        lsr a
        clc
        adc #1
        tax
        lda (ziyl),y
        and #$40
        bne LAF11
        ldx #1
LAF11:  lda zb
        sta t0
        pha                     ; push bc
        lda zc
        pha
        stx zb
        lda #4
        sta zc
        ldy #7
        lda (ziyl),y
        sta zh
        lda #$67
        sta zl
        lda t0
        and #2
        bne LAF26
        lda $75F5
        clc
        adc #$61
        sta zl
        lda #$FC
        sta zc
LAF26:  lda zb                  ; push bc ; push hl
        pha
        lda zc
        pha
        lda zl
        pha
        lda zh
        pha
        dec zh
        jsr exx_
        jsr sb4a5
        php
        jsr exx_
        plp
        bne LAF5D
        pla                     ; pop hl ; push hl
        sta zh
        pla
        sta zl
        pha
        lda zh
        pha
        inc zh
        jsr exx_
        jsr sb502
        php
        jsr exx_
        plp
        bne LAF5D
        pla                     ; pop hl ; pop bc
        sta zh
        pla
        sta zl
        pla
        sta zc
        pla
        sta zb
        lda zc
        clc
        adc zl
        sta zl
        dec zb
        bne LAF26
        pla                     ; pop bc
        sta zc
        pla
        sta zb
LAF3E:  ldy #11
        lda #2
        sta (ziyl),y
        ldy #10
        lda (ziyl),y
        and #$10
        beq LAF56
        lda $75FD
        lsr a
        bcs LAF60
        lda (ziyl),y
        and #$EF
        sta (ziyl),y
        lda $75FD
        ora #1
        sta $75FD
LAF56:  lda $7604
        and #$FE
        sta $7604
        jmp LB036
LAF5D:  pla                     ; pop af ; pop af ; pop bc
        pla
        pla
        pla
        pla
        sta zc
        pla
        sta zb
LAF60:  ldy #11
        lda #0
        sta (ziyl),y
        rts

LAF65:  ldy #2                  ; (ix+17) bit0 rule set, dir 0
        lda (ziyl),y
        and #2
        bne LAF72
        lda $75FA
        and #8
        bne LAF80
LAF72:  lda zl
        and #$10
        bne :+
        jmp LAE49
:       lda t1
        sec
        sbc #$0E
        cmp ze
        bcs :+
        jmp LADA3
:       jmp LAE49
LAF80:  lda t1
        sec
        sbc #$0E
        cmp ze
        bcs :+
        jmp LADA3
:       beq :+
        jmp LAE49
:       ldy #11
        lda (ziyl),y
        cmp #3
        bcc :+
        jmp LADA3
:       lda #0
        sta (ziyl),y
        rts

; --- junction approach, dir 2 (ze = L) ---------------------------------------
LAF96:  ldy #10
        lda (ziyl),y
        sta zl
        lda $75F2
        lsr a
        bcc :+
        jmp LB003
:       lda $75EC
        and #$20
        beq LAFA7
        jmp LAFF8
LAFA7:  lda zl
        and #$20
        beq :+
        jmp LADC5
:       bit zl
        bmi :+
        jmp LB033
:       ldy #11
        lda (ziyl),y
        cmp #7
        bcc :+
        lda #6
        sta (ziyl),y
:       lda $75F5
        sec
        sbc #4
        lsr a
        tax
        bit zl
        bvs LAFCD
        ldx #0
        lda ze2
        and #2
        jmp LAFD6
LAFCD:  bit $7602
        bpl :+
        ldx #0
:       lda ze2
        and #1
LAFD6:  bne LAFF0
        lda $75F1
        and #8
        bne LAFE2
        jmp LAE7F
LAFE2:  lda $7602
        and #2
        beq LAFEE
        lda $7602
        lsr a
        bcc LAFF0
LAFEE:  txa
        clc
        adc #4
        tax
LAFF0:  txa
        clc
        adc #$67
        ldx ze
        stx zd
        sta ze
        txa
        jmp LAEA8
LAFF8:  lda #$62
        cmp ze
        bcs :+
        jmp LAFA7
:       beq :+
        jmp LADA3
:       jmp LAEF1
LB003:  ldy #2
        lda (ziyl),y
        and #2
        bne LB00F
        lda $75FA
        and #8
        bne LB01D
LB00F:  lda zl
        and #$10
        bne :+
        jmp LAFA7
:       lda #$62
        cmp ze
        bcs :+
        jmp LAFA7
:       jmp LADA3
LB01D:  lda #$62
        cmp ze
        bcs :+
        jmp LAFA7
:       beq :+
        jmp LADA3
:       ldy #11
        lda (ziyl),y
        cmp #3
        bcc :+
        jmp LADA3
:       lda #0
        sta (ziyl),y
        rts

; --- move along the lane ------------------------------------------------------
LB033:  jsr Z_B9B1
LB036:  ldy #11
        lda (ziyl),y
        bne :+
        rts
:       jsr Z_B905
        ldy #1
        lda (ziyl),y
        sta zc
        jsr Z_B3B3
        ldy #11
        lda (ziyl),y
        tax
        ldy #2
        lda (ziyl),y
        and #2
        beq :+
        cpx #1
        bne :+
        ldx #2
:       stx zc2
        txa
        lsr a
        bcc LB05E
        tax
        lda $75F8
        lsr a
        bcc :+
        inx
:       txa
LB05E:  cmp #0
        bne :+
        jmp LB09E
:       tax
        lda $7604
        lsr a
        bcc :+
        ldx #0
:       ldy #5
        lda (ziyl),y
        and #2
        bne :+
        txa
        eor #$FF
        clc
        adc #1
        tax
:       txa
        clc
        adc zl2
        ldy #6
        sta (ziyl),y
        sta zl2
        sec
        sbc #6
        sta zb2
        lda $75F5
        clc
        adc #$C2
        cmp zb2
        bcs LB084
        jmp Z_DBFA
LB084:  lda $7604
        and #$10
        bne LB090
        ldy #0
        lda (ziyl),y
        beq LB09E
LB090:  lda zc2
        cmp #3
        lda #1
        bcc :+
        lda #2
:       ldx zh2
        jsr sb0aa
        stx zh2
        txa
        ldy #7
        sta (ziyl),y
LB09E:  lda #$1C
        sec
        sbc $7603
        sta za2
        ; fall into LB82C

; LB82C: draw the car at zl2/zh2; if blocked, restore the backup and redraw.
        ZPROC $B82C
        jsr Z_B412
        bne :+
        rts
:       jsr Z_B913
        lda ZV_B8F9+6
        sta zl2
        lda ZV_B8F9+7
        sta zh2
        jmp Z_B412

; ===========================================================================
; SB0AA - one step of a lane change.  Internal: X = H, A = step.  Out: X = H.
        ZPROC $B0AA
        ldx zh
        jsr sb0aa
        stx zh
        txa
        rts
sb0aa:  sta t0                  ; b = step
        ldy #1
        lda (ziyl),y
        sta t1
        and #$20
        beq :+
        lda t1
        eor #$FF
        sta t1
:       lda t1
        and #8
        bne LB0D2
        ldy #0
        lda (ziyl),y
        bne LB0CB
        sec
        sbc t0
        and #7
        sta t2
        ldy #1
        lda (ziyl),y
        and #$20
        beq :+
        inx
        jmp :++
:       dex
:       lda t2
        jmp LB0E8
LB0CB:  sec
        sbc t0
        beq LB0E3
        bcs LB0E8
        bcc LB0E3
LB0D2:  ldy #0
        lda (ziyl),y
        clc
        adc t0
        sta t2
        and #8
        bne :+
        lda t2
        jmp LB0E8
:       ldy #1
        lda (ziyl),y
        and #$20
        beq :+
        dex
        jmp LB0E3
:       inx
LB0E3:  ldy #1
        lda (ziyl),y
        and #$FB
        sta (ziyl),y
        lda #0
LB0E8:  ldy #0
        sta (ziyl),y
        ldy #1
        lda (ziyl),y
        and #$DF
        cpx #$60
        bcc :+
        ora #$20
:       sta (ziyl),y
        rts

; SB0F8 - look ahead 16 cells.  X = H, Y = L, A = 0 -> start at L-3.
; LB0FF: X = count, Y = L, gp+1 = H.  Out: Z = clear (A=0); NZ: A = cell,
; X = count left (the original B), Y = L of the hit, gp+1 = H.
sb0f8:  stx gp+1
        cmp #0
        bne :+
        dey
        dey
        dey
:       ldx #16
lb0ff:  lda #0
        sta gp
        lda ZV_B100
        cmp #$2D
        beq @dec
        cmp #$2C
        beq @inc
@nop:   lda (gp),y
        bne @r
        dex
        bne @nop
        rts
@dec:   dey
        lda (gp),y
        bne @r
        dex
        bne @dec
@r:     rts
@inc:   iny
        lda (gp),y
        bne @r
        dex
        bne @inc
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
        lda zd2
        cmp #$0E
        bcc :+
        lda $7604
        ora #1
        sta $7604
        lda zd2
:       cmp #9
        bcs sb12f_p
        ldy #0
        lda (zl),y
        and #1
        bne sb12f_p
        rts

; SB12F - follow the obstacle (record+1 in zl/zh, or tp for sb12f)
        ZPROC $B12F
sb12f_p:
        lda zl
        sta tp
        lda zh
        sta tp+1
sb12f:  ldy #4
        lda (tp),y
        ldy #5
        cmp (ziyl),y
        bne LB159
        ldy #10
        lda (tp),y
        sta t0
        lda $7600
        cmp t0
        bcs :+
        ldy #0                  ; already slower: ret c
        lda (tp),y
        and #1
        rts
:       lda t0
        beq LB151
        sec
        sbc #1
        bne LB151
        lda #1
LB151:  sta $7600
        ldy #0
        lda (tp),y
        and #1
        rts
LB159:  lda #1
        sta $7600
        rts

; SB162 - are these cells free: X = H, Y = L, zb2 = count.  Z = free.
sb162:  stx gp+1
        lda #0
        sta gp
        ldx zb2
:       lda (gp),y
        bne @r
        dey
        dex
        bne :-
        lda #0
@r:     rts

; ===========================================================================
; LB16A - spawn a car into an empty slot
LB16A:  lda $75F8
        and #$0A
        beq :+
        rts
:       GET_R
        sta zd
        and #$0C
        beq :+
        rts
:       lda zd
        lsr a
        lsr a
        lsr a
        lsr a
        and #3
        sta t0
        ldy #2
        lda (ziyl),y
        and #2
        beq LB198
        lda (ziyl),y
        and #4
        beq :+
        rts
:       lda $75F2
        lsr a
        bcc :+
        rts
:       lda $7611
        bne :+
        rts
:       lda $75F8
        and #$1F
        beq :+
        rts
:       sta t0
LB198:  lda t0
        ldy #5
        sta (ziyl),y
        ldx $7606
        stx zb
        lsr a
        bcc :+
        jmp LB2D8
:       lsr a
        bcc :+
        jmp LB2AC
:       lda $75F5
        clc
        adc #$C7
        ldy #6
        sta (ziyl),y
        tax
        lda zb
        and #8
        beq :+
        rts
:       stx zc
        lda $7607
        and #7
        cmp #7
        bne Z_B1BC
        rts

        ZPROC $B1BC
        lda $7601
        jsr sb387
        beq :+
        rts
:       tax
        lda #0
        cpx #3
        bne :+
        lda #$20
:       ldy #1
        sta (ziyl),y
        txa
        clc
        adc #$5D
        ldy #7
        sta (ziyl),y
        sta zh
        ldy #6
        lda (ziyl),y
        sta zl
        ldy #2
        lda (ziyl),y
        and #2
        beq LB1FA
        lda $7793
        and #$40
        beq :+
        rts
:       lda $7799
        sta zh
        lda $7798
        sta zl
        cmp #$8C
        bcs :+
        rts
:       clc
        adc #6
        sta zl
        ldy #7
        lda zh
        sta (ziyl),y
        lda $75D6
        cmp zh
        bne :+
        rts
:       lda zh
        cmp #$60
        bcc LB1FA
        rts
LB1FA:  ldy #6
        lda zl
        sta (ziyl),y
        sta ze
        lda zh
        sta gp+1
        lda #0
        sta gp
        ldy zl
        ldx #4
:       lda (gp),y
        beq :+
        rts
:       dey
        dex
        bne :--
        ldy ze
        lda #$1C
        sec
        sbc $7603
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
        ldy #0
        sta (ziyl),y
        ldy #10
        sta (ziyl),y
        ldy #1
        lda (ziyl),y
        ora #$80
        sta (ziyl),y
        ldy #11
        lda #3
        sta (ziyl),y
        ldy #2
        lda (ziyl),y
        and #2
        beq Z_B241
        jsr Z_BA5F
        .byte $38,$0B,$8A,"CLOSING IN"
        lda $779D
        clc
        adc #1
        ldy #11
        sta (ziyl),y
        ; fall into SB241

; SB241 - choose what to do at the next junction -> rec+10
        ZPROC $B241
        ldx $7607
        ldy #5
        lda (ziyl),y
        beq LB257
        tay
@l:     txa
        asl a
        tax
        and #$10
        beq :+
        txa
        and #$EF
        ora #1
        tax
:       dey
        bne @l
LB257:  stx zb
        lda ZV_9560
        jsr sb265
        ldy #10
        sta (ziyl),y
        lda ZV_9560
        rts

; SB265 - A = random, zb = blocked mask -> A = the turn code
sb265:  sta t0
        and #4
        bne LB288
        lda zb
        and #2
        bne :+
        lda #0
        rts
:       lda t0
        and #8
        beq LB27D
        lda zb
        and #4
        bne :+
        lda #$80
        rts
:       lda zb
        and #1
        bne :+
        lda #$D0
        rts
:       lda #$20
        rts
LB27D:  lda zb
        and #1
        bne :+
        lda #$D0
        rts
:       lda zb
        and #4
        bne :+
        lda #$80
        rts
:       lda #$20
        rts
LB288:  lda t0
        and #8
        bne LB29E
        lda zb
        and #4
        bne :+
        lda #$80
        rts
:       lda zb
        and #1
        bne LB29A
        lda #$D0
        rts
LB29A:  lda zb
        and #2
        beq :+
        lda #$20
        rts
:       lda #0
        rts
LB29E:  lda zb
        and #1
        bne :+
        lda #$D0
        rts
:       lda zb
        and #4
        bne LB29A
        lda #$80
        rts

; LB2AC - spawn an oncoming (dir 2) car
LB2AC:  lda zb
        and #2
        beq :+
        rts
:       ldy #5
        lda (ziyl),y
        sta zc
        lda $7607
        and #$0D
        cmp #$0D
        bne :+
        rts
:       lda $7601
        jsr sb387
        beq :+
        rts
:       tax
        lda #$A0
        cpx #3
        bne :+
        lda #$80
:       ldy #1
        sta (ziyl),y
        txa
        eor #$FF
        sec
        adc #$62
        ldy #7
        sta (ziyl),y
        sta zh
        lda #6
        sta zl
        jmp LB1FA

; LB2D8 - spawn a car at the far end of a side street (dir 1/3)
LB2D8:  ldy #10
        lda #0
        sta (ziyl),y
        ldy #5
        lda (ziyl),y
        and #2
        beq :+
        jmp LB36C
:       lda zb
        and #4
        beq :+
        rts
:       jsr Z_B241
        lda $7602
        jsr sb387
        beq :+
        rts
:       pha
        ldy #1
        lda #$40
        sta (ziyl),y
        pla
        ldx #<$FD60
        ldy #>$FD60
LB2F5:  stx ze
        sty zd
        sta t0
        ldy #10
        lda (ziyl),y
        bpl LB309
        and #$40
        beq LB306
        lda tent
        and #2
        bne LB309
        rts
LB306:  lda tent
        and #4
        bne LB309
        rts
LB309:  lda $7602
        and #3
        cmp #3
        bne :+
        lda #2
:       sta t1
        lda t0
        sec
        sbc t1
        asl a
        asl a
        clc
        adc #5
        ldy #9
        sta (ziyl),y
        jsr mul12
        clc
        adc ze
        sta zl
        txa
        adc zd
        sta zh
        ldy #7
        sta (ziyl),y
        ldy #6
        lda zl
        sta (ziyl),y
        jsr map_z
        ldx #$F4
        jsr p4base
        jsr or4
        bne @r
        ldy #5
        lda (ziyl),y
        and #2
        bne @m
        clc
        lda zl
        adc #1
        sta gl
        lda zh
        adc #0
        jmp @n
@m:     sec
        lda zl
        sbc #1
        sta gl
        lda zh
        sbc #0
@n:     sta gh
        jsr map_g
        ldx #$F4
        jsr p4base
        jsr or4
        bne @r
        jsr map_z
        ldx #$F4
        jsr p4base
        lda #$1C
        sec
        sbc $7603
        ldy o3
        sta (mp),y
        lda #$FF
        ldy o2
        sta (mp),y
        ldy o1
        sta (mp),y
        ldy #0
        sta (mp),y
        ldy #1
        lda (ziyl),y
        ora #$80
        sta (ziyl),y
        ldy #8
        lda #$0B
        sta (ziyl),y
        ldy #11
        lda #1
        sta (ziyl),y
        ldy #0
        lda #0
        sta (ziyl),y
@r:     rts
LB36C:  lda zb
        lsr a
        bcc :+
        rts
:       jsr Z_B241
        lda $7602
        jsr sb387
        beq :+
        rts
:       tax
        ldy #1
        lda #$60
        sta (ziyl),y
        txa
        eor #$FF
        sec
        adc #5
        ldx #<$FEBB
        ldy #>$FEBB
        jmp LB2F5

; SB387 - random lane for a spawn: A = road type.  Out: A = lane (0..3),
; Z = usable, tent = the DB3A3 entry.
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
        and #1
        php
        lda ze
        plp
        rts

; ===========================================================================
; SB3B3 - erase car IY from the grid (zc = flags, zl2/zh2 = position)
        ZPROC $B3B3
        ldx #$FF
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
        sta za2
        ldx ze2
        jsr p4base
        jsr clr4
        lda #0
        sta zb2
        ldy #0
        lda (ziyl),y
        bne :+
        rts
:       ldy #1
        lda (ziyl),y
        and #$40
        bne LB3E6
        lda zl2
        sta gl
        ldx zh2
        inx
        lda (ziyl),y
        and #$20
        beq :+
        dex
        dex
:       stx gh
        jmp LB3DD
LB3E6:  ldy #8
        lda (ziyl),y
        beq LB3F7
        ldy #1
        lda (ziyl),y
        and #$20
        beq @i
        sec
        lda zl2
        sbc #1
        sta gl
        lda zh2
        sbc #0
        sta gh
        jmp LB3DD
@i:     clc
        lda zl2
        adc #1
        sta gl
        lda zh2
        adc #0
        sta gh
        jmp LB3DD
LB3F7:  ldy #9
        lda (ziyl),y
        clc
        adc #$64
        sta gl
        ldy #1
        lda (ziyl),y
        and #$20
        bne :+
        lda $75D6
        clc
        adc #1
        jmp :++
:       lda $75D7
        sec
        sbc #1
:       sta gh
        lda #$FF
        sta ze2
LB3DD:  jsr map_g
        ldx ze2
        jsr p4base
        jsr clr4
        lda #0
        rts

; ===========================================================================
; SB412 - draw car IY (za2 = code, zl2/zh2 = position).  Z = drawn.
        ZPROC $B412
        ldx #$FF
        ldy #1
        lda (ziyl),y
        and #$40
        beq :+
        ldx #$F4
:       stx zc2
        lda #$FF
        sta zb2
        jsr map_z2
        ldx zc2
        jsr p4base
        jsr or4
        beq :+
        rts
:       lda za2
        ldy o3
        sta (mp),y
        lda #$FF
        ldy o2
        sta (mp),y
        ldy o1
        sta (mp),y
        ldy #0
        sta (mp),y
        lda (ziyl),y
        bne :+
        rts
:       lda zc2
        sta ZV_B457
        lda zb2
        sta ZV_B457+1
        ldy #1
        lda (ziyl),y
        and #$40
        bne LB46F
        lda zl2
        sta gl
        lda zh2
        sta gh
LB43F:  ldx #$FD
        ldy #1
        lda (ziyl),y
        and #$20
        beq :+
        inx
        dec gh
        jmp LB44B
:       inc gh
LB44B:  stx zd2
        jsr map_g
        ldx zc2
        jsr p4base
        jsr or4
        beq LB463
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
        rts
LB463:  lda zd2
        ldy o3
        sta (mp),y
        lda #$FF
        ldy o2
        sta (mp),y
        ldy o1
        sta (mp),y
        ldy #0
        sta (mp),y
        lda #0
        sta ze2
        rts
LB46F:  ldy #8
        lda (ziyl),y
        beq LB483
        ldx #$FD
        ldy #1
        lda (ziyl),y
        and #$20
        beq @i
        inx
        sec
        lda zl2
        sbc #1
        sta gl
        lda zh2
        sbc #0
        sta gh
        jmp LB44B
@i:     clc
        lda zl2
        adc #1
        sta gl
        lda zh2
        adc #0
        sta gh
        jmp LB44B
LB483:  ldy #9
        lda (ziyl),y
        clc
        adc #$64
        sta gl
        ldy #1
        lda (ziyl),y
        and #$20
        beq :+
        lda $75D7
        jmp :++
:       lda $75D6
:       sta gh
        lda #$FF
        sta zc2
        jmp LB43F

; SB49A - A = (HL)|(HL+BC)|(HL+2BC)|(HL+3BC) (current set), Z = free
        ZPROC $B49A
        lda zl
        sta gl
        lda zh
        sta gh
        lda #0
        sta t0
        ldx #4
@l:     jsr map_g
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
        bne @l
        lda t0
        rts

; ===========================================================================
; Scanners for the transverse cars (alt set: zl2/zh2 = HL, zb2 = B, zc2 = C,
; ze2/zd2 = DE, za2 = A').  Out: Z = clear, NZ = blocked.

; SB4A5 - towards +H
        ZPROC $B4A5
sb4a5:  lda #5
        sta zb2
        lda #0
        sta zc2
        jsr sb548
        lda zb2
        sta $7608
        ldy #1
        lda (ziyl),y
        and #$20
        bne LB4C8
        ldy #0
        lda (ziyl),y
        beq LB4C8
        inc zb2
        jmp LB4C8
LB4BF:  lda #0
        sta zc2
        jsr sb548
LB4C5:  lda #0
        sta gp
        lda zh2
        sta gp+1
        ldy zl2
        lda (gp),y
        bne LB4CD
LB4C8:  inc zh2
        dec zb2
        bne LB4C5
        lda #0
        rts
LB4CD:  bpl @r
        tax
        and #$40
        bne LB4D4
        txa
@r:     rts
LB4D4:  lda zb2
        clc
        adc #1
        cmp $7608
        bcc LB4E0
        jmp LB4C8
LB4E0:  cpx #$FD
        bcc :+
        txa
        rts
:       lda #$B0
        sta zl2
        lda #$FE
        sta zh2
        lda #$81
        sta zc2
        txa
LB4EA:  and #$1F
        jsr mul12
        sta ze2
        stx zd2
        clc
        adc zl2
        sta zl2
        lda zd2
        adc zh2
        sta zh2
        lda zc2
        lsr a
        bcc :+
        lda #1
        sta ze2
        lda #0
        sta zd2
        beq @l
:       lda #$FF
        sta ze2
        sta zd2
@l:     jsr rd2
        bne @r
        clc
        lda zl2
        adc ze2
        sta zl2
        lda zh2
        adc zd2
        sta zh2
        dec zb2
        bne @l
        lda #0
@r:     rts

; SB502 - towards -H
        ZPROC $B502
sb502:  lda #5
        sta zb2
        lda #0
        sta zc2
        jsr sb55b
        lda zb2
        sta $7608
        ldy #1
        lda (ziyl),y
        and #$20
        beq LB525
        ldy #0
        lda (ziyl),y
        beq LB525
        inc zb2
        jmp LB525
LB51C:  lda #0
        sta zc2
        jsr sb55b
LB522:  lda #0
        sta gp
        lda zh2
        sta gp+1
        ldy zl2
        lda (gp),y
        bne LB52A
LB525:  dec zh2
        dec zb2
        bne LB522
        lda #0
        rts
LB52A:  bpl @r
        tax
        and #$40
        bne LB531
        txa
@r:     rts
LB531:  lda zb2
        cmp $7608
        bcc LB53C
        jmp LB525
LB53C:  cpx #$FD
        bcc :+
        txa
        rts
:       lda #$6B
        sta zl2
        lda #$FD
        sta zh2
        lda #$80
        sta zc2
        txa
        jmp LB4EA

; SB548 / SB55B - stop the scan at a kerb without a side street
sb548:  lda $75F1
        lsr a
        bcc @r
        lda $75D7
        sec
        sbc zh2
        sec
        sbc #1
        beq LB558
        cmp zb2
        bcs @r
        sta zb2
@r:     rts
LB558:  lda #1
        sta zb2
        rts
sb55b:  lda $75F1
        and #4
        beq @r
        lda zh2
        sec
        sbc $75D6
        sec
        sbc #1
        beq LB558
        cmp zb2
        bcs @r
        sta zb2
@r:     rts

; DB56D - side-street car moving towards the main road
db56d:  ldx #5
        stx zb2
        ldy #0
        lda (ziyl),y
        beq LB57C
        inc zb2
        jmp LB57C
LB579:  jsr rd2
        bne LB585
LB57C:  clc
        lda zl2
        adc ze2
        sta zl2
        lda zh2
        adc zd2
        sta zh2
        dec zc2
        bmi LB597
        dec zb2
        bne LB579
        lda #0
        rts
LB585:  lda zb2
        cmp #5
        bcc :+
        jmp LB57C
:       ldx #$80
        lda ze2
        bpl :+
        ldx #$81
:       stx zc2
        lda zb2
        rts
LB597:  ldx $75D6
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
        bmi :+
        jmp LB4BF
:       jmp LB51C

; DB5BB - side-street car moving away from the main road
db5bb:  lda #5
        sta zb2
        jmp LB5C3
LB5BF:  jsr rd2
        bne LB5CD
LB5C3:  clc
        lda zl2
        adc ze2
        sta zl2
        lda zh2
        adc zd2
        sta zh2
        inc zc2
        lda zc2
        cmp #12
        beq @r
        dec zb2
        bne LB5BF
        lda #0
@r:     rts
LB5CD:  tay
        ldx #$80
        lda ze2
        bmi :+
        ldx #$81
:       stx zc2
        tya
        rts

; call the scan routine whose Spectrum address is A (lo) / X (hi)
scan_disp:
        cmp #<$B4A5
        bne :+
        jmp sb4a5
:       cmp #<$B502
        bne :+
        jmp sb502
:       cmp #<$B56D
        bne :+
        jmp db56d
:       jmp db5bb

; ===========================================================================
; LB5D7 - transverse cars (dir 1/3); P: zb = dir, zc = flags
LB5D7:  bit zc
        bvc LB608
        lda zc
        tax
        lda zb
        and #2
        beq :+
        txa
        eor #$FF
        tax
:       txa
        and #$20
        beq LB5EE
        lda #<$B5BB
        sta zl
        lda #>$B5BB
        sta zh
        ldy #8
        lda (ziyl),y
        sta zc2
        jmp LB5F9
LB5EE:  lda #<$B56D
        sta zl
        lda #>$B56D
        sta zh
        ldy #8
        lda (ziyl),y
        sta zc2
        ldy #9
        lda (ziyl),y
        sta za2
LB5F9:  ldy #5
        lda (ziyl),y
        and #2
        beq :+
        lda #$FF
        sta ze2
        sta zd2
        bne LB612
:       lda #1
        sta ze2
        lda #0
        sta zd2
        beq LB612
LB608:  lda zb
        and #2
        bne :+
        lda #<$B4A5
        ldx #>$B4A5
        bne :++
:       lda #<$B502
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
        lda zl2                 ; push hl'
        pha
        lda zh2
        pha
        lda ZV_B61F
        ldx ZV_B61F+1
        jsr scan_disp
        beq :+
        jsr sb96a
:       pla                     ; pop hl ; push hl
        sta zh2
        pla
        sta zl2
        pha
        lda zh2
        pha
        ldx #$DC
        ldy #1
        lda (ziyl),y
        and #$40
        bne :+
        ldx #$FD
:       stx ze2
        lda #$FF
        sta zd2
        txa
        clc
        adc zl2
        sta zl2
        lda zh2
        adc #$FF
        sta zh2
        lda za2
        sec
        sbc #3
        sta za2
        ldy #8
        lda (ziyl),y
        sta zc2
        lda ZV_B63B
        sta ze2
        lda ZV_B63B+1
        sta zd2
        lda ZV_B63E
        ldx ZV_B63E+1
        jsr scan_disp
        beq :+
        jsr sb96a
:       pla
        sta zh2
        pla
        sta zl2
        ; B644 (P)
        bit zc
        bvc LB65C
        ldy #8
        lda (ziyl),y
        cmp #4
        bcc :+
        jmp LB7CF
:       lda zc
        tax
        lda zb
        and #2
        beq :+
        txa
        eor #$FF
        tax
:       txa
        and #$20
        beq LB65C
        jmp LB7CF
LB65C:  lda $75F2
        lsr a
        bcc :+
        jmp LB785
:       lda zb
        and #2
        bne :+
        lda $75E7
        and #8
        jmp LB671
:       lda $75E7
        and #4
LB671:  beq LB673
        jmp LB6E9
LB673:  ldy #10
        lda (ziyl),y
        bmi :+
        jmp LB7CF
:       lda $7600
        cmp #4
        bcc :+
        lda #4
        sta $7600
:       ldy #10
        lda (ziyl),y
        and #$40
        bne LB6A3
LB68C:  ldy #0
        lda (ziyl),y
        cmp #4
        beq :+
        jmp LB75A
:       bit zc
        bvs :+
        jmp LAECC
:       ldy #8
        lda (ziyl),y
        bne :+
        jmp LAECC
:       jmp LB75A
LB6A3:  bit $7601
        bmi LB68C
        ldy #10
        lda (ziyl),y
        and #$10
        beq LB6BE
        lda $75FD
        lsr a
        bcs LB6CE
        lda $75FD
        ora #1
        sta $75FD
        lda (ziyl),y
        and #$EF
        sta (ziyl),y
LB6BE:  bit zc
        bvc :+
        jmp LB7CF
:       ldy #7
        lda (ziyl),y
        tax
        lda zb
        and #2
        bne LB6D5
        cpx #$5E
        beq @s
        bcs LB6DE
        jmp LB7CF
@s:     jmp LB75A
LB6CE:  lda #0
        sta $7600
        jmp LB7CF
LB6D5:  cpx #$61
        beq @s
        bcc LB6DE
        jmp LB7CF
@s:     jmp LB75A
LB6DE:  ldy #0
        lda (ziyl),y
        cmp #4
        beq :+
        jmp LB75A
:       jmp LAECC
LB6E9:  bit zc
        bvs :+
        jmp LB673
:       ldy #8
        lda (ziyl),y
        bne :+
        jmp LB673
:       cmp #1
        beq :+
        jmp LB75A
:       ldy #0
        lda (ziyl),y
        cmp #2
        beq LB704
        bcc :+
        jmp LB673
:       jmp LB75A
; wait for a gap in the cross traffic
LB704:  lda #$2D
        sta ZV_B100
        ldx #$FF
        lda $75D7
        sec
        sbc #1
        tay
        lda zc
        and #$20
        bne :+
        ldx #1
        ldy $75D6
        iny
:       sty zh
        stx ze
        ldy #9
        lda (ziyl),y
        clc
        adc #$7C
        sta zl
        lda $75DF
        asl a
        tax
        ldy #10
        lda (ziyl),y
        bpl LB737
        and #$40
        beq :+
        txa
        lsr a
        clc
        adc #1
        tax
        jmp LB737
:       ldx #1
LB737:  txa
        jsr Z_B9A0
        beq :+
        ldy #11
        lda #0
        sta (ziyl),y
        rts
:       ldy #11
        lda #0
        sta (ziyl),y
        ldy #10
        lda (ziyl),y
        and #$10
        beq LB753
        lda $75FD
        lsr a
        bcc :+
        rts                     ; (LB73A: speed 0, ret nz)
:       lda $75FD
        ora #1
        sta $75FD
        lda (ziyl),y
        and #$EF
        sta (ziyl),y
LB753:  ldy #11
        lda #1
        sta (ziyl),y
        ldy #5
        lda (ziyl),y
        sta zb
; brake
LB75A:  ldy #11
        lda (ziyl),y
        sec
        sbc #1
        beq LB773
        bmi LB773
        cmp #3
        bcc LB76D
        lda (ziyl),y
        sec
        sbc #2
        sta (ziyl),y
LB76D:  lda (ziyl),y
        sec
        sbc #1
        sta (ziyl),y
        jmp LB7D2
LB773:  lda $7600
        beq LB780
        lda #1
        sta (ziyl),y
        jmp LB7D2
LB780:  lda #0
        sta (ziyl),y
        rts
; (ix+17) bit0 rule set (never seen in play)
LB785:  bit $75FA
        bmi LB7AD
        ldy #10
        lda (ziyl),y
        and #$10
        bne :+
        jmp LB673
:       bit zc
        bvs :+
        jmp LB673
:       ldy #8
        lda (ziyl),y
        bne :+
        jmp LB673
:       cmp #1
        beq :+
        jmp LB75A
:       ldy #0
        lda (ziyl),y
        cmp #2
        bcc :+
        jmp LB673
:       jmp LB75A
LB7AD:  bit zc
        bvs :+
        jmp LB673
:       ldy #8
        lda (ziyl),y
        bne :+
        jmp LB673
:       cmp #1
        beq :+
        jmp LB75A
:       ldy #0
        lda (ziyl),y
        cmp #2
        beq LB7CA
        bcc :+
        jmp LB673
:       jmp LB75A
LB7CA:  ldy #11
        lda #0
        sta (ziyl),y
        rts
; move by `speed' sub-steps
LB7CF:  jsr Z_B9B1
LB7D2:  ldy #11
        lda (ziyl),y
        bne :+
        rts
:       lda zc
        tax
        lda zb
        and #2
        beq :+
        txa
        eor #$FF
        tax
:       txa
        and #$20
        tax
        ldy #0
        lda (ziyl),y
        sta ZV_B8F9
        cpx #0
        bne LB81B
        clc
        ldy #11
        adc (ziyl),y
        cmp #8
        bcc LB7F0
        clc
        jmp LB820
LB7F0:  sta nsub
        cmp #0
        beq LB7FF
        ldy #0
        lda (ziyl),y
        beq LB7FF
        lda nsub
        sta (ziyl),y
        rts
LB7FF:  jsr Z_B3B3
        lda nsub
        ldy #0
        sta (ziyl),y
        jsr Z_B412
        bne :+
        rts
:       lda ZV_B8F9
        ldy #0
        sta (ziyl),y
        ldy #6
        lda (ziyl),y
        sta zl2
        iny
        lda (ziyl),y
        sta zh2
        jmp Z_B412
LB81B:  sec
        ldy #11
        sbc (ziyl),y
        bcs LB7F0
        sec
LB820:  php
        pha
        jsr Z_B3B3
        jsr Z_B905
        pla
        plp
        jsr Z_B83A
        jmp Z_B82C

; ===========================================================================
; SB83A - step to the next cell (A = sub-position, C = direction of the
; overflow, zc = flags, zl2/zh2 = position)
        ZPROC $B83A
        bit zc
        bvs :+
        jmp LB894
:       bcc LB863
        and #7
        ldy #0
        sta (ziyl),y
        ldy #8
        lda (ziyl),y
        clc
        adc #1
        sta (ziyl),y
        cmp #12
        bne LB853
        pla
        pla
        jmp Z_DBFA
LB853:  lda zc
        and #$20
LB855:  beq @d
        inc zl2
        bne LB85B
        inc zh2
        jmp LB85B
@d:     lda zl2
        bne :+
        dec zh2
:       dec zl2
LB85B:  ldy #6
        lda zl2
        sta (ziyl),y
        iny
        lda zh2
        sta (ziyl),y
        rts
LB863:  and #7
        ldy #0
        sta (ziyl),y
        ldy #8
        lda (ziyl),y
        beq LB877
        sec
        sbc #1
        sta (ziyl),y
        lda zc
        eor #$FF
        and #$20
        jmp LB855
LB877:  ldy #1
        lda (ziyl),y
        and #$BF
        sta (ziyl),y
        lda zc
        and #$BF
        sta zc
        and #$20
        bne :+
        lda $75D6
        clc
        adc #2
        jmp :++
:       lda $75D7
:       sec
        sbc #1
        sta zh2
        ldy #9
        lda (ziyl),y
        clc
        adc #$64
        sta zl2
        jmp LB85B
LB894:  bcc LB8BE
        and #7
        ldy #0
        sta (ziyl),y
        lda zc
        and #$20
        beq LB8A2
LB8A0:  inc zh2
        inc zh2
LB8A2:  dec zh2
LB8A3:  ldy #7
        lda zh2
        sta (ziyl),y
        sta gp+1
        lda #0
        sta gp
        ldy zl2
        lda (gp),y
        cmp #$FD
        bcc :+
        rts
:       tax
        and #$C0
        cmp #$C0
        beq :+
        rts
:       ldy #1
        lda (ziyl),y
        ora #$40
        sta (ziyl),y
        lda zc
        ora #$40
        sta zc
        txa
        jsr Z_B9EE
        lda zl
        sta zl2
        lda zh
        sta zh2
        rts
LB8BE:  and #7
        ldy #0
        sta (ziyl),y
        lda zc
        and #$20
        beq LB8E1
        lda zh2
        cmp #$60
        bne LB8A2
        ldy #1
        lda (ziyl),y
        and #$DF
        sta (ziyl),y
        ldy #0
        lda (ziyl),y
        eor #$FF
        clc
        adc #1
        and #7
        sta (ziyl),y
        beq :+
        dec zh2
:       dec zh2
        jmp LB8A3
LB8E1:  lda zh2
        cmp #$5F
        bne LB8A0
        ldy #1
        lda (ziyl),y
        ora #$20
        sta (ziyl),y
        ldy #0
        lda (ziyl),y
        eor #$FF
        clc
        adc #1
        and #7
        sta (ziyl),y
        beq :+
        inc zh2
:       inc zh2
        jmp LB8A3

; ===========================================================================
; SB905 / SB913 - back up / restore the record
        ZPROC $B905
        ldy #11
:       lda (ziyl),y
        sta ZV_B8F9,y
        dey
        bpl :-
        rts
        ZPROC $B913
        ldy #11
:       lda ZV_B8F9,y
        sta (ziyl),y
        dey
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
LB93C:  tax
        and #1
        beq :+
        dec zh2
        jmp :++
:       inc zh2
:       jsr rd2
        bpl LB966
        jsr sb98d
        sta zl2
        stx zh2
        jsr rd2
        jmp LB966
LB94E:  txa
        and #7
        jmp LB966
LB952:  lda #12
        sta ze2
        lda #0
        sta zd2
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
        bcs @i
        lda zl2
        bne :+
        dec zh2
:       dec zl2
        jmp :+
@i:     inc zl2
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
        bne :+
        rts
:       jmp sb12f
LB97E:  lda #0
        sta $7600
        ldy #11
        lda (ziyl),y
        cmp #3
        bcs :+
        rts
:       lda #2
        sta (ziyl),y
        rts

; SB98D - A -> table record address.  Internal: A = lo, X = hi.
        ZPROC $B98D
        jsr sb98d
        sta zl
        stx zh
        rts
sb98d:  sta t6
        and #$1F
        jsr mul12
        tay
        lda t6
        and #$20
        bne @r
        tya
        clc
        adc #<$FD6B
        tay
        txa
        adc #>$FD6B
        tax
        tya
        rts
@r:     tya
        clc
        adc #<$FEB0
        tay
        txa
        adc #>$FEB0
        tax
        tya
        rts

; SB9A0 - test A rows of the cross traffic (P: zl/zh = cell, ze = step)
        ZPROC $B9A0
        sta cnt
@l:     lda zh
        sta gp+1
        ldy zl
        ldx #$34
        jsr lb0ff
        bne @r
        lda zh
        clc
        adc ze
        sta zh
        dec cnt
        bne @l
@r:     rts

; SB9B1 - ease the speed towards D7600
        ZPROC $B9B1
        lda $7600
        ldy #11
        sec
        sbc (ziyl),y
        bne :+
        rts
:       bcc LB9C8
        cmp #4
        lda #2
        bcs :+
        lda #1
:       clc
        adc (ziyl),y
        sta (ziyl),y
        rts
LB9C8:  cmp #$FE
        php
        lda (ziyl),y
        sec
        sbc #1
        plp
        bcs :+
        sec
        sbc #1
:       sta (ziyl),y
        rts

; SB9D2 - "multiply by 12" (exact): A -> ze/zd
        ZPROC $B9D2
        jsr mul12
        sta ze
        stx zd
        rts

; SB9DD - A -> zl/zh = (rec1 bit5 ? $FEB0 : $FD6B) + 12*A
        ZPROC $B9DD
        jsr mul12
        sta ze
        stx zd
        ldy #1
        lda (ziyl),y
        and #$20
        bne @r
        lda ze
        clc
        adc #<$FD6B
        sta zl
        lda zd
        adc #>$FD6B
        sta zh
        rts
@r:     lda ze
        clc
        adc #<$FEB0
        sta zl
        lda zd
        adc #>$FEB0
        sta zh
        rts

; SB9EE - convert the position to junction-table mode (row = rec+6 - $64)
        ZPROC $B9EE
        ldy #6
        lda (ziyl),y
        sec
        sbc #$64
        ldy #9
        sta (ziyl),y
        tax
        ldy #8
        lda #0
        sta (ziyl),y
        txa
        jsr Z_B9DD
        ldy #6
        lda zl
        sta (ziyl),y
        iny
        lda zh
        sta (ziyl),y
        rts

; SBA04 - a stopped criminal car "SUBMITS" (never seen in play)
        ZPROC $BA04
        ldy #11
        lda (ziyl),y
        beq :+
        rts
:       ldy #1
        lda (ziyl),y
        ora #1
        sta (ziyl),y
        ldy #2
        lda (ziyl),y
        and #2
        bne :+
        rts
:       lda #$8A
        sta zb
        lda (ziyl),y
        and #4
        beq LBA37
        jsr Z_DBD7
        lda #$89
        sta zb
        ldy #0
        lda (zixl),y
        ora #$40
        sta (zixl),y
        ldy #2
        lda (ziyl),y
        and #8
        bne LBA34
        dec zb
        ldy #6
        lda (zixl),y
        and #8
        bne LBA37
        jsr Z_DDD3
        lda #$32
        jmp LBA39
LBA34:  jsr Z_DDD3
LBA37:  lda #$C8
LBA39:  ldx #<$75E1
        stx zixl
        ldx #>$75E1
        stx zixh
        tax
        lda zb
        pha
        txa
        jsr Z_F36A
        pla
        sta ZV_BA4A
        jsr Z_BA5F
        .byte $30,$08
        ZLABEL $BA4A, 1
        .byte $00,"SUBMITS"
        ldy #1
        lda (ziyl),y
        sta zc
        rts

; ===========================================================================
; LE833 - turn a car at a junction (P: zb = rec+5, zc = flags, zl2/zh2 = pos)
        ZPROC $E833
LE833:  jsr Z_B3B3
        jsr Z_B905
        lda zb
        sta zd
        lsr a
        lsr a
        and #3
        tax
        ldy #10
        lda (ziyl),y
        and #$40
        beq LE85F
        inx
        cpx #3
        bne LE876
        jsr e8clr
        lda $75FD
        and #$FE
        sta $75FD
        ldx #0
        inc zd
        jmp LE876
LE85F:  dex
        bne :+
        jsr e8clr
        jmp LE876
:       bpl LE876
        ldx #2
        dec zd
LE876:  txa
        asl a
        asl a
        and #$0C
        sta ze
        lda zd
        and #3
        ora ze
        ldy #5
        sta (ziyl),y
        lda zb
        asl a
        tax
        ldy #10
        lda (ziyl),y
        and #$40
        beq :+
        inx
:       lda T_E94D,x
        sta ent
        and #1
        beq LE8A5
        lda ent
        and #2
        beq @d
        inc zl2
        bne @s
        inc zh2
        jmp @s
@d:     lda zl2
        bne :+
        dec zh2
:       dec zl2
@s:     ldy #6
        lda zl2
        sta (ziyl),y
        iny
        lda zh2
        sta (ziyl),y
LE8A5:  lda ent
        and #4
        bne :+
        jmp Z_B82C
:       lda ent
        eor zc
        and #$20
        tax
        ldy #0
        lda (ziyl),y
        cpx #0
        bne LE8F6
        sec
        sbc #2
        bcc :+
        jmp LE945
:       lda zc
        and #$20
        bne LE8E7
        dec zh2
        lda #6
        sta zc2
        lda $75D6
        cmp zh2
        bne LE8DB
        lda zl2
        ldx #<$FD6B
        ldy #>$FD6B
LE8CA:  stx zl2
        sty zh2
        sec
        sbc #$64
        ldy #9
        sta (ziyl),y
        pha
        ldy #8
        lda #0
        sta (ziyl),y
        ldy #1
        lda (ziyl),y
        ora #$40
        sta (ziyl),y
        pla
        jsr mul12
        sta ze2
        stx zd2
        clc
        adc zl2
        sta zl2
        lda zd2
        adc zh2
        sta zh2
LE8DB:  ldy #6
        lda zl2
        sta (ziyl),y
        iny
        lda zh2
        sta (ziyl),y
        ldy #0
        lda zc2
        sta (ziyl),y
        jmp Z_B82C
LE8E7:  lda #6
        sta zc2
        inc zh2
        lda $75D7
        cmp zh2
        bne LE8DB
        lda zl2
        ldx #<$FEB0
        ldy #>$FEB0
        jmp LE8CA
LE8F6:  clc
        adc #2
        cmp #8
        bcs :+
        jmp LE945
:       lda zc
        and #$20
        bne LE92E
        bit zc
        bvc LE921
        lda $75D6
        clc
        adc #1
LE908:  sta zh2
        ldy #9
        lda (ziyl),y
        clc
        adc #$64
        sta zl2
        ldy #1
        lda (ziyl),y
        and #$BF
        sta (ziyl),y
LE914:  ldy #6
        lda zl2
        sta (ziyl),y
        iny
        lda zh2
        sta (ziyl),y
        ldy #0
        lda #0
        sta (ziyl),y
        jmp Z_B82C
LE921:  inc zh2
        lda zh2
        cmp #$60
        bne LE914
        ldy #1
        lda (ziyl),y
        ora #$20
        sta (ziyl),y
        jmp LE914
LE92E:  bit zc
        bvc LE938
        lda $75D7
        sec
        sbc #1
        jmp LE908
LE938:  dec zh2
        lda zh2
        cmp #$5F
        bne LE914
        ldy #1
        lda (ziyl),y
        and #$DF
        sta (ziyl),y
        jmp LE914
LE945:  and #7
        ldy #0
        sta (ziyl),y
        jmp Z_B82C

; rec+10 &= ~$81 ; rec+1 &= ~4
e8clr:  ldy #10
        lda (ziyl),y
        and #$7E
        sta (ziyl),y
        ldy #1
        lda (ziyl),y
        and #$FB
        sta (ziyl),y
        rts
