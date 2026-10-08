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

hjmp:   .res 3                  ; D9AE5/D9B14: transition handler
        ZVAR $FD60, $2A0        ; cross-street grids
FDB = ZV_FD60 - $FD60           ; FDB + $FDxx = Oric address of Spectrum $FDxx
        .segment "LOWRAM"       ; $0180-$02FF (stack shortened to $0100-$017F)
        ZVAR $9282, $153        ; current city block (copied in by the city select)
        .segment "DATA"

        .zeropage
W:      .res 12                 ; the record being processed (copy of (ziy))
tp:     .res 2                  ; general pointer
w_b:    .res 1                  ; B in S8F3D (new +5)
w_c:    .res 1                  ; C in S8F3D (old +1 flags)
w_d:    .res 1                  ; D (kerb page)
w_e:    .res 1                  ; E (row / random)
w_step: .res 1
w_x:    .res 1
t0:     .res 1
t1:     .res 1
t2:     .res 1
u0:     .res 1                  ; scratch (meaning per routine, see below)
u1:     .res 1
u2:     .res 1
u3:     .res 1
u4:     .res 1
u5:     .res 1
w_fe:   .res 1                  ; D75FE on entry to S9AA8
w_id:   .res 1                  ; E in S9AA8's loops (record id)
w_par:  .res 1                  ; C in S9AA8's loops (0 traffic, 3 objects)

; private variables of the non-nesting routines share the scratch bytes
oldFC   = u0                    ; S958B: D976D (D75FC on entry)
rowT    = u1
colT    = u2
curT    = u3
crossT  = u4
rel     = u5
tofs    = w_b                   ; T9816 offset for the heading
segk    = w_c                   ; segment counter (2, 1)
stride  = w_step
dcnt    = w_x
w_a     = u0                    ; S9999: value A
w_neg   = u1                    ; S9999: BC negative
mval    = u2                    ; D99B4
w_row   = u3                    ; S99DD: base row E
w_fl    = u4
w_y     = u4                    ; D9D94: D9DF2
xb      = w_b                   ; 9BD6: the exx'd register set
xc      = w_c
xd      = w_d
xe      = w_e
xl      = u0
xh      = u1
xt      = u2
xdist   = u3

        .segment "RODATA4"
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
; The record being processed is worked on in the zero-page copy W (win /
; wout); the routines of other modules always see it written back.
; ===========================================================================
; (S8F3D works on the record with X = its offset from REC = $770E.)
REC = $770E
ZPROC $8F23
        ldx #0
        lda #1
@l:     sta za2
        stx w_x
        jsr Z_8F3D
        lda w_x
        clc
        adc #12
        tax
        lda za2
        clc
        adc #1
        cmp #4
        bne @l
        rts

nextiy: lda ziyl
        clc
        adc #12
        sta ziyl
        bcc :+
        inc ziyh
:       rts

; record (ziy) <-> W
win:    ldy #11
:       lda (ziy),y
        sta W,y
        dey
        bpl :-
        rts
wout:   ldy #11
:       lda W,y
        sta (ziy),y
        dey
        bpl :-
        rts
; SB905 / SB913 (other region, inlined): W <-> DB8F9 backup
bkupx:  ldy #11                 ; REC,x -> DB8F9
        txa
        clc
        adc #11
        tax
:       lda REC,x
        sta ZV_B8F9,y
        dex
        dey
        bpl :-
        inx
        rts
rstrx:  ldy #11
        txa
        clc
        adc #11
        tax
:       lda ZV_B8F9,y
        sta REC,x
        dex
        dey
        bpl :-
        inx
        rts
bkup:   ldy #11
:       lda W,y
        sta ZV_B8F9,y
        dey
        bpl :-
        rts
rstr:   ldy #11
:       lda ZV_B8F9,y
        sta W,y
        dey
        bpl :-
        rts

; SF53D (inlined): A = kerb page of the record's side (Y clobbered)
f53dx:  lda REC+1,x
        .byte $2C               ; (skip lda W+1)
f53d:   lda W+1
        ldy #0
        and #$20
        beq :+
        iny
:       lda $75D6,y
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
b9ddx:  pha
        lda REC+1,x
        jmp :+
b9dd:   pha
        lda W+1
:       ldy #0
        and #$20
        beq :+
        ldy #2
:       pla
        jsr mul12
; HL = arm base Y (0 left $FD6B, 2 right $FEB0) + DE
armb:   lda abase,y
        sta zl
        lda abase+1,y
        sta zh
hladde: lda zl                  ; HL += DE
        clc
        adc ze
        sta zl
        lda zh
        adc zd
        sta zh
        rts
hlsube: lda zl                  ; HL -= DE
        sec
        sbc ze
        sta zl
        lda zh
        sbc zd
        sta zh
        rts
abase:  .word $FD6B, $FEB0

; SB9EE (inlined): move a main-grid record standing on an opening into the
; cross grid: +9 = +6-0x64, +8 = 0, ptr = HL = SB9DD(+9)
b9eex:  lda REC+6,x
        sec
        sbc #$64
        sta REC+9,x
        lda #0
        sta REC+8,x
        lda REC+9,x
        jsr b9ddx
wstx:   lda zl                  ; (REC+6,REC+7),x = HL
        sta REC+6,x
        lda zh
        sta REC+7,x
        rts
wldx:   lda REC+6,x
        sta zl
        lda REC+7,x
        sta zh
        rts
wst:    lda zl                  ; (W+6,W+7) = HL
        sta W+6
        lda zh
        sta W+7
        rts

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
        jsr bkupx
car:    lda REC+1,x
        bmi :+
        jmp spawn
:       sta w_c
        jsr wldx
        lda REC+5,x
        clc
        adc #4
        and #7
        sta REC+5,x
        sta w_b
        bit w_c
        bvc :+
        jmp cross
:       lsr
        bcc :+
        jmp sideways
:       and #2                  ; (b>>1)&2 = b bit2
        beq rts1
        jsr Z_9230
        lda w_b
        and #2
        beq fwd
        inc zl                  ; towards the player
        lda $75F5
        clc
        adc #$C8
        cmp zl
        bne l8f7c
off:    asl REC+1,x                 ; left the grid: bit 7 off
        lsr REC+1,x
rts1:   rts
fwd:    dec zl
        beq off
l8f7c:  jsr wstx
        jsr Z_924B
        bcc nop8fa8
        jsr b9eex                ; turned into an opening
        lda REC+1,x
        ora #$40
        sta REC+1,x
        jsr Z_9205
        bne rev1
        bit $75FD
        bmi rts1
        lda REC+1,x                 ; +5 = bit5 ? 1 : 3
        and #$20
        lsr
        lsr
        lsr
        lsr
        eor #3
        sta REC+5,x
        rts
rev1:   jmp reverse
nop8fa8:
        jsr Z_9205
        bne rev1
        lda zl
        sta w_e
        cmp #$2E
        bne :+
        ldy #1                  ; entrance in the segment beyond (D75FC)
        jsr s9255
        beq rts1
:       lda $75F5
        clc
        adc #$92
        cmp w_e
        bne :+
        ldy #0                  ; entrance in the current segment (D75FB)
        jsr s9255
        beq rts1
:       lda w_b
        and #2
        beq :+
        lda $75F5               ; (never run)
        clc
        adc #$63
        ldy #8
        bne :++
:       lda #$64
        ldy #2
:       cmp w_e
        bne rts1
        tya
        and $75F1
        beq rts1
        bne l9266

; S9255 (A=row matched by the caller): entrance flags $75FB+X.  Z = taken.
s9255:  lda $75FB,y
        bmi no9255
        lsr
        bcc no9255
        lda $75FB,y
        ora #$80
        sta $75FB,y
        lda #$0F
        sta REC+10,x
; L9266: turn sideways: +5 = (old +1 bit5) ? 3 : 1, Z
l9266:  lda w_c
        and #$20
        lsr
        lsr
        lsr
        lsr
        ora #1
        sta REC+5,x
        lda #0
        rts
no9255: lda #1
        rts

; L9220: back out: restore the record, reverse the direction, re-occupy
reverse:
        jsr rstrx
        lda #2
        eor REC+5,x
        sta REC+5,x
        jsr wldx
        jmp Z_9205

; L8FE3: sideways in the main grid (direction 1/3)
sideways:
        lda REC+10,x
        beq @go
        dec REC+10,x
        lda REC+5,x
        and #3
        sta REC+5,x
        rts
@go:    lda w_b                 ; (never run from here on)
        and #2
        beq :+
        lda #$20
:       eor w_c
        and #$20
        bne sdec
        inc REC+0,x
        lda REC+0,x
        cmp #5
        bne rts2
        lda #$FD
        jsr s9045
        beq :+
        jmp reverse
:
        lda w_b
        and #2
        bne @b1
        lda zh
        cmp #$60
        bne rts2
        lda #$20
        ora REC+1,x
        bne @st
@b1:    lda zh
        cmp #$5F
        bne rts2
        lda #$DF
        and REC+1,x
@st:    sta REC+1,x
        lda #3
        sta REC+0,x
rts2:   rts
sdec:   dec REC+0,x
        lda REC+0,x
        cmp #1
        beq kerb
        cmp #$FC
        bne rts2
        lda #4
        jsr s9045
        beq rts2
        jmp reverse

; S9045: one sideways cell step (A = new +0)
s9045:  sta REC+0,x
        jsr Z_9230
        lda w_b
        and #2
        bne :+
        inc zh
        inc zh
:       dec zh
        lda zh
        sta REC+7,x
        jsr Z_924B
        bcc :+
        lda REC+1,x
        ora #$40
        sta REC+1,x
        jsr b9eex
:       jmp Z_9205

; L9064: reached the kerb
kerb:   jsr f53dx
        cmp REC+7,x
        bne rts2
        lda REC+6,x
        cmp #$64
        bne :+
        lda #2
        bne @s5
:       lda $75F5
        clc
        adc #$63
        cmp REC+6,x
        bne :+
        lda #0
        beq @s5
:       ldy #0
        lda REC+6,x
        cmp #$2E
        bne :+
        iny
:       lda $75FB,y
        and #$7F
        sta $75FB,y
        GET_R
        and #2
@s5:    sta REC+5,x
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
        ldy #1
        bne :++
:       lda #2
        eor w_b
        sta w_b
        lda $75D6
        ldy #$FF
:       sta w_d
        sty w_step
        lda w_b
        and #2
        bne tow90ea
        dec REC+0,x                 ; away from the main road
        lda REC+0,x
        cmp #$FC
        bne rts3
        lda #4
        sta REC+0,x
        jsr Z_9230
        jsr hlstep
        inc REC+8,x
        lda REC+8,x
        cmp #12
        beq :+
        jmp l9178
:
        asl REC+1,x
        lsr REC+1,x
rts3:   rts
tow90ea:
        inc REC+0,x                 ; towards the main road
        lda REC+0,x
        cmp #2
        beq mouth
        cmp #5
        bne rts3
        lda #$FD
        sta REC+0,x
        jsr Z_9230
        jsr hlunst
        dec REC+8,x
        bpl l9178
        lda REC+9,x                 ; (never run)
        clc
        adc #$64
        sta zl
        ldy w_d
        iny
        lda REC+1,x
        and #$20
        beq :+
        dey
        dey
:       sty zh
        jmp l9141
mouth:  lda REC+8,x
        bne rts3
        lda REC+9,x
        beq :+
        lda $75F1
        and #8
        bne rts3
        jsr Z_9230
        lda REC+9,x
        clc
        adc #$65
        ldy #2
        bne :++
:       lda $75F1
        and #2
        bne rts3
        jsr Z_9230
        lda #$63
        ldy #0
:       sta zl
        lda w_d
        sta zh
        tya
        sta REC+5,x
        lda #1
        sta REC+0,x
l9141:  lda REC+1,x
        and #$BF
        sta REC+1,x
l9178:  jsr wstx
        jsr Z_9205
        bne :+
        rts
:
        jmp reverse

hlstep: lda w_step              ; HL += step
        bmi hldec
hlinc:  inc zl
        bne :+
        inc zh
:       rts
hlunst: lda w_step              ; HL -= step
        bmi hlinc
hldec:  lda zl
        bne :+
        dec zh
:       dec zl
        rts

; L9154: along the cross street in a cross grid (never run)
l9154:  lda w_b
        and #4
        bne :+
        rts
:
        jsr Z_9230
        lda w_b
        and #2
        beq @dn
        lda zl
        clc
        adc #12
        sta zl
        bcc :+
        inc zh
:       inc REC+9,x
        lda $75F5
        cmp REC+9,x
        bne l9178
        clc
        adc #$64
        jmp l9170
@dn:    lda zl
        sec
        sbc #12
        sta zl
        bcs :+
        dec zh
:       dec REC+9,x
        bpl l9178
        lda #$63
l9170:  sta zl
        jsr f53dx
        sta zh
        jmp l9141

; L918F: spawn a new car (Z80 R register as random source)
spawn:  lda $75F1
        sta t0
        GET_R
        sta w_e
        and #3
        sta t1
        tay
        beq :++
:       asl t0
        dey
        bne :-
:       lda t0
        and #8
        beq :+
        rts
:
        lda #1
        sta REC+0,x
        lda t1
        sta REC+5,x
        lsr
        bcs @arm
        ldy #0                  ; main grid
        lda w_e
        and #4
        beq :+
        iny
        lda #$A0
        .byte $2C               ; (skip the next lda)
:       lda #$80
        sta REC+1,x
        lda $75D6,y
        sta REC+7,x
        lda #1
        ldy t1
        bne :+
        lda $75F5
        clc
        adc #$C7
:       sta REC+6,x
        rts
@arm:   lda #$C0                ; cross-street arm, far end (col 11)
        ldy t1
        cpy #3
        ldy #0
        bcc :+
        lda #$E0
        ldy #2
:       sta REC+1,x
        lda sbase,y
        sta zl
        lda sbase+1,y
        sta zh
        lda #0
        sta t0
        lda w_e
        and #4
        beq :+
        lda $75F5
        sec
        sbc #1
        sta t0
        jsr mul12
        jsr hladde
:       lda t0
        sta REC+9,x
        lda #$0B
        sta REC+8,x
        jmp wstx
sbase:  .word $FD60, $FEBB


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
        lda #0
        sta ze
        ldx #3
@l:     lda zl
        clc
        adc dlt,x
        sta t1
        lda zh
        clc
        adc dht,x
        sta t0
        txa
        pha
        jsr lookup
        sta t2
        pla
        tax
        lda t2
        and mt,x
        beq :+
        lda ze
        ora et,x
        sta ze
:       dex
        bpl @l
        rts
dlt:    .byte 0, 0, $FF, 0      ; (L,H) offsets: N and E of the node, E of
dht:    .byte 0, 0, 0, $FF      ; the node to the W, N of the node to the S
mt:     .byte 1, $10, $10, 1
et:     .byte 2, 1, 4, 8

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
        sta ze2                 ; ze2/zd2: s << k
        lda ZV_9560+1
        sta zb2
        sta zd2
        lda #$29                ; zl2/zh2: 0x29 + sum
        sta zl2
        lda #0
        sta zh2
        lda #<1509
        sta t0
        lda #>1509
        sta t1
:       lsr t1
        ror t0
        bcc :+
        lda zl2
        clc
        adc ze2
        sta zl2
        lda zh2
        adc zd2
        sta zh2
:       asl ze2
        rol zd2
        lda t0
        ora t1
        bne :--
        lda zl2
        sta ZV_9560
        sta zl
        lda zh2
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
        lda $7504               ; NS_TYPE[L]
        ldy #0
        jsr styp
        sta rowT
        lda $7505               ; EW_TYPE[H]
        ldy #$20
        jsr styp
        sta colT
        lda $75F0               ; t1 = 4 when heading bit 1
        and #2
        asl
        sta t1
        lda $75F0
        lsr
        bcc :+
        lda rowT
        eor #4
        ldx colT
        jmp :++
:       lda colT
        ldx rowT
:       eor t1
        sta crossT
        sta $7602
        txa
        eor t1
        sta curT
        sta $7601
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
        eor #3                  ; 0 -> 3, 1 -> 2
:       asl
        tax
        lda crossT               ; D75E7
        ldy #$1E
        jsr onew
        sta $75E7
        inx
        lda curT                 ; D75EC
        ldy #$33
        jsr onew
        sta $75EC
        ldy #0
        cpx #3
        bne :+
        iny
:       sty $75F2
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
@same:  lda crossT               ; cross-street class record (T755D)
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
        lsr
        sta $788C
        lda rel
        and #1
        asl
        sta $78AF
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
        ldy #6
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
        dey
        bne :-
        lda t1
        sta t0
        dec dcnt
        bne @dst
        ; side entrance / obstruction flags of this segment (Y: 0 FB, 1 FC)
        lda ZV_9562
        and #$12
        bne @nxt
        lda $75DF
        cmp #1
        beq @nxt
        lda #2
        sec
        sbc segk
        tay
        lda #2
        bit ZV_9563
        bvs @or
        ldx #0
        tya
        beq :+
        ldx #$12
:       lda $78A7,x             ; D78A7 / D78B9 bit 5
        ora #$20
        sta $78A7,x
        lda #1
        cpy #0
        bne @or
        ldx $75FE
        cpx #2
        bne @or
        bit oldFC
        bpl @or
        ora #$80                ; (never run)
@or:    ora $75FB,y
        sta $75FB,y
@nxt:   lda tofs
        clc
        adc #6
        sta tofs
        dec segk
        beq :+
        jmp @seg
:       ; ---- ahead / behind closed
        lda #$40
        sta t0
        ldx #$8E
        ldy #$B1
        lda $75F1
        and #2
        beq :+
        jsr sbset               ; (never run)
        jmp :++
:       jsr sbclr
:
        lda #$80
        sta t0
        ldx #$8A
        ldy #$AD
        lda $75F1
        and #8
        bne :+
        jsr sbclr
        jmp @tail
:       jsr sbset               ; (never run) bit7 of 787E,7880..788A and
        dex                     ; 78A1..78AD (the original runs the tail
        dex                     ; twice, which is idempotent)
        dey
        dey
        cpx #$7C
        bne :-
@tail:  lda $75F1               ; traffic direction masks with one-way rules
        sta t0                  ; b
        sta t1                  ; c
        ldx #1
        lda $7602
        jsr omask
        ldx #2
        lda $7601
        jsr omask
        lda t0
        sta $7606
        lda t1
        sta $7607
        rts

; A = NS_TYPE/EW_TYPE[A] (Y = 0 / $20), 0 off the map
styp:   cmp #$20
        bcs :+
        sty t0
        adc t0
        tay
        lda ZV_9382,y
        rts
:       lda #0
        rts

; one-way street correction of T98D4[X] (A = street type, Y = mask)
onew:   sty t0
        and #$84
        cmp #$84
        lda T_98D4,x
        bcc :+
        bit t0                  ; (never run)
        beq :+
        eor t0
:       rts

; set / clear the bits t0 of $78xx (X) and $78yy (Y)
sbset:  lda t0
        ora $7800,x
        sta $7800,x
        lda t0
        ora $7800,y
        sta $7800,y
        rts
sbclr:  lda t0
        eor #$FF
        and $7800,x
        sta $7800,x
        lda t0
        eor #$FF
        and $7800,y
        sta $7800,y
        rts

; one-way rules of a street type A (X = 1 cross / 2 current): b = t0, c = t1
omask:  bpl @r
        and #4
        beq @s
        txa                     ; (never run)
        ora t1
        sta t1
        txa
        asl
        asl
        ora t0
        sta t0
        rts
@s:     txa
        ora t0
        sta t0
        txa
        asl
        asl
        ora t1
        sta t1
@r:     rts

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
        bmi r9971
        lda $75F5
        sec
        sbc #2
        jsr mul12               ; DE = 12*(F5-2)
        lda $75F2
        and #1
        beq :+
        lda #7
:       sta w_a
        lda #<(FDB+$FD77)       ; left arm, BC = -6
        ldx #>(FDB+$FD77)
        ldy #3
        jsr s9999
        lda #<(FDB+$FEBC)       ; right arm, BC = +6
        ldx #>(FDB+$FEBC)
        ldy #0
; S9999 (tp = HL = X:A, ze/zd = DE, Y = 0: BC = +6 / 3: BC = -6, w_a = A)
s9999:  sta tp
        stx tp+1
        sty w_neg
        inc $75F0
        ldy #0
        lda $75B5
        cmp #1
        beq :+
        ldy #5
:       sty mval
        lda $75F0
        and #2
        beq :+
        jsr tpde
:       ldx w_neg
        ldy #0
        lda w_a
        sta (tp),y
        jsr tpdx                ; HL += BC
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
:       inx                     ; HL += BC<0 ? 5 : -5
        jsr tpdx
        lda #5
        sta (tp),y
        inx                     ; HL += BC<0 ? +1 : -1 (B was reloaded
        jsr tpdx                ; with the +-5 above)
        lda w_a
        sta (tp),y
        dec $75F0
r9971:  rts
tpde:   lda tp                  ; tp += DE
        clc
        adc ze
        sta tp
        lda tp+1
        adc zd
        sta tp+1
        rts
tpdx:   lda tp                  ; tp += dlo/dhi[X], Y = 0
        clc
        adc dlo,x
        sta tp
        lda tp+1
        adc dhi,x
        sta tp+1
        ldy #0
        rts
dlo:    .byte 6, $FB, $FF, $FA, 5, 1
dhi:    .byte 0, $FF, $FF, $FF, 0, 0

; S99DD: A = segment features, w_row = base row: side entrances, the lane
; obstruction and the lamp posts of one segment
ZPROC $99DD
        sta w_fl
        lda #0
        sta tp
        lda w_fl
        lsr
        bcc @nb0
        ldx #6                  ; entrance markers
        lda $75D7
        ldy #$2C
        jsr pokep
        lda $75D6
        ldy #$30
        jsr pokep
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
:       txa
        ldy #$32
        ldx #$0B
        jsr pokep
        lda $75DF
        lsr
        bcc @even
        ldx #$0A
        tya
        adc #4                  ; (C=1) +5
        tay
        txa
        sta (tp),y
        tya
        sec
        sbc #10
        tay
        txa
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
@lamps: ldx $75D6
        ldy $75D7
        lda $75F0
        and #2
        bne :+
        ldx $75D7
        ldy $75D6
:       sty t1
        stx tp+1
        lda #2
        ldx #4
        jsr s9a49
        lda $75DF
        cmp #1
        beq :+
        lda t1
        sta tp+1
        lda #$0E
        ldx #3
        jmp s9a49
:       rts

; [page A, row w_row+Y] = X (tp = 0); Y = the row
pokep:  sta tp+1
        tya
        clc
        adc w_row
        tay
        txa
        sta (tp),y
        rts

; S9A49: lamp posts (value 4) on page tp+1 at row w_row+A, then X more
; every 24 rows
s9a49:  clc
        adc w_row
        tay
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
        asl $75FD               ; bit 7 off (set again below if a station)
        lda $75F1
        and #$0F
        cmp #5
        bne @c
        lda $75DF
        cmp #2
        bne @c
        lda $75B5
        cmp #1
        bne @c
        sec
        ror $75FD
        lda $7504
        eor $7505
        lsr
        eor $75F0
        ldy #9
        and #2
        beq @right
        lda #0
        sta $788C
        sty FDB+$FDA6
        sty FDB+$FDA6+$24
        lda #1
        bne @e
@right: sta $78AF
        sty FDB+$FEED
        sty FDB+$FEED+$24
        lda #4
@e:     sta $75F1
        lda #0
        sta $75E7
        rts
@c:     lsr $75FD
        rts

; ===========================================================================
; S9AA8: remap the traffic cars and objects after a node transition
; ===========================================================================
exx:    ldx #5                  ; Z80 EXX on the zero-page register file
:       lda zc,x                ; (zc..zh and zc2..zh2 are contiguous, zx.s)
        ldy zc2,x
        sta zc2,x
        sty zc,x
        dex
        bpl :-
        rts

ZPROC $9AA8
        jsr Z_BB18
        lda $75FE
        sta w_fe
        ldx #0                  ; handler index into htab
        and #4
        bne @set
        ldx #6                  ; (never run) left / right turn
        lda w_fe
        and #2
        beq @set
        lda $75FD
        and #$FE
        sta $75FD
        ldx #2
        lda w_fe
        lsr
        bcc @set
        ldx #4                  ; (never run) backward
@set:   stx hjmp+2
        lda htab,x
        sta hjmp
        lda htab+1,x
        sta hjmp+1
        lda #<$770E             ; the 3 traffic cars
        sta ziyl
        lda #>$770E
        sta ziyh
        lda #0
        sta w_par
        lda #1
        sta w_id
@l1:    jsr callh
        ldy #1
        lda (ziy),y
        bpl :+
        lda w_id
        sta za2
        jsr Z_9205
        beq :+
        ldy #1                  ; (never run)
        lda (ziy),y
        and #$7F
        sta (ziy),y
:       jsr nextiy
        inc w_id
        lda w_id
        cmp #4
        bne @l1
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
        ldy #1
        lda (ziy),y
        bpl l9b39
        lda w_id
        sta za2
        sta ze
        jsr exx
        jsr Z_B412
        beq l9b39
        ldy #2                  ; (never run)
        lda (ziy),y
        and #6
        cmp #6
        bne :+
        jsr Z_DC4C
:       ldy #1
        lda (ziy),y
        and #$7F
        sta (ziy),y
l9b39:  jsr nextiy
        inc w_id
        dec $7603
        bne l2_9b10
        jmp Z_DE15

htab:   .word Z_9D94-1, Z_9B4A-1, Z_9BB6-1, Z_9BD6-1

; handler call: W = record, A = D75FE, w_par = C, w_id = E; W written back.
; A handler that skips the loop's occupancy step leaves through skip.
callh:  ldy #1                  ; inactive record: only D9D94 (any) and
        lda (ziy),y             ; D9B4A's L9B8F (objects without +2 bit 1)
        bmi @f                  ; do anything - skip the copies otherwise
        lda hjmp+2              ; handler index: 0 D9D94, 2 D9B4A
        beq @f
        cmp #2
        bne @r
        lda w_par
        and #2
        beq @r
        iny
        lda (ziy),y
        and #2
        bne @r
@f:     jsr win
        jsr @h
        jmp wout
@h:     lda hjmp+1
        pha
        lda hjmp
        pha
        lda w_fe
@r:     rts
skip:   jsr wout
skip2:  pla                     ; drop the handler's and callh's returns
        pla
        pla
        pla
        jmp l9b39

; D9B4A: forward step - keep what was beyond the junction, drop the rest
ZPROC $9B4A
        lda W+1
        bpl new
        and #$7F
        sta W+1
        and #$40
        bne drop9b8c
        lda W+6
        cmp #$64
        bcs drop9b8c
        adc #$64
        clc
        adc $75F5
keep:   sta W+6                 ; 9B66
        sta zl
        lda W+1
        ora #$80
        sta W+1
        lda W+7
        sta zh
        lda w_par
        and #2
        beq r9b66
        lda #0
        sta W+10
        lda zl
        pha
        lda zh
        pha
        jsr wout
        jsr Z_B241
        jsr win
        pla
        sta zh
        pla
        sta zl
r9b66:  lda W+6
        rts
drop9b8c:
        jsr Z_9B7F
new:    lda w_par               ; L9B8F: objects get a fresh one ahead
        and #2
        beq r9b8f
        lda W+2
        and #2
        bne r9b8f
        lda #0
        sta W+5
        lda ZV_9561
        and #$1F
        clc
        adc #$3C
        sta W+6
        lda $7607
        and #2
        bne r9b8f
        jsr wout
        jsr Z_B1BC
        jsr win
        lda #0
        sta W+11
        jmp skip
r9b8f:  rts

; S9B7F: a special vehicle (+2 bits 1 and 2) was lost
ZPROC $9B7F
        lda W+2
        and #6
        cmp #6
        bne :+
        jsr wout                ; (never run)
        jsr Z_DC4C
        jmp win
:       rts

; D9BB6: backward step (never run)
ZPROC $9BB6
        lda W+1
        bpl r9b8f
        and #$7F
        sta W+1
        and #$40
        bne Z_9B7F
        lda W+6
        sec
        sbc $75FF
        bcc Z_9B7F
        sbc #$69
        bcc Z_9B7F
        adc #4                  ; C=1: +5
        jmp keep

; D9D94: U-turn - mirror every record about the grid centre
ZPROC $9D94
        lda W+5
        tax
        clc
        adc #2
        and #3
        sta t0
        txa
        and #$0C
        ora t0
        sta W+5
        lda W+1
        eor #$20
        sta W+1
        and #$40                ; SF2FE
        beq :+
        lda W+9
        clc
        adc #$64
        .byte $2C               ; (skip lda W+6)
:       lda W+6
        sta w_y
        lda $75F5
        clc
        adc #$C7
        clc
        adc w_par
        sec
        sbc w_y
        bit W+1
        bvc @main
        sec                     ; in a cross grid
        sbc #$64
        bcs :+
        lda #0
:       cmp $75F5
        bcc :+
        sbc #1                  ; (never run)
        bcs :-
:       sta W+9
        jsr b9dd
        lda W+8
        sta ze
        lda #0
        sta zd
        lda W+1
        and #$20
        beq :+
        jsr hladde
        jmp @st
:       jsr hlsube
@st:    jsr wst
        jmp @tail
@main:  sta zl
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
@off:   asl W+1                 ; (never run)
        lsr W+1
@k:     lda zl
        sta W+6
        lda #$BF
        sec
        sbc W+7
        sta W+7
        sta zh
@tail:  lda w_id
        cmp #$0C
        beq :+
        rts
:
        jsr wout
        jsr Z_F4A7
        jsr Z_F2D1
        jmp skip2

; D9BD6: left / right turn - rotate every record through the junction
; square (never run in the coverage; code shown as data in te.lst)
ZPROC $9BD6
        lda W+1
        bmi :+
        rts
:
        jsr bkup
        lda w_par
        and #2
        beq @a                  ; traffic
        lda w_id
        cmp #$0C
        beq @a                  ; player
        lda W+5
        lsr
        bcs @a
        lda W+10
        lsr
        bcs @a
        jsr Z_9D62
@a:     bit W+1                 ; 9BFA
        bvc :+
        lda W+9
        sta xc
        lda $75FF
        sec
        sbc #1
        jmp :++
:       lda W+6
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
        inx
:       sta xt
        txa                     ; c' = turn ^ sgn
        eor w_fe
        sta xc
        lda xt
        lsr
        lsr
        lsr
        sta xb                  ; lateral
        lda xt
        and #7
        eor #$FF
        sec
        adc #4                  ; 4 - (t&7)
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
:       tax
        lda xc
        lsr
        txa
        bcs :+
        eor #$FF
:       clc
        adc #$60
        sta xh
        ldx W+7                 ; old page
        sta W+7
        bit W+1
        bvc @mg
        lda W+1
        and #$BF
        sta W+1
        lda $7609
        clc
        adc W+8
        sta xdist
        lda W+1
        and #$20
        bne @rt
        beq @s1
@mg:    txa
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
        sbc W+0
        ldx xd
        stx W+0
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
        sta W+6
        sta xl
        sta tp
        lda xh
        sta tp+1
        ldy #0
        lda (tp),y
        bpl @l9d05
        and #$40
        bne @open
@drop:  jsr rstr
        asl W+1
        lsr W+1
        jmp Z_9B7F
@open:  lda xl
        sec
        sbc #$64
        sta W+9
        jsr mul12
        lda xc
        and #1
        asl
        tay
        jsr armb
        lda xb
        sec
        sbc $75DF
        cmp #12
        bcs @drop
        sta W+8
        sta ze
        lda #0
        sta zd
        lda xc
        lsr
        bcc :+
        jsr hladde
        jmp :++
:       jsr hlsube
:       lda W+1
        ora #$40
        sta W+1
        jsr wst
        lda zl
        sta xl
        lda zh
        sta xh
@l9d05: lda W+1
        ora #$20
        tax
        lda xc
        lsr
        txa
        bcs :+
        and #$DF
:       sta W+1
        lda w_fe                ; direction rotates with the turn
        lsr
        lda W+5
        bcc :+
        sbc #2                  ; C=1
:       clc
        adc #1
        eor W+5
        and #3
        eor W+5
        sta W+5
        lda xl
        sta zl
        lda xh
        sta zh
        lda w_id
        cmp #$0C
        bne @r
        bit W+1                 ; player: back onto the main road
        bvc :+
        lda W+1
        and #$BF
        sta W+1
        jsr f53d
        sta zh
        sta W+7
        lda W+9
        clc
        adc #$64
        sta zl
        sta W+6
:       jsr Z_9D62
        lda W+7
        sta zh
        cmp $75D6
        bne :+
        inc W+7
        inc zh
@r:     rts
:       cmp $75D7
        bne @r
        dec W+7
        dec zh
        rts

; 9D62: finish a pending sideways step
ZPROC $9D62
        lda W+1
        and #$FB
        sta W+1
        lda W+0
        beq @r
        ldx #0
        stx W+0
        cmp #4
        bcc @r
        lda W+1
        and #$20
        bne :+
        inc W+7
        lda W+7
        cmp #$60
        bne @r
        lda W+1
        ora #$20
        bne @s
:       dec W+7
        lda W+7
        cmp #$5F
        bne @r
        lda W+1
        and #$DF
@s:     sta W+1
@r:     rts
