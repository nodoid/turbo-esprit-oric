; world.s - the city: map lookup, road description, lane grids, traffic
; cars, node-transition remap, engine temperature and fuel.
;
; Translation of Spectrum 0x8F23-0x9E1D (reverse-engineering notes R4).
; IX is always D75E1 in this code, so (ix+n) is written as the absolute
; Spectrum address.  IY (a traffic car / object record) is the zero-page
; pointer ziy; HL is zl/zh; the id the original kept in A' is za2.
;
; Relocated Spectrum memory owned here:
;   ZV_9282 ($153)  current-city block (map, street types, entry streets, spots)
;   ZV_9494 (4)     engine temperature, fuel units, fuel sub-counter (word)
;   ZV_9560 (4)     RNG seed (word), building RNG state sL/sH
;   ZV_FD60 ($2A0)  the two cross-street ("side street") lane grids.  Cell
;                   pointers into them (HL, object records +6/+7, B8FF) keep
;                   the Spectrum values $FD60-$FFFF, as in traffic.s; every
;                   access through such a pointer relocates it (mapz).
;
; Interfaces (Z80 register -> zero page as in docs/PORTING.md):
;   Z_8F23  move the 3 traffic cars.          Z_93D5  engine/fuel (jp target)
;   Z_958B  road description of D7504/D75F0.  Z_9498  refuel (jp target)
;   Z_9907  rebuild the lane grids.           Z_94E5  engine/fuel init
;   Z_9AA8  remap records after a node transition (D75FE)
;   Z_9564  zl=L zh=H -> ze = blocked-exit mask (zl/zh kept; the original
;           left HL pointing into the map, no caller uses it)
;   Z_952F  A = index, zl/zh = table (ZV_9382 / ZV_93A2) -> A; zb=0, zc=A,
;           zl/zh += A as the original (A >= $20: A = 0, nothing else)
;   Z_953B  -> zl/zh = new seed; A kept; alternate BC/DE/HL as the original
;   Z_98F4  zl/zh = 2 key entries -> zd = 0/3/1/2, zl/zh += 5
;   Z_9205 / Z_9230 / Z_924B  occupy / vacate / is-opening of cell zl/zh
;           (id in za2); Z_9274 / Z_927B  (ziy)+6/+7 <-> zl/zh.
;   SB905/SB913 (record backup), SB9D2, SB9DD, SB9EE, SF53D, SF2FE are tiny
;   helpers of other regions; they are inlined here (same effect on memory).
;
; Self-modified operands of the original that only live during one call
; (976D, 9724, 992B, 99B4, 9AE5/9B14, 9DF2) are private variables here.
; S958B saved SP in D74F9; that store is not reproduced (no SP to save).

        .include "zx.inc"

        ZIMPORT $BA5F           ; status-line message, inline data (other module)
        ZIMPORT $A41E           ; redraw temperature/fuel gauges (gfx)
        ZIMPORT $B241
        ZIMPORT $B1BC
        ZIMPORT $B412
        ZIMPORT $DC4C
        ZIMPORT $BB18
        ZIMPORT $F4A7
        ZIMPORT $F2D1
        ZIMPORT $DE15
        ZIMPORT $F37A           ; key test (hw.s)
        ZVIMPORT $B8F9          ; 12-byte backup of the record being moved
        ZVIMPORT $A093          ; game state (non-zero: engine/fuel suspended)
        ZVIMPORT $E968          ; engine load (fuel used per check)

        .export ZV_9382, ZV_93A2, ZV_93C2, ZV_93C3, ZV_93C4, ZV_93CC
        .export ZV_9495, ZV_9496, ZV_9561, ZV_9562, ZV_9563

; ---------------------------------------------------------------------------
        .segment "DATA"
        ZVAR $9494, 4           ; temperature, fuel units, fuel sub-counter (word)
        ZVAR $9560, 4           ; RNG seed (word), building RNG sL, sH
ZV_9382 = ZV_9282 + $100        ; NS_TYPE[32]
ZV_93A2 = ZV_9282 + $120        ; EW_TYPE[32]
ZV_93C2 = ZV_9282 + $140        ; ENTRY_L
ZV_93C3 = ZV_9282 + $141        ; ENTRY_H
ZV_93C4 = ZV_9282 + $142        ; SPOTS
ZV_93CC = ZV_9282 + $14A
ZV_9495 = ZV_9494 + 1
ZV_9496 = ZV_9494 + 2
ZV_9561 = ZV_9560 + 1
ZV_9562 = ZV_9560 + 2
ZV_9563 = ZV_9560 + 3

; private (not hot) variables
oldFC:  .res 1                  ; D976D: D75FC on entry to S958B
rowT:   .res 1
colT:   .res 1
curT:   .res 1
crossT: .res 1
rel:    .res 1
tofs:   .res 1                  ; T9816 offset for the heading
segk:   .res 1                  ; segment counter (2, 1)
stride: .res 1
dcnt:   .res 1
vcnt:   .res 1
w_a:    .res 1                  ; S9999: value A
w_neg:  .res 1                  ; S9999: BC negative
mval:   .res 1                  ; D99B4
w_row:  .res 1                  ; S99DD: base row E
w_fl:   .res 1
hjmp:   .res 2                  ; D9AE5/D9B14: transition handler
w_fe:   .res 1                  ; D75FE on entry to S9AA8
w_id:   .res 1                  ; E in S9AA8's loops (record id)
w_par:  .res 1                  ; C in S9AA8's loops (0 traffic, 3 objects)
w_cnt:  .res 1
w_y:    .res 1                  ; D9DF2
xb:     .res 1                  ; 9BD6: the exx'd register set
xc:     .res 1
xd:     .res 1
xe:     .res 1
xl:     .res 1
xh:     .res 1
xsgn:   .res 1
xt:     .res 1
xold:   .res 1
xdist:  .res 1
        ZVAR $FD60, $2A0        ; cross-street grids
FDB = ZV_FD60 - $FD60           ; FDB + $FDxx = Oric address of Spectrum $FDxx
        ZVAR $9282, $153        ; current city block (copied in by the city select)

        .zeropage
tp:     .res 2                  ; general pointer
w_b:    .res 1                  ; B in S8F3D (new +5)
w_c:    .res 1                  ; C in S8F3D (old +1 flags)
w_d:    .res 1                  ; D (kerb page)
w_e:    .res 1                  ; E (row / random)
w_step: .res 1
t0:     .res 1
t1:     .res 1

        .segment "RODATA"
        .include "world_tables.inc"

        .code

; field access of the record at ziy
.macro LDF n
        ldy #n
        lda (ziy),y
.endmacro
.macro STF n
        ldy #n
        sta (ziy),y
.endmacro

; ===========================================================================
; S8F23: move the 3 traffic cars (records D770E, D771A, D7726, ids 1..3)
; ===========================================================================
ZPROC $8F23
        lda #<$770E
        sta ziyl
        lda #>$770E
        sta ziyh
        lda #1
@l:     sta za2
        jsr Z_8F3D
        lda ziyl
        clc
        adc #12
        sta ziyl
        bcc :+
        inc ziyh
:       ldx za2
        inx
        txa
        cmp #4
        bne @l
        rts

; SB905 / SB913 (other region, inlined): record <-> DB8F9 backup
backup: ldy #11
@l:     lda (ziy),y
        sta ZV_B8F9,y
        dey
        bpl @l
        rts
restore:
        ldy #11
@l:     lda ZV_B8F9,y
        sta (ziy),y
        dey
        bpl @l
        rts

; SF53D (inlined): A = kerb page of the record's side
f53d:   ldy #1
        lda (ziy),y
        and #$20
        beq @l
        lda $75D7
        rts
@l:     lda $75D6
        rts

; SB9D2 (inlined): ze/zd = 12*A with the original's 8-bit overflow (A*4 and
; A*8 are 8-bit, only the last add carries into D)
mul12:  asl
        asl
        sta ze
        asl
        clc
        adc ze
        sta ze
        lda #0
        rol
        sta zd
        rts

; SB9DD (inlined): HL = cross-grid row A (col 0) of the record's arm
b9dd:   jsr mul12
        ldy #1
        lda (ziy),y
        and #$20
        beq @l
        lda #<$FEB0
        clc
        adc ze
        sta zl
        lda #>$FEB0
        adc zd
        sta zh
        rts
@l:     lda #<$FD6B
        clc
        adc ze
        sta zl
        lda #>$FD6B
        adc zd
        sta zh
        rts

; SB9EE (inlined): move a main-grid record standing on an opening into the
; cross grid: +9 = +6-0x64, +8 = 0, ptr = HL = SB9DD(+9)
b9ee:   LDF 6
        sec
        sbc #$64
        STF 9
        pha
        lda #0
        STF 8
        pla
        jsr b9dd
        ; fall through
; S9274: (iy+6,iy+7) = HL
ZPROC $9274
        ldy #6
        lda zl
        sta (ziy),y
        iny
        lda zh
        sta (ziy),y
        rts

; S927B: HL = (iy+6,iy+7)
ZPROC $927B
        ldy #6
        lda (ziy),y
        sta zl
        iny
        lda (ziy),y
        sta zh
        rts

; ===========================================================================
; S8F3D: one traffic car (record at ziy, id in za2)
; ===========================================================================
ZPROC $8F3D
        jsr backup
        lda ZV_B8F9+1
        bmi @act
        jmp spawn
@act:   sta w_c
        lda ZV_B8F9+6
        sta zl
        lda ZV_B8F9+7
        sta zh
        lda ZV_B8F9+5
        clc
        adc #4
        and #7
        STF 5
        sta w_b
        bit w_c
        bvc :+
        jmp cross
:       lsr
        bcc :+
        jmp sideways
:       and #2                  ; (b>>1)&2 = b bit2
        bne :+
        rts
:       jsr Z_9230
        lda w_b
        and #2
        beq f8f74
        inc zl                  ; towards the player
        lda $75F5
        clc
        adc #$C8
        cmp zl
        bne l8f7c
off:    LDF 1                   ; left the grid
        and #$7F
        sta (ziy),y
        rts
f8f74:   dec zl
        beq off
l8f7c:  jsr Z_9274
        jsr Z_924B
        bcc nop8fa8
        jsr b9ee                ; turned into an opening
        LDF 1
        ora #$40
        sta (ziy),y
        jsr Z_927B
        jsr Z_9205
        beq :+
        jmp reverse
:       lda $75FD
        bmi r8f3d
        LDF 1
        and #$20
        beq :+
        lda #1
        STF 5
        rts
:       lda #3
        STF 5
r8f3d:     rts
nop8fa8:   jsr Z_9205
        beq :+
        jmp reverse
:       lda zl
        sta w_e
        cmp #$2E
        bne :+
        ldx #1                  ; entrance in the segment beyond (D75FC)
        jsr s9255
        beq r8f3d
:       lda $75F5
        clc
        adc #$92
        cmp w_e
        bne :+
        ldx #0                  ; entrance in the current segment (D75FB)
        jsr s9255
        beq r8f3d
:       lda w_b
        and #2
        beq f8fd7
        lda $75F5               ; (never run)
        clc
        adc #$63
        cmp w_e
        bne r8f3d
        lda $75F1
        and #8
        beq r8f3d
        jmp l9266
f8fd7:    lda #$64
        cmp w_e
        bne r8f3d
        lda $75F1
        and #2
        beq r8f3d
        jmp l9266

; S9255 (A=row matched by the caller): entrance flags $75FB+X.  Z = taken.
s9255:  lda $75FB,x
        bmi no9255
        lsr
        bcc no9255
        lda $75FB,x
        ora #$80
        sta $75FB,x
        lda #$0F
        STF 10
; L9266: turn sideways: +5 = (old +1 bit5) ? 3 : 1, Z
l9266:  lda w_c
        and #$20
        beq :+
        lda #3
        bne :++
:       lda #1
:       STF 5
        lda #0
        rts
no9255:    lda #1
        rts

; L9220: back out: restore the record, reverse the direction, re-occupy
reverse:
        jsr restore
        LDF 5
        eor #2
        sta (ziy),y
        lda ZV_B8F9+6
        sta zl
        lda ZV_B8F9+7
        sta zh
        jmp Z_9205

; L8FE3: sideways in the main grid (direction 1/3)
sideways:
        LDF 10
        beq @go
        sec
        sbc #1
        sta (ziy),y
        LDF 5
        and #3
        sta (ziy),y
        rts
@go:    lda w_b                 ; (never run from here on)
        and #2
        beq :+
        lda #$20
:       eor w_c
        and #$20
        bne @dec
        ldy #0
        lda (ziy),y
        clc
        adc #1
        sta (ziy),y
        cmp #5
        bne @r
        lda #$FD
        jsr s9045
        beq :+
        jmp reverse
:       lda w_b
        and #2
        bne @b1
        lda zh
        cmp #$60
        bne @r
        lda #3
        STF 0
        LDF 1
        ora #$20
        sta (ziy),y
@r:     rts
@b1:    lda zh
        cmp #$5F
        bne @r
        lda #3
        STF 0
        LDF 1
        and #$DF
        sta (ziy),y
        rts
@dec:   ldy #0
        lda (ziy),y
        sec
        sbc #1
        sta (ziy),y
        cmp #1
        beq kerb
        cmp #$FC
        bne @r
        lda #4
        jsr s9045
        beq @r
        jmp reverse

; S9045: one sideways cell step (A = new +0)
s9045:  STF 0
        jsr Z_9230
        lda w_b
        and #2
        bne :+
        inc zh
        bne :++
:       dec zh
:       lda zh
        STF 7
        jsr Z_924B
        bcc :+
        LDF 1
        ora #$40
        sta (ziy),y
        jsr b9ee
:       jmp Z_9205

; L9064: reached the kerb
kerb:   jsr f53d
        ldy #7
        cmp (ziy),y
        bne @r
        LDF 6
        cmp #$64
        bne :+
        lda #2
        STF 5
@r:     rts
:       lda $75F5
        clc
        adc #$63
        cmp (ziy),y
        bne :+
        lda #0
        STF 5
        rts
:       lda #$2E
        cmp (ziy),y
        bne :+
        lda $75FC
        and #$7F
        sta $75FC
        jmp :++
:       lda $75FB
        and #$7F
        sta $75FB
:       GET_R
        and #2
        STF 5
        rts

; L909C: in a cross grid
cross:  lda w_b
        lsr
        bcs :+
        jmp l9154
:       lda w_c
        and #$20
        beq :+
        lda $75D7
        ldx #1
        bne :++
:       lda w_b
        eor #2
        sta w_b
        lda $75D6
        ldx #$FF
:       sta w_d
        stx w_step
        lda w_b
        and #2
        bne tow90ea
        ldy #0                  ; away from the main road
        lda (ziy),y
        sec
        sbc #1
        sta (ziy),y
        cmp #$FC
        bne r909c
        lda #4
        sta (ziy),y
        jsr Z_9230
        lda w_step              ; HL += step
        bmi :+
        jsr hlinc
        jmp :++
:       jsr hldec
:       LDF 8
        clc
        adc #1
        sta (ziy),y
        cmp #12
        beq :+
        jmp l9178
:
        LDF 1
        and #$7F
        sta (ziy),y
r909c:     rts
tow90ea:   ldy #0                  ; towards the main road
        lda (ziy),y
        clc
        adc #1
        sta (ziy),y
        cmp #2
        beq mouth
        cmp #5
        bne r909c
        lda #$FD
        sta (ziy),y
        jsr Z_9230
        lda w_step              ; HL -= step
        bpl :+
        jsr hlinc
        jmp :++
:       jsr hldec
:       LDF 8
        sec
        sbc #1
        sta (ziy),y
        bpl l9178
        LDF 9                   ; (never run)
        clc
        adc #$64
        sta zl
        ldx w_d
        inx
        LDF 1
        and #$20
        beq :+
        dex
        dex
:       stx zh
        jmp l9141
mouth:  LDF 8
        bne r909c
        LDF 9
        beq m9148
        lda $75F1
        and #8
        bne r909c
        jsr Z_9230
        LDF 9
        clc
        adc #$65
        sta zl
        lda w_d
        sta zh
        lda #2
        bne l913a
m9148:    lda $75F1
        and #2
        bne r909c
        jsr Z_9230
        lda #$63
        sta zl
        lda w_d
        sta zh
        lda #0
l913a:  STF 5
        lda #1
        STF 0
l9141:  LDF 1
        and #$BF
        sta (ziy),y
l9178:  jsr Z_9274
        jsr Z_9205
        beq :+
        jmp reverse
:       rts



hlinc:  inc zl
        bne :+
        inc zh
:       rts
hldec:  lda zl
        bne :+
        dec zh
:       dec zl
        rts

; L9154: along the cross street in a cross grid (never run)
l9154:  lda w_b
        and #4
        beq r9154
        jsr Z_9230
        lda w_b
        and #2
        beq dn9182
        lda zl
        clc
        adc #12
        sta zl
        bcc :+
        inc zh
:       LDF 9
        clc
        adc #1
        sta (ziy),y
        cmp $75F5
        bne l9178
        lda $75F5
        clc
        adc #$64
        sta zl
        jmp l9170
dn9182:    lda zl
        sec
        sbc #12
        sta zl
        bcs :+
        dec zh
:       LDF 9
        sec
        sbc #1
        sta (ziy),y
        bpl l9178
        lda #$63
        sta zl
l9170:  jsr f53d
        sta zh
        jmp l9141
r9154:     rts

; L918F: spawn a new car (Z80 R register as random source)
spawn:  lda $75F1
        sta t0
        GET_R
        sta w_e
        and #3
        sta t1
        beq :++
        tax
:       asl t0
        dex
        bne :-
:       lda t0
        and #8
        beq :+
        rts
:       lda t1
        STF 5
        lda #1
        STF 0
        lda t1
        lsr
        bcs @arm
        lda #$80                ; main grid
        STF 1
        lda w_e
        and #4
        bne :+
        lda $75D6
        jmp :++
:       LDF 1
        ora #$20
        sta (ziy),y
        lda $75D7
:       STF 7
        lda t1
        and #2
        beq :+
        lda #1
        bne :++
:       lda $75F5
        clc
        adc #$C7
:       STF 6
        rts
@arm:   lda #$C0                ; cross-street arm, far end (col 11)
        STF 1
        lda t1
        and #2
        bne :+
        lda #<$FD60
        sta zl
        lda #>$FD60
        sta zh
        jmp :++
:       LDF 1
        ora #$20
        sta (ziy),y
        lda #<$FEBB
        sta zl
        lda #>$FEBB
        sta zh
:       lda #0
        sta t0
        lda w_e
        and #4
        beq :+
        lda $75F5
        sec
        sbc #1
        sta t0
        jsr mul12
        lda zl
        clc
        adc ze
        sta zl
        lda zh
        adc zd
        sta zh
:       lda t0
        STF 9
        jsr Z_9274
        lda #$0B
        STF 8
        rts

; S9205: occupy (HL) with the id in za2.  Z = done, NZ = blocked (A = cell)
; mapz: tp = Oric address of the Spectrum address zh:zl (cross grids moved)
mapz:   lda zh
        cmp #$FD
        bcs :+
        sta tp+1
        lda zl
        sta tp
        rts
:       lda zl
        clc
        adc #<FDB
        sta tp
        lda zh
        adc #>FDB
        sta tp+1
        rts

ZPROC $9205
        jsr mapz
        ldy #0
        lda (tp),y
        bne @nz
        lda za2
        sta (tp),y
        lda #0
        rts
@nz:    cmp #8
        bcs @blk
        lda za2
        sta ze
        asl
        asl
        asl
        ora #$80
        ora (tp),y
        sta (tp),y
        lda #0
        rts
@blk:   cmp #0                  ; Z clear
        rts

; S9230: vacate (HL) of the id in za2
ZPROC $9230
        jsr mapz
        ldy #0
        lda (tp),y
        bmi @m
        tya
        sta (tp),y
        rts
@m:     sta ze
        and #7
        sta (tp),y
        cmp za2
        bne @r
        lda ze
        lsr
        lsr
        lsr
        and #7
        sta (tp),y
@r:     rts

; S924B: C set when (HL) is a kerb opening (0xC0..0xFC)
ZPROC $924B
        jsr mapz
        ldy #0
        lda (tp),y
        cmp #$FD
        bcs @no
        cmp #$C0
        rts
@no:    clc
        rts

; ===========================================================================
; L93D5: main-loop tail - engine temperature and fuel (every 64 passes)
; ===========================================================================
ZPROC $93D5
        lda $75F8
        and #$3F
        bne r93d5
        lda ZV_A093
        bne r93d5
        lda $760E
        and #2
        beq :+
r93d5:     rts
:       GET_R
        sta zc                  ; C (SBA5F below may change it, as on the Spectrum)
        and #$42
        bne fuel
        lda $760E
        lsr
        bcc nf93f2
        lda zc                  ; engine fault: up with p=3/4
        and #$0C
        beq dn9418
        bne up9416
nf93f2:    lda ZV_9560
        cmp #$68
        bne l9409
        lda $760E               ; (never run)
        ora #1
        sta $760E
        jsr Z_BA5F
        .byte $28,$07,$85,$86,$46,$41,$55,$4C,$54       ; "WARNING - ENGINE FAULT"
l9409:  lda ZV_9494
        cmp #7
        bcc up9416
        bne dn9418
        lda zc
        and #$20
        beq dn9418
up9416:    lda ZV_9494
        clc
        adc #1
        jmp :+
dn9418:    lda ZV_9494
        sec
        sbc #1
:       bpl :+
        clc
        adc #1
:       sta ZV_9494
        cmp #10
        bcc fuel
        bne sz943a
        jsr Z_BA5F              ; (never run)
        .byte $10,$0D,$85,$86,$4F,$56,$45,$52,$48,$45,$41,$54,$49,$4E,$47 ; "WARNING - ENGINE OVERHEATING"
        jmp fuel
sz943a: lda $760E               ; (never run)
        ora #2
        sta $760E
        jsr Z_BA5F
        .byte $48,$07,$86,$53,$49,$45,$5A,$45,$44       ; "ENGINE SIEZED"
fuel:   lda ZV_9496
        sec
        sbc ZV_E968
        sta ZV_9496
        lda ZV_9496+1
        sbc #0
        sta ZV_9496+1
        bcs gauge
        lda #$28
        sta ZV_9496
        lda #0
        sta ZV_9496+1
        dec ZV_9495
        beq nof9486
        lda ZV_9495
        cmp #1
        bne gauge
        jsr Z_BA5F
        .byte $38,$05,$85,$4C,$4F,$57,$87               ; "WARNING - LOW FUEL"
gauge:  jmp Z_A41E
nof9486:
        lda $760E
        ora #2
        sta $760E
        jsr Z_BA5F
        .byte $60,$03,$4E,$4F,$87                       ; "NO FUEL"
        jmp Z_A41E

; L9498: refuel / repair while standing in a petrol station
ZPROC $9498
        lda $75FD
        bpl @r
        lda $7793
        and #$40
        beq @r
        lda ZV_A093
        bne @r
        lda $760E
        lsr
        bcc :+
        lda $760E
        and #$FE
        sta $760E
        jsr Z_BA5F
        .byte $40,$09,$86,$52,$45,$50,$41,$49,$52,$45,$44 ; "ENGINE REPAIRED"
:       lda ZV_9496
        clc
        adc #3
        sta ZV_9496
        bcc :+
        inc ZV_9496+1
:       lda ZV_9496
        cmp #$28
        lda ZV_9496+1
        sbc #0
        bcc @r
        ldx ZV_9495
        inx
        cpx #12
        beq full
        lda #$14
        bne setf
@r:     rts

; S94E5: engine/fuel init
ZPROC $94E5
        lda #0
        sta $760E
        sta ZV_9494
full:   ldx #$0B
        lda #$28
setf:   stx ZV_9495
        sta ZV_9496
        lda #0
        sta ZV_9496+1
        jmp Z_A41E

; ===========================================================================
; S94F3: map byte for node (t1=L, t0=H) -> A (bit0: north edge closed,
; bit4: east edge closed); outside the map only the entry streets are open
; ===========================================================================
lookup: lda t0
        ora t1
        and #$E0
        bne @out
        lda t0
        and #$1C
        asl
        asl
        asl
        ora t1
        tay
        lda t0
        and #3
        tax
        lda ZV_9282,y
        cpx #0
        beq @r
:       lsr
        dex
        bne :-
@r:     rts
@out:   lda t1
        and #$E0
        beq @lin
        lda ZV_93C3
        cmp t0
        beq :+
@ff:    lda #$FF
        rts
:       lda #1
        rts
@lin:   lda ZV_93C2
        cmp t1
        bne @ff
        lda #$10
        rts

; S9564: E = connectivity of node (L=zl, H=zh): bit1 N, bit0 E, bit2 W,
; bit3 S closed.  zl/zh preserved.
ZPROC $9564
        lda zl
        sta t1
        lda zh
        sta t0
        lda #0
        sta ze
        jsr lookup
        lsr
        bcc :+
        ldx #2
        stx ze
:       and #8
        beq :+
        inc ze
:       dec t1
        jsr lookup
        and #$10
        beq :+
        lda ze
        ora #4
        sta ze
:       inc t1
        dec t0
        jsr lookup
        lsr
        bcc :+
        lda ze
        ora #8
        sta ze
:       rts

; S952F: A = A < 32 ? (HL)[A] : 0  (also B=0, C=A, HL+=A like the original)
ZPROC $952F
        cmp #$20
        bcs @z
        sta zc
        ldy #0
        sty zb
        clc
        adc zl
        sta zl
        bcc :+
        inc zh
:       lda (zl),y
        rts
@z:     lda #0
        rts

; S953B: seed = seed*1509 + 0x29; HL = new seed.  A, BC, DE preserved; the
; alternate BC/DE/HL are left as by the original (old seed, 0x29, new seed).
ZPROC $953B
        pha
        lda ZV_9560
        sta zc2
        sta ze2                 ; temp: s
        lda ZV_9560+1
        sta zb2
        sta zd2
        ldx #4                  ; tp = 16s
        lda zc2
        sta tp
        lda zb2
        sta tp+1
:       asl tp
        rol tp+1
        dex
        bne :-
        lda tp                  ; zl2 = 15s
        sec
        sbc zc2
        sta zl2
        lda tp+1
        sbc zb2
        sta zh2
        asl tp                  ; + 32s = 47s
        rol tp+1
        lda zl2
        clc
        adc tp
        sta zl2
        lda zh2
        adc tp+1
        sta zh2
        ldx #3                  ; *8 = 376s
:       asl zl2
        rol zh2
        dex
        bne :-
        lda zl2                 ; + s = 377s
        clc
        adc zc2
        sta zl2
        lda zh2
        adc zb2
        sta zh2
        asl zl2                 ; *4 = 1508s
        rol zh2
        asl zl2
        rol zh2
        lda zl2                 ; + s + 0x29
        clc
        adc zc2
        sta zl2
        lda zh2
        adc zb2
        sta zh2
        lda zl2
        clc
        adc #$29
        sta zl2
        sta ZV_9560
        sta zl
        lda zh2
        adc #0
        sta zh2
        sta ZV_9560+1
        sta zh
        lda #$29
        sta ze2
        lda #0
        sta zd2
        pla
        rts

; ===========================================================================
; S958B: road description of the junction ahead (D7504, heading D75F0)
; ===========================================================================
ZPROC $958B
        lda $75FC
        sta oldFC
        lda #0
        sta $75FB
        sta $75FC
        lda $7504
        sta zl
        lda $7505
        sta zh
        jsr Z_9564              ; ze = E
        ldx $7504               ; NS_TYPE[L]
        lda #0
        cpx #$20
        bcs :+
        lda ZV_9382,x
:       sta rowT
        ldx $7505               ; EW_TYPE[H]
        lda #0
        cpx #$20
        bcs :+
        lda ZV_93A2,x
:       sta colT
        ldx rowT                ; crossT / curT
        ldy colT
        lda $75F0
        lsr
        bcc :+
        lda rowT
        eor #4
        tay
        ldx colT
:       lda $75F0               ; X = curT, Y = crossT
        and #2
        beq :+
        txa
        eor #4
        tax
        tya
        eor #4
        tay
:       sty crossT
        sty $7602
        stx curT
        stx $7601
        lda $75F0               ; rel = rotl4(E, heading)
        and #3
        tax
        lda ze
        cpx #0
        beq @rd
:       asl
        cmp #$10
        bcc :+
        sbc #$0F                ; drop bit 4, set bit 0
:       dex
        bne :--
@rd:    sta rel
        sta $75F1
        lsr
        sta t0
        lda curT
        and #3
        asl
        asl
        sta t1
        lda crossT
        and #3
        ora t1
        asl
        asl
        asl
        ora t0
        tax
        lda rel
        lsr                     ; C = rel bit0: high nibble
        lda T_9854,x
        bcc :+
        lsr
        lsr
        lsr
        lsr
:       and #$0F
        cmp #10
        bne :+
        lda $7504               ; (never run)
        eor $7505
        lsr
        eor $75F0
        and #1
        eor #1
        ora #2                  ; 0 -> 2, 1 -> 3
:       asl
        tax
        lda crossT               ; D75E7
        bpl @e7
        and #4
        beq @e7
        lda T_98D4,x            ; (never run)
        and #$1E
        beq @e7
        lda T_98D4,x
        eor #$1E
        jmp :+
@e7:    lda T_98D4,x
:       sta $75E7
        lda curT                 ; D75EC
        bpl @ec
        and #4
        beq @ec
        lda T_98D4+1,x          ; (never run)
        and #$33
        beq @ec
        lda T_98D4+1,x
        eor #$33
        jmp :+
@ec:    lda T_98D4+1,x
:       sta $75EC
        lda #0
        cpx #2
        bne :+
        lda #1
:       sta $75F2
        lda curT                 ; current street type changed?
        cmp $75F4
        beq @same
        sta $75F4
        and #3
        asl
        tax
        lda T_980E,x
        sta tp
        lda T_980E+1,x
        sta tp+1
        lda $75DF
        sta $7609
        ldy #11
:       lda (tp),y
        sta $75D6,y
        dey
        bpl :-
@same:  lda crossT               ; crossT-street class record (T755D)
        and #3
        cmp #3
        bne :+
        lda #2
:       asl
        asl
        asl
        tax
        lda $75F5
        sta $75FF
        lda $755D,x
        sta $788D
        sta $78B0
        sta $75F5
        ldy #0
:       lda $755E,x
        sta $75B5,y
        inx
        iny
        cpy #7
        bne :-
        lda rel
        and #4
        beq :+
        lda #2
:       sta $788C
        lda rel
        and #1
        beq :+
        lda #2
:       sta $78AF
        ; ---- building heights of the 2 segments (2 lists each)
        lda $75F0
        and #3
        asl
        asl
        asl
        asl
        sta tofs
        tax
        lda T_9816,x            ; stride (+2 / -2; all dests are in page $78)
        sta stride
        lda #2
        sta segk
@seg:   ldx tofs
        lda $7504
        clc
        adc T_9816+2,x
        sta ZV_9562
        lda $7505
        clc
        adc T_9816+3,x
        sta ZV_9563
        lda T_9816+4,x
        sta t0
        lda T_9816+6,x
        sta t1
        lda #2
        sta dcnt
@dst:   lda ZV_9562             ; sL: rotate right (sL&7)+1 times
        and #7
        tay
        lda ZV_9562
:       lsr
        bcc :+
        ora #$80
:       dey
        bpl :--
        adc #$AA
        sta ZV_9562
        sta w_e
        lda ZV_9563             ; sH: rotate left (sH&7)+1 times
        and #7
        tay
        lda ZV_9563
:       cmp #$80
        rol
        dey
        bpl :-
        adc #$A5
        sta ZV_9563
        sta w_d
        ldx t0                  ; 6 values (de&3)+1 at dest, dest+stride, ...
        lda #6
        sta vcnt
:       lda w_e
        and #3
        clc
        adc #1
        sta $7800,x
        txa
        clc
        adc stride
        tax
        lsr w_d
        ror w_e
        lsr w_d
        ror w_e
        dec vcnt
        bne :-
        lda t1
        sta t0
        dec dcnt
        bne @dst
        ; side entrance / obstruction flags of this segment
        lda ZV_9562
        and #$12
        bne @nxt
        lda $75DF
        cmp #1
        beq @nxt
        lda segk
        cmp #1
        beq @s2
        bit ZV_9563
        bvc :+
        lda $75FB
        ora #2
        sta $75FB
        jmp @nxt
:       lda $78A7
        ora #$20
        sta $78A7
        lda $75FE
        cmp #2
        bne :+
        lda oldFC
        bpl :+
        lda $75FB               ; (never run)
        ora #$80
        sta $75FB
:       lda $75FB
        ora #1
        sta $75FB
        jmp @nxt
@s2:    bit ZV_9563
        bvc :+
        lda $75FC
        ora #2
        sta $75FC
        jmp @nxt
:       lda $78B9
        ora #$20
        sta $78B9
        lda $75FC
        ora #1
        sta $75FC
@nxt:   lda tofs
        clc
        adc #6
        sta tofs
        dec segk
        beq :+
        jmp @seg
:
        ; ---- ahead / behind closed
        lda $75F1
        and #2
        bne :+
        lda $788E
        and #$BF
        sta $788E
        lda $78B1
        and #$BF
        sta $78B1
        jmp @beh
:       lda $788E               ; (never run)
        ora #$40
        sta $788E
        lda $78B1
        ora #$40
        sta $78B1
@beh:   lda $75F1
        and #8
        bne :+
        lda $788A
        and #$7F
        sta $788A
        lda $78AD
        and #$7F
        sta $78AD
        jmp @tail
:       ldx #12                 ; (never run) bit7 of 787E,7880..788A and
:       lda $787E,x             ; 78A1,78A3..78AD (the original runs the
        ora #$80                ; tail below twice, which is idempotent)
        sta $787E,x
        lda $78A1,x
        ora #$80
        sta $78A1,x
        dex
        dex
        bpl :-
@tail:  lda $75F1               ; traffic direction masks with one-way rules
        sta t0                  ; b
        sta t1                  ; c
        lda $7602
        bpl @cu
        and #4                  ; (never run)
        beq :+
        lda #1
        ldx #4
        bne :++
:       lda #4
        ldx #1
:       ora t1
        sta t1
        txa
        ora t0
        sta t0
@cu:    lda $7601
        bpl @st
        and #4                  ; (never run)
        beq :+
        lda #2
        ldx #8
        bne :++
:       lda #8
        ldx #2
:       ora t1
        sta t1
        txa
        ora t0
        sta t0
@st:    lda t0
        sta $7606
        lda t1
        sta $7607
        rts

; ===========================================================================
; S98F4: two keys from the table at (zl,zh): D = 0 none, 3 first only,
; 1 second only, 2 both; zl/zh advanced by 5
; ===========================================================================
ZPROC $98F4
        lda #0
        sta zd
        jsr Z_F37A
        inc zl
        bne :+
        inc zh
:       cmp #0
        bne :+
        lda #3
        sta zd
:       jsr Z_F37A
        bne :+
        lda #1
        eor zd
        sta zd
:       rts

; ===========================================================================
; S9907: rebuild the lane grids for the new junction
; ===========================================================================
ZPROC $9907
        lda #0
        tax
:       sta $5C00,x
        sta $5D00,x
        sta $5E00,x
        sta $5F00,x
        sta $6000,x
        sta $6100,x
        sta $6200,x
        sta $6300,x
        sta ZV_FD60,x
        sta ZV_FD60+$100,x
        inx
        bne :-
        ldx #$A0
:       sta ZV_FD60+$1FF,x
        dex
        bne :-
        jsr Z_9971
        lda $75F1
        and #2
        bne :+
        lda #0
        sta w_row
        lda $75FC
        jsr Z_99DD
:       lda $75F1
        and #8
        bne :+
        lda $75F5
        clc
        adc #$64
        sta w_row
        lda $75FB
        jsr Z_99DD
:       lda $75F1
        and #1
        bne :+
        lda $75D7
        ldx #$E0
        jsr Z_9965
:       lda $75F1
        and #4
        bne :+
        lda $75D6
        ldx #$C0
        jsr Z_9965
:       rts

; S9965: openings in the kerb page A: rows 0x64.. = X, X+1, ... (D75F5 cells)
ZPROC $9965
        sta tp+1
        lda #0
        sta tp
        ldy #$64
        lda $75F5
        sta t0
        txa
:       sta (tp),y
        clc
        adc #1
        iny
        dec t0
        bne :-
        rts

; S9971: petrol station check, then the junction corner markers in both arms
ZPROC $9971
        jsr Z_9A55
        lda $75FD
        bmi @r
        lda $75F5
        sec
        sbc #2
        jsr mul12               ; DE = 12*(F5-2)
        lda $75F2
        and #1
        beq :+
        lda #7
:       sta w_a
        lda #<(FDB+$FD77)
        sta tp
        lda #>(FDB+$FD77)
        sta tp+1
        lda #1
        sta w_neg
        jsr s9999
        lda #<(FDB+$FEBC)
        sta tp
        lda #>(FDB+$FEBC)
        sta tp+1
        lda #0
        sta w_neg
        jmp s9999
@r:     rts

; S9999 (tp = HL, ze/zd = DE, w_neg: BC = -6 / +6, w_a = A)
tpde:   lda tp                  ; tp += DE
        clc
        adc ze
        sta tp
        lda tp+1
        adc zd
        sta tp+1
        rts
s9999:  inc $75F0
        lda $75B5
        cmp #1
        beq :+
        lda #5
        bne :++
:       lda #0
:       sta mval
        lda $75F0
        and #2
        beq :+
        jsr tpde
:       ldy #0
        lda w_a
        sta (tp),y
        ldy #6                  ; HL += BC
        lda w_neg
        beq :+
        lda tp
        sec
        sbc #6
        sta tp
        bcs :++
        dec tp+1
        bcc :++
:       tya
        clc
        adc tp
        sta tp
        bcc :+
        inc tp+1
:       ldy #0
        lda mval
        sta (tp),y
        lda $75F0
        and #2
        beq :+
        lda tp                  ; HL -= DE
        sec
        sbc ze
        sta tp
        lda tp+1
        sbc zd
        sta tp+1
        jmp :++
:       jsr tpde
:       lda w_neg               ; HL += BC<0 ? 5 : -5
        beq :+
        lda tp
        clc
        adc #5
        sta tp
        bcc :++
        inc tp+1
        bcs :++
:       lda tp
        sec
        sbc #5
        sta tp
        bcs :+
        dec tp+1
:       ldy #0
        lda #5
        sta (tp),y
        lda w_neg               ; HL += BC<0 ? +1 : -1 (B was reloaded
        beq @m1                 ; with the +-5 above)
        inc tp
        bne @w
        inc tp+1
        bne @w
@m1:    lda tp
        bne :+
        dec tp+1
:       dec tp
@w:     lda w_a
        sta (tp),y
        dec $75F0
        rts

; S99DD: A = segment features, w_row = base row: side entrances, the lane
; obstruction and the lamp posts of one segment
ZPROC $99DD
        sta w_fl
        lda #0
        sta tp
        lda w_fl
        lsr
        bcc @nb0
        lda $75D7               ; entrance markers
        sta tp+1
        lda w_row
        clc
        adc #$2C
        tay
        lda #6
        sta (tp),y
        lda $75D6
        sta tp+1
        lda w_row
        clc
        adc #$30
        tay
        lda #6
        sta (tp),y
@nb0:   lda w_fl
        and #2
        beq @lamps
        lda $75F0               ; obstruction one lane in from the kerb
        and #2
        beq :+
        ldx $75D6
        inx
        bne :++
:       ldx $75D7
        dex
:       stx tp+1
        lda w_row
        clc
        adc #$32
        tay
        lda $75DF
        lsr
        bcc @even
        lda #$0B
        sta (tp),y
        tya
        clc
        adc #5
        tay
        lda #$0A
        sta (tp),y
        tya
        sec
        sbc #10
        tay
        lda #$0A
        sta (tp),y
        jmp @lamps
@even:  lda #8                  ; (never run)
        sta (tp),y
        ldx #5
        lda #$FF
:       dey
        sta (tp),y
        dex
        bne :-
        dey
        lda #$0A
        sta (tp),y
@lamps: lda $75F0
        and #2
        beq :+
        lda $75D6
        ldx $75D7
        bne :++
:       lda $75D7
        ldx $75D6
:       stx t1
        sta tp+1
        lda w_row
        clc
        adc #2
        ldx #4
        jsr s9a49
        lda $75DF
        cmp #1
        beq :+
        lda t1
        sta tp+1
        lda w_row
        clc
        adc #$0E
        ldx #3
        jmp s9a49
:       rts

; S9A49: lamp posts (value 4) on page tp+1 at row A, then X more every 24 rows
s9a49:  tay
        lda #4
        sta (tp),y
:       tya
        clc
        adc #$18
        tay
        lda #4
        sta (tp),y
        dex
        bne :-
        rts

; S9A55: petrol station on a straight 2-lane street (never run past the tests)
ZPROC $9A55
        lda $75FD
        and #$7F
        sta $75FD
        lda $75F1
        and #$0F
        cmp #5
        bne @r
        lda $75DF
        cmp #2
        bne @r
        lda $75B5
        cmp #1
        bne @r
        lda $7504
        eor $7505
        lsr
        eor $75F0
        tax
        lda $75FD
        ora #$80
        sta $75FD
        txa
        and #2
        beq @right
        lda #0
        sta $788C
        lda #9
        sta FDB+$FDA6
        sta FDB+$FDA6+$24
        lda #1
        bne @e
@right: lda #0
        sta $78AF
        lda #9
        sta FDB+$FEED
        sta FDB+$FEED+$24
        lda #4
@e:     sta $75F1
        lda #0
        sta $75E7
@r:     rts

; ===========================================================================
; S9AA8: remap the traffic cars and objects after a node transition
; ===========================================================================
exx:    ldx zc                  ; Z80 EXX on the zero-page register file
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
        rts

ZPROC $9AA8
        jsr Z_BB18
        lda $75FE
        sta w_fe
        ldx #<(Z_9D94-1)
        ldy #>(Z_9D94-1)
        and #4
        bne set9acd
        lda w_fe
        and #2
        bne :+
        ldx #<(Z_9BD6-1)           ; (never run) left / right turn
        ldy #>(Z_9BD6-1)
        bne set9acd
:       lda $75FD
        and #$FE
        sta $75FD
        ldx #<(Z_9B4A-1)
        ldy #>(Z_9B4A-1)
        lda w_fe
        lsr
        bcc set9acd
        ldx #<(Z_9BB6-1)           ; (never run) backward
        ldy #>(Z_9BB6-1)
set9acd:   stx hjmp
        sty hjmp+1
        lda #<$770E             ; the 3 traffic cars
        sta ziyl
        lda #>$770E
        sta ziyh
        lda #0
        sta w_par
        lda #1
        sta w_id
        lda #3
        sta w_cnt
l1_9ae1:    jsr callh
        LDF 1
        bpl :+
        lda w_id
        sta za2
        jsr Z_9205
        beq :+
        LDF 1                   ; (never run)
        and #$7F
        sta (ziy),y
:       jsr nextiy
        inc w_id
        dec w_cnt
        bne l1_9ae1
        lda #16                 ; the 16 objects, player first
        sta $7603
        lda #<$7792
        sta ziyl
        lda #>$7792
        sta ziyh
        lda #3
        sta w_par
        lda #$0C
        sta w_id
l2_9b10:    jsr callh
        LDF 1
        bpl l9b39
        lda w_id
        sta za2
        sta ze
        jsr exx
        jsr Z_B412
        beq l9b39
        LDF 2                   ; (never run)
        and #6
        cmp #6
        bne :+
        jsr Z_DC4C
:       LDF 1
        and #$7F
        sta (ziy),y
l9b39:  jsr nextiy
        inc w_id
        dec $7603
        bne l2_9b10
        jmp Z_DE15

callh:  lda hjmp+1               ; handler: A = D75FE, w_par = C, w_id = E
        pha
        lda hjmp
        pha
        lda w_fe
        rts

nextiy: lda ziyl
        clc
        adc #12
        sta ziyl
        bcc :+
        inc ziyh
:       rts

; D9B4A: forward step - keep what was beyond the junction, drop the rest
ZPROC $9B4A
        LDF 1
        bpl new
        and #$7F
        sta (ziy),y
        and #$40
        bne drop9b8c
        LDF 6
        cmp #$64
        bcs drop9b8c
        adc #$64
        clc
        adc $75F5
keep:   STF 6                   ; 9B66
        sta zl
        LDF 1
        ora #$80
        sta (ziy),y
        LDF 7
        sta zh
        lda w_par
        and #2
        beq r9b66
        lda #0
        STF 10
        lda zl
        pha
        lda zh
        pha
        jsr Z_B241
        pla
        sta zh
        pla
        sta zl
r9b66:     LDF 6
        rts
drop9b8c:  jsr Z_9B7F
new:    lda w_par               ; L9B8F: objects get a fresh one ahead
        and #2
        beq r9b8f
        LDF 2
        and #2
        bne r9b8f
        lda #0
        STF 5
        lda ZV_9561
        and #$1F
        clc
        adc #$3C
        STF 6
        lda $7607
        and #2
        bne r9b8f
        jsr Z_B1BC
        lda #0
        STF 11
        pla
        pla
        jmp l9b39
r9b8f:    rts

; S9B7F: a special vehicle (+2 bits 1 and 2) was lost
ZPROC $9B7F
        LDF 2
        and #6
        cmp #6
        bne :+
        jmp Z_DC4C              ; (never run)
:       rts

; D9BB6: backward step (never run)
ZPROC $9BB6
        LDF 1
        bmi :+
        rts
:       and #$7F
        sta (ziy),y
        and #$40
        bne @drop
        LDF 6
        sec
        sbc $75FF
        bcc @drop
        sbc #$69
        bcc @drop
        adc #4                  ; C=1: +5
        jmp keep
@drop:  jmp Z_9B7F

; D9D94: U-turn - mirror every record about the grid centre
ZPROC $9D94
        LDF 5
        tax
        clc
        adc #2
        and #3
        sta t0
        txa
        and #$0C
        ora t0
        sta (ziy),y
        LDF 1
        eor #$20
        sta (ziy),y
        and #$40                ; SF2FE
        beq :+
        LDF 9
        clc
        adc #$64
        jmp :++
:       LDF 6
:       sta w_y
        lda $75F5
        clc
        adc #$C7
        clc
        adc w_par
        sec
        sbc w_y
        sta t1
        LDF 1
        and #$40
        beq @main
        lda t1                  ; in a cross grid
        sec
        sbc #$64
        bcs :+
        lda #0
:       cmp $75F5
        bcc :+
        sbc #1                  ; (never run)
        jmp :-
:       STF 9
        jsr b9dd
        LDF 8
        sta ze
        lda #0
        sta zd
        LDF 1
        and #$20
        beq :+
        lda zl
        clc
        adc ze
        sta zl
        bcc @st
        inc zh
        bcs @st
:       lda zl
        sec
        sbc ze
        sta zl
        bcs @st
        dec zh
@st:    jsr Z_9274
        jmp @tail
@main:  lda t1
        sta zl
        lda w_par
        lsr
        bcs @k
        lda w_y
        cmp #$2E
        beq @off
        sec
        sbc $75F5
        cmp #$92
        bne @k
@off:   LDF 1                   ; (never run)
        and #$7F
        sta (ziy),y
@k:     lda zl
        STF 6
        lda #$BF
        sec
        iny
        sbc (ziy),y
        sta (ziy),y
        sta zh
@tail:  lda w_id
        cmp #$0C
        beq :+
        rts
:       pla
        pla
        jsr Z_F4A7
        jsr Z_F2D1
        jmp l9b39

; D9BD6: left / right turn - rotate every record through the junction
; square (never run in the coverage; code shown as data in te.lst)
ZPROC $9BD6
        LDF 1
        bmi :+
        rts
:       jsr backup
        lda w_par
        and #2
        beq @a                  ; traffic
        lda w_id
        cmp #$0C
        beq @a                  ; player
        LDF 5
        lsr
        bcs @a
        LDF 10
        lsr
        bcs @a
        jsr Z_9D62
@a:     LDF 1                   ; 9BFA
        and #$40
        beq :+
        LDF 9
        sta xc
        lda $75FF
        sec
        sbc #1
        jmp :++
:       LDF 6
        sta xc
        lda $75FF
        clc
        adc #$C7
:       sta xb
        lda #0                  ; t = 2*cc - c (carry of the last add)
        sec
        sbc w_par
        clc
        adc xc
        clc
        adc xc
        ldx #0
        bcc :+
        sbc xb                  ; C=1: plain subtract
        jmp :++
:       sec
        sbc xb
        bcs :+
        eor #$FF
        adc #1
        ldx #1
:       sta xt
        stx xsgn
        lda w_fe                ; c' = turn ^ sgn
        eor xsgn
        sta xc
        lda xt
        lsr
        lsr
        lsr
        sta xb                  ; lateral
        lda xt
        and #7
        sta t0
        lda #4
        sec
        sbc t0
        sta xd
        lda w_par
        and #2
        beq :+
        lda xd
        bpl :+
        clc
        adc #8
        sta xd
        inc xb
:       lda xb
        cmp $75DF
        bcc :+
        lda $75DF
:       sta t0
        lda xc
        lsr
        lda t0
        bcs :+
        eor #$FF
:       clc
        adc #$60
        sta xh
        LDF 7
        sta xold
        lda xh
        sta (ziy),y
        LDF 1
        and #$40
        beq @mg
        lda (ziy),y
        and #$BF
        sta (ziy),y
        lda $7609
        ldy #8
        clc
        adc (ziy),y
        sta xdist
        LDF 1
        and #$20
        bne @rt
        beq @s1
@mg:    lda xold
        sec
        sbc #$60
        sta xdist
        bcs @rt
        eor #$FF
        sta xdist
@s1:    lda xc
        ora #2
        sta xc
@rt:    lda $75FE
        lsr
        bcc :+
        lda xc
        eor #2
        sta xc
:       lda xdist
        clc
        adc #1
        asl
        asl
        asl
        sec
        ldy #0
        sbc (ziy),y
        sta t0
        lda xd
        sta (ziy),y
        lda t0
        sec
        sbc #4
        bcs :+
        eor #$FF
        adc #1
        tax
        lda xc
        eor #2
        sta xc
        txa
:       sta xe
        lda $75F5
        clc
        adc #$C8
        tax
        lda xc
        and #2
        beq :++
        txa
        sec
        sbc xe
        bcc :+
        clc
        bcc @rr
:       sec
        bcs @rr
:       txa
        clc
        adc xe
@rr:    ror
        sta xl
        lda w_par
        lsr
        clc
        adc xl
        STF 6
        sta xl
        sta tp
        lda xh
        sta tp+1
        ldy #0
        lda (tp),y
        bmi :+
        jmp @l9d05
:
        and #$40
        bne @open
@drop:  jsr restore
        LDF 1
        and #$7F
        sta (ziy),y
        jmp Z_9B7F
@open:  lda xl
        sec
        sbc #$64
        STF 9
        jsr mul12
        lda xc
        lsr
        bcc :+
        lda #<$FEB0
        ldx #>$FEB0
        bne :++
:       lda #<$FD6B
        ldx #>$FD6B
:       clc
        adc ze
        sta tp
        txa
        adc zd
        sta tp+1
        lda xb
        sec
        sbc $75DF
        cmp #12
        bcs @drop
        STF 8
        sta ze
        lda xc
        lsr
        bcc :+
        lda tp
        clc
        adc ze
        sta tp
        bcc :++
        inc tp+1
        bcs :++
:       lda tp
        sec
        sbc ze
        sta tp
        bcs :+
        dec tp+1
:       lda #0
        sta zd
        LDF 1
        ora #$40
        sta (ziy),y
        lda tp
        sta xl
        STF 6
        lda tp+1
        sta xh
        STF 7
@l9d05: LDF 1
        ora #$20
        sta (ziy),y
        lda xc
        lsr
        bcs :+
        lda (ziy),y
        and #$DF
        sta (ziy),y
:       LDF 5                   ; direction rotates with the turn
        sta t0
        lda w_fe
        lsr
        lda t0
        bcc :+
        sbc #2                  ; C=1
:       clc
        adc #1
        and #3
        sta t1
        lda t0
        and #$FC
        ora t1
        sta (ziy),y
        lda xl
        sta zl
        lda xh
        sta zh
        lda w_id
        cmp #$0C
        beq :+
        rts
:       LDF 1                   ; player: back onto the main road
        and #$40
        beq :+
        lda (ziy),y
        and #$BF
        sta (ziy),y
        jsr f53d
        sta zh
        STF 7
        LDF 9
        clc
        adc #$64
        sta zl
        STF 6
:       jsr Z_9D62
        LDF 7
        sta zh
        cmp $75D6
        bne :+
        clc
        adc #1
        sta (ziy),y
        inc zh
        rts
:       cmp $75D7
        bne :+
        sec
        sbc #1
        sta (ziy),y
        dec zh
:       rts

; 9D62: finish a pending sideways step
ZPROC $9D62
        LDF 1
        and #$FB
        sta (ziy),y
        ldy #0
        lda (ziy),y
        bne :+
        rts
:       tax
        lda #0
        sta (ziy),y
        cpx #4
        bcs :+
        rts
:       LDF 1
        and #$20
        bne @r
        LDF 7
        clc
        adc #1
        sta (ziy),y
        cmp #$60
        bne :+
        LDF 1
        ora #$20
        sta (ziy),y
:       rts
@r:     LDF 7
        sec
        sbc #1
        sta (ziy),y
        cmp #$5F
        bne :+
        LDF 1
        and #$DF
        sta (ziy),y
:       rts
