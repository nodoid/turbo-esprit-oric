; player.s - the player's driving code (Spectrum E94D-F756, notes R8 part B)
;
;   SE96A  speed / automatic gearbox          SEAE2  PLAYER_STEP (main loop 7300)
;   lane change, handbrake turn, skid, scan-ahead, collisions, run-over,
;   crash/bump, fire (SF549 + tracer line), "BANG !" hazard check SF6E3,
;   penalty / score adders SF34B / SF36A.
;
; Translated 1:1 from the Z80.  IY is the player record $7792 almost
; everywhere, so the code uses constant addresses ($7792 = iy+0, $7793 = iy+1
; ...) and only goes through (ziyl) where IY can point at another object.
; IX is always $75E1 (constant addresses $75F0.. = ix+15..) except after
; SDBD7, which returns a car record in zixl/zixh.
; ziy / zix are kept equal to the Z80 IY / IX at every external call.
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
        ZVIMPORT $FD6B          ; left junction table (DFD77 = record 1)

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
.macro NEGA
        eor #$FF
        clc
        adc #1
.endmacro
.macro IYPLAYER
        lda #<$7792
        sta ziyl
        lda #>$7792
        sta ziyh
.endmacro
.macro IXMAIN
        lda #<$75E1
        sta zixl
        lda #>$75E1
        sta zixh
.endmacro
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
.macro SETB addr, mask
        lda addr
        ora #mask
        sta addr
.endmacro
.macro RESB addr, mask
        lda addr
        and #<~mask
        sta addr
.endmacro

        .code

; exx: swap BC DE HL with the alternate set.  Preserves A (flags = A).
exx:    pha
        ldx zc
        ldy zc2
        stx zc2
        sty zc
        ldx zb
        ldy zb2
        stx zb2
        sty zb
        ldx ze
        ldy ze2
        stx ze2
        sty ze
        ldx zd
        ldy zd2
        stx zd2
        sty zd
        ldx zl
        ldy zl2
        stx zl2
        sty zl
        ldx zh
        ldy zh2
        stx zh2
        sty zh
        pla
        rts

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
        rts

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
        sta zl
        lda #>$752D
        sta zh
        jsr Z_98F4              ; D = A/S key code
        lda $760E
        and #2
        beq LE998
        lda ZV_E967             ; engine dead
        bne LE986
        SETB $760E, 8
        rts
LE986:  lda $75F8
        lsr a
        bcc LE990
LE98C:  lda #3
        sta zd
        jmp LE9A8
LE990:  GET_R
        and #7
        beq LE98C
        jmp LE9A8
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
        bcc LE9A8
        rts
LE9A8:  lda zd
        lsr a
        bcs LE9C0
        lda #0                  ; no key / both keys: coast
        sta $760A
        jsr gear_x
        lda ZV_E967+1
        cmp T_EAB5-2,x
        bcs gup
        rts
gup:    txa                     ; next entry
        clc
        adc #6
        tax
        jmp gchange
LE9C0:  lda $760A
        and #2
        beq LE9CF
        lda ZV_E969
        cmp zd
        bne :+
        rts
:       RESB $760A, 2
LE9CF:  lda zd
        sta ZV_E969
        jsr gear_x
        lda $760A
        lsr a
        bcs LE9E3
        SETB $760A, 1
        lda T_EAB5,x            ; first pass of a press: half step
        cmp #$80
        ror a
        jmp LE9E4
LE9E3:  lda T_EAB5,x
LE9E4:  sta p_t0
        lda zd
        and #2
        beq LEA00
        lda ZV_E967             ; brake
        cmp #6
        bcc LE9FC
        sec
        sbc #6
        bmi LE9FB
        lda #SND_SCREECH
        jsr snd_fx
LE9FB:  asl p_t0
LE9FC:  lda p_t0
        NEGA
        sta p_t0
        jmp LEA1E
LEA00:  lda ZV_E967             ; accelerate
        cmp #15
        bcs LEA1E
        clc
        adc ZV_E967+1
        sta p_t1
        lda #$21
        sec
        sbc p_t1
        tax                     ; the delay C the original patches into EA1A
        lda #SND_REV
        jsr snd_fx
LEA1E:  jsr gear_x
        lda ZV_E967+1
        clc
        adc p_t0
        bpl LEA30
        lda zd                  ; revs < 0
        and #2
        bne LEA37
        jmp gup
LEA30:  cmp T_EAB5+1,x
        bcs LEA74
        cmp T_EAB5+2,x
        bcc :+
        jmp LEA84
:
LEA37:  lda T_EAB5+3,x          ; below min
        and #$20
        beq LEA40
        lda T_EAB5+2,x
        jmp LEA84
LEA40:  txa                     ; previous entry
        sec
        sbc #6
        tax
        jmp gchange
LEA74:  lda T_EAB5+3,x          ; above max
        and #$40
        bne :+
        jmp gup
:
        lda T_EAB5+1,x
        jmp LEA84

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
        sta p_t2                ; revs = (speed*16)/r + 1
        lda ZV_E967
        sta p_t0
        lda #0
        sta p_t1
        asl p_t0
        rol p_t1
        asl p_t0
        rol p_t1
        asl p_t0
        rol p_t1
        asl p_t0
        rol p_t1
        lda #0
        ldy #16
@dv:    asl p_t0
        rol p_t1
        rol a
        cmp p_t2
        bcc @dn
        sbc p_t2
        inc p_t0
@dn:    dey
        bne @dv
        lda p_t0
        clc
        adc #1
LEA61:  cmp #$12
        bcc LEA68
        lda #$11
LEA68:  ldy T_EAB5+3,x
        bpl LEA84
        SETB $760A, 2           ; neutral: latch
        lda #0
LEA84:  sta ZV_E967+1           ; STORE revs
        sta p_t1                ; p_t1:p_t0 = revs<<k, p_t3:p_t2 = product
        lda T_EAB5+3,x
        and #$1F
        beq LEAAA
        sta p_t0
        lda #0
        sta p_t2
        sta p_t3
        sta zf
@ml:    lsr p_t0
        bcc @ms
        clc
        lda p_t2
        adc p_t1
        sta p_t2
        lda p_t3
        adc zf
        sta p_t3
@ms:    asl p_t1
        rol zf
        lda p_t0
        bne @ml
        lda p_t3                ; (product >> 4) & $FF
        asl a
        asl a
        asl a
        asl a
        sta p_t3
        lda p_t2
        lsr a
        lsr a
        lsr a
        lsr a
        ora p_t3
        ldy T_EAB5,x
        bpl LEAAA
        NEGA                    ; reverse
        sta ZV_E967
        lda #0
        jmp LEAAD
LEAAA:  sta ZV_E967
LEAAD:  jsr Z_A36F
        IXMAIN
        rts

; =================================================================== SEAE2
ZPROC $EAE2
        IYPLAYER
        IXMAIN
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
        sta zl
        lda #>$7524
        sta zh
        jsr Z_98F4              ; J / L
        lda #<$752A
        sta zl
        lda #>$752A
        sta zh
        jsr Z_F37A              ; K
        bne LEB19
        SETB zd, 4
LEB19:  lda ZV_EADF
        sta ze
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
        ; SKID_STEP
        lda ZV_F470
        sta p_t0
        lda #0
        sta ZV_F470
        lda p_t0
        asl a
        clc
        adc p_t0
        lsr a
        and #7
        pha
        jsr Z_B905
        pla
        jsr Z_ED87
        jsr Z_EDE9
        lda ZV_A093
        beq LEB75
        jsr Z_A0B1
LEB75:  jsr Z_F2D1
        bne :+
        rts
:       jsr Z_F3D7
        jmp LEB75
LEB7E:  lda zc
        and #4
        beq :+
        jmp LEE6F
:       lda zd
        lsr a
        bcc LEB88
        jmp LECEA
LEB88:  lda ZV_A093
        beq LEB8F
        jsr Z_A0B1
LEB8F:  lda ZV_F470
        bne :+
        jmp LEBDE
:       jsr exx
        sta zb
LEB98:  lda ZV_E967
        jsr Z_ECA8
        lda $760C
        beq LEBAD
        lda ZV_EAE0
        sta zl
        lda ZV_EAE0+1
        sta zh
        jsr Z_EBEF
        beq LEB98
LEBAD:  lda ZV_EE4E
        ldx ZV_E967
        bmi LEBBA
        sec
        sbc zc
        jmp LEBBB
LEBBA:  clc
        adc zc
LEBBB:  sta p_t0
        cmp #$67
        bcs LEBC6
        lda $75F1
        and #2
        beq LEBC6
        jmp LEC83
LEBC6:  lda p_t0
        sta zb
        lda $75F5
        clc
        adc #$63
        cmp zb
        bcs LEBD6
        tax
        lda $75F1
        and #8
        beq LEBD6
        txa
        jmp LEC7A
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

; past the near / far end of the block (;? in the original)
LEC7A:  sta zb
        lda ZV_EE4E
        NEGA
        clc
        adc zb
        jmp LEC88
LEC83:  lda ZV_EE4E
        sec
        sbc #$67
LEC88:  sta zc
        lda ZV_E967
        bpl :+
        NEGA
:       cmp #6
        bcs LEC9D
        lda #1
        sta zd
        jsr SEC6C
        jmp LEBAD
LEC9D:  SETB $7793, 2
        SETB $760E, 8
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
        IYPLAYER
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
        ldy #10
        lda (ziyl),y
        ora #$20
        sta (ziyl),y
        ldy #7
        lda (zixl),y
        clc
        adc #1
        sta (zixl),y
        jmp LEC36
LEC27:  lda $750F
        sec
        sbc #1
        bne LEC33
        lda #10
        pha
        ldy #10
        lda (ziyl),y
        ora #$20
        sta (ziyl),y
        pla
LEC33:  sta $750F
LEC36:  IXMAIN
        lda #5
        jsr Z_F36A
        lda #0
        sta zd
LEC41:  POPBC
        ldy #5
        lda (ziyl),y
        and #3
        beq LEC50
        IYPLAYER
        lda #0
        jmp LEC5B
LEC50:  ldy #11
        lda (ziyl),y
        tax
        IYPLAYER
        txa
        lsr a
        adc #0
LEC5B:  sec
        sbc zc
        bcs SEC6C
        cmp #$FC
        bcs SEC6C
        SETB $7793, 2           ; rear-ended: wrecked
        SETB $760E, 8
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

; ------------------------------------------------- SECA8 / SECAB SCAN_AHEAD
; B = cells; A bit 7 = direction (the Z80 sign flag); SECA8 loads HL.
ZPROC $ECA8
        tax
        lda ZV_EE4E
        sta zl
        lda ZV_EE4E+1
        sta zh
        txa
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
        lda zl
        sta ZV_EAE0
        lda zh
        sta ZV_EAE0+1
        lda ze
        sta zd
        lda zb
        sta $760C
LECC9:  POPHL
        lda $7792
        bne :+
        rts
:       lda $7793
        and #$20
        bne LECD7
        inc zh
        inc zh
LECD7:  dec zh
        lda zc
        sta zb
        jsr Z_F31C
        bne :+
        rts
:       lda zb
        cmp $760C
        bcs :+
        rts
:       sta $760C
        lda zl
        sta ZV_EAE0
        lda zh
        sta ZV_EAE0+1
        lda ze
        sta zd
        rts

; ------------------------------------------------- LANE_START (LECEA)
LECEA:  lda ZV_A093
        bne :+
        jsr Z_A0B1
:       lda zh
        sta zb
        lda zd
        and #2
        bne LED04
        SETB $7793, 8
        inc zh
        lda $75F1
        and #1
        sta p_side
        lda $75D7
        jmp LED10
LED04:  RESB $7793, 8
        dec zh
        lda $75F1
        and #4
        sta p_side
        lda $75D6
LED10:  cmp zb
        bne LED18
        SETB ze, 2              ; already in the edge column (;?)
        jmp LED49
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
        jmp LED3F
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
        clc
        adc #3
        sec
        sbc $75F5
        bcs LED3C
        jmp LED3F
LED5C:  lda ZV_F470
        jsr Z_ED6E
        SETB $7793, 4
        jmp LED3F

; ------------------------------------------------- SED69 / SED6E LANE_SHIFT
ZPROC $ED69
        lda ZV_F470
        bne Z_ED6E
        rts
ZPROC $ED6E
        tax
        lda ze
        lsr a
        bcs LED72
        cpx #2
        lda #1
        bcc LED7C
        lda #2
        bne LED7C
LED72:  lda #1
LED7C:  ldx ZV_EE4E
        stx zl
        ldx ZV_EE4E+1
        stx zh
        jsr Z_B0AA
        lda zh
        sta ZV_EE4E+1
        rts

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
        NEGA
:       tax
        lda $7793
        and #$20
        beq :+
        txa
        NEGA
        tax
:       txa
        clc
        adc $7792
        sta $7792
        cmp #8
        bcs :+
        rts
:       lda $7798
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
        lda $7793
        and #$20
        bne LEDDC
        lda $75D6
        sta zb
        cmp $7799
        bcs :+
        sec                     ; b < (iy+7): CY = 1
        rts
:       bne LEDD3
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
        sec
        rts

; ------------------------------------------------- SEDE9
ZPROC $EDE9
        bit $7793
        bvs LEDF6
        jsr Z_EDBA
        bcc :+
        rts
:       jmp Z_F3F4
LEDF6:  lda $779A               ; (;?)
        bne LEE02
        lda $7792
        cmp #4
        bcc LEE02
        rts
LEE02:  lda $7793
        and #$20
        bne LEE1C
        lda $7798
        clc
        adc $779A
        sta $7798
        lda #0
        sta $779A
        bcc LEE2B
        inc $7799
        jmp LEE2B
LEE1C:  lda $7798
        sec
        sbc $779A
        sta $7798
        lda #0
        sta $779A
        bcs LEE2B
        dec $7799
LEE2B:  lda #4
        sta $7792
        jmp Z_F3F4

; ------------------------------------------------- SEE32 COMMIT_POS
ZPROC $EE32
        lda ZV_EE4E
        sta zl
        lda ZV_EE4E+1
        sta zh
        ldy #0
        lda (zl),y
        and #$C0
        cmp #$C0
        beq LEE44
        RESB $7793, $40
        lda zl
        sta $7798
        lda zh
        sta $7799
        rts
LEE44:  SETB $7793, $40         ; (;?)
        lda zl
        sta $7798
        lda #$C0
        jmp Z_B9EE

; ------------------------------------------------- SEE51 GET_POS
ZPROC $EE51
        lda ze
        and #$FE
        sta ze
        lda $7798
        sta zl
        lda $7799
        sta zh
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
        tya
        cmp zh
        bne :+
        inc ze
:       rts

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
        lda ZV_A093
        bne :+
        jsr Z_A0B1
:       SETB ze, 4
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
LEEB9:  lda ZV_A093
        bne :+
        jsr Z_A0B1
:       RESB $760B, $C0
        lda ZV_E967
        sta zl
        lda $7797
        sta zb
        bne :+
        jmp LEF0B
:       SETB $760B, $80
        lda zb
        tax
        lda zd
        and #2
        beq :+
        txa
        eor #$FF
        tax
:       lda zl
        bpl :+
        txa
        eor #$FF
        tax
:       txa
        lsr a
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
        IYPLAYER
        POPBC
        lda zb
        sta $7797
        POPDE
        SETB zd, 8
        lda $7793
        sta zc
LEF0B:  SETB $760B, 2
        lda zc
        ora #$0C
        sta zc
        lda zd
        and #2
        beq LEF1A
        inc zb
        RESB zc, 8
LEF1A:  lda zc
        sta $7793
        lda ZV_E967
        bmi LEF2B
        sec
        sbc #9
        bcs LEF34
        lda #0
        beq LEF34
LEF2B:  SETB $760B, $40         ; (;?)
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
        beq LEF49
        rts

; ------------------------------------------------- TURN_STEP (LEF49)
LEF49:  lda ZV_F470
        cmp #5
        bcc :+
        sbc #1
:       sta ZV_F30C
        RESB $760B, $10
        jsr Z_B905
LEF5B:  RESB $760B, 8
        lda #0
        sta ZV_F470
        lda ZV_F30C
        bne :+
        jmp LF1BE
:       lda ZV_E967
        and #$80
        lsr a
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
        pha
        RESB $760B, 2
        jsr Z_A487
        pla
        jmp LEFB4
LEF97:  RESB $760B, 2
        jsr Z_A487
        jmp LF1BE
LEFA1:  cmp #6
        bcs LEF97
        adc #2
        cmp #6
        bcc LEFB4
        pha
        RESB $760B, 2
        jsr Z_A487
        pla
LEFB4:  sta $7797
        and #6
        cmp #4
        bne LEFD0
        lda $760D
        beq LEFD0
        sec
        sbc #1
        sta $760D
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
        sta zb
        dec ZV_F30C
        lda ZV_F30C
        ora zb
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
        bit $7793
        bvs LF03D
        lda ZV_E967
        asl a
        lda ZV_F470
        bcs :+
        NEGA
:       clc
        adc $7798
        sta zl
        sta $7798
        ldy #0
        lda (zl),y
        cmp #$FD
        bcs LF098J
        and #$C0
        cmp #$C0
        bne LF098J
        lda zl                  ; (;?) drove onto a junction cell
        sec
        sbc #$64
        sta $779B
        lda #0
        sta $779A
        lda $779B
        jsr Z_B9DD
        lda zl
        sta $7798
        lda zh
        sta $7799
        jsr exx
        SETB $7793, $40
LF098J: jmp LF098
LF03D:  lda ZV_E967             ; (;?) junction mode
        asl a
        lda ZV_F470
        bcs :+
        NEGA
:       clc
        adc $779B
        sta $779B
        sta zb
        jsr Z_B9DD
        lda $779A
        bne LF075
        lda zl
        sta $7798
        lda zh
        sta $7799
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
        RESB $7793, $40
        lda zl
        sta $7798
        lda zh
        sta $7799
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
        lda $7793
        and #$20
        beq LF092
        clc
        lda zl
        adc ze
        sta zl
        lda zh
        adc #0
        sta zh
        jmp LF095
LF092:  sec
        lda zl
        sbc ze
        sta zl
        lda zh
        sbc #0
        sta zh
LF095:  lda zl
        sta $7798
        lda zh
        sta $7799
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
        jsr Z_B9DD
        lda zl
        sta $7798
        lda zh
        sta $7799
        SETB $760B, 8
LF0C9:  jsr Z_F2FE
        cmp #$67
        bcs :+
        jmp LF140
:       sec
        sbc #$64
        cmp $75F5
        bcc :+
        jmp LF148
:       lda $7793               ; (;?) inside the crossing zone
        and #$40
        beq :+
        jmp LF1BE
:       lda $7793
        and #$20
        bne LF100
        lda $75D6
        sta zb
        sec
        sbc $7799
        bcs :+
        jmp LF1BE
:       beq LF0F6
        tax
        lda $75F1
        and #4
        jmp LF110
LF0F6:  lda $7792
        cmp #4
        bcc LF131
        jmp LF1BE
LF100:  lda $75D7
        sta zb
        sec
        sbc $7799
        beq LF0F6
        bcc :+
        jmp LF1BE
:       tax
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
        NEGA
:       stx zd
        sta p_t0
        sec
        lda zl
        sbc ze
        sta zl
        lda zh
        sbc zd
        sta zh
        lda p_t0
        sta $779A
        lda zl
        sta $7798
        lda zh
        sta $7799
        SETB $7793, $40
        jmp LF098
LF131:  lda zb
        sta $7799
        lda #4
        sta $7792
        SETB $760B, 8
        jmp LF098
LF140:  lda $75F1
        and #2
        tax
        lda #3
        jmp LF150
LF148:  lda $75F1
        and #8
        tax
        lda $75F5
        sec
        sbc #1
LF150:  cpx #0
        beq LF174
        tax                     ; (;?) wall at the end of the block
        bit $7793
        bvs LF164X
        txa
        clc
        adc #$64
        sta $7798
        SETB $760B, 8
        jmp LF098
LF164X: txa
LF164:  sta $779B
        jsr Z_B9DD
        lda zl
        sta $7798
        lda zh
        sta $7799
        SETB $760B, 8
        jmp LF098
LF174:  lda $7793
        and #$40
        beq LF1B5
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
        SETB $760B, 8
        jmp LF098
LF1A5:  lda $779B
        sec
        sbc #3
        bmi :+
        lda $75F5
        sec
        sbc #1
        jmp LF164
:       lda #3
        jmp LF164
LF1B5:  jsr Z_EDBA
        bcs LF1BE
        SETB $760B, 8
LF1BE:  lda $760B
        and #8
        beq LF1D2
        jsr Z_B913
        SETB $760B, $12
        jmp LEF5B
LF1D2:  jsr Z_F2D1
        beq LF1E2
        SETB $760B, $12
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
        bvs :+
        rts
:       lda $779A               ; (;?)
        bne LF20C
        lda $7792
        cmp #4
        bcc LF20C
        rts
LF20C:  lda $7797
        pha
        jsr Z_F288
        pla
        sta zb
        and #1
        sta zc
        lda zb
        and #6
        NEGA
        clc
        adc #7
        eor zc
        sta $7797
        lda $760B
        eor #$80
        sta $760B
        rts
LF22C:  lda $7797
        cmp #1
        bne LF237
        lda #0
        sta $7797
LF237:  cmp #0
        beq LF26A
        bit $760B
        bpl :+
        rts
:       bit $75FD
        bpl :+
        rts
:       lda $75F1
        and #5
        cmp #5
        bne :+
        rts
:       lda $7793
        and #$40
        bne :+
        lda $7798
        jmp LF25A
:       lda $779B
        clc
        adc #$64
LF25A:  sec
        sbc #$67
        bcs :+
        rts
:       clc
        adc #3
        cmp $75F5
        bcc :+
        rts
:       jsr Z_F288
        lda #0
        sta $7797
LF26A:  lda $7792
        bne :+
        rts
:       SETB $7793, 4
        lda $7792
        cmp #4
        beq :+
        rts
:       jsr Z_F53D
        tax
        bit $7793
        bvs LF283
        cpx $7799
        beq LF283
        rts
LF283:  RESB $7793, 4
        rts

; ------------------------------------------------- SF288 ROTATE_HEADING
ZPROC $F288
        lda $7797
        lsr a
        bcc LF297
        dec $75F0
        lda #0
        sta $75FE
        jmp LF29E
LF297:  inc $75F0
        lda #1
        sta $75FE
LF29E:  jsr Z_F2BC
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
; black paper and columns 1-38 (Spectrum x 0-227) blank.  S862E repaints all
; of it at the next view copy.
ZPROC $F2BC
        lda #<($A000+4*40)
        sta p_t0
        lda #>($A000+4*40)
        sta p_t1
        ldx #96
@ln:    ldy #0
        lda #$10
        sta (p_t0),y
        lda #$40
        iny
@px:    sta (p_t0),y
        iny
        cpy #39
        bne @px
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
        IYPLAYER
        lda $7798
        sta zl
        lda $7799
        sta zh
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
LF2F4:  IYPLAYER
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
        beq :+
        lda #$E6                ; INC zp
        bne @st
:       lda #$C6                ; DEC zp
@st:    sta scan_op
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
        jmp LF322
LF341:  dec ze
        pla
        pla
        POPBC
        lda $7793
        and #$20
        bne :+
        dec ze
:       ldy #0
        lda (zl),y
        rts

; ------------------------------------------------- SF34B / SF36A
; penalty / score += A (units of 10), then print it.  HL preserved.
ZPROC $F34B
        tax
        PUSHHL
        txa
        clc
        adc $750D
        sta $750D
        sta zl
        lda $750E
        adc #0
        sta $750E
        sta zh
        lda #$50
LF359:  sta pr_x
        jsr Z_A4C9
        .byte $01, $FF
pr_x:   .byte $40, $B0, $FC, $00, $00, $30, $00
        POPHL
        rts
ZPROC $F36A
        tax
        PUSHHL
        txa
        clc
        adc $750B
        sta $750B
        sta zl
        lda $750C
        adc #0
        sta $750C
        sta zh
        lda #$C0
        jmp LF359

; ------------------------------------------------- SF38B RUN_OVER (HL, IY)
ZPROC $F38B
        ldy #1
        lda (ziyl),y
        and #$7F
        sta (ziyl),y
        ldy #0
        lda (zl),y
        bpl LF39C
        lsr a                   ; (;?)
        lsr a
        lsr a
        and #7
        sta (zl),y
        jmp LF3A4
LF39C:  lda #0
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
        jmp LF3CF
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
        SETB $7793, 2
        SETB $760E, 8
        lda ZV_E967
LF3EA:  cmp #4
        lda #1
        bcc :+
        lda #2
:       pha
        jmp LF40A
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
        sty zd
        jmp LF410
LF40A:  lda #<(T_EAB5+8)        ; EABD neutral, speed 0, revs 3
        ldx #>(T_EAB5+8)
        ldy #0
        sty ze
        ldy #3
        sty zd
LF410:  sta ZV_E965
        stx ZV_E965+1
        sta zl
        stx zh
        lda ze
        sta ZV_E967
        lda zd
        sta ZV_E967+1
        lda ze
        jsr Z_A36F
        IXMAIN
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
        lda #0
:       ora p_t0
        sta zc
        ldy #1
        lda (ziyl),y
        and #$20
        beq LF43B
        SETB zc, 1
        jmp LF43B
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
        NEGA
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
        NEGA
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
        ldy #0
        sta (ze),y
        dec ze
        sta (ze),y
        dec ze
        sta (ze),y
        dec ze
        sta (ze),y
        lda $7798
        sta zl
        lda $7799
        sta zh
        lda #0
        sta (zl),y
        rts

ZPROC $F4BA
        jsr Z_F4EF
        bne :+
        jmp Z_B412
:       lda #<(ZV_FD6B+12)      ; (;?) DFD77
        sta zl
        lda #>(ZV_FD6B+12)
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
        beq :+
        rts
:       jsr exx
        lda #$F4
        sta zc
        ldy #0
        lda (zl),y
        beq :+
        rts
:       jsr exx
        ldx #$FE
        lda $7793
        and #$20
        bne :+
        dex
:       txa
        ldy #0
        sta (zl),y
        lda #$FF
        dec zl
        sta (zl),y
        dec zl
        sta (zl),y
        dec zl
        sta (zl),y
        jsr exx
        lda za2
        ldy #0
        sta (zl),y
        lda #0
        rts

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
        lda $7793
        and #$20
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
        sta ze
        lda $7793
        and #$20
        bne :+
        lda $75D6
        clc
        adc #1
        jmp @d
:       lda $75D7
        sec
        sbc #1
@d:     sta zd
        lda #$64
        clc
        adc ze
        sta ze
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
        bvc :+
        rts
:       lda $7797
        beq :+
        rts
:       PUSHDE
        jsr Z_F692
        sta ZV_F691
        ldx #5
        lda #SND_CRASH          ; gunshot
        jsr snd_fx
        lda #$14
        sta zb
        lda $7798
        sta zl
        lda $7799
        sta zh
        lda #0
        jsr Z_ECAB
        lda zb
        NEGA
        clc
        adc #$18
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
        bcs :+
        jmp LF5D6
:       clc
        adc #$81
        sta tr_dy
        lda #0
        sta zc
        lda ZV_F691
        sec
        sbc #$7A
        bcs LF59F
        inc zc
        NEGA
LF59F:  sta p_t0                ; |off|
        lda #$36
        sta ze
        lda p_t0
        jsr Z_8C87
        ror a
        sta p_t1                ; e1
        ldy #6
        lda (ziyl),y
        sta ze
        lda p_t0
        jsr Z_8C87
        ror a
        sec
        sbc p_t1
        NEGA
        ldx zc
        bne :+
        eor #$80
:       sta tr_dx
        lda p_t1
        ldx zc
        beq :+
        NEGA
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
        bne :+
        jmp LF684
:       lda ZV_EAE0             ; (;?) something was hit
        sta zl
        lda ZV_EAE0+1
        sta zh
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
        bcc LF684J
        cmp #3
        bcs LF684J
        jsr Z_927B
        jsr Z_9230
        ldy #1
        lda (ziyl),y
        and #$7F
        sta (ziyl),y
        jsr Z_F6CF
        jsr Z_F3B6
LF684J: jmp LF684
LF60F:  jsr Z_F34B
        jmp LF684
LF614:  cmp #$0D
        bcs :+
        jmp LF684
:
        ldy #1
        lda (ziyl),y
        and #2
        beq :+
        jmp LF684
:
        lda ZV_F691
        sta zb
        jsr Z_F692
        sec
        sbc zb
        bcs :+
        jmp LF684
:
        cmp #8
        bcc :+
        jmp LF684
:
        GET_R
        and #1
        bne LF684
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
        jmp LF60F
:       lda zb
        and #8
        beq LF65C
        lda zb
        and #4
        bne :+
        lda #$32
        jmp LF670
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
LF684:  IYPLAYER
        IXMAIN
        lda $7793
        sta zc
        POPDE
        rts

; ------------------------------------------------- SF692 LATERAL_COORD (IY)
ZPROC $F692
        ldy #1
        lda (ziyl),y
        and #$40
        bne LF6AE
        ldy #7
        lda (ziyl),y
        sec
        sbc #$50
LF69D:  asl a
        asl a
        asl a
        sta p_t3
        ldy #1
        lda (ziyl),y
        and #$20
        bne LF6AA
        ldy #0
        lda p_t3
        clc
        adc (ziyl),y
        rts
LF6AA:  ldy #0
        lda p_t3
        sec
        sbc (ziyl),y
        rts
LF6AE:  ldy #1                  ; (;?)
        lda (ziyl),y
        and #$20
        bne LF6BD
        ldy #8
        lda (ziyl),y
        NEGA
        clc
        adc #$0B
        jmp LF69D
LF6BD:  ldy #8
        lda (ziyl),y
        clc
        adc #$14
        jmp LF69D

; ------------------------------------------------- SF6C1 / SF6CF
ZPROC $F6C1
        ldy #10
        lda (ziyl),y
        and #$40
        bne :+
        rts
:       lda (ziyl),y
        and #$10
        beq :+
        rts
:       RESB $75FD, 1
        rts

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
        beq LF6E0
        rts
LF6E0:  ldy #0
        lda (zl),y
        and #$7F
        sta (zl),y
        rts

; ------------------------------------------------- SF6E3 BANG_CHECK
ZPROC $F6E3
        lda $779F
        bmi :+
        rts
:       and #2
        beq :+
        rts
:       lda $7798
        sta zl
        lda $7799
        sta zh
        lda $77A4
        cmp zl
        beq :+
        rts
:       inc zh
        lda $77A5
        cmp zh
        beq :+
        rts
:       lda $7797
        beq :+
        rts
:       lda $760E
        and #8
        beq :+
        rts
:       lda $77A3
        beq :+
        rts
:       lda #10
        sta zb
        tax
        lda #SND_CRASH
        jsr snd_fx
        lda #10
        jsr Z_BA56
        .byte $68, $06, "BANG !"
        GET_R
        and #3
        beq :+
        rts
:       lda #$1E
        jsr Z_BA56
        .byte $30, $13, "LOTUS INCAPACITATED"
        SETB $760E, $0A
        lda ZV_E967
        sec
        sbc #6
        bpl :+
        rts
:       lda #3
        sta $7797
        SETB $760B, 2
        lda #$14
        sta $760D
        rts
