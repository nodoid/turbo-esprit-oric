; mission.s - the enemy cars (armed car + 2 drug cars): Spectrum DA7F-E0A9.
;
; Translation of the original's map-level AI (notes R8 section 3): launch,
; movement along the map segments, arrival logic (meeting point, drug
; exchange, hiding places, escape), the route search SDCE8 and the
; conversion between "map cars" (records D785E/D7868/D7872, 10 bytes) and the
; 3D objects 14/15/16 (D77AA/D77B6/D77C2).
;
; Register use: the Z80 IX (car record) is kept in the private pointer `car`;
; routines entered from other modules copy zix into it.  Where the original
; ends with "ld ix,D75E1" zix is set to $75E1 too.  IY (object) is ziy.
;
; The city block D9282-D93D4 is relocated (owned by the map module): it is
; addressed as ZV_9282 + offset.  DDDCF keeps the *Spectrum* address of the
; next hiding place (so the state compares 1:1) and is converted on use.
;
; Known deviation: the route search uses its own arrays instead of the Z80
; private stack at D72A8-D72CF (scratch bytes in the sprite work area that
; nothing reads; D72CC = first direction of the current path is kept in a
; variable).

        .include "zx.inc"

        ZIMPORT $9564           ; map: blocked-exit mask of HL -> E
        ZIMPORT $953B           ; RNG -> HL
        ZIMPORT $BA5F           ; status-line message (inline stream)
        ZIMPORT $B241           ; traffic: choose turn (IY)
        ZIMPORT $B412           ; traffic: put object into the lane grid
        ZIMPORT $F422           ; find the object blocking a grid cell
        ZIMPORT $B9DD           ; junction record address
        ZVIMPORT $9282          ; city block (map, street types, hiding places)
        ZVIMPORT $9560          ; RNG seed


CAR0    = $785E
CAR1    = $7868
CAR2    = $7872
T_9382  = ZV_9282 + $100        ; street type per column
T_93A2  = ZV_9282 + $120        ; street type per row
V_93C2  = ZV_9282 + $140        ; x of the main N-S road
V_93C3  = ZV_9282 + $141        ; y of the main E-W road
T_93C4  = ZV_9282 + $142        ; 8 hiding places (x,y)
CITYOFF = ZV_9282 - $9282       ; Spectrum address -> Oric address

.macro IX_GLOBAL
        lda #$E1
        sta zixl
        lda #$75
        sta zixh
.endmacro

        .zeropage
car:    .res 2                  ; IX: current car record
lp:     .res 2                  ; hiding-place pointer
lsy:    .res 2                  ; saved IY (collision path)
mx:     .res 1                  ; S7D2D work position
my:     .res 1
rd:     .res 1                  ; route search: current depth

        .data                   ; (scalars: absolute is fast enough)
lb:     .res 1                  ; B = car +6
lc:     .res 1
ld_:    .res 1
le_:    .res 1
lpos:   .res 1                  ; A' (position on the segment)
lrel:   .res 1
lt:     .res 1
lt2:    .res 1
ll:     .res 1
ldir:   .res 1
lhl:    .res 2
lsv:    .res 2
kidx:   .res 1
; route search
rnb:    .res 1                  ; depth of the new node
rnp:    .res 1                  ; passes of the new node
rdist:  .res 1
rcame:  .res 1
rroot:  .res 1                  ; D72CC: first direction of the path

rx:     .res 9                  ; per depth: position, mask, next dir index,
ry:     .res 9                  ; player passes
rm:     .res 9
rk:     .res 9
rp:     .res 9

        .data
        ZLABEL $DA7F, 1         ; object id of the car being processed
        .byte $0E
        ZLABEL $DCE7, 1         ; route search depth
        .byte $08
        ZLABEL $DD6D, 2         ; route search target (x,y)
        .byte 0, 0
        ZLABEL $DDCF, 2         ; Spectrum address of the next hiding place
        .byte 0, 0
        ZLABEL $DDD1, 1         ; drug car launch countdown
        .byte 0
        ZLABEL $DDD2, 1         ; exchanges left before the armed car runs
        .byte 0
        ZLABEL $E088, 2         ; meeting point (x,y)
        .byte 0, 0

        .rodata
T_DDCB: .byte $08, $04, $02, $01        ; no U-turn: mask by arrival direction
kdir:   .byte 1, 0, 3, 2                ; search order E N W S
kbit:   .byte 1, 2, 4, 8
cartab: .byte <CAR0, <CAR1, <CAR2       ; all in page $78

        .code

; ---------------------------------------------------------------------------
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

; ---------------------------------------------------------------------------
; SDA80: IY = the 3D object of the car IX (14, 15 or 16)
        ZPROC $DA80
        lda zixl
        sta car
        lda zixh
        sta car+1
sda80:  ldy #6
        lda (car),y
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
        lda zixl
        sta car
        lda zixh
        sta car+1
lda97:  jsr sda80
        ldy #0
        lda (car),y
        and #3
        sta (car),y
        sty le_                 ; e = 0
        iny                     ; SDBB2 (from-junction)
        lda (car),y
        cmp $7504
        bne @n1
        iny
        lda (car),y
        cmp $7505
        beq @vis
@n1:    ldy #3                  ; SDBB2 (to-junction)
        lda (car),y
        cmp $7504
        bne @ret
        iny
        lda (car),y
        cmp $7505
        bne @ret
        inc le_                 ; ;? approaching
        bne @vis
@ret:   rts                     ; NZ
@vis:   ldy #0
        lda (car),y
        ora #$08
        sta (car),y
        sec
        sbc $75F0
        and #3
        sta lrel
        ldy #5
        lda (car),y
        sta lpos
        lda lrel
        sta (ziyl),y            ; (iy+5) = rel
        lda #0
        tay
        sta (ziyl),y            ; (iy+0) = d = 0
        lda #$80
        sta ld_
        lda lrel
        lsr a
        bcs @odd
        ldx #$5F
        lsr a
        bcc @dad3
        inx                     ; ;? opposite direction
        jsr sdbbf
        lda ld_
        ora #$20
        sta ld_
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
        jmp ldb39
@odd:   lda ld_
        ora #$40
        sta ld_
        lda lrel
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
        lda ld_
        ora #$20
        sta ld_
@db0d:  lda lpos
        cmp #$30
        bcc @db18
        IX_GLOBAL               ; NZ
        rts
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
        sta lhl
        lda zh
        sta lhl+1
        IX_GLOBAL
        jsr Z_B241
        lda lhl
        sta zl
        lda lhl+1
        sta zh
        lda ZV_DA7F
        sta za2
        lda zl                  ; the original EXXs: position goes in HL'
        sta zl2
        lda zh
        sta zh2
        jsr Z_B412
        php
        lda zl2                 ; and comes back (ghost position) in HL'
        sta zl
        lda zh2
        sta zh
        plp
        bne ldb6d
ldb4e:  ldy #0
        lda (car),y
        ora #$04
        sta (car),y
        ldy #6
        lda (car),y
        and #3
        cmp #3
        bne @db67
        lda (car),y             ; ;? waiting drug car: exchange cancelled
        and #$FD
        sta (car),y
        lda $7864
        and #$FD
        sta $7864
@db67:  IX_GLOBAL
        lda #0                  ; Z
        rts
ldb6d:  ldy #2                  ; ;? grid cell occupied
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
        ldy #1
        lda (ziyl),y
        and #$7F
        sta (ziyl),y
        lda lsy
        sta ziyl
        lda lsy+1
        sta ziyh
        ldy #2
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
@dba6:  lda lsy
        sta ziyl
        lda lsy+1
        sta ziyh
        IX_GLOBAL
        ldy #1
        lda (ziyl),y
        and #$7F
        sta (ziyl),y
        lda #1                  ; NZ
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
        and #$08
        bne @set
        ldx #<CAR1
        lda (ziyl),y
        and #$10
        beq @set
        ldx #<CAR2
@set:   stx car
        stx zixl
        lda #>CAR0
        sta car+1
        sta zixh
        rts

; SDBEE: car +0 = (D75F0 + obj +5) & 3 (also in A)
        ZPROC $DBEE
        lda zixl
        sta car
        lda zixh
        sta car+1
sdbee:  ldy #5
        lda (ziyl),y
        clc
        adc $75F0
        and #3
        ldy #0
        sta (car),y
        rts

; ---------------------------------------------------------------------------
; LDBFA: a car object (IY) left the view; turn it back into a map car.
        ZPROC $DBFA
        ldy #1
        lda (ziyl),y
        and #$7F
        sta (ziyl),y
        iny
        lda (ziyl),y
        and #$06
        cmp #$06
        bne @rts
        jsr sdbd7
        ldy #0
        lda (car),y
        tax
        and #$40
        beq @dc15
        txa                     ; ;?
        ora #$80
        sta (car),y
        tax
@dc15:  txa
        bmi @dc42
        jsr sdbee
        ldx $7504
        stx mx
        ldx $7505
        stx my
        jsr mstep
        ldy #1                  ; SDBCA (D7504, moved)
        lda $7504
        sta (car),y
        iny
        lda $7505
        sta (car),y
        iny
        lda mx
        sta (car),y
        iny
        lda my
        sta (car),y
        iny
        lda #$64
        sta (car),y
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
        ldy #5
        sta (car),y
        ldy #0
        lda (car),y
        ora #$08
        sta (car),y
@dc42:  IX_GLOBAL
@rts:   rts

; SDC4C: same without the flag tests (;? never executed)
        ZPROC $DC4C
        jsr sdbd7
        ldy #0
        lda (car),y
        tax
        and #$40
        beq @n
        txa
        ora #$80
        sta (car),y
        tax
@n:     txa
        bpl sdc5f
        IX_GLOBAL
        rts

; ---------------------------------------------------------------------------
; SDC5F: rebuild a map-style record (IX) from the object IY on the
; player's road grid.
        ZPROC $DC5F
        lda zixl
        sta car
        lda zixh
        sta car+1
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
        jmp @g
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
        bmi @f5
        lda $75FF
        jmp @fc
@f5:    lda $75F5
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
        bne l_dc99
        lda #$64
        sec
        sbc lpos
        sta lpos
l_dc99:  lda lpos
        ldy #5
        sta (car),y
        jsr sdbee
        sta ldir
        ldy #5
        lda (ziyl),y
        eor ll
        sta lt
        ldy #1
        lda (ziyl),y
        bmi l_p4
        ldx $7506
        ldy $7507
        jmp l_bs
l_p4:    ldx $7504
        ldy $7505
l_bs:    stx mx
        sty my
        stx lsv
        sty lsv+1
        lda lt
        and #2
        bne l_dcc0
        lda ldir
        jsr mstep
        ldy #1                  ; from = base, to = moved
        lda lsv
        sta (car),y
        iny
        lda lsv+1
        sta (car),y
        iny
        lda mx
        sta (car),y
        iny
        lda my
        sta (car),y
        IX_GLOBAL
        rts
l_dcc0:  lda ldir
        eor #2
        jsr mstep
        ldy #1                  ; from = moved, to = base
        lda mx
        sta (car),y
        iny
        lda my
        sta (car),y
        iny
        lda lsv
        sta (car),y
        iny
        lda lsv+1
        sta (car),y
        IX_GLOBAL
        rts
l_dcca:  lda #0
        ldy #1
        lda (ziyl),y
        and #$40
        beq l_dcd4
        ldy #8                  ; ;?
        lda (ziyl),y
        .byte $2C               ; skip the lda #0
l_dcd4:  lda #0
        clc
        adc #1
        asl a
        asl a
        sta lt
        ldy #1
        lda (ziyl),y
        and #$20
        beq l_dce3
        lda #$64                ; ;?
        sec
        sbc lt
        jmp dc8b
l_dce3:  lda #2
        sta ll
        lda lt
        jmp dc8b

; ---------------------------------------------------------------------------
; SDCE8: route search.  HL = start junction, C = arrival direction,
; ZV_DD6D = target, ZV_DCE7 = depth.  Result D71D2-D71D5 (D71D5 = first
; direction of the best route, $FF = none).  HL is preserved.
        ZPROC $DCE8
sdce8:  lda #$FF
        sta $71D2
        sta $71D3
        sta $71D4
        sta $71D5
        lda zl
        sta rx
        lda zh
        sta ry
        lda zc
        sta rcame
        ldx #0
        stx rp
@enter: stx rd
        lda rx,x                ; mask = S9564 | one-way | no U-turn
        sta zl
        lda ry,x
        sta zh
        jsr Z_9564
        ldx rd
        lda ze
        sta lt
        ldy rx,x
        cpy #$20
        bcs @n1
        lda T_9382,y
        bpl @n1
        and #$04
        beq @s3
        lda #$02
        bne @o1
@s3:    lda #$08
@o1:    ora lt
        sta lt
@n1:    ldy ry,x
        cpy #$20
        bcs @n2
        lda T_93A2,y
        bpl @n2
        and #$04
        beq @s2
        lda #$01
        bne @o2
@s2:    lda #$04
@o2:    ora lt
        sta lt
@n2:    ldy rcame
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
        jmp @enter
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
@leaf:  lda ZV_DD6D             ; |dx| + |dy|
        sec
        sbc mx
        bpl @ax
        eor #$FF
        clc
        adc #1
@ax:    sta lt
        lda ZV_DD6D+1
        sec
        sbc my
        bpl @ay
        eor #$FF
        clc
        adc #1
@ay:    clc
        adc lt
@eval:  sta rdist
        ldx rd
        lda $71D2
        cmp rnp
        bcs :+
        jmp @next
:
        bne @acc
        lda $71D3
        cmp rdist
        bcs :+
        jmp @next
:
        bne @acc
        lda $71D4
        cmp rnb
        bcs :+
        jmp @next
:
@acc:   lda rnp
        sta $71D2
        lda rdist
        sta $71D3
        lda rnb
        sta $71D4
        lda rroot
        sta $71D5
        jmp @next

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
        ZPROC $DDF4
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
        jsr sde43
        ldx kidx
        inx
        cpx #3
        bne @l
        IX_GLOBAL
        rts

; LDE15: re-place every active map car (end of a traffic pass)
        ZPROC $DE15
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
        ldy #0                  ; SDE36
        lda (car),y
        and #$84
        bne @n
        jsr lda97
@n:     ldx kidx
        inx
        cpx #3
        bne @l
        IX_GLOBAL
        rts

; ---------------------------------------------------------------------------
; SDE43: update one car (IX)
        ZPROC $DE43
        lda zixl
        sta car
        lda zixh
        sta car+1
sde43:  ldy #6
        lda (car),y
        sta lb
        ldy #0
        lda (car),y
        bmi :+
        jmp lded0
:
        lda lb                  ; inactive: launch a drug car?
        lsr a
        bcc @rts
        lda $75F8
        and #7
        bne @rts
        dec ZV_DDD1
        bne @rts
        lda #$40
        sta ZV_DDD1
        lda CAR0
        and #$C0
        bne @rts
        lda CAR0+6
        and #$04
        bne @rts
        lda ZV_DDCF
        clc
        adc #<CITYOFF
        sta lp
        lda ZV_DDCF+1
        adc #>CITYOFF
        sta lp+1
        ldy #0
        lda (lp),y
        bmi @rts
        ldy #8
        sta (car),y
        ldy #1
        lda (lp),y
        ldy #9
        sta (car),y
        lda ZV_DDCF
        clc
        adc #2
        sta ZV_DDCF
        bcc sde82
        inc ZV_DDCF+1
        bcs sde82
@rts:   rts

; SDE82: launch the car IX from a random map-edge entry point
        ZPROC $DE82
        lda zixl
        sta car
        lda zixh
        sta car+1
sde82:  jsr se08a
        ldy #0
        lda lc
        sta (car),y
        iny                     ; SDBCA (x,y) both junctions
        lda le_
        sta (car),y
        iny
        lda ld_
        sta (car),y
        iny
        lda le_
        sta (car),y
        iny
        lda ld_
        sta (car),y
        lda #$5E
        iny
        sta (car),y
        lda $7513
        ldy #7
        sta (car),y
        ldy #6
        lda (car),y
        and #$81
        sta (car),y
        ldx #$89
        lsr a
        bcc @t
        dex
@t:     stx ZV_DEC1
        ldy #0
        lda (car),y
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
        ldy #3
        lda (car),y
        iny
        ora (car),y
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
        ldy #5
        adc (car),y
        sta (car),y
        cmp #$5F
        bcs ldf14
@df0c:  ldy #0
        lda (car),y
        and #$08
        beq @rts
        jmp lda97
@rts:   rts

; arrival at the to-junction
ldf14:  lda #5
        sta (car),y
        ldy #6
        lda (car),y
        sta lb
        and #$04
        beq @t
        ldy #8                  ; ;? hiding place / escape point
        lda (car),y
        tax
        iny
        lda (car),y
        jmp @s
@t:     ldx ZV_E088             ; meeting point
        lda ZV_E088+1
@s:     stx ZV_DD6D
        sta ZV_DD6D+1
        ldy #3
        lda (car),y
        sta le_
        iny
        lda (car),y
        sta ld_
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
        ldy #6
        lda (car),y
        ora #$02
        sta (car),y
        ldy #5
        lda #$64
        sta (car),y
        rts
ldf55:  jsr cmphere             ; ;?
        beq :+
        jmp ldfcf
:
        ldy #0
        lda (car),y
        ora #$80
        sta (car),y
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
        ldy #0
        lda (car),y
        ora #$80
        sta (car),y
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
        lda CAR1+6
        and #$02
        beq @c2
        lda CAR1+6
        and #$FD
        ora #$0C
        sta CAR1+6
        jmp @x
@c2:    lda CAR2+6
        and #$FD
        ora #$0C
        sta CAR2+6
@x:     jsr se001
        beq @dfbe
        jsr Z_BA5F
        .byte $40, $0F, "DRUGS EXCHANGED"
@dfbe:  ldy #6
        lda (car),y
        and #$FD
        sta (car),y
        jmp ldfcf
ldfc5:  lda lb
        and #$02
        bne ldfcb
        lda #2
        bne ldfd1
ldfcb:  lda #5
        bne ldfd1
ldfcf:  lda #3
ldfd1:  sta ZV_DCE7
        ldy #1
        lda le_
        sta (car),y
        sta zl
        iny
        lda ld_
        sta (car),y
        sta zh
        ldy #0
        lda (car),y
        and #3
        sta zc
        jsr sdce8
        lda $71D5
        bpl @dff2
        ldy #0
        lda (car),y
        and #3
        eor #2
@dff2:  ldy #0
        sta (car),y
        ldx le_
        stx mx
        ldx ld_
        stx my
        jsr mstep
        ldy #3
        lda mx
        sta (car),y
        iny
        lda my
        sta (car),y
        jmp lda97

; Z if target ZV_DD6D == here (le_, ld_)
cmphere:
        lda ZV_DD6D
        cmp le_
        bne @r
        lda ZV_DD6D+1
        cmp ld_
@r:     rts

; SE001: one exchange done; after the 4th the armed car runs (returns Z)
se001:  dec ZV_DDD2
        bne @r
        lda CAR0+6
        ora #$04
        sta CAR0+6
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
        lda CAR0
        ora #$80
        sta CAR0
        lda $7611
        beq @np
        jsr sde82
@np:    jsr se08a
        ldy #8
        lda le_
        sta (car),y
        iny
        lda ld_
        sta (car),y
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
        IX_GLOBAL
        rts

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
