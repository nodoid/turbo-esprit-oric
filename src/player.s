; player.s - the player's driving code (Spectrum E94D-F756, notes R8 part B)
;
;   SE96A  speed / automatic gearbox          SEAE2  PLAYER_STEP (main loop 7300)
;   lane change, handbrake turn, skid, scan-ahead, collisions, run-over,
;   crash/bump, fire (SF549 + tracer line), "BANG !" hazard check SF6E3,
;   penalty / score adders SF34B / SF36A.
;
; Translated 1:1 from the Z80 (compacted for size: small helpers and shared
; tails).  IY is the player record $7792 almost everywhere, so the code uses
; constant addresses ($7792 = iy+0, $7793 = iy+1 ...) and only goes through
; (ziyl) where IY can point at another object.  IX is always $75E1 (constant
; addresses $75F0.. = ix+15..) except after SDBD7, which returns a car record
; in zixl/zixh.  ziy / zix are kept equal to the Z80 IY / IX at every
; external call.
;
; Variables:  DE965 = Oric pointer into T_EAB5 (gear entry; the Spectrum held
; the Spectrum address, the tests convert); DE967 speed, DE968 revs ...
; Sounds: beeper calls -> snd_fx (see snd.inc).  The tyre-screech hook in the
; screen copier (D8687 = D86D9) becomes snd_fx SND_SCREECH; restoring the
; hook at F1EF (no screech) has no equivalent (the effect just runs out).

        .include "zx.inc"
        .include "snd.inc"

        ZIMPORT $98F4           ; key pair -> D
        ZIMPORT $F37A           ; key test (hw.s)
        ZIMPORT $A36F           ; speedo / tacho needles (A)
        ZIMPORT $A496           ; indicator flash
        ZIMPORT $A487           ; indicator off
        ZIMPORT $A0B1           ; steering-wheel graphic (D)
        ZIMPORT $9498           ; refuel / repair check (tail jump)
        ZIMPORT $8EAB           ; take object IY out of the map
        ZIMPORT $B412           ; put object A' at HL' into the map, Z = ok
        ZIMPORT $B91B           ; identify occupant of cell HL -> A, DB161
        ZIMPORT $B905           ; save record (IY) -> DB8F9
        ZIMPORT $B913           ; restore record
        ZIMPORT $B83A           ; step object to the next column (tail jump)
        ZIMPORT $B0AA           ; one lane-change step
        ZIMPORT $B9EE           ; enter junction mode
        ZIMPORT $B9DD           ; junction record of row A -> HL
        ZIMPORT $B98D           ; junction record of cell A -> HL
        ZIMPORT $B49A           ; test 4-cell footprint
        ZIMPORT $7CA1
        ZIMPORT $8F0B
        ZIMPORT $A4C9           ; graphics engine, inline stream (text)
        ZIMPORT $A4D6           ; graphics engine, inline stream (lines)
        ZIMPORT $8C87           ; projection multiply (A, E) -> A, CY
        ZIMPORT $927B
        ZIMPORT $9230
        ZIMPORT $DBD7           ; IX = enemy-car record of object IY
        ZIMPORT $DDD3
        ZIMPORT $BA56           ; status-line message, inline stream
        ZVIMPORT $A093          ; steering-wheel state
        ZVIMPORT $B161          ; object id found by SB91B
        ZVIMPORT $B8F9          ; saved object record (DB8FE = +5)
        ZVIMPORT $FD60          ; left junction table (DFD77 = record 1)

        .export T_EAB5, T_E94D, T_F471, T_F30D

; ---------------------------------------------------------------- variables
        .zeropage
p_t0:   .res 1
p_t1:   .res 1
p_t2:   .res 1
p_t3:   .res 1
p_side: .res 1

        .data
        ZLABEL $E965, 2         ; current gear entry (pointer into T_EAB5)
        .word T_EAB5+8
        ZLABEL $E967, 2         ; speed (signed), revs
        .byte $00, $03
ZV_E968 = ZV_E967 + 1           ; revs (read by world and dash)
        .export ZV_E968
        ZVAR $E969, 1           ; key code of the last processed press
        ZVAR $EADF, 1           ; previous pass key bits
        ZVAR $EAE0, 2           ; obstacle cell found by the scan ahead
        ZVAR $EE4E, 3           ; working position l, h ; edge column
        ZVAR $F30C, 1           ; turn sub-steps left
        ZVAR $F470, 1           ; cells to move this pass
        ZVAR $F691, 1           ; player lateral coordinate when firing

        .rodata
; DE94D: table used by the traffic code (E88E)
T_E94D: .byte $01,$01,$24,$24,$03,$03,$04,$04,$01,$25,$24,$27,$03,$07,$04,$05
        .byte $25,$24,$27,$03,$07,$04,$05,$01
; gear table EAB5-EADE (entries of 6 bytes at +2, +8, ... see R8 B.1)
T_EAB5: .byte $ff,$66,$fc,$10,$03,$63,$ff,$33
        .byte $0e,$04,$04,$80,$0a,$f6,$04,$12,$02,$03,$0a,$97
        .byte $03,$12,$07,$07,$0c,$fb,$02,$12,$09,$0b,$0d,$fc,$01,$10,$0a,$4f
        .byte $ff,$0b,$01,$0b,$0a,$56
; turn step table F30D (+ the 4 code bytes that follow it on the Spectrum,
; reachable only with phase 6/7)
T_F30D: .byte $09,$12,$23,$2c,$11,$21,$2a,$33,$20,$31,$39,$39
        .byte $32,$1e,$f3,$af
; cells per pass, F471
T_F471: .byte $00,$00,$00,$10,$10,$10,$11,$11,$12,$12,$12,$22,$22,$22,$23,$23
        .byte $23,$33,$33,$33,$34,$34,$34,$44,$44,$44,$45,$45,$45,$55,$55,$55

; ---------------------------------------------------------------- macros
.macro PUSHBC
        lda zc
        pha
        lda zb
        pha
.endmacro
.macro POPBC
        pla
        sta zb
        pla
        sta zc
.endmacro
.macro PUSHDE
        lda ze
        pha
        lda zd
        pha
.endmacro
.macro POPDE
        pla
        sta zd
        pla
        sta ze
.endmacro
.macro PUSHHL
        lda zl
        pha
        lda zh
        pha
.endmacro
.macro POPHL
        pla
        sta zh
        pla
        sta zl
.endmacro

        .code

; ---------------------------------------------------------------- helpers
; exx: swap BC DE HL with the alternate set.  Preserves A (flags = A).
; (zx.s keeps zc zb ze zd zl zh and zc2 .. zh2 contiguous, same order.)
exx:    pha
        ldx #5
@l:     ldy zc,x
        lda zc2,x
        sta zc,x
        tya
        sta zc2,x
        dex
        bpl @l
        pla
        rts

neg:    eor #$FF
        clc
        adc #1
        rts

iyp:    lda #<$7792             ; IY = player
        sta ziyl
        lda #>$7792
        sta ziyh
        rts
ixp:    lda #<$75E1             ; IX = $75E1
        sta zixl
        lda #>$75E1
        sta zixh
        rts

; bit set / reset on the flag bytes, A = mask (or ~mask)
or0B:   ora $760B
        sta $760B
        rts
an0B:   and $760B
        sta $760B
        rts
or93:   ora $7793
        sta $7793
        rts
an93:   and $7793
        sta $7793
        rts
wreck:  lda #2                  ; set 1,(iy+1) ; set 3,(ix+45)
        jsr or93
        lda #8
or0E:   ora $760E
        sta $760E
        rts
side:   lda $7793               ; (iy+1) bit 5 (NZ = right carriageway)
        and #$20
        rts

hlpos:  lda $7798               ; HL = (D7798)
        sta zl
        lda $7799
        sta zh
        rts
poshl:  lda zl                  ; (D7798) = HL
        sta $7798
        lda zh
        sta $7799
        rts
hlee:   lda ZV_EE4E             ; HL = (DEE4E)
        sta zl
        lda ZV_EE4E+1
        sta zh
        rts
hlae:   lda ZV_EAE0             ; HL = (DEAE0)
        sta zl
        lda ZV_EAE0+1
        sta zh
        rts
aehl:   lda zl                  ; (DEAE0) = HL ; d = e
        sta ZV_EAE0
        lda zh
        sta ZV_EAE0+1
        lda ze
        sta zd
        rts
key98:  sta zl                  ; S98F4 with HL = X:A
        stx zh
        jmp Z_98F4
wheel0: lda ZV_A093             ; if DA093 == 0: SA0B1
        bne rts0
        jmp Z_A0B1
wheel1: lda ZV_A093             ; if DA093 != 0: SA0B1
        beq rts0
        jmp Z_A0B1

; mul12 (SB9D2): DE = 12*A computed like the Z80 (8-bit, last carry in D)
mul12:  asl a
        asl a
        sta ze
        asl a
        clc
        adc ze
        sta ze
        lda #0
        adc #0
        sta zd
rts0:   rts

; gear_x: X = offset of the current gear entry in T_EAB5
gear_x: lda ZV_E965
        sec
        sbc #<T_EAB5
        tax
        rts

; =================================================================== SE96A
; Speed control / automatic gearbox.  Called twice per main-loop pass.
ZPROC $E96A
        lda #<$752D
        ldx #>$752D
        jsr key98               ; D = A/S key code
        lda $760E
        and #2
        beq LE998
        lda ZV_E967             ; engine dead
        bne LE986
        lda #8
        jmp or0E
LE986:  lda $75F8
        lsr a
        bcs LE98C
        GET_R
        and #7
        bne LE9A8
LE98C:  lda #3
        sta zd
        bne LE9A8
LE998:  lda $760E               ; overheating
        lsr a
        bcc LE9A8
        lda zd
        and #2
        bne LE9A8
        lda $75F8
        and #$10
        bne LE9A8
        lda $75F8
        lsr a
        bcs rts0
LE9A8:  jsr gear_x
        lda zd
        lsr a
        bcs LE9C0
        lda #0                  ; no key / both keys: coast
        sta $760A
        lda ZV_E967+1
        cmp T_EAB5-2,x
        bcc rts0
gup:    txa                     ; next entry
        clc
        adc #6
        tax
        beq :+
        jmp gchange
:
LE9C0:  lda $760A
        and #2
        beq LE9CF
        lda ZV_E969
        cmp zd
        beq rts0
        lda #$FD
        and $760A
        sta $760A
LE9CF:  lda zd
        sta ZV_E969
        lda $760A
        lsr a
        lda T_EAB5,x
        bcs LE9E4
        cmp #$80                ; first pass of a press: half step
        ror a
        inc $760A
LE9E4:  sta p_t0
        lda zd
        and #2
        bne LE9E9
        lda ZV_E967             ; accelerate
        cmp #15
        bcs LEA1E
        adc ZV_E967+1
        eor #$FF
        clc
        adc #$22                ; C = 0: $21 - (speed + revs)
        tax                     ; the delay C the original patches into EA1A
        lda #SND_REV
        jsr snd_fx
        jmp LEA1E
LE9E9:  lda ZV_E967             ; brake
        cmp #6
        bcc LE9FC
        sbc #6
        bmi LE9FB
        lda #SND_SCREECH
        jsr snd_fx
LE9FB:  asl p_t0
LE9FC:  lda p_t0
        jsr neg
        sta p_t0
LEA1E:  jsr gear_x
        lda ZV_E967+1
        clc
        adc p_t0
        bpl LEA30
        lda zd                  ; revs < 0
        and #2
        beq gup
        bne LEA37
LEA30:  cmp T_EAB5+1,x
        bcs LEA74
        cmp T_EAB5+2,x
        bcs LEA84
LEA37:  lda T_EAB5+3,x          ; below min
        and #$20
        beq LEA40
        lda T_EAB5+2,x
        bne LEA84               ; (min revs are never 0)
LEA40:  txa                     ; previous entry
        sec
        sbc #6
        tax
        bne gchange
LEA74:  lda T_EAB5+3,x          ; above max
        and #$40
        bne :+
        jmp gup
:
        lda T_EAB5+1,x
        bne LEA84               ; (max revs are never 0)

; CHANGE: X = new entry
gchange:
        txa
        clc
        adc #<T_EAB5
        sta ZV_E965
        lda #>T_EAB5
        adc #0
        sta ZV_E965+1
        lda T_EAB5+3,x
        and #$1F
        beq LEA61
        sta p_t2                ; revs = (speed*16)/r + 1 (8-bit, by
        lda ZV_E967             ; counting subtractions like the Z80)
        sta p_t0
        lda #0
        sta p_t1
        ldy #4
@s:     asl p_t0
        rol p_t1
        dey
        bne @s
@d:     iny
        lda p_t0
        sec
        sbc p_t2
        sta p_t0
        lda p_t1
        sbc #0
        sta p_t1
        bcs @d
        tya
LEA61:  cmp #$12
        bcc LEA68
        lda #$11
LEA68:  ldy T_EAB5+3,x
        bpl LEA84
        lda $760A               ; neutral: latch
        ora #2
        sta $760A
        lda #0
LEA84:  sta ZV_E967+1           ; STORE revs
        lda T_EAB5+3,x
        and #$1F
        beq LEAAA
        tay                     ; speed = (revs * r) >> 4
        lda #0
        sta p_t3
@m:     clc
        adc ZV_E967+1
        bcc :+
        inc p_t3
:       dey
        bne @m
        ldy #4
@r:     lsr p_t3
        ror a
        dey
        bne @r
        ldy T_EAB5,x
        bpl LEAAA
        jsr neg                 ; reverse
        sta ZV_E967
        lda #0
        beq LEAAD
LEAAA:  sta ZV_E967
LEAAD:  jsr Z_A36F
        jmp ixp

; =================================================================== SEAE2
ZPROC $EAE2
        jsr iyp
        jsr ixp
        lda $7793
        and #2
        beq LEAF9
LEAF0:  lda #0
        sta $75F6
        sta $75F7
        sta zl
        sta zh
        jmp Z_9498
LEAF9:  lda $7793
        and #4
        beq :+
        jsr Z_A496
:       lda #0
        sta zd
        lda $7610
        lsr a
        bcs LEB19
        jsr Z_E96A
        lda #<$7524
        ldx #>$7524
        jsr key98               ; J / L
        lda #<$752A
        sta zl
        lda #>$752A
        sta zh
        jsr Z_F37A              ; K
        bne LEB19
        lda zd
        ora #4
        sta zd
LEB19:  ldx ZV_EADF
        stx ze
        lda zd
        sta ZV_EADF
        ora ze
        lsr a
        bcs LEB2C
        lda zd
        and ze
        and #4
        beq LEB2C
        jsr Z_F549              ; fire
LEB2C:  lda ZV_E967
        beq LEAF0
        PUSHDE
        PUSHBC
        jsr Z_F4A7
        POPBC
        POPDE
        jsr Z_F448
        lda $760B
        sta ze
        lda $7793
        sta zc
        jsr Z_EE51
        lda ze
        and #2
        beq :+
        jmp LEF49
:       lda zd
        ora #$FA
        cmp #$FF
        bne :+
        jmp LEEB9
:       lda $7797
        beq LEB7E
        lda ZV_F470             ; SKID_STEP
        asl a
        clc
        adc ZV_F470
        lsr a
        and #7
        pha
        lda #0
        sta ZV_F470
        jsr Z_B905
        pla
        jsr Z_ED87
        jsr Z_EDE9
        jsr wheel1
LEB75:  jsr Z_F2D1
        bne :+
        rts
:
        jsr Z_F3D7
        jmp LEB75
LEB7E:  lda zc
        and #4
        beq :+
        jmp LEE6F
:       lda zd
        lsr a
        bcc LEB88
        jmp LECEA
LEB88:  jsr wheel1
LEB8F:  lda ZV_F470
        beq LEBDE
        jsr exx
        sta zb
LEB98:  lda ZV_E967
        jsr Z_ECA8
        lda $760C
        beq LEBAD
        jsr hlae
        jsr Z_EBEF
        beq LEB98
LEBAD:  lda ZV_EE4E
        ldx ZV_E967
        bmi LEBBA
        sec
        sbc zc
        bcs LEBBB               ; (C is ignored; always taken or falls)
        bcc LEBBB
LEBBA:  clc
        adc zc
LEBBB:  sta zb
        cmp #$67
        bcs LEBC6
        lda $75F1
        and #2
        bne LEC83
LEBC6:  lda $75F5
        clc
        adc #$63
        cmp zb
        bcs LEBD6
        tax
        lda $75F1
        and #8
        beq LEBD6
        txa
        sta zb                  ; past the far end (;?)
        lda ZV_EE4E
        jsr neg
        clc
        adc zb
        bcc LEC88               ; (C ignored)
        bcs LEC88
LEBD6:  lda zb
        sta ZV_EE4E
        lda zc
        sta ZV_F470
LEBDE:  asl a
        sta $779D
        jsr Z_EE32
        jsr exx
        lda #$0C
        sta za2
        jsr Z_F4BA
        jmp Z_F491
rts1:   rts

LEC83:  lda ZV_EE4E             ; past the near end (;?)
        sec
        sbc #$67
LEC88:  sta zc
        lda ZV_E967
        bpl :+
        jsr neg
:       cmp #6
        bcs LEC9D
        lda #1
        sta zd
        jsr SEC6C
        jmp LEBAD
LEC9D:  jsr wreck
        jmp LEBAD

; ------------------------------------------------- SEBEF HIT_OBJECT_AHEAD
; HL = cell, D = scan e, C = step.  Returns NZ (A=1) normally, Z (A=0) if the
; object was removed.
ZPROC $EBEF
        PUSHBC
        jsr Z_F43A
        ldy #2
        lda (ziyl),y
        lsr a
        bcs LEC04
        jsr Z_F38B              ; non-solid: run over it
        POPBC
        jsr iyp
        lda zc
        sta zb
        lda #0
        rts
LEC04:  ldx #1
        stx zd
        lsr a
        bcc LEC41
        dec zd                  ; wanted criminal car
        sta zb
        ldy #11
        lda (ziyl),y
        cmp #4
        bcc LEC41
        lda zb
        lsr a
        bcc LEC27
        jsr Z_DBD7
        ldy #7
        lda (zixl),y
        sec
        sbc #1
        sta (zixl),y
        bne LEC36
        jsr iy10b5
        ldy #7
        lda #1
        sta (zixl),y
        bne LEC36
LEC27:  ldx $750F
        dex
        bne LEC33
        jsr iy10b5
        ldx #10
LEC33:  stx $750F
LEC36:  jsr ixp
        lda #5
        jsr Z_F36A
        lda #0
        sta zd
LEC41:  POPBC
        ldy #5
        lda (ziyl),y
        and #3
        beq LEC50
        jsr iyp
        lda #0
        beq LEC5B
LEC50:  ldy #11
        lda (ziyl),y
        pha
        jsr iyp
        pla
        lsr a
        adc #0
LEC5B:  sec
        sbc zc
        bcs SEC6C
        cmp #$FC
        bcs SEC6C
        jsr wreck               ; rear-ended: wrecked
        jmp LEC72
SEC6C:  PUSHBC
        lda zd
        jsr Z_F3F6
        POPBC
LEC72:  lda zc
        sec
        sbc $760C
        sta zc
        lda #1
        rts
iy10b5: ldy #10                 ; set 5,(iy+10)
        lda (ziyl),y
        ora #$20
        sta (ziyl),y
        rts

; ------------------------------------------------- SECA8 / SECAB SCAN_AHEAD
; B = cells; A bit 7 = direction (the Z80 sign flag); SECA8 loads HL.
ZPROC $ECA8
        pha
        jsr hlee
        pla
ZPROC $ECAB
        ldx #0
        stx $760C
        tax
        bmi LECB9
        dec zl
        dec zl
        dec zl
        lda #$2D
        bne LECBB
LECB9:  lda #$2C
LECBB:  ldx zb
        stx zc
        tax
        PUSHHL
        txa
        jsr Z_F319
        beq LECC9
        jsr aehl
        lda zb
        sta $760C
LECC9:  POPHL
        lda $7792
        bne :+
        rts
:
        jsr side
        bne LECD7
        inc zh
        inc zh
LECD7:  dec zh
        lda zc
        sta zb
        jsr Z_F31C
        bne :+
        rts
:
        lda zb
        cmp $760C
        bcs :+
        rts
:
        sta $760C
        jmp aehl

; ------------------------------------------------- LANE_START (LECEA)
LECEA:  jsr wheel0
        lda zh
        sta zb
        lda zd
        and #2
        bne LED04
        lda #8
        jsr or93
        inc zh
        lda $75F1
        and #1
        sta p_side
        lda $75D7
        bne LED10
LED04:  lda #$F7
        jsr an93
        dec zh
        lda $75F1
        and #4
        sta p_side
        lda $75D6
LED10:  cmp zb
        bne LED18
        lda ze                  ; already in the edge column (;?)
        ora #2
        sta ze
        bne LED49
LED18:  PUSHBC
        PUSHDE
        inc zl
LED1B:  PUSHHL
        lda #4
        sta zb
        lda #$2D
        jsr Z_F319
        beq LED42
        lda ze
        sta zd
        lda #0
        sta zc
        jsr Z_EBEF
        tax
        POPHL
        txa
        beq LED1B
        lda ZV_E967
        bne LED37
        sta ZV_F470
LED37:  POPDE
        POPBC
        jmp LEB8F
LED3C:  jsr Z_F3F4
LED3F:  jmp LEB8F
LED42:  lda ze
        and #2
        tax
        POPHL
        POPDE
        POPBC
        txa
        beq LED5C
LED49:  lda p_side
        bne LED3C
        lda ZV_EE4E
        sec
        sbc #$67
        bcc LED3C
        adc #2                  ; C = 1: +3
        sec
        sbc $75F5
        bcs LED3C
        bcc LED3F
LED5C:  lda ZV_F470
        jsr Z_ED6E
        lda #4
        jsr or93
        jmp LEB8F

; ------------------------------------------------- SED69 / SED6E LANE_SHIFT
ZPROC $ED69
        lda ZV_F470
        beq rts2
ZPROC $ED6E
        tax
        lda ze
        lsr a
        lda #1
        bcs LED7C
        cpx #2
        bcc LED7C
        lda #2
LED7C:  pha
        jsr hlee
        pla
        jsr Z_B0AA
        lda zh
        sta ZV_EE4E+1
rts2:   rts

; ------------------------------------------------- SED87 MOVE_LATERAL(A)
ZPROC $ED87
        sta zd
        lda $7797
        lsr a
        lda #0
        ror a
        eor ZV_E967
        sta p_t0                ; bit 7 = negate
        lda zd
        bit p_t0
        bpl :+
        jsr neg
:       tax
        jsr side
        beq :+
        txa
        jsr neg
        tax
:       txa
        clc
        adc $7792
        sta $7792
        cmp #8
        bcc rts2
        lda $7798
        sta zl2
        lda $7799
        sta zh2
        lda $7793
        sta zc
        lda $7792
        asl a                   ; CY = bit 7 (went below 0)
        lda $7792
        jmp Z_B83A

; ------------------------------------------------- SEDBA KERB_CHECK -> CY ok
ZPROC $EDBA
        jsr side
        bne LEDDC
        lda $75D6
        sta zb
        cmp $7799
        bcc LEDD1               ; b < (iy+7): CY = 1
        bne LEDD3
LEDCA:  lda $7792
        cmp #4
        bcc LEDD3
LEDD1:  sec
        rts
LEDD3:  lda zb
        sta $7799
        lda #4
        sta $7792
        clc
        rts
LEDDC:  lda $75D7
        sta zb
        cmp $7799
        beq LEDCA
        bcc LEDD3
        rts                     ; C = 1

; ------------------------------------------------- SEDE9
ZPROC $EDE9
        bit $7793
        bvs LEDF6
        jsr Z_EDBA
        bcc :+
        rts
:
        jmp Z_F3F4
LEDF6:  lda $779A               ; (;?)
        bne LEE02
        lda $7792
        cmp #4
        bcc :+
        rts
:
LEE02:  jsr side
        bne LEE1C
        lda $7798
        clc
        adc $779A
        jsr LEE2Bs
        bcc LEE2B
        inc $7799
        bcs LEE2B
LEE1C:  lda $7798
        sec
        sbc $779A
        jsr LEE2Bs
        bcs LEE2B
        dec $7799
LEE2B:  lda #4
        sta $7792
        jmp Z_F3F4
LEE2Bs: sta $7798               ; (iy+6) = A ; (iy+8) = 0, C kept
        lda #0
        sta $779A
        rts

; ------------------------------------------------- SEE32 COMMIT_POS
ZPROC $EE32
        jsr hlee
        ldy #0
        lda (zl),y
        and #$C0
        cmp #$C0
        beq LEE44
        lda #$BF
        jsr an93
        jmp poshl
LEE44:  lda #$40                ; (;?)
        jsr or93
        lda zl
        sta $7798
        lda #$C0
        jmp Z_B9EE

; ------------------------------------------------- SEE51 GET_POS
ZPROC $EE51
        lda ze
        and #$FE
        sta ze
        jsr hlpos
        jsr Z_F53D
        tay
        lda zc
        and #$40
        beq :+
        sty zh
        lda $779B
        clc
        adc #$64
        sta zl
:       lda zl
        sta ZV_EE4E
        lda zh
        sta ZV_EE4E+1
        sty ZV_EE4E+2
        cpy zh
        bne rts3
        inc ze
rts3:   rts

; ------------------------------------------------- LANE_CONT (LEE6F)
LEE6F:  lda ze
        and #$FB
        sta ze
        lda zd
        lsr a
        bcc LEE94
        lda zc
        lsr a
        lsr a
        eor zd
        and #2
        bne LEE94
        PUSHBC
        PUSHDE
        jsr Z_A487
        POPDE
        POPBC
        lda zc
        eor #8
        sta $7793
        sta zc
        jsr wheel0
        lda ze
        ora #4
        sta ze
LEE94:  PUSHDE
        jsr Z_ED69
        POPDE
        lda ze
        lsr a
        bcc LEEAB
        lda $7792
        cmp #4
        bne LEEAB
LEEA4:  PUSHDE
        jsr Z_A487
        POPDE
        jmp LEEB1
LEEAB:  lda $7793
        and #4
        beq LEEA4
LEEB1:  lda ze
        and #4
        bne :+
        jmp LEB88
:       jmp LEB8F

; ------------------------------------------------- TURN_START (LEEB9)
LEEB9:  jsr wheel0
        lda #$3F
        jsr an0B
        lda ZV_E967
        sta zl
        lda $7797
        sta zb
        beq LEF0B
        lda #$80
        jsr or0B
        ldx zb
        lda zd
        and #2
        beq :+
        txa
        eor #$FF
        tax
:       txa
        ldx zl
        bpl :+
        eor #$FF
:       lsr a
        bcs LEF0B
        PUSHDE                  ; U-turn
        lda #4
        sta $75FE
        inc $75F0
        inc $75F0
        lda zb
        eor #1
        sta zb
        PUSHBC
        jsr Z_F2BC
        jsr Z_7CA1
        jsr Z_F2A7
        jsr iyp
        POPBC
        lda zb
        sta $7797
        POPDE
        lda zd
        ora #8
        sta zd
        lda $7793
        sta zc
LEF0B:  lda #2
        jsr or0B
        lda zc
        ora #$0C
        sta zc
        lda zd
        and #2
        beq LEF1A
        inc zb
        lda zc
        and #$F7
        sta zc
LEF1A:  lda zc
        sta $7793
        lda ZV_E967
        bmi LEF2B
        sec
        sbc #9
        bcs LEF34
        lda #0
        beq LEF34
LEF2B:  lda #$40                ; (;?)
        jsr or0B
        lda zb
        eor #1
        sta zb
        lda #0
LEF34:  cmp #4
        bcc :+
        lda #3
:       sta $760D
        lda $7797
        bne :+
        lda zb
        sta $7797
:       lda zd
        and #8
        beq :+
        rts
:

; ------------------------------------------------- TURN_STEP (LEF49)
LEF49:  lda ZV_F470
        cmp #5
        bcc :+
        sbc #1
:       sta ZV_F30C
        lda #$EF
        jsr an0B
        jsr Z_B905
LEF5B:  lda #$F7
        jsr an0B
        lda #0
        sta ZV_F470
        lda ZV_F30C
        bne :+
        jmp LF1BE
:       lda ZV_E967
        and #$40                ; (the Z80 tests bit 6 here: sign of 2*speed)
        eor $760B
        asl a
        eor $760B
        asl a                   ; CY = going backwards through the phases
        lda $7797
        sta zb
        bcc LEFA1
        cmp #2
        bcc LEF97
        sbc #2
        cmp #2
        bcs LEFB4
        bcc LEFAB
LEF97:  lda #$FD
        jsr an0B
        jsr Z_A487
        jmp LF1BE
LEFA1:  cmp #6
        bcs LEF97
        adc #2
        cmp #6
        bcc LEFB4
LEFAB:  pha
        lda #$FD
        jsr an0B
        jsr Z_A487
        pla
LEFB4:  sta $7797
        and #6
        cmp #4
        bne LEFD0
        lda $760D
        beq LEFD0
        dec $760D
        lda zb
        sta $7797
        lda #SND_SCREECH
        jsr snd_fx
LEFD0:  lda ZV_B8F9+5
        cmp $7797
        bcc LEFDB
        lda $7797
LEFDB:  asl a
        and #$0C
        dec ZV_F30C
        ora ZV_F30C
        tax
        lda T_F30D,x
        and #7
        sta ZV_F470
        lda T_F30D,x
        lsr a
        lsr a
        lsr a
        and #7
        jsr Z_ED87
        lda $7799
        sta zh
        lda ZV_E967
        asl a
        lda ZV_F470
        bcs :+
        jsr neg
:       bit $7793
        bvs LF03D
        clc
        adc $7798
        sta zl
        sta $7798
        ldy #0
        lda (zl),y
        cmp #$FD
        bcc :+
        jmp LF098
:
        and #$C0
        cmp #$C0
        beq :+
        jmp LF098
:
        lda zl                  ; (;?) drove onto a junction cell
        sec
        sbc #$64
        sta $779B
        ldx #0
        stx $779A
        jsr Z_B9DD
        jsr poshl
        jsr exx
        lda #$40
        jsr or93
        jmp LF098
LF03D:  clc                     ; (;?) junction mode
        adc $779B
        sta $779B
        sta zb
        jsr Z_B9DD
        lda $779A
        bne LF075
        jsr poshl
        jsr Z_F53D
        sta zh
        lda $779B
        clc
        adc #$64
        sta zl
        ldy #0
        lda (zl),y
        and #$C0
        cmp #$C0
        beq LF098
        lda #$BF
        jsr an93
        jsr poshl
        jmp LF098
LF075:  lda $779B
        bpl LF083
        lda #0
        sta $779B
        jsr Z_B9DD
LF083:  lda $779A
        sta ze
        lda #0
        sta zd
        jsr side
        beq LF092
        lda ze
        clc
        adc zl
        sta zl
        bcc LF095
        inc zh
        bcs LF095
LF092:  lda zl
        sec
        sbc ze
        sta zl
        bcs LF095
        dec zh
LF095:  jsr poshl
LF098:  lda $75FD
        ora $760B
        bpl LF0C9
        bit $7793
        bvc LF0C9
        lda $779A               ; (;?)
        bne LF0B4
        lda $7792
        cmp #4
        bcs LF0C9
LF0B4:  lda #4
        sta $7792
        lda #0
        sta $779A
        lda $779B
        jmp LF164b
LF0C9:  jsr Z_F2FE
        cmp #$67
        bcs :+
        jmp LF140
:
        sbc #$64
        cmp $75F5
        bcs LF148
        bit $7793               ; (;?) inside the crossing zone
        bvs LF1BEj
        jsr side
        bne LF100
        lda $75D6
        sta zb
        sec
        sbc $7799
        bcc LF1BEj
        beq LF0F6
        tax
        lda $75F1
        and #4
        jmp LF110
LF0F6:  lda $7792
        cmp #4
        bcc LF131
LF1BEj: jmp LF1BE
LF100:  lda $75D7
        sta zb
        sec
        sbc $7799
        beq LF0F6
        bcs LF1BEj
        tax
        lda $75F1
        and #1
LF110:  bne LF131
        txa
        pha
        jsr Z_B9EE
        pla
        sta ze
        ldx #0
        tay
        bpl :+
        dex
        jsr neg
:       stx zd
        sta $779A
        lda zl
        sec
        sbc ze
        sta zl
        lda zh
        sbc zd
        sta zh
        jsr poshl
        lda #$40
        jsr or93
        jmp LF098
LF131:  lda zb
        sta $7799
        lda #4
        sta $7792
        bne LF0B3
LF140:  ldx #2
        lda #3
        bne LF150
LF148:  ldx #8
        lda $75F5
        sec
        sbc #1
LF150:  sta p_t0
        txa
        and $75F1
        beq LF174
        bit $7793               ; (;?) wall at the end of the block
        lda p_t0
        bvs LF164
        clc
        adc #$64
        sta $7798
        bcc LF0B3
        bcs LF0B3
LF164:  sta $779B
LF164b: jsr Z_B9DD
        jsr poshl
LF0B3:  lda #8
        jsr or0B
        jmp LF098
LF174:  bit $7793
        bvc LF1B5
        lda $779A               ; (;?)
        clc
        adc #1
        asl a
        asl a
        asl a
        sec
        sbc $7792
        cmp #7
        bcs LF1A5
        lda $779A
        bne LF195
        lda $7792
        cmp #4
        bcs LF1BE
LF195:  lda #0
        sta $779A
        lda #4
        sta $7792
        bne LF0B3
LF1A5:  lda $779B
        sec
        sbc #3
        bmi @three
        lda $75F5
        sec
        sbc #1
        jmp LF164
@three: lda #3
        jmp LF164
LF1B5:  jsr Z_EDBA
        bcs LF1BE
        lda #8
        jsr or0B
LF1BE:  lda $760B
        and #8
        beq LF1D2
        jsr Z_B913
        jmp LF1DB
LF1D2:  jsr Z_F2D1
        beq LF1E2
LF1DB:  lda #$12
        jsr or0B
        jmp LEF5B
LF1E2:  lda $760B
        and #$10
        beq LF1F5
        lda #0
        sta $760D
        jsr Z_F3D7
LF1F5:  lda $760B
        and #2
        beq LF22C
        bit $7793
        bvc rts4
        lda $779A               ; (;?)
        bne LF20C
        lda $7792
        cmp #4
        bcs rts4
LF20C:  lda $7797
        pha
        jsr Z_F288
        pla
        tax
        and #1
        sta zc
        txa
        and #6
        eor #$FF
        sec
        adc #7
        eor zc
        sta $7797
        lda $760B
        eor #$80
        sta $760B
rts4:   rts
LF22C:  lda $7797
        cmp #1
        bne LF237
        lda #0
        sta $7797
LF237:  tax
        beq LF26A
        bit $760B
        bmi rts4
        bit $75FD
        bmi rts4
        lda $75F1
        and #5
        cmp #5
        beq rts4
        lda $7798
        bit $7793
        bvc LF25A
        lda $779B
        clc
        adc #$64
LF25A:  sec
        sbc #$67
        bcc rts4
        adc #2                  ; C = 1: +3
        cmp $75F5
        bcs rts4
        jsr Z_F288
        lda #0
        sta $7797
LF26A:  lda $7792
        beq rts4
        lda #4
        jsr or93
        lda $7792
        cmp #4
        bne rts4
        jsr Z_F53D
        bit $7793
        bvs LF283
        cmp $7799
        bne rts4
LF283:  lda #$FB
        jmp an93

; ------------------------------------------------- SF288 ROTATE_HEADING
ZPROC $F288
        lda $7797
        lsr a
        lda #0
        bcc LF297
        dec $75F0
        bcs LF29E
LF297:  inc $75F0
        lda #1
LF29E:  sta $75FE
        jsr Z_F2BC
        jsr Z_8F0B
        jsr Z_7CA1
ZPROC $F2A7
        lda $7508
        sec
        sbc $75F6
        sta $7508
        lda $74FF
        sec
        sbc $75F6
        and #7
        sta $74FF
        rts

; ------------------------------------------------- SF2BC CLEAR_VIEW_ATTR
; The Spectrum blacked out the attributes of the 3D view (12 rows x 28
; columns).  Oric: Spectrum rows 0-95 = HIRES lines 4-99; column 0 becomes
; black paper and columns 1-37 blank (38-39 = the static A-pillar).  S862E repaints all
; of it at the next view copy.
ZPROC $F2BC
        lda #<($A000+4*40)
        sta p_t0
        lda #>($A000+4*40)
        sta p_t1
        ldx #96
@ln:    ldy #37                 ; columns 38-39 (A-pillar) untouched
        lda #$40
@px:    sta (p_t0),y
        dey
        bne @px
        lda #$10
        sta (p_t0),y
        lda p_t0
        clc
        adc #40
        sta p_t0
        bcc :+
        inc p_t1
:       dex
        bne @ln
        rts

; ------------------------------------------------- SF2D1 PLACE_PLAYER
; Z = ok, NZ = blocked (record restored)
ZPROC $F2D1
        jsr iyp
        jsr hlpos
        jsr exx
        lda #$0C
        sta za2
        jsr Z_F4BA
        bne LF2E2
        jsr Z_F491
        lda #0
        rts
LF2E2:  jsr Z_F422
        ldy #2
        lda (ziyl),y
        lsr a
        bcs LF2F4
        jsr Z_F38B
        jmp Z_F2D1
LF2F4:  jsr iyp
        jsr Z_B913
        lda #1
        rts

; ------------------------------------------------- SF2FE ROW_POS (IY)
ZPROC $F2FE
        ldy #1
        lda (ziyl),y
        and #$40
        bne :+
        ldy #6
        lda (ziyl),y
        rts
:       ldy #9
        lda (ziyl),y
        clc
        adc #$64
        rts

; ------------------------------------------------- SF319 / SF31C SCAN_LINE
; A = $2D (dec l) or $2C (inc l) as on the Spectrum; HL, B = count.
; Z: nothing in B cells (A=0, B=0).  NZ: A = cell, B = cells left incl. it.
ZPROC $F319
        cmp #$2D
        lda #$C6                ; DEC zp
        bcs :+
        lda #$E6                ; INC zp
:       sta scan_op
ZPROC $F31C
        lda #0
        sta ze
LF31E:
scan_op: inc zl                 ; opcode patched
        ldy #0
        lda (zl),y
        bne LF325
LF322:  dec zb
        bne LF31E
        lda #0
        rts
LF325:  cmp #$FD
        bcs LF332
        tax
        and #$C0
        cmp #$C0
        beq LF335
        txa
LF332:  ora #0                  ; NZ (A = cell)
        rts
LF335:  PUSHBC                  ; junction cell
        PUSHHL
        txa
        jsr Z_B98D
        ldy #0
        lda (zl),y
        bne LF341
        POPHL
        POPBC
        lda #0
        beq LF322
LF341:  dec ze
        pla
        pla
        POPBC
        jsr side
        bne :+
        dec ze
:       ldy #0
        lda (zl),y
        rts

; ------------------------------------------------- SF34B / SF36A
; penalty / score += A (units of 10), then print it.  HL preserved.
ZPROC $F34B
        ldx #$0D-$0B
        ldy #$50
        bne LF34E
ZPROC $F36A
        ldx #0
        ldy #$C0
LF34E:  sty pr_x
        tay
        PUSHHL
        tya
        clc
        adc $750B,x
        sta $750B,x
        sta zl
        lda $750C,x
        adc #0
        sta $750C,x
        sta zh
        jsr Z_A4C9
        .byte $01, $FF
pr_x:   .byte $40, $B0, $FC, $00, $00, $30, $00
        POPHL
        rts

; ------------------------------------------------- SF38B RUN_OVER (HL, IY)
ZPROC $F38B
        ldy #1
        lda (ziyl),y
        and #$7F
        sta (ziyl),y
        dey
        lda (zl),y
        bpl LF39C
        lsr a                   ; (;?)
        lsr a
        lsr a
        and #7
        sta (zl),y
        bpl LF3A4
LF39C:  tya
        sta (zl),y
        dec zl
        lda (zl),y
        cmp #$FF
        beq LF39C
LF3A4:  ldy #4
        lda (ziyl),y
        cmp #8
        bne LF3B0
        jsr Z_F6CF
        jmp Z_F3B6
LF3B0:  cmp #4                  ; (;?)
        beq Z_F3B6
        lda #2
        bne LF3CF
ZPROC $F3B6
        lda #10
        jsr Z_F34B
        lda #SND_CHIRP
        jmp snd_fx
LF3CF:  jsr Z_F34B
        lda #10
        sta zb
        tax
        lda #SND_CRASH
        jmp snd_fx

; ------------------------------------------------- SF3D7 CRASH
ZPROC $F3D7
        lda ZV_E967
        bmi Z_F3F4
        cmp #15
        bcc LF3EA
        jsr wreck
        lda ZV_E967
LF3EA:  cmp #4
        lda #1
        bcc :+
        lda #2
:       pha
        bne LF40A
; LF3F4 / SF3F6 BUMP(A)
ZPROC $F3F4
        lda #1
ZPROC $F3F6
        pha
        lda ZV_E967
        bmi LF40A
        cmp #4
        bcc LF40A
        lda #<(T_EAB5+20)       ; EAC9 2nd gear, speed 3, revs 10
        ldx #>(T_EAB5+20)
        ldy #3
        sty ze
        ldy #10
        bne LF410
LF40A:  lda #<(T_EAB5+8)        ; EABD neutral, speed 0, revs 3
        ldx #>(T_EAB5+8)
        ldy #0
        sty ze
        ldy #3
LF410:  sty zd
        sta ZV_E965
        stx ZV_E965+1
        sta zl
        stx zh
        sty ZV_E967+1
        lda ze
        sta ZV_E967
        jsr Z_A36F
        jsr ixp
        pla
        jmp LF3CF

; ------------------------------------------------- SF422 / SF43A OBJECT_AT
; -> IY = record of the object in cell HL
ZPROC $F422
        ldy #0
LF423:  lda (zl),y
        bne LF429
        clc
        lda zl
        adc zc
        sta zl
        lda zh
        adc zb
        sta zh
        jmp LF423
LF429:  lda zc
        lsr a
        lsr a
        and #$3E
        sta p_t0
        lda zc
        lsr a
        lda #$80
        bcc :+
        lsr a                   ; A = $40, cleared by the and below
:       and #$80
        ora p_t0
        sta zc
        jsr side
        beq LF43B
        inc zc
        bne LF43B
ZPROC $F43A
        lda zd
        sta zc
LF43B:  jsr Z_B91B
        jsr mul12
        clc
        lda ze
        adc #<$7702
        sta ziyl
        lda zd
        adc #>$7702
        sta ziyh
        rts

; ------------------------------------------------- SF448 STEP_FROM_SPEED
ZPROC $F448
        lda ZV_E967
        bpl :+
        jsr neg
:       asl a
        tax
        lda $75F8
        and #2
        beq :+
        inx
:       lda $75F8
        lsr a
        lda T_F471,x
        bcc :+
        lsr a
        lsr a
        lsr a
        lsr a
:       and #$0F
        sta ZV_F470
        rts

; ------------------------------------------------- SF491 SET_RENDER_STEP
ZPROC $F491
        ldx #0
        lda ZV_F470
        ldy ZV_E967
        bpl LF4A2
        jsr neg
        beq LF4A2
        dex
LF4A2:  sta $75F6
        stx $75F7
        sta zl
        stx zh
        rts

; ------------------------------------------------- SF4A7 / SF4BA / SF4EF
ZPROC $F4A7
        jsr Z_F4EF
        bne :+
        jmp Z_8EAB
:       lda #0                  ; (;?)
        tay
        ldx #4
@z:     sta (ze),y
        dec ze
        dex
        bne @z
        inc ze
        jsr hlpos
        txa
        sta (zl),y
        rts

ZPROC $F4BA
        jsr Z_F4EF
        bne :+
        jmp Z_B412
:       lda #<(ZV_FD60+$0B+12)  ; (;?) DFD77
        sta zl
        lda #>(ZV_FD60+$0B+12)
        sta zh
        lda $75F2
        lsr a
        bcc :+
        lda #1
        rts
:       ldx ze                  ; ex de,hl
        lda zl
        sta ze
        stx zl
        ldx zd
        lda zh
        sta zd
        stx zh
        lda #$FF
        sta zc
        sta zb
        jsr Z_B49A
        bne rts5
        jsr exx
        lda #$F4
        sta zc
        ldy #0
        lda (zl),y
        bne rts5
        jsr exx
        jsr side
        beq :+
        lda #$FE
        bne @s
:       lda #$FD
@s:     ldy #0
        ldx #3
@w:     sta (zl),y
        dec zl
        lda #$FF
        dex
        bpl @w
        inc zl
        jsr exx
        lda za2
        ldy #0
        sta (zl),y
        lda #0
rts5:   rts

ZPROC $F4EF
        bit $7793
        bvs LF51B
        jsr Z_F53D
        cmp $7799
        beq LF4FF
LF4FD:  lda #0
        rts
LF4FF:  lda $75F5
        clc
        adc #$64
        sta zb
        lda $7798
        sec
        sbc zb
        cmp #3
        bcs LF4FD
        lda $7798               ; (;?)
        sta ze
        ldx $7799
        jsr side
        beq :+
        dex
        dex
:       inx
        stx zd
        rts
LF51B:  lda $779A               ; (;?)
        bne LF4FD
        lda $779B
        cmp #3
        bcs LF4FD
        adc #$64
        sta ze
        jsr side
        bne :+
        ldx $75D6
        inx
        bne @d
:       ldx $75D7
        dex
@d:     stx zd
        lda ze                  ; NZ
        rts

; ------------------------------------------------- SF53D EDGE_COLUMN (IY)
ZPROC $F53D
        ldy #1
        lda (ziyl),y
        and #$20
        bne :+
        lda $75D6
        rts
:       lda $75D7
        rts

; ------------------------------------------------- SF549 FIRE
ZPROC $F549
        bit $7793
        bvs rts5
        lda $7797
        bne rts5
        PUSHDE
        jsr Z_F692
        sta ZV_F691
        ldx #5
        lda #SND_CRASH          ; gunshot
        jsr snd_fx
        lda #$14
        sta zb
        jsr hlpos
        lda #0
        jsr Z_ECAB
        lda #$18
        sec
        sbc zb
        sta zb
        lda $75F1
        and #2
        beq LF57D
        lda $7798               ; (;?)
        sec
        sbc #$64
        cmp zb
        bcs LF57D
        sta zb
LF57D:  lda zb
        jsr mul12
        clc
        lda ze
        adc #<$790A
        sta ziyl
        lda zd
        adc #>$790A
        sta ziyh
        ldy #0
        lda #$4F
        sec
        sbc (ziyl),y
        bcc LF5D6
        adc #$80                ; C = 1: +$81
        sta tr_dy
        ldx #0
        lda ZV_F691
        sec
        sbc #$7A
        bcs LF59F
        inx
        jsr neg
LF59F:  stx zc
        sta p_t0                ; |off|
        ldx #$36
        jsr pmul
        sta p_t1                ; e1
        ldy #6
        lda (ziyl),y
        tax
        jsr pmul
        sec
        sbc p_t1
        jsr neg
        ldx zc
        bne :+
        eor #$80
:       sta tr_dx
        lda p_t1
        ldx zc
        beq :+
        jsr neg
:       clc
        adc #$70
        sta tr_x0
        lda p_t0
        sta zd
        lda p_t1
        sta ze
        jsr Z_A4D6
        .byte $8C, $86, $87
tr_x0:  .byte $00, $4E, $01
tr_dx:  .byte $00
tr_dy:  .byte $00, $00
LF5D6:  lda $760C
        beq LF684j
        jsr hlae                ; something was hit
        jsr Z_F43A
        lda ZV_B161
        cmp #4
        bcs LF614
        jsr Z_F692
        sta zb
        dec zb
        lda ZV_F691
        clc
        adc #3
        sec
        sbc zb
        bcc LF684j
        cmp #3
        bcs LF684j
        jsr Z_927B
        jsr Z_9230
        ldy #1
        lda (ziyl),y
        and #$7F
        sta (ziyl),y
        jsr Z_F6CF
        jsr Z_F3B6
LF684j: jmp LF684
LF60F:  jsr Z_F34B
        jmp LF684
LF614:  cmp #$0D
        bcc LF684j
        ldy #1
        lda (ziyl),y
        and #2
        bne LF684j
        lda ZV_F691
        sta zb
        jsr Z_F692
        sec
        sbc zb
        bcc LF684j
        cmp #8
        bcs LF684j
        GET_R
        and #1
        bne LF684j
        ldy #1
        lda (ziyl),y
        ora #2
        sta (ziyl),y
        ldy #11
        lda (ziyl),y
        sta zc
        lda #0
        sta (ziyl),y
        jsr Z_F6C1
        ldy #2
        lda (ziyl),y
        sta zb
        and #2
        bne :+
        lda #$1E                ; innocent car: penalty 300
        bne LF60F
:       lda zb
        and #8
        beq LF65C
        lda zb
        and #4
        bne :+
        lda #$32
        bne LF670
:       ldy #1                  ; immune
        lda (ziyl),y
        and #$FD
        sta (ziyl),y
        ldy #11
        lda zc
        sta (ziyl),y
        jmp LF684
LF65C:  jsr Z_DBD7
        ldy #0
        lda (zixl),y
        ora #$80
        sta (zixl),y
        ldy #6
        lda (zixl),y
        and #8
        beq :+
        lda #$32
        bne LF670
:       jsr Z_DDD3
        lda #5
LF670:  pha
        ldy #11
        lda (ziyl),y
        bne LF680
        ldy #10
        lda (ziyl),y
        and #$20
        beq LF680
        pla
        jmp LF60F
LF680:  pla
        jsr Z_F36A
LF684:  jsr iyp
        jsr ixp
        lda $7793
        sta zc
        POPDE
        rts

; pmul: A = (S8C87(A = p_t0, E = X) rotated right through CY)
pmul:   stx ze
        lda p_t0
        jsr Z_8C87
        ror a
        rts

; ------------------------------------------------- SF692 LATERAL_COORD (IY)
ZPROC $F692
        ldy #1
        lda (ziyl),y
        tax
        and #$40
        bne LF6AE
        ldy #7
        lda (ziyl),y
        sec
        sbc #$50
LF69D:  asl a
        asl a
        asl a
        ldy #0
        sta p_t3
        txa
        and #$20
        bne LF6AA
        lda p_t3
        clc
        adc (ziyl),y
        rts
LF6AA:  lda p_t3
        sec
        sbc (ziyl),y
        rts
LF6AE:  ldy #8                  ; (;?)
        lda (ziyl),y
        pha
        txa
        and #$20
        bne LF6BD
        pla
        jsr neg
        clc
        adc #$0B
        jmp LF69D
LF6BD:  pla
        clc
        adc #$14
        jmp LF69D

; ------------------------------------------------- SF6C1 / SF6CF
ZPROC $F6C1
        ldy #10
        lda (ziyl),y
        and #$50
        cmp #$40
        bne rts6
        lda $75FD
        and #$FE
        sta $75FD
rts6:   rts

ZPROC $F6CF
        lda #<$75FC
        sta zl
        lda #>$75FC
        sta zh
        ldy #6
        lda (ziyl),y
        cmp #$2E
        beq LF6E0
        dec zl
        sec
        sbc $75F5
        cmp #$92
        bne rts6
LF6E0:  ldy #0
        lda (zl),y
        and #$7F
        sta (zl),y
        rts

; ------------------------------------------------- SF6E3 BANG_CHECK
ZPROC $F6E3
        lda $779F
        bpl rts6
        and #2
        bne rts6
        jsr hlpos
        lda $77A4
        cmp zl
        bne rts6
        inc zh
        lda $77A5
        cmp zh
        bne rts6
        lda $7797
        bne rts6
        lda $760E
        and #8
        ora $77A3
        bne rts6
        lda #10
        sta zb
        tax
        lda #SND_CRASH
        jsr snd_fx
        lda #10
        jsr Z_BA56
        .byte $68, $06, "BANG !"
        GET_R
        and #3
        bne rts6
        lda #$1E
        jsr Z_BA56
        .byte $30, $13, "LOTUS INCAPACITATED"
        lda #$0A
        jsr or0E
        lda ZV_E967
        sec
        sbc #6
        bpl :+
        rts
:
        lda #3
        sta $7797
        lda #2
        jsr or0B
        lda #$14
        sta $760D
        rts
