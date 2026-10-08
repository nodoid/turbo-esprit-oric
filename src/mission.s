; mission.s - the enemy cars (armed car + 2 drug cars): Spectrum DA7F-E0A9.
;
; Translation of the original's map-level AI (notes R8 section 3): launch,
; movement along the map segments, arrival logic (meeting point, drug
; exchange, hiding places, escape), the route search SDCE8 and the
; conversion between "map cars" (records D785E/D7868/D7872, 10 bytes) and the
; 3D objects 14/15/16 (D77AA/D77B6/D77C2).
;
; Size-optimised: the car record being processed (the Z80's IX) is copied
; into the zero-page work record CR (cin) and written back afterwards
; (cout); `car` keeps its address.  Code that touches the current car through
; another address in the original (D7864 = car 0 +6 in SE001) uses CR too.
; Where the original ends with "ld ix,D75E1" zix is set to $75E1 (ixg).
; IY (object) is ziy.
;
; The city block D9282-D93D4 is relocated (owned by the map module): it is
; addressed as ZV_9282 + offset.  DDDCF keeps the *Spectrum* address of the
; next hiding place (so the state compares 1:1) and is converted on use.
;
; Known deviation: the route search uses its own arrays instead of the Z80
; private stack at D72A8-D72CF (scratch bytes in the sprite work area that
; nothing reads; D72CC = first direction of the current path is a variable).

        .include "zx.inc"

        ZIMPORT $9564           ; map: blocked-exit mask of HL -> E
        ZIMPORT $953B           ; RNG -> HL
        ZIMPORT $BA5F           ; status-line message (inline stream)
        ZIMPORT $B241           ; traffic: choose turn (IY)
        ZIMPORT $B412           ; traffic: put object into the lane grid (HL')
        ZIMPORT $F422           ; find the object blocking a grid cell
        ZIMPORT $B9DD           ; junction record address
        ZVIMPORT $9282          ; city block (map, street types, hiding places)
        ZVIMPORT $9560          ; RNG seed

CAR0    = $785E
CAR1    = $7868
CAR2    = $7872
T_9382  = ZV_9282 + $100        ; street type per column (+$20: per row)
V_93C2  = ZV_9282 + $140        ; x of the main N-S road
V_93C3  = ZV_9282 + $141        ; y of the main E-W road
T_93C4  = ZV_9282 + $142        ; 8 hiding places (x,y)
CITYOFF = ZV_9282 - $9282       ; Spectrum address -> Oric address

        .exportzp CR            ; used by mapview.s
        .exportzp lb, lc, ld_, le_, lpos, lt, ll, ldir, rnp, rdist, rcame, rd
        .export getix, ixg, cartab

        .zeropage
CR:     .res 10                 ; work copy of the current car record
car:    .res 2                  ; its address (IX)
lsy:    .res 2                  ; saved IY (collision path)
                                ; (mapview.s uses CR..lsy+1 as its D71D0-DD)
mx:     .res 1                  ; S7D2D work position
my:     .res 1
rd:     .res 1                  ; route search: current depth
lb:     .res 1                  ; B = car +6
lc:     .res 1                  ; SE08A results: direction, y, x
ld_:    .res 1
le_:    .res 1
lpos:   .res 1                  ; A' (position on the segment)
lt:     .res 1
ll:     .res 1
ldir:   .res 1
rnp:    .res 1                  ; route search: passes of the new node
rdist:  .res 1
rcame:  .res 1
        ZLABEL $DD6D, 2         ; route search target (x,y)
        .res 2

        .data
lt2:    .res 1
lsv:    .res 2
kidx:   .res 1
lmode:  .res 1
; route search
rnb:    .res 1                  ; depth of the new node
rroot:  .res 1                  ; D72CC: first direction of the path
rx:     .res 6                  ; per depth (max depth 5): position, mask, next dir index,
ry:     .res 6                  ; player passes
rm:     .res 6
rk:     .res 6
rp:     .res 6

        ZLABEL $DA7F, 1         ; object id of the car being processed
        .byte $0E
        ZLABEL $DCE7, 1         ; route search depth
        .byte $08
        ZLABEL $DDCF, 2         ; Spectrum address of the next hiding place
        .byte 0, 0
        ZLABEL $DDD1, 1         ; drug car launch countdown
        .byte 0
        ZLABEL $DDD2, 1         ; exchanges left before the armed car runs
        .byte 0
        ZLABEL $E088, 2         ; meeting point (x,y)
        .byte 0, 0

        .segment "RODATAH1"
T_DDCB: .byte $08, $04, $02, $01        ; no U-turn: mask by arrival direction
kdir:   .byte 1, 0, 3, 2                ; search order E N W S
kbit:   .byte 1, 2, 4, 8
owm:    .byte 2, 8, 1, 4                ; one-way masks: column, row
cartab: .byte <CAR0, <CAR1, <CAR2       ; all in page $78

        .code

; ---------------------------------------------------------------------------
; small helpers
getix:  lda zixl                ; car = IX, CR = record
        sta car
        lda zixh
        sta car+1
cin:    ldy #9
@l:     lda (car),y
        sta CR,y
        dey
        bpl @l
        rts

outix:  jsr cout
ixg:    lda #$E1                ; ld ix,D75E1
        sta zixl
        lda #$75
        sta zixh
        rts

cout:   ldy #9
@l:     lda CR,y
        sta (car),y
        dey
        bpl @l
        rts

set7:   lda CR
        ora #$80
        sta CR
        rts

; +0 bit6 -> bit7 ; returns N = bit7
b6b7:   bit CR
        bvc @n
        jsr set7
@n:     lda CR
        rts

; res 7,(iy+1) (returns Y = 1)
res7iy: ldy #1
        lda (ziyl),y
        and #$7F
        sta (ziyl),y
        rts

restiy: lda lsy
        sta ziyl
        lda lsy+1
        sta ziyh
        rts

; A = (D75F0 + obj +5) & 3   (SDBEE without the store)
dirA:   ldy #5
        lda (ziyl),y
        clc
        adc $75F0
        and #3
        rts

; mstep (S7D2D): move (mx,my) one cell in direction A (0 N y+1, 1 E x+1,
; 2 S y-1, 3 W x-1).
mstep:  lsr a
        bcs @ew
        lsr a
        bcs @s
        inc my
        rts
@s:     dec my
        rts
@ew:    lsr a
        bcs @w
        inc mx
        rts
@w:     dec mx
        rts

; from = (mx,my), to = moved by A (CR +1..+4)
fromto: ldx mx
        stx CR+1
        ldx my
        stx CR+2
        jsr mstep
        lda mx
        sta CR+3
        lda my
        sta CR+4
        rts

; SDBBF / SDBC3: e ^= 1 ; A' = 100 - A'
sdbbf:  lda le_
        eor #1
        sta le_
sdbc3:  lda #$64
        sec
        sbc lpos
        sta lpos
        rts

; ---------------------------------------------------------------------------
; SDA80: IY = the 3D object of the car IX (14, 15 or 16)
        ZPROC $DA80
        ldy #6
        lda (zixl),y
        .byte $2C               ; skip the next instruction
sda80:  lda CR+6
        ldx #<$77AA
        lsr a
        bcc @set
        ldx #<$77B6
        and #$40
        beq @set
        ldx #<$77C2
@set:   stx ziyl
        lda #$77
        sta ziyh
        rts

; ---------------------------------------------------------------------------
; LDA97: place the map car IX into the player's local view if it is on the
; player's road.  Returns Z = placed.
        ZPROC $DA97
        jsr getix
        jsr lda97
        php
        jsr cout
        plp
        rts

lda97:  jsr sda80
        lda CR
        and #3
        sta CR
        ldx #0                  ; e
        lda CR+1                ; SDBB2 (from-junction)
        cmp $7504
        bne @n1
        lda CR+2
        cmp $7505
        beq @vis
@n1:    lda CR+3                ; SDBB2 (to-junction)
        cmp $7504
        bne @ret
        lda CR+4
        cmp $7505
        bne @ret
        inx                     ; ;? approaching
@vis:   stx le_
        lda CR
        ora #$08
        sta CR
        sec
        sbc $75F0
        and #3
        ldy #5
        sta (ziyl),y            ; (iy+5) = rel
        tax
        lda CR+5
        sta lpos
        lda #0
        tay
        sta (ziyl),y            ; (iy+0) = d = 0
        lda #$80
        sta ld_
        txa
        lsr a
        bcs @odd
        ldx #$5F
        lsr a
        bcc @dad3
        inx                     ; opposite direction
        jsr sdbbf
        jsr setd20
@dad3:  ldy #1
        lda ld_
        sta (ziyl),y
        ldy #7
        txa
        sta (ziyl),y
        stx lc
        lda #$64
        sec
        sbc lpos
        ldx le_
        beq @dae9
        clc                     ; ;?
        adc $75F5
        clc
        adc #$64
@dae9:  ldy #6
        sta (ziyl),y
        sta zl
        lda lc
        sta zh
        bne ldb39               ; (always)
@ret:   rts                     ; NZ
@odd:   lda ld_
        ora #$40
        sta ld_
        txa
        and #2
        beq @r1
        lda $75F5
        sec
        sbc #3
        jmp @db01
@r1:    jsr sdbbf               ; ;?
        lda #5
@db01:  ldy #9
        sta (ziyl),y
        sta lc
        lda le_
        beq @db0d
        jsr sdbc3               ; ;?
        jsr setd20
@db0d:  lda lpos
        cmp #$30
        bcc @db18
        jmp ixg                 ; NZ
@db18:  lsr a                   ; ;? (never executed in the original)
        lsr a
        and #$0F
        ldy #8
        sta (ziyl),y
        sta lt
        ldy #1
        lda ld_
        sta (ziyl),y
        lda lc
        jsr Z_B9DD
        ldy #1
        lda (ziyl),y
        and #$20
        beq @sub
        clc
        lda zl
        adc lt
        sta zl
        bcc @st
        inc zh
        bcs @st
@sub:   sec
        lda zl
        sbc lt
        sta zl
        bcs @st
        dec zh
@st:    ldy #6                  ; S9274
        lda zl
        sta (ziyl),y
        iny
        lda zh
        sta (ziyl),y
ldb39:  lda zl
        pha
        lda zh
        pha
        jsr ixg
        jsr Z_B241
        pla                     ; the original EXXs: position in HL'
        sta zh2
        pla
        sta zl2
        lda ZV_DA7F
        sta za2
        jsr Z_B412              ; (comes back in HL', BC')
        bne ldb6d
ldb4e:  lda CR
        ora #$04
        sta CR
        lda CR+6
        and #3
        cmp #3
        bne @db67
        lda CR+6                ; ;? waiting drug car: exchange cancelled
        and #$FD
        sta CR+6
        lda $7864
        and #$FD
        sta $7864
@db67:  jsr ixg
        lda #0                  ; Z
        rts
ldb6d:  lda zl2                 ; ;? grid cell occupied
        sta zl
        lda zh2
        sta zh
        lda zc2
        sta zc
        lda zb2
        sta zb
        ldy #2
        lda (ziyl),y
        sta lsv+1
        sta zd
        iny
        lda (ziyl),y
        sta lsv
        sta ze
        lda ziyl
        sta lsy
        lda ziyh
        sta lsy+1
        jsr Z_F422
        ldy #2
        lda (ziyl),y
        and #2
        bne @dba6
        ldy #4
        lda (ziyl),y
        cmp #$10
        bne @dba6
        ldy #11
@cp:    lda (ziyl),y
        sta (lsy),y
        dey
        bpl @cp
        jsr res7iy
        jsr restiy
        iny
        lda lsv+1
        sta (ziyl),y
        iny
        lda lsv
        sta (ziyl),y
        ldy #6                  ; S927B
        lda (ziyl),y
        sta zl
        iny
        lda (ziyl),y
        sta zh
        lda ZV_DA7F
        ldy #0
        sta (zl),y
        jmp ldb4e
@dba6:  jsr restiy
        jsr ixg
        jsr res7iy              ; NZ (A = $75)
        lda #1
        rts

setd20: lda ld_
        ora #$20
        sta ld_
        rts

; ---------------------------------------------------------------------------
; SDBCA: car +1,+2 = DE ; +3,+4 = HL
        ZPROC $DBCA
        ldy #1
        lda ze
        sta (zixl),y
        iny
        lda zd
        sta (zixl),y
        iny
        lda zl
        sta (zixl),y
        iny
        lda zh
        sta (zixl),y
        rts

; SDBD7: IX = the car of object IY (obj +2: bit3 car 0, else bit4 clear
; car 1, set car 2)
        ZPROC $DBD7
sdbd7:  ldy #2
        lda (ziyl),y
        ldx #<CAR0
        lsr a
        lsr a
        lsr a
        lsr a
        bcs @set
        ldx #<CAR1
        lsr a
        bcc @set
        ldx #<CAR2
@set:   stx car
        stx zixl
        lda #>CAR0
        sta car+1
        sta zixh
        rts

; SDBEE: car +0 = (D75F0 + obj +5) & 3 (also in A)
        ZPROC $DBEE
        jsr dirA
        ldy #0
        sta (zixl),y
        rts

; ---------------------------------------------------------------------------
; LDBFA: a car object (IY) left the view; turn it back into a map car.
        ZPROC $DBFA
        jsr res7iy
        iny
        lda (ziyl),y
        and #$06
        cmp #$06
        bne @rts
        jsr sdbd7
        jsr cin
        jsr b6b7
        bmi @dc42
        jsr dirA
        sta CR
        ldx $7504
        stx mx
        ldx $7505
        stx my
        jsr fromto              ; SDBCA (D7504, moved)
        lda #$64
        sta CR+5
        ldy #1
        lda (ziyl),y
        and #$40
        beq @dc42
        ldy #8
        lda (ziyl),y
        clc
        adc #1
        asl a
        asl a
        sta CR+5
        lda CR
        ora #$08
        sta CR
@dc42:  jmp outix
@rts:   rts

; SDC4C: same without the flag tests (;? never executed)
        ZPROC $DC4C
        jsr sdbd7
        jsr cin
        jsr b6b7
        bpl sdc5f
        jmp outix

; ---------------------------------------------------------------------------
; SDC5F: rebuild a map-style record (IX) from the object IY on the
; player's road grid.
        ZPROC $DC5F
        jsr getix
sdc5f:  lda #0
        sta ll
        ldy #5
        lda (ziyl),y
        lsr a
        bcc :+
        jmp l_dcca
:
        ldy #1                  ; SF2FE
        lda (ziyl),y
        and #$40
        bne @f9
        ldy #6
        lda (ziyl),y
        bcc @g                  ; (always)
@f9:    ldy #9
        lda (ziyl),y
        clc
        adc #$64
@g:     cmp #$64
        bcc dc8b
        sbc #$64
        sta lt
        lda #2
        sta ll
        ldy #1
        lda (ziyl),y
        asl a
        lda $75FF
        bcc @fc
        lda $75F5
@fc:    sta lt2
        lda lt
        sec
        sbc lt2
        bcs @dc85
        lda #0
@dc85:  cmp #$64
        bcc dc8b
        lda #$63                ; ;?
dc8b:   sta lpos
        ldy #5
        lda (ziyl),y
        and #2
        bne @dc99
        jsr sdbc3
@dc99:  lda lpos
        sta CR+5
        jsr dirA
        sta CR
        sta ldir
        ldy #5
        lda (ziyl),y
        eor ll
        sta lt
        ldy #1
        lda (ziyl),y
        asl a
        ldx $7506
        ldy $7507
        bcc @bs
        ldx $7504
        ldy $7505
@bs:    stx mx
        sty my
        lda lt
        and #2
        bne @dcc0
        lda ldir
        jsr fromto              ; from = base, to = moved
        jmp outix
@dcc0:  stx CR+3                ; from = moved back, to = base
        sty CR+4
        lda ldir
        eor #2
        jsr mstep
        lda mx
        sta CR+1
        lda my
        sta CR+2
        jmp outix
l_dcca:  ldy #1
        lda (ziyl),y
        sta lt
        lda #0
        bit lt
        bvc l_dcd4
        ldy #8                  ; ;?
        lda (ziyl),y
l_dcd4:  clc
        adc #1
        asl a
        asl a
        sta lpos
        lda lt
        and #$20
        bne l_neg
        lda #2
        sta ll
        lda lpos
        jmp dc8b
l_neg:   jsr sdbc3               ; ;?
        jmp dc8b

; ---------------------------------------------------------------------------
; SDCE8: route search.  HL = start junction, C = arrival direction,
; ZV_DD6D = target, ZV_DCE7 = depth.  Result D71D2-D71D5 (D71D5 = first
; direction of the best route, $FF = none).  HL is preserved.
        ZPROC $DCE8
sdce8:  lda #$FF
        ldx #3
@f:     sta $71D2,x
        dex
        bpl @f
        lda zl
        sta rx
        lda zh
        sta ry
        lda zc
        sta rcame
        inx
        stx rp
@enter: stx rd
        lda rx,x                ; mask = S9564 | one-way | no U-turn
        sta zl
        lda ry,x
        sta zh
        jsr Z_9564
        lda ze
        sta lt
        ldx rd
        lda rx,x
        ldx #0
        jsr oneway
        ldx rd
        lda ry,x
        ldx #2
        jsr oneway
        ldx rd
        ldy rcame
        lda lt
        ora T_DDCB,y
        sta rm,x
        lda #0
        sta rk,x
@next:  ldy rk,x
        cpy #4
        beq @done
        inc rk,x
        lda rm,x
        and kbit,y
        bne @next
        lda kdir,y
        sta ldir
        cpx #0
        bne @nr
        sta rroot
@nr:    ldy rx,x
        sty mx
        ldy ry,x
        sty my
        jsr mstep
        lda rp,x
        sta rnp
        inx
        stx rnb
        lda mx
        cmp ZV_DD6D
        bne @nt
        lda my
        cmp ZV_DD6D+1
        bne @nt
        lda #0                  ; reached the target
        beq @eval
@nt:    lda mx
        cmp $7504
        bne @np
        lda my
        cmp $7505
        bne @np
        inc rnp                 ; route through the player's junction
@np:    cpx ZV_DCE7
        beq @leaf
        lda mx                  ; go deeper
        sta rx,x
        lda my
        sta ry,x
        lda rnp
        sta rp,x
        lda ldir
        sta rcame
        bmi :+
        jmp @enter
:
@done:  ldx rd
        beq @ret
        dex
        stx rd
        jmp @next
@ret:   lda rx
        sta zl
        lda ry
        sta zh
        rts
@nx:    jmp @next
@leaf:  lda ZV_DD6D             ; |dx| + |dy|
        sec
        sbc mx
        jsr absa
        sta lt
        lda ZV_DD6D+1
        sec
        sbc my
        jsr absa
        clc
        adc lt
@eval:  sta rdist
        ldx rd
        lda $71D2
        cmp rnp
        bcc @nx
        bne @acc
        lda $71D3
        cmp rdist
        bcc @nx
        bne @acc
        lda $71D4
        cmp rnb
        bcc @nx
@acc:   lda rnp
        sta $71D2
        lda rdist
        sta $71D3
        lda rnb
        sta $71D4
        lda rroot
        sta $71D5
        jmp @next

absa:   bpl @r
        eor #$FF
        clc
        adc #1
@r:     rts

; one-way street: A = column (X = 0) / row (X = 2) index, ORs into lt
oneway: cmp #$20
        bcs @r
        cpx #0
        beq @c
        ora #$20                ; row table (T_93A2)
@c:     tay
        lda T_9382,y
        bpl @r
        and #$04
        bne @s
        inx
@s:     lda owm,x
        ora lt
        sta lt
@r:     rts

; ---------------------------------------------------------------------------
; SDDD3: every car heads for its hiding place
        ZPROC $DDD3
        ldx #20
@l:     lda CAR0+6,x
        and #$FD
        ora #$04
        sta CAR0+6,x
        txa
        sec
        sbc #10
        tax
        bcs @l
        rts

; ---------------------------------------------------------------------------
; SDDF4: per-pass update of the three cars (main loop)
; LDE15: re-place every active map car (end of a traffic pass)
        ZPROC $DDF4
        lda #0
        .byte $2C
        ZPROC $DE15
        lda #$80
        sta lmode
        ldx #0
@l:     stx kidx
        txa
        clc
        adc #$0E
        sta ZV_DA7F
        lda cartab,x
        sta car
        lda #>CAR0
        sta car+1
        jsr cin
        bit lmode
        bmi @de36
        jsr sde43
        jmp @o
@de36:  lda CR                  ; SDE36
        and #$84
        bne @o
        jsr lda97
@o:     jsr cout
        ldx kidx
        inx
        cpx #3
        bne @l
        jmp ixg

; ---------------------------------------------------------------------------
; SDE43: update one car (CR)
s43r:   rts
sde43:  lda CR+6
        sta lb
        lda CR
        bmi :+
        jmp lded0
:
        lda lb                  ; inactive: launch a drug car?
        lsr a
        bcc s43r
        lda $75F8
        and #7
        bne s43r
        dec ZV_DDD1
        bne s43r
        lda #$40
        sta ZV_DDD1
        lda CAR0
        and #$C0
        bne s43r
        lda CAR0+6
        and #$04
        bne s43r
        lda ZV_DDCF
        clc
        adc #<CITYOFF
        sta zl
        lda ZV_DDCF+1
        adc #>CITYOFF
        sta zh
        ldy #0
        lda (zl),y
        bmi s43r
        sta CR+8
        iny
        lda (zl),y
        sta CR+9
        lda ZV_DDCF
        clc
        adc #2
        sta ZV_DDCF
        bcc sde82
        inc ZV_DDCF+1
; SDE82: launch the car from a random map-edge entry point
sde82:  jsr se08a
        lda lc
        sta CR
        lda le_
        sta CR+1                ; SDBCA (x,y) both junctions
        sta CR+3
        lda ld_
        sta CR+2
        sta CR+4
        lda #$5E
        sta CR+5
        lda $7513
        sta CR+7
        lda CR+6
        and #$81
        sta CR+6
        ldx #$89
        lsr a
        bcc @t
        dex
@t:     stx ZV_DEC1
        lda CR
        lsr a
        lda #$4E                ; 'N': number = x
        ldx le_
        bcc @ns
        lda #$45                ; 'E': number = y
        ldx ld_
@ns:    sta ZV_DECA
        stx zl
        lda #0
        sta zh
        jsr Z_BA5F
        .byte $30, $0C
        ZLABEL $DEC1, 1
        .byte $00
        .byte "SEEN ON "
        ZLABEL $DECA, 1
        .byte $00
        .byte ":", $C0, $C0, $12
        rts

; active car
lded0:  and #$04
        bne @rts                ; it is a 3D object now
        lda CR+3
        ora CR+4
        and #$E0
        beq @deea
        lda lb                  ; ;? left the map
        lsr a
        lda #$88
        bcc :+
        jmp ldf77
:
        lda #$89
        beq :+
        jmp ldf77
:
@deea:  lda lb
        and #3
        cmp #3
        beq @df0c
        lda $75F8
        and #3
        tax
        inx
        lda $7512
@r:     lsr a
        dex
        bne @r
        and #1
        sec
        adc CR+5
        sta CR+5
        cmp #$5F
        bcs ldf14
@df0c:  lda CR
        and #$08
        beq @rts
        jmp lda97
@rts:   rts

; arrival at the to-junction
ldf14:  lda #5
        sta CR+5
        ldx ZV_E088             ; meeting point
        ldy ZV_E088+1
        lda lb
        and #$04
        beq @t
        ldx CR+8                ; ;? hiding place / escape point
        ldy CR+9
@t:     stx ZV_DD6D
        sty ZV_DD6D+1
        lda lb
        lsr a
        bcc ldf6d
        lda lb
        and #$04
        bne ldf55
        jsr cmphere             ; drug car
        beq :+
        jmp ldfcb
:
        lda $7864               ; ;? at the meeting point
        and #$02
        beq :+
        jmp ldfcb
:
        lda $7864
        ora #$02
        sta $7864
        lda CR+6
        ora #$02
        sta CR+6
        lda #$64
        sta CR+5
        rts
ldf55:  jsr cmphere             ; ;?
        beq :+
        jmp ldfcf
:
        jsr set7
        jsr Z_BA5F
        .byte $38, $0A, $88, "IN HIDING"
        rts
ldf6d:  lda lb                  ; armed car
        and #$04
        beq ldf8c
        jsr cmphere             ; ;?
        bne ldfcf
        lda #$89
ldf77:  sta ZV_DF83
        jsr set7
        jsr Z_BA5F
        .byte $38, $08
        ZLABEL $DF83, 1
        .byte $89
        .byte "ESCAPED"
        rts
ldf8c:  jsr cmphere
        bne ldfc5
        lda lb                  ; ;? at the meeting point
        and #$02
        beq ldfcf
        ldx #10
        lda CAR1+6
        and #$02
        bne @c
        ldx #20
@c:     lda CAR0+6,x
        and #$FD
        ora #$0C
        sta CAR0+6,x
        jsr se001
        beq @dfbe
        jsr Z_BA5F
        .byte $40, $0F, "DRUGS EXCHANGED"
@dfbe:  lda CR+6
        and #$FD
        sta CR+6
        jmp ldfcf
ldfc5:  lda lb
        and #$02
        bne ldfcb
        lda #2
        bne ldfd1
ldfcb:  lda #5
        .byte $2C
ldfcf:  lda #3
ldfd1:  sta ZV_DCE7
        lda CR+3
        sta CR+1
        sta zl
        lda CR+4
        sta CR+2
        sta zh
        lda CR
        and #3
        sta zc
        jsr sdce8
        lda CR+1
        sta mx
        lda CR+2
        sta my
        lda $71D5
        bpl @dff2
        lda CR
        and #3
        eor #2
@dff2:  sta CR
        jsr mstep
        lda mx
        sta CR+3
        lda my
        sta CR+4
        jmp lda97

; Z if target ZV_DD6D == here (CR+3, CR+4)
cmphere:
        lda ZV_DD6D
        cmp CR+3
        bne @r
        lda ZV_DD6D+1
        cmp CR+4
@r:     rts

; SE001: one exchange done; after the 4th the armed car (= CR) runs (Z)
se001:  dec ZV_DDD2
        bne @r
        lda CR+6
        ora #$04
        sta CR+6
        jsr Z_BA5F
        .byte $38, $08, $89, "RUNNING"
        lda #0
@r:     rts

; ---------------------------------------------------------------------------
; SE01D: enemy set-up at the start of each life
        ZPROC $E01D
        lda #<$93CC
        sta ZV_DDCF
        lda #>$93CC
        sta ZV_DDCF+1
        lda ZV_9560
        and #$0E
        clc
        adc #2
        tax
@rot:   lda T_93C4              ; rotate the 16 bytes left by one
        pha
        ldy #0
@c:     lda T_93C4+1,y
        sta T_93C4,y
        iny
        cpy #15
        bne @c
        pla
        sta T_93C4+15
        dex
        bne @rot
        lda #<CAR0
        sta car
        lda #>CAR0
        sta car+1
        jsr cin
        jsr set7
        lda $7611
        beq @np
        jsr sde82
@np:    jsr se08a
        lda le_
        sta CR+8
        lda ld_
        sta CR+9
        jsr cout
        lda #4
        sta ZV_DDD2
@pick:  jsr Z_953B              ; meeting point: x,y in 12..19, 4-way
        lda zl
        and #7
        clc
        adc #$0C
        sta mx
        sta zl
        lda zh
        and #7
        adc #$0C
        sta my
        sta zh
        jsr Z_9564
        lda ze
        bne @pick
        lda mx
        sta ZV_E088
        lda my
        sta ZV_E088+1
        lda #$20
        sta ZV_DDD1
        lda #$80
        sta CAR1
        sta CAR2
        jmp ixg

; SE08A: random entry point on a main road at the map edge
; -> lc = direction, le_ = x, ld_ = y
se08a:  jsr Z_953B
        lda zh
        and #3
        sta lc
        ldx #0
        and #2
        beq @v
        ldx #$1F
@v:     lda lc
        lsr a
        bcs @ew
        stx ld_
        lda V_93C2
        sta le_
        rts
@ew:    stx le_
        lda V_93C3
        sta ld_
        rts
