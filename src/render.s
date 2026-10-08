; render.s - the 3D road and scenery renderer (Spectrum $7BBE-$862D).
;
; Draws the building fronts, kerbs + chequered pavements, side roads,
; centre line / junction stop lines and the dashed lane dividers into the
; Spectrum-format off-screen buffer at $6400 (same address and layout on
; the Oric), bit-exact with the original.  See notes R2 for the algorithm;
; this is a routine-by-routine translation with these 6502 changes:
;
;  * The pixel cursor (Z80 hl'/c'/b') is cl/ch/cm/cb1 in zero page.  Hot
;    loops keep its low byte in Y and address the byte as (cp),y with
;    cp = 0 / ch, so "inc l" / "dec l" are iny/dey (same 8-bit wrap) and a
;    row step is a 16-bit -32 on ch:Y.
;  * The left/right "half" opcode patching of 7D3E patches the 6502 step
;    instructions (lsr/asl, ror/rol, iny/dey) and the fill_out jump.
;  * The far perspective record pointer IY is kept as an index ik (0..58,
;    58 = the horizon record) plus a pointer iyp for field reads.  The
;    per-unit pixel counts of the 82BC loop come from prefix-sum tables
;    (data/render_data.inc), so a line call costs O(pixels), not O(units).
;  * The horizontal span fills (8195/81B7) work a byte at a time with the
;    LOWBELOW / HIGHABOVE tables instead of a pixel at a time; 8191 (always
;    pattern $FF) has its own copies.
;  * Line stepper (82AC): the Bresenham accumulator is kept as acc - d (or
;    acc - e), so "carry or >=" becomes a plain carry test; the loops are
;    specialised for y-/x-major, plot/no plot/pavement dither, and in "lite"
;    copies that skip ixl and y1 (only the building line needs them).
;    Steps without plotting move the cursor rows in one go.
;  * Vertical runs (building edges, centre line, side wall edges) go two
;    rows per turn (vplot).
;  * Near the horizon every lane-dash gap is drawn solid, so dashes() draws
;    the rest of a divider with one line call (same pixels).
; These rely only on the static tables of the original (D78FE, the line
; records at D76AC): records start at table rows 0 or 3 with acc < d (e),
; and only record 58 has field 7 bit 7 set.  gen_render.py checks the latter.
;
; Persistent state that lived in the original's code area is relocated:
; D7D15/D7D17 (left segment pointer/offset), D7D18/D7D1A (right),
; D81D5 (working dither pattern), D81D6 (checker phase).  All other state
; is at its Spectrum address ($74F5..$75FE).

        .include "zx.inc"

        ZIMPORT $958B
        ZIMPORT $9907
        ZIMPORT $9AA8

; ---- Spectrum variables used here (identity addresses) -------------------
CORNER  = $74F5         ; previous roof corner (L = inward x, H = y1)
NEXTP   = $74F7         ; pointer to the next segment's type byte
RECSP   = $74FB         ; line record stack pointer
SEGP    = $74FD         ; type ptr of the segment where the line starts
DASH    = $74FF         ; lane-dash phase
SCROLL  = $7502
MAPC    = $7504         ; current map cell
MAPP    = $7506         ; previous map cell
BLKPOS  = $7508
SIDEXR  = $7509
SIDEXL  = $750A
MASKS   = $75CE         ; 80 40 20 10 08 04 02 01
CFG_DEFC = $75D8        ; default corner table pointer
CFG_NEAR = $75DA        ; near-zone table pointer
CFG_REC = $75DC         ; line record stack start
CFG_LANES = $75DF
CFG_KOFS = $75E0
NEARN   = $75E1         ; (ix+0)
OFS     = $75E2         ; (ix+1)
CTYPE   = $75E3         ; (ix+2)
NDEP    = $75E4         ; (ix+3)
FLAGS   = $75E5         ; (ix+4)
EDGEH   = $75E6         ; (ix+5)
KFLAGS  = $75E7         ; (ix+6)
BX      = $75E8         ; (ix+7)
BY1     = $75E9         ; (ix+8)
SEGU    = $75EA         ; (ix+9)
SVW     = $75EB         ; (ix+10)
JFLAGS  = $75EC
HEADING = $75F0
BLEN    = $75F5         ; (ix+20)
SPEED   = $75F6         ; (ix+21), word
FD      = $75FD
BLKDIR  = $75FE         ; (ix+29)
V7610   = $7610
HORIZON = 58            ; index of the horizon record in D78FE

; ---- zero page -------------------------------------------------------------
        .zeropage
cp:     .res 2          ; cp = 0, cp+1 = page of the cursor byte
cq:     .res 2          ; vplot: cq = $E0, cq+1 = ch - 1 (one row up)
ch      = cp+1
cl:     .res 1          ; cursor: low byte, mask, y1 (= row + 1)
cm:     .res 1
cb1:    .res 1
acc:    .res 1          ; Bresenham accumulator (Z80 A')
lx:     .res 1          ; inward x of the line (Z80 ixl)
ik:     .res 1          ; far record index (Z80 iy = $78FE + 12*ik)
iyp:    .res 2          ; record pointer for field reads (far or near)
sld:    .res 1          ; slope d, e of the current line
sle:    .res 1
nn:     .res 1          ; pixel count of the current line call
von:    .res 2          ; line loops (plot / no plot) for the current line
voff:   .res 2
pp:     .res 2          ; segment list pointer (Z80 hl of the scans)
tp:     .res 2          ; scratch pointer
dp:     .res 2          ; dp = 0, dp+1 = page for dfill
t0:     .res 1          ; scratch
t1:     .res 1
t2:     .res 1
t3:     .res 1
t4:     .res 1
t5:     .res 1

; aliases of the scratch bytes, per routine (never live at the same time)
pat     = t0            ; fill pattern
rgn     = t1            ; fill region
fvl     = t2            ; fill start byte value
dd      = t0            ; dfill / side wall: mask d
dold    = t1
dsy     = t2
ww      = t3            ; side wall width
racc    = t0            ; roofline accumulator
rl      = t4            ; roofline dx / dy
rh      = t5
cnt     = t3            ; loop counter save in dither loops

; ---- relocated variables ---------------------------------------------------
        .segment "DATA2"
        ZLABEL $7D15, 2
        .word $787C
        ZLABEL $7D17, 1
        .byte 0
        ZLABEL $7D18, 2
        .word $789F
        ZLABEL $7D1A, 1
        .byte 0
        ZLABEL $81D5, 1
        .byte $55
        ZLABEL $81D6, 1
        .byte $55

; private state (not compared: recomputed every frame)
dith:   .res 1          ; non-zero: pavement dither mode (82D5/831C = ccf)
lite:   .res 1          ; bit 7: kerb / lanes line (lx, y1 not needed)
nsel:   .res 1          ; near zone: type column
ntl:    .res 1          ; saved cursor (near edge top / boundary)
nth:    .res 1
ntm:    .res 1
svl:    .res 1          ; boundary: saved line point
svh:    .res 1
svm:    .res 1
svy:    .res 1
ka:     .res 1          ; kerb / centre / lanes registers a b c d
kb:     .res 1
kc:     .res 1
kd:     .res 1
kpb:    .res 1          ; pushed bc
kpc:    .res 1
lcnt:   .res 1          ; lanes: records left
lcnt0:  .res 1
dn:     .res 1          ; dashes: pieces left
ln:     .res 1          ; far_seg: segment length
bb:     .res 1          ; far_seg: units

        .segment "RODATA2"
        .include "render_data.inc"
PSLO:   .byte <PS7, <PS8, <PS9, <PS10, <PS11
PSHI:   .byte >PS7, >PS8, >PS9, >PS10, >PS11

; ---- self-modified step instructions (7D3E) ------------------------------
nIA .set 0
nIB .set 0
nIC .set 0
nOA .set 0
nOB .set 0
nOC .set 0
nFD .set 0
.macro IN_A
        .ident(.sprintf("sIA%d", nIA)) = *
        lsr cm
        nIA .set nIA + 1
.endmacro
.macro IN_B
        .ident(.sprintf("sIB%d", nIB)) = *
        ror cm
        nIB .set nIB + 1
.endmacro
.macro IN_C
        .ident(.sprintf("sIC%d", nIC)) = *
        iny
        nIC .set nIC + 1
.endmacro
.macro OUT_A
        .ident(.sprintf("sOA%d", nOA)) = *
        asl cm
        nOA .set nOA + 1
.endmacro
.macro OUT_B
        .ident(.sprintf("sOB%d", nOB)) = *
        rol cm
        nOB .set nOB + 1
.endmacro
.macro OUT_C
        .ident(.sprintf("sOC%d", nOC)) = *
        dey
        nOC .set nOC + 1
.endmacro
.macro FILLD                   ; 8188 inline: toggle D81D5, fill outwards with it
        lda ZV_81D5
        eor #$FF
        sta ZV_81D5
        .ident(.sprintf("sFD%d", nFD)) = *
        jsr fill_left
        nFD .set nFD + 1
.endmacro
; one pixel towards the road centre / towards the screen edge (cursor in Y);
; both leave C = 0
.macro INWARD
        IN_A
        bcc :+
        IN_B
        IN_C
:
.endmacro
.macro OUTWARD
        OUT_A
        bcc :+
        OUT_B
        OUT_C
:
.endmacro
; cursor one row up / down (ch:Y)
.macro ROWUP
        tya
        sec
        sbc #32
        tay
        bcs *+4
        dec ch
.endmacro
.macro ROWUP0                  ; same, when C = 0 is known
        tya
        sbc #31
        tay
        bcs *+4
        dec ch
.endmacro
.macro ROWDN
        tya
        clc
        adc #32
        tay
        bcc *+4
        inc ch
.endmacro
.macro PLOT
        lda (cp),y
        ora cm
        sta (cp),y
.endmacro
.macro INC16 v
        inc v
        bne *+4
        inc v+1
.endmacro
.macro DEC16 v
        lda v
        bne *+4
        dec v+1
        dec v
.endmacro

        .segment "CODE2"
; ============================================================================
; 7BBE render_view
ZPROC $7BBE
        lda ZV_81D6
        ldx SPEED
        beq :+
        eor #$FF
        sta ZV_81D6
:       sta ZV_81D5
        lda DASH
        clc
        adc SPEED
        and #7
        sta DASH
        lda BLKPOS
        clc
        adc SPEED
        sta BLKPOS
        sec
        sbc BLEN
        bcc :+
        cmp #$7B
        bcc :+
        jsr Z_7C8D
:       lda BLKPOS
        cmp #$0A
        bcs Z_7BF8
        jsr Z_7C82
ZPROC $7BF8
        lda #$E0
        sta cq
        lda #0
        sta cp
        sta dp
        sta dith
        lda SCROLL
        sec
        sbc SPEED
        sta SCROLL
        lda SCROLL+1
        sbc SPEED+1
        sta SCROLL+1
        ldx #0
        jsr set_half
        lda #0
        sta FLAGS
        lda ZV_7D15
        sta pp
        lda ZV_7D15+1
        sta pp+1
        lda ZV_7D17
        jsr advance
        sta ZV_7D17
        ldx pp
        stx ZV_7D15
        ldx pp+1
        stx ZV_7D15+1
        lda V7610
        lsr a
        bcs :+
        lda ZV_7D17
        jsr side_scan
        jsr kerb
:       lda #0
        sta dith
        lda SIDEXR
        sta SIDEXL
        ldx #1
        jsr set_half
        lda #$80
        sta FLAGS
        lda ZV_7D18
        sta pp
        lda ZV_7D18+1
        sta pp+1
        lda ZV_7D1A
        jsr advance
        sta ZV_7D1A
        ldx pp
        stx ZV_7D18
        ldx pp+1
        stx ZV_7D18+1
        lda V7610
        lsr a
        bcc :+
        rts
:       lda KFLAGS              ; rrc (ix+6)
        lsr a
        ror KFLAGS
        lda ZV_7D1A
        jsr side_scan
        jsr kerb
        lda KFLAGS              ; rlc (ix+6)
        asl a
        rol KFLAGS
        lda #0
        sta dith
        jsr centre
        jmp lanes

; ============================================================================
; 7C82 / 7C8D / 7CA1: block change
ZPROC $7C82
        lda #3
        sta BLKDIR
        lda HEADING
        eor #2
        jmp blk_step
ZPROC $7C8D
        lda #2
        sta BLKDIR
        lda HEADING
blk_step:
        ldx MAPC
        stx zl
        stx MAPP
        ldx MAPC+1
        stx zh
        stx MAPP+1
        jsr Z_7D2D
        ldx zl
        stx MAPC
        ldx zh
        stx MAPC+1
        ldx MAPP
        stx zl
        ldx MAPP+1
        stx zh
        ldx #<$75E1
        stx zixl
        ldx #>$75E1
        stx zixh
        jmp blk_new
ZPROC $7CA1
        ldx MAPC
        stx zl
        stx MAPP
        ldx MAPC+1
        stx zh
        stx MAPP+1
blk_new:
        jsr Z_958B
        jsr Z_9907
        jsr Z_9AA8
        ; 7CB0
        lda $7793
        ora #$80
        sta $7793
        and #$40
        beq :+
        lda $779B
        clc
        adc #$64
        jmp :++
:       lda $7798
:       sta t0                  ; b
        sec
        sbc #$3A
        clc
        adc SPEED
        sta SCROLL
        lda #$5C
        sta SCROLL+1
        lda t0
        clc
        adc #5
        eor #$FF                ; neg
        clc
        adc #1
        and #7
        sta DASH
        lda t0
        eor #$FF
        sec                     ; -b + (ix+20)
        adc BLEN
        clc
        adc #$C7
        sec
        sbc NEARN
        clc
        adc CFG_KOFS            ; (ix-1)
        sta BLKPOS
        sec
        sbc SPEED
        sta t0
        ldx #<$787D
        ldy #>$787D
        jsr blk_scan
        stx ZV_7D15
        sty ZV_7D15+1
        sta ZV_7D17
        lda t0
        ldx #<$78A0
        ldy #>$78A0
        jsr blk_scan
        stx ZV_7D18
        sty ZV_7D18+1
        stx zl                  ; Z80 exit: HL = D7D18, A = D7D1A, B = units
        sty zh
        sta ZV_7D1A
        ldx t0
        stx zb
        rts
; A = units, X/Y = first length byte; returns X/Y = type ptr, A = offset
blk_scan:
        stx tp
        sty tp+1
        ldy #0
@l:     cmp (tp),y
        bcc @e
        sbc (tp),y
        iny
        iny
        bne @l
        inc tp+1
        bne @l
@e:     tax
        tya
        clc
        adc tp
        sta tp
        bcc :+
        inc tp+1
:       DEC16 tp
        txa
        ldx tp
        ldy tp+1
        rts

; ============================================================================
; 7D1B advance: pp = type ptr, A = offset; adds the speed (one boundary max)
advance:
        INC16 pp
        ldy #0
        clc
        adc SPEED
        bpl @p
        tax                     ; moving backwards
        DEC16 pp
        DEC16 pp
        txa
        clc
        adc (pp),y
@p:     cmp (pp),y
        bcc @b
        sbc (pp),y
        tax
        INC16 pp
        txa
        rts
@b:     tax
        DEC16 pp
        txa
        rts

; 7D2D map_step: A = heading, zl/zh = map cell (h = y, l = x)
ZPROC $7D2D
        ror a
        bcs @x
        ror a
        bcs :+
        inc zh
        rts
:       dec zh
        rts
@x:     ror a
        bcs :+
        inc zl
        rts
:       dec zl
        rts

; ============================================================================
; 7D64 side_scan: A = offset in the current segment, pp = its type ptr.
; Building line of one half.
side_scan:
        sta OFS
        lda #0
        sta lite
        lda #$80
        sta SIDEXR
        lda CFG_REC
        sta RECSP
        lda CFG_REC+1
        sta RECSP+1
        ldy #0
        lda (pp),y
        sta CTYPE
        jsr def_corner
        INC16 pp
        ldy #0
        lda (pp),y
        sec
        sbc OFS
; ---- near zone: vertical building edges on the bottom row ----
ss_near:
        cmp NEARN
        bcc :+
        jmp ss_far
:       sta NDEP
        asl a
        asl a
        asl a
        clc
        adc CFG_NEAR
        sta iyp
        lda CFG_NEAR+1
        adc #0
        sta iyp+1
        INC16 pp                ; now at the next type
        lda FLAGS
        and #$FE
        sta FLAGS
        lda CTYPE
        bpl :+
        lda #0
:       and #7
        sta nsel
        ldy #5
        lda (iyp),y
        bit FLAGS
        bpl :+
        eor #$FF                ; 0xE0 - x
        sec
        adc #$E0
:       tax
        and #7
        tay
        lda MASKS,y
        sta cm
        txa
        lsr a
        lsr a
        lsr a
        clc
        adc #<$7002
        sta cl
        lda #>$7002
        sta ch
        ldy nsel
        lda (iyp),y
        sta EDGEH
        bne :+
        lda FLAGS
        ora #1
        sta FLAGS
:       lda #$60
        sec
        sbc EDGEH
        beq ss_n0
        tax
        ldy cl
        jsr vplot
        PLOT
        sty cl
        sty ntl
        lda ch
        sta nth
        lda cm
        sta ntm
        lda FLAGS
        lsr a
        bcs @fill
        ldy #5
        lda (iyp),y
        sec
        sbc CORNER
        sta rl
        lda EDGEH
        sec
        sbc CORNER+1
        sta rh
        jsr roofline
        lda FLAGS
        and #4
        beq @nof
@fill:  jsr fill_ff
@nof:   lda ntl
        sta cl
        lda nth
        sta ch
        lda ntm
        sta cm
ss_n0:  ; L7E28
        ldy #0
        lda (pp),y
        bne @nz
        bit CTYPE
        bmi @nz
        ldy #5
        lda (iyp),y
        eor #$FF                ; 0x6E - x
        sec
        adc #$6E
        sta SIDEXR
        lda #0
@nz:    sta CTYPE
        tax
        bmi ss_n92
        and #7
        beq ss_n92
        tay
        lda (iyp),y
        cmp EDGEH
        bcs @ge
        sta t0
        lda EDGEH
        sec
        sbc t0
        tax
        lda t0
        sta EDGEH
        jsr side_wall
        jmp @h
@ge:    sta EDGEH
@h:     lda EDGEH
        beq @def
        sta CORNER+1
        ldy #5
        lda (iyp),y
        sta CORNER
        lda FLAGS
        and #$FB
        sta FLAGS
        jmp ss_n92
@def:   jsr def_corner
ss_n92: INC16 pp
        ldy #0
        lda NDEP
        clc
        adc (pp),y
        jmp ss_near

; ---- far zone: along the perspective building line ----
ss_far: tax
        lda pp
        sec
        sbc #1
        sta SEGP
        lda pp+1
        sbc #0
        sta SEGP+1
        txa
        sec
        sbc NEARN
        sta SEGU
        jsr pop_line
        ldx SEGU
        beq ss_bnd
ss_seg: jsr far_seg
        bcc ss_bnd
        rts
ss_bnd: jsr boundary
        lda NEXTP
        clc
        adc #1
        sta pp
        lda NEXTP+1
        adc #0
        sta pp+1
        ldy #0
        lda (pp),y
        tax
        jmp ss_seg

; def_corner: CORNER = default corner [CTYPE&7]; FLAGS |= 4
def_corner:
        lda CFG_DEFC
        sta tp
        lda CFG_DEFC+1
        sta tp+1
        lda CTYPE
        and #7
        asl a
        tay
        lda (tp),y
        sta CORNER
        iny
        lda (tp),y
        sta CORNER+1
        lda FLAGS
        ora #4
        sta FLAGS
        rts

; L7EAE far_seg: X = units of the current segment (pp at its length).
; C = 1: end of the building line (horizon or end of list).
far_seg:
        lda ik
        cmp #HORIZON
        beq @end
        lda CTYPE
        bit CTYPE
        bvs @end
        bpl :+
        jsr line_off
        clc
        rts
@on:    jsr line_on
        clc
        rts
@end:   sec
        rts
:       and #7
        bne @on
        bit FD
        bmi @on
        ; side road gap
        stx bb
        ldy #0
        lda (pp),y
        sta ln
        sec
        sbc #2
        cmp bb
        bcs @e0
        sta t0                  ; ln-2 < b: line(b - (ln-2), off)
        lda bb
        sec
        sbc t0
        tax
        lda t0
        sta bb
        jsr line_off
@e0:    lda ln
        lsr a
        cmp bb
        bcs @fd
        sta t0
        lda bb
        sec
        sbc t0
        tax
        lda t0
        sta bb
        lda KFLAGS
        and #2
        jsr line_z
        ldx ik
        lda IY0,x
        cmp #$23
        bcc @fd
        jsr fill_ff
@fd:    lda bb
        cmp #3
        bcs @lg
        tax
        jsr line_off
        clc
        rts
@lg:    sbc #2
        tax
        lda KFLAGS
        and #8
        jsr line_z
        ldx #1
        jsr line_off
        ldx ik
        lda IY0,x
        cmp #$23
        bcc :+
        jsr fill_ff
:       ldx #1
        jsr line_off
        clc
        rts

; L7F23 boundary: end of a segment (pp at the length byte of the segment)
boundary:
        ldx ik
        lda IYLO,x
        sta iyp
        lda IYHI,x
        sta iyp+1
        lda lx
        sta BX
        INC16 pp
        lda pp
        sta NEXTP
        lda pp+1
        sta NEXTP+1
        ldy #0
        lda (pp),y
        and #$40
        beq :+
        bit FLAGS
        bpl :+
        jsr fill_lff
:       lda cl
        sta svl
        lda ch
        sta svh
        lda cm
        sta svm
        lda cb1
        sta svy
        sta BY1
        lda FLAGS
        and #$FD
        sta FLAGS
        lda CTYPE
        bpl @t
        ldy #0
        lda (pp),y
        bpl @gap
        jmp bd_next
@t:     and #7
        bne @bld
@gap:   lda ik
        cmp #HORIZON
        beq :+
        jsr fill_ff
:       lda FLAGS
        ora #2
        sta FLAGS
        ldy #6
        lda (iyp),y
        sta SVW
        lda #0
        sta EDGEH
        sta (iyp),y
        jmp bd_next
@bld:   tay
        lda (iyp),y
        sta EDGEH
        tax
        lda FLAGS
        and #$FE
        cpx cb1
        bne :+
        ora #1
:       sta FLAGS
        ldy cl
        jsr vplot
        PLOT
        sty cl
        sty ntl
        lda ch
        sta nth
        lda cm
        sta ntm
        lda FLAGS
        lsr a
        bcs @fill
        lda BX
        sec
        sbc CORNER
        sta rl
        lda BY1
        sec
        sbc EDGEH
        sec
        sbc CORNER+1
        bcs :+
        lda #0
:       sta rh
        jsr roofline
        lda FLAGS
        and #4
        beq @nof
@fill:  jsr fill_ff
@nof:   lda ntl
        sta cl
        lda nth
        sta ch
        lda ntm
        sta cm
        lda #0
        sta cb1
bd_next: ; L7FC8
        ldy #0
        lda (pp),y
        bne @nz
        bit CTYPE
        bmi @nz
        lda BX
        eor #$FF                ; 0x6E - X
        sec
        adc #$6E
        sta SIDEXR
        lda #0
@nz:    sta CTYPE
        tax
        bmi bd_4d
        and #7
        beq bd_4d
        tay
        lda (iyp),y
        cmp EDGEH
        bcc @lt
        beq @eq
        sta t0
        sec
        sbc EDGEH
        tax
        lda t0
        sta EDGEH
        lda ik
        cmp #HORIZON
        beq @c
        jsr side_wall
        jmp @c
@eq:    bit FLAGS
        bpl @c
        lda CTYPE
        and #$40
        beq @c
        jsr sw8222
        jmp @c
@lt:    sta EDGEH
@c:     lda BY1                 ; L8022
        sec
        sbc EDGEH
        beq @def
        sta CORNER+1
        lda BX
        sta CORNER
        lda FLAGS
        and #$FB
        sta FLAGS
        jmp bd_4d
@def:   jsr def_corner
bd_4d:  lda FLAGS
        and #2
        beq :+
        lda SVW
        ldy #6
        sta (iyp),y
:       lda svl
        sta cl
        lda svh
        sta ch
        lda svm
        sta cm
        lda svy
        sta cb1
        rts

; ============================================================================
; 806C kerb: kerb line + pavement dither
kerb:
        lda #$FF
        sta dith
        sta lite
        jsr pop_line
        lda SEGP
        sta pp
        lda SEGP+1
        sta pp+1
        lda CFG_KOFS
        clc
        adc SEGU
        INC16 pp
        ldy #0
        cmp (pp),y
        bcc :+
        sbc (pp),y
        tax
        DEC16 pp
        DEC16 pp
        txa
:       tax
        DEC16 pp
        stx kb
        stx SEGU
        lda pp
        sta SEGP
        lda pp+1
        sta SEGP+1
        ldy #0
        lda (pp),y
        bpl :+
        jmp kb_8155
:       and #7
        bne kb_d0
        bit FD
        bmi kb_d0
        lda #$3C
        sec
        sbc kb
        sta kpb                 ; push af (budget)
        INC16 pp
        lda kb
        beq kb_cb
        cmp #1
        beq kb_c4
        tax
        dex                     ; b = c - 1
        clc
        adc #1
        ldy #0
        cmp (pp),y
        bne kb_c1
        lda ik
        cmp #HORIZON
        beq :+
        jsr fill_ff
:       ldy #0
        lda (pp),y
        sec
        sbc #2
        tax
kb_c1:  jsr line_off
kb_c4:  lda ik
        cmp #HORIZON
        beq kb_cb
        jsr fill_ff
kb_cb:  lda kpb
        sta kb
        lda #1
        jmp kb_d3
kb_d0:  INC16 pp
        ldx #$3C
        stx kb
        lda SEGU                ; A = b
kb_d3:  sta ka                  ; L80D3
        INC16 pp
        ldy #0
        lda (pp),y
        and #$40
        bne kb_14
        lda ka
        sta kc
        lda (pp),y
        and #7
        beq kb_e9
kb_de:  INC16 pp                ; L80DE
        ldy #0
        lda (pp),y
        clc
        adc kc
        cmp kb
        bcs :+
        jmp kb_d3
:       tax
        jmp line_on
kb_e9:  bit FD
        bmi kb_de
        inc kc
        lda kb
        sta kpb
        lda kc
        sta kpc
        ldx kc
        jsr line_on
kb_f6:  jsr fill_ff                ; L80F6
        INC16 pp
        ldy #0
        lda (pp),y
        sec
        sbc #2
        tax
        jsr line_off
        lda ik
        cmp #HORIZON
        bne :+
        rts
:       jsr fill_ff
        lda kpb
        sec
        sbc kpc
        ldy #0
        sec
        sbc (pp),y
        sta kb
        lda #1
        jmp kb_d3
kb_14:  ldx ka                  ; L8114
        dex
        beq :+
        jsr line_on
:       jmp end_band
kb_8155:                        ; L8155 [never seen in real play]
        INC16 pp
        lda kb
        sta ka
        lda #$3C
        sta kb
@l:     INC16 pp
        ldy #0
        lda (pp),y
        bpl @x
        INC16 pp
        lda ka
        clc
        adc (pp),y
        sta ka
        cmp kb
        bcc @l
        rts
@x:     lda ka
        sta kc
        sta kpc
        lda kb
        sta kpb
        ldx ka
        beq :+
        jsr line_off
:       lda cl
        pha
        lda ch
        pha
        jsr end_band
        pla
        sta ch
        pla
        sta cl
        ldx #1
        jsr line_off
        lda kpb
        sta kb
        lda kpc
        sta kc
        ldy #0
        lda (pp),y
        and #7
        beq :+
        lda #$FF
        sta kc
        jmp kb_de
:       jmp kb_f6

; 8119 end_band: dead-end band, right half only
end_band:
        bit FLAGS
        bpl @r
        jsr fill_lff
        jsr fill_rff
        ldx ik
        lda IYLO,x
        sta iyp
        lda IYHI,x
        sta iyp+1
        ldy #7
        lda (iyp),y
        beq @r
        bmi @r
        sec
        sbc #1
        beq @r
        sta kd
@l:     lda cl
        sec
        sbc #32
        sta cl
        bcs :+
        dec ch
:       lda ZV_81D5
        eor #$FF
        sta ZV_81D5
        jsr fill_left
        lda ZV_81D5
        jsr fill_right
        lda ZV_81D5
        and cm
        bne :+
        lda cm
        eor #$FF
        ldy cl
        and (cp),y
        sta (cp),y
:       dec kd
        bne @l
@r:     rts

; ============================================================================
; 8188 / 8191 / 8195 / 81B7: horizontal fills from the cursor pixel.
; The start pixel is set; then pixels are filled (pattern & mask) outwards
; up to the first set pixel; whole zero bytes get the raw pattern.
; Cursor unchanged; A X Y clobbered.
fill_ff:                        ; 8191 with A = $FF
        jmp fill_lff
fill_left:                      ; 8195
        sta pat
        ldy cl
        lda cm                  ; region = bits left of the start pixel
        asl a
        bcs fl_edge
        sbc #0                  ; C = 0: 2c - 1
        eor #$FF
        sta rgn
        lda (cp),y
        ora cm
        sta fvl
        and rgn
        bne fl_b                ; something set in the region: stops here
        lda rgn
        and pat
        ora fvl
        sta (cp),y
fl_z0:  ldx pat
fl_z:   dey                     ; whole zero bytes get the pattern
        lda (cp),y
        bne fl_e
        txa
        sta (cp),y
        dey
        lda (cp),y
        bne fl_e
        txa
        sta (cp),y
        jmp fl_z
fl_e:   tax                     ; up to the first set pixel
        lda LOWBELOW,x
        and pat
        ora (cp),y
        sta (cp),y
        rts
fl_b:   tax
        lda LOWBELOW,x
        and rgn
        and pat
        ora fvl
        sta (cp),y
        rts
fl_edge:
        lda (cp),y
        ora cm
        sta (cp),y
        jmp fl_z0
fill_lff:                       ; 8195 with A = $FF
        ldy cl
        lda cm
        asl a
        bcs flf_edge
        sbc #0
        eor #$FF
        sta rgn
        lda (cp),y
        ora cm
        sta fvl
        and rgn
        bne flf_b
        lda rgn
        ora fvl
        sta (cp),y
flf_z:  dey
        lda (cp),y
        bne flf_e
        lda #$FF
        sta (cp),y
        dey
        lda (cp),y
        bne flf_e
        lda #$FF
        sta (cp),y
        bne flf_z
flf_e:  tax
        lda LOWBELOW,x
        ora (cp),y
        sta (cp),y
        rts
flf_b:  tax
        lda LOWBELOW,x
        and rgn
        ora fvl
        sta (cp),y
        rts
flf_edge:
        lda (cp),y
        ora cm
        sta (cp),y
        jmp flf_z
fill_right:                     ; 81B7
        sta pat
        ldy cl
        lda cm                  ; region = bits right of the start pixel
        sec
        sbc #1
        sta rgn
        lda (cp),y
        ora cm
        sta fvl
        and rgn
        bne fr_b
        lda rgn
        and pat
        ora fvl
        sta (cp),y
        ldx pat
fr_z:   iny
        lda (cp),y
        bne fr_e
        txa
        sta (cp),y
        iny
        lda (cp),y
        bne fr_e
        txa
        sta (cp),y
        jmp fr_z
fr_e:   tax
        lda HIGHABOVE,x
        and pat
        ora (cp),y
        sta (cp),y
        rts
fr_b:   tax
        lda HIGHABOVE,x
        and rgn
        and pat
        ora fvl
        sta (cp),y
        rts
fill_rff:                       ; 81B7 with A = $FF
        ldy cl
        lda cm
        sec
        sbc #1
        sta rgn
        lda (cp),y
        ora cm
        sta fvl
        and rgn
        bne frf_b
        lda rgn
        ora fvl
        sta (cp),y
frf_z:  iny
        lda (cp),y
        bne frf_e
        lda #$FF
        sta (cp),y
        iny
        lda (cp),y
        bne frf_e
        lda #$FF
        sta (cp),y
        bne frf_z
frf_e:  tax
        lda HIGHABOVE,x
        ora (cp),y
        sta (cp),y
        rts
frf_b:  tax
        lda HIGHABOVE,x
        and rgn
        ora fvl
        sta (cp),y
        rts

; ============================================================================
; 81D7 pop_line: pop a 16-byte line record from (RECSP).
; The Bresenham accumulator is kept as acc - d (y-major) or acc - e
; (x-major), which is negative for every record (acc < d or e): one step
; is then "add the minor slope, step on carry", exactly the original's
; "carry or >=" test for these ranges.
pop_line:
        lda RECSP
        sta tp
        lda RECSP+1
        sta tp+1
        ldy #1
        lda (tp),y
        bpl :+
        sta acc                 ; end marker
        lda #2
        jmp @adv
:       sec
        sbc #7
        tax
        lda PSLO,x
        sta psf1+1
        sta psf2+1
        sta psn1+1
        sta psn2+1
        lda PSHI,x
        sta psf1+2
        sta psf2+2
        sta psn1+2
        sta psn2+2
        ldy #2
        bit FLAGS
        bpl :+
        ldy #6
:       lda (tp),y
        sta cl
        iny
        lda (tp),y
        sta ch
        iny
        lda (tp),y
        sta cm
        iny
        lda (tp),y
        sta cb1
        ldy #10
        lda (tp),y
        sta lx
        iny
        lda (tp),y
        sta acc
        iny
        lda (tp),y
        sta sle
        iny
        lda (tp),y
        sta sld
        ldx #0
        cmp sle
        bcc :+
        ldx #2                  ; y-major (d >= e)
        lda acc
        sbc sld                 ; C = 1
        jmp :++
:       lda acc
        sec
        sbc sle
:       sta acc
        bit lite
        bpl :+
        inx                     ; lite loops
        inx
        inx
        inx
:       lda VOFF,x
        sta voff
        lda VOFF+1,x
        sta voff+1
        lda dith
        beq :+
        inx
        inx
        inx
        inx
:       lda VON,x
        sta von
        lda VON+1,x
        sta von+1
        ldy #14
        lda (tp),y
        sta iyp
        iny
        lda (tp),y
        sta iyp+1
        ; ik = (iy - $78FE) / 12
        ldx #0                  ; fast paths: rows 0 and 3 (all records)
        lda iyp
        ldy iyp+1
        cpy #>$78FE
        bne :+
        cmp #<$78FE
        beq @dd
        bne @g
:       ldx #3
        cpy #>($78FE+36)
        bne @g
        cmp #<($78FE+36)
        beq @dd
@g:     sec
        sbc #<$78FE
        sta t0
        lda iyp+1
        sbc #>$78FE
        sta t1
        ldx #0
@dv:    lda t0
        sec
        sbc #12
        tay
        lda t1
        sbc #0
        bcc @dd
        sta t1
        sty t0
        inx
        bne @dv
@dd:    stx ik
        lda #16
@adv:   clc
        adc RECSP
        sta RECSP
        bcc :+
        inc RECSP+1
:       rts
VOFF:   .word ln_xs, ln_ys, lx_s, ly_s
VON:    .word ln_xp, ln_yp, lx_p, ly_p, lx_d, ly_d

; ============================================================================
; 82AA / 82AC / 82AF line: advance the line by X depth units (0 = 256),
; plotting (line_on) or not (line_off); line_z: plot if A != 0.
; The pixel count is the sum of field SEL of the records passed (82BC),
; read from the prefix-sum table selected by pop_line.
line_z: cmp #0
        bne line_on
line_off:
        txa
        beq @h
        clc
        adc ik
        bcs @h
        cmp #HORIZON
        bcc :+
@h:     lda #HORIZON
:       tax
psf1:   lda PS7,x
        ldy ik
        stx ik
        sec
psf2:   sbc PS7,y
        beq @r
        sta nn
        tax
        ldy cl
        jmp (voff)
@r:     rts
line_on:
        txa
        beq @h
        clc
        adc ik
        bcs @h
        cmp #HORIZON
        bcc :+
@h:     lda #HORIZON
:       tax
psn1:   lda PS7,x
        ldy ik
        stx ik
        sec
psn2:   sbc PS7,y
        beq @r
        sta nn
        tax
        ldy cl
        jmp (von)
@r:     rts

; cursor up A rows (ch:Y), C = anything
rows_up:
        sta t0
        lsr a
        lsr a
        lsr a
        sta t1
        lda t0
        asl a
        asl a
        asl a
        asl a
        asl a
        sta t0
        tya
        sec
        sbc t0
        tay
        lda ch
        sbc t1
        sta ch
        rts

; Loops: X = pixel count (nn), Y = cursor low byte.  The full versions keep
; lx (Z80 ixl) and cb1 (y1), which only the building line uses; the "lite"
; versions (kerb, lanes) leave them alone.
; y-major, plot
ln_yp:  PLOT
        lda acc
        clc
        adc sle
        bcc yp_n
        sbc sld                 ; result < 0: C = 0
        sta acc
        inc lx
        INWARD                  ; leaves C = 0
        ROWUP0
        dex
        bne ln_yp
        beq ln_yend
yp_n:   sta acc
        ROWUP0
        dex
        bne ln_yp
ln_yend:
        sty cl
        lda cb1
        sec
        sbc nn
        sta cb1
        rts

; y-major, no plot: only the inward steps, then all rows at once
ln_ys:  lda acc
ys_l:   clc
        adc sle
        bcc ys_n
        sbc sld
        inc lx
        INWARD
ys_n:   dex
        bne ys_l
        sta acc
        lda nn
        jsr rows_up
        jmp ln_yend

; x-major, plot
ln_xp:  INWARD                  ; C = 0
        PLOT
        lda acc
        adc sld
        bcc xp_n
        sbc sle                 ; result < 0: C = 0
        sta acc
        dec cb1
        ROWUP0
        dex
        bne ln_xp
        beq ln_xend
xp_n:   sta acc
        dex
        bne ln_xp
ln_xend:
        sty cl
        lda lx
        clc
        adc nn
        sta lx
        rts

; x-major, no plot: inward steps, rows counted and applied at the end
ln_xs:  lda #0
        sta t2
        lda acc
xs_l:   INWARD                  ; C = 0
        adc sld
        bcc xs_n
        sbc sle
        inc t2
xs_n:   dex
        bne xs_l
        sta acc
        lda cb1
        sec
        sbc t2
        sta cb1
        lda t2
        beq ln_xend
        jsr rows_up
        jmp ln_xend

; ---- lite versions ----
; y-major, plot
ly_p:   PLOT
        lda acc
        clc
        adc sle
        bcc lyp_n
        sbc sld
        sta acc
        INWARD
        ROWUP0
        dex
        bne ly_p
        sty cl
        rts
lyp_n:  sta acc
        ROWUP0
        dex
        bne ly_p
        sty cl
        rts

; y-major, no plot
ly_s:   lda acc
lys_l:  clc
        adc sle
        bcc lys_n
        sbc sld
        INWARD
lys_n:  dex
        bne lys_l
        sta acc
        lda nn
        jsr rows_up
        sty cl
        rts

; y-major, dither: fill every row
ly_d:   sty cl
        stx cnt
        FILLD
        ldx cnt
        ldy cl
        lda acc
        clc
        adc sle
        bcc lyd_n
        sbc sld
        sta acc
        INWARD
        ROWUP0
        dex
        bne ly_d
        sty cl
        rts
lyd_n:  sta acc
        ROWUP0
        dex
        bne ly_d
        sty cl
        rts

; x-major, plot
lx_p:   INWARD                  ; C = 0
        PLOT
        lda acc
        adc sld
        bcc lxp_n
        sbc sle
        sta acc
        ROWUP0
        dex
        bne lx_p
        sty cl
        rts
lxp_n:  sta acc
        dex
        bne lx_p
        sty cl
        rts

; x-major, no plot
lx_s:   lda #0
        sta t2
        lda acc
lxs_l:  INWARD                  ; C = 0
        adc sld
        bcc lxs_n
        sbc sle
        inc t2
lxs_n:  dex
        bne lxs_l
        sta acc
        lda t2
        beq :+
        jsr rows_up
:       sty cl
        rts

; x-major, dither: fill at the first pixel of every row
lx_d:
lxd_f:  INWARD
        sty cl
        stx cnt
        FILLD
        ldx cnt
        ldy cl
        lda acc
        clc
        adc sld
        bcc lxd_n1
        sbc sle
        sta acc
        ROWUP0
        dex
        bne lxd_f
        sty cl
        rts
lxd_n1: sta acc
        dex
        bne lxd_p
        sty cl
        rts
lxd_p:  INWARD                  ; C = 0
        PLOT
        lda acc
        adc sld
        bcc lxd_n2
        sbc sle
        sta acc
        ROWUP0
        dex
        bne lxd_f
        sty cl
        rts
lxd_n2: sta acc
        dex
        bne lxd_p
        sty cl
        rts

; ============================================================================
; 8337 roofline: from the cursor, rl pixels outward and rh pixels up
roofline:
        lda rl
        ora rh
        bne :+
        rts
:       ldy cl
        lda rh
        cmp rl
        bcc rf_sh
        tax                     ; steep: h rows up, plot at the x steps
        lsr a
        sec
        sbc rh                  ; racc = a - h (always < 0)
        sta racc
rf_sl:  lda racc
        clc
        adc rl
        bcc rf_s0               ; carry = (a + l >= h)
        sbc rh
        sta racc
        PLOT
        OUTWARD                 ; C = 0
        ROWUP0
        dex
        bne rf_sl
        sty cl
        rts
rf_s0:  sta racc
        ROWUP0
        dex
        bne rf_sl
        sty cl
        rts
rf_sh:  ldx rl                  ; shallow: l pixels outward
        lda rl
        lsr a
        sec
        sbc rl
        sta racc
        clc
rf_hl:  lda racc                ; C = 0 here
        adc rh
        bcc rf_h0
        sbc rl
        sta racc
        ROWUP0
        OUTWARD                 ; C = 0
        PLOT
        dex
        bne rf_hl
        sty cl
        rts
rf_h0:  sta racc
        OUTWARD
        PLOT
        dex
        bne rf_hl
        sty cl
        rts

; vplot: X = k (0 = 256) times {plot, row up} from ch:Y with mask cm,
; two rows per turn (cq = cursor - 32).  Y and ch are left k rows up.
vplot:  txa
        beq @k256
        lsr a
        tax
        bcc @ev
        PLOT
        ROWUP
        cpx #0
        beq @r
@ev:    lda ch
        sta cq+1
        dec cq+1
        sec
@l:     lda (cp),y
        ora cm
        sta (cp),y
        lda (cq),y
        ora cm
        sta (cq),y
        tya
        sbc #64
        tay
        bcc @pg
        dex
        bne @l
@r:     rts
@pg:    dec ch
        dec cq+1
        sec
        dex
        bne @l
        rts
@k256:  ldx #128
        bne @ev

; ============================================================================
; 820B side_wall: X = rows to extend the edge up (0 = 256), then the visible
; side wall (width iy[6]) with its dithered face and far edge.
side_wall:
        ldy #6
        lda (iyp),y
        sta ww
        ldy cl
        jsr vplot
        bit FLAGS
        bpl sw_31
        lda CTYPE
        and #$40
        bne sw_22
sw_31:  PLOT                    ; 8231
        lda #0
        sta dd
sw_36:  OUT_A                   ; 8236
        bcc sw_56
        OUT_B
        jsr dfill
sw_3d:  lda #0                  ; 823D
        sta dd
        OUT_C
        lda (cp),y
        bne sw_56
        lda ww
        sec
        sbc #8
        bcc sw_56
        sta ww
        lda #$FF
        sta dd
        sta (cp),y
        jsr dfill
        lda ww
        bne sw_3d
        beq sw_69
sw_56:  lda (cp),y              ; 8256
        and cm
        beq :+
        sty cl
        jmp dfill
:       lda dd
        ora cm
        sta dd
        PLOT
        dec ww
        bne sw_36
        lda dd
        eor cm
        sta dd
        jsr dfill
sw_69:  ROWDN                   ; 8269: far vertical edge down
@l:     lda (cp),y
        and cm
        bne @r
        PLOT
        ROWDN
        jmp @l
@r:     sty cl
        rts
; 8222: always leftwards to the first set pixel, then the wall from there
sw8222:
        ldy cl
sw_22:
@l:     asl cm
        bcc @c
        rol cm
@z:     dey                     ; 16-bit dec hl
        cpy #$FF
        bne :+
        dec ch
:       lda (cp),y
        beq @z
@c:     lda (cp),y
        and cm
        beq @l
        lda #0
        sta ww
        jmp sw_31

; 8276 dfill: dithered fill down under the mask dd from byte ch:Y.
; Y preserved, dd changed.
dfill:  lda dd
        bne :+
        rts
:       sty dsy
        ldx ZV_81D5
        lda ch
        sta dp+1
        lda dd
        cmp #$FF
        beq @full
@pb:    tya
        clc
        adc #32
        tay
        bcc @pb2
        inc dp+1
@pb2:   lda (dp),y
        sta dold
        txa
        and dd
        ora dold
        sta (dp),y
        txa
        asl a
        adc #0
        tax
        lda dold
        eor #$FF
        and dd
        sta dd
        bne @pb
        ldy dsy
        rts
@full:  lda #$20                ; two rows per turn: tp = dp + 32
        sta tp
        tya
        clc
        adc #32
        tay
        bcc :+
        inc dp+1
:       lda dp+1
        sta tp+1
@fl:    lda (dp),y
        bne @nz
        txa
        sta (dp),y
        asl a
        adc #0
        tax
        lda (tp),y
        bne @nz2
        txa
        sta (tp),y
        asl a
        adc #0                  ; C = 0
        tax
        tya
        adc #64
        tay
        bcc @fl
        inc dp+1
        inc tp+1
        bcs @fl
@nz2:   cmp #$FF
        beq @x
        tya
        clc
        adc #32
        tay
        bcc @pb2
        inc dp+1
        bcs @pb2
@nz:    cmp #$FF
        bne @pb2
@x:     ldy dsy
        rts

; ============================================================================
; 8377 centre: centre line and junction stop lines.  qq = q - 36 so that
; (qq),y with y = 36 reads M[q] and y = 0 / 1 read M[q-36] / M[q-35].
qq      = tp
QO      = 36
centre:
        lda #<$7010
        sta cl
        lda #>$7010
        sta ch
        lda #$80
        sta cm
        lda #0
        sta ik
        lda SEGP
        sec
        sbc #QO
        sta qq
        lda SEGP+1
        sbc #0
        sta qq+1
        ldy #QO
        lda (qq),y
        tax
        INC16 qq
        txa
        bpl :+
        jmp ce_6c
:       and #$20
        beq ce_b4
        lda SEGU
        cmp #4
        bcc ce_c5b
        sbc #4
        cmp #4
        bcc :+
        sbc #8
        jsr c84B1
        bcc ce_ac
        rts
:       jsr c84C6
ce_ac:  INC16 qq
        lda #7
        sta kb
        lda #4
        sta kc
        jmp ce_c8
ce_b4:  txa
        and #7
        beq :+
        ldy #0
        lda (qq),y
        and #7
        bne ce_c5b
:       jmp ce_44b
ce_c5b: lda #7
        sta kb
        lda SEGU
ce_c5:  sta kc                  ; L83C5
        INC16 qq
ce_c8:  ldy #QO                 ; L83C8
        lda (qq),y
        sta ka
        and #$40
        bne ce_ea
        lda ka
        and #$20
        beq :+
        lda kc
        jsr c84B1
        bcc :+
        rts
:       INC16 qq
        lda ka
        and #7
        beq ce_f2
        ldy #0
        lda (qq),y
        and #7
        beq ce_f2
        ldy #QO
        lda kc
        clc
        adc (qq),y
ce_e5:  dec kb                  ; L83E5
        bne ce_c5
        jmp cdraw
ce_ea:  lda kc
        beq ce_r
        sec
        sbc #1
        beq ce_r
        jmp cdraw
ce_r:   rts
ce_f2:  lda kc                  ; L83F2: junction ahead
        jsr cdraw
        lda ik
        cmp #HORIZON
        beq ce_r
        lda JFLAGS
        and #1
        beq :+
        jsr fill_lff
:       lda JFLAGS
        and #2
        beq :+
        jsr fill_rff
:       ldy #QO
        lda (qq),y
        lsr a
        ldx JFLAGS
ce_15:  sta kc                  ; L8415 (X = flags for bit 6)
        txa
        and #$40
        php
        lda kc
        plp
ce_18:  jsr cdraw_z             ; L8418
        lda ik
        cmp #HORIZON
        beq ce_r
        lda JFLAGS
        and #4
        beq :+
        jsr fill_lff
:       lda JFLAGS
        and #8
        beq :+
        jsr fill_rff
:       ldy #QO
        lda (qq),y
        lsr a
        sta kc
        lda JFLAGS
        and #$80
        php
        lda kc
        plp
ce_2e:  jsr cdraw_z             ; L842E
        lda ik
        cmp #HORIZON
        beq ce_r
        lda JFLAGS
        and #$10
        beq :+
        jsr fill_lff
:       lda JFLAGS
        and #$20
        beq :+
        jsr fill_rff
:       lda #0
        jmp ce_e5
ce_44b: lda #7                  ; L844B: inside a junction
        sta kb
        lda SEGU
        asl a
        ldy #QO
        cmp (qq),y
        bcc @a
        sbc (qq),y
        lsr a
        sta kc
        lda JFLAGS
        and #$40
        php
        lda kc
        plp
        jmp ce_18
@a:     lsr a
        sta kc
        lda JFLAGS
        and #$80
        php
        lda kc
        plp
        jmp ce_2e
ce_6c:  lda SEGU                ; L846C [never seen in real play]
        sta ka
        lda #7
        sta kb
@l:     INC16 qq
        ldy #QO
        lda (qq),y
        bpl @x
        INC16 qq
        lda ka
        clc
        adc (qq),y
        sta ka
        dec kb
        bne @l
        rts
@x:     lda ka
        clc
        adc #1
        jsr cskip
        jsr fill_lff
        jsr fill_rff
        ldy #QO
        lda (qq),y
        and #7
        beq @g
        ldy #1                  ; (ix-35)
        lda (qq),y
        and #7
        beq @g
        INC16 qq
        lda #$FF
        ldy #QO
        clc
        adc (qq),y
        jmp ce_e5
@g:     INC16 qq
        ldy #QO
        lda (qq),y
        lsr a
        sec
        sbc #1
        ldx JFLAGS
        jmp ce_15

; 84B1: C = 1 if the horizon was reached (Z80 "ret nz")
c84B1:  clc
        adc #4
        jsr cdraw
        lda ik
        cmp #HORIZON
        beq @h
        jsr fill_lff
        jsr fill_rff
        lda #4
        jsr c84C6
        clc
        rts
@h:     sec
        rts
; 84C6: skip A units, fill both ways; c = $F8
c84C6:  jsr cskip
        jsr fill_lff
        jsr fill_rff
        lda #$F8
        sta kc
        clc
        rts

; 84EA: Z = 1: cskip(A) else cdraw(A)
cdraw_z:
        beq cskip
; 84ED cdraw: A units of the centre line (field 7) drawn upwards
cdraw:  jsr sum7
        beq @r
        tax
        ldy cl
        jsr vplot
        sty cl
@r:     rts
; 8511 cskip: same, cursor only
cskip:  jsr sum7
        beq @r
        sta t0                  ; cursor -= 32 * k
        lsr a
        lsr a
        lsr a
        sta t1
        lda t0
        asl a
        asl a
        asl a
        asl a
        asl a
        sta t0
        lda cl
        sec
        sbc t0
        sta cl
        lda ch
        sbc t1
        sta ch
@r:     rts
; sum of field 7 over A records from ik (0 = 256), stopping at the horizon
sum7:   tax
        beq @z
        clc
        adc ik
        bcs @h
        cmp #HORIZON
        bcc :+
@h:     lda #HORIZON
:       tax
        lda PS7,x
        ldy ik
        sec
        sbc PS7,y
        stx ik
        rts
@z:     lda #0                  ; Z80: "or a / ret z" before the loop
        rts

; ============================================================================
; 8532 lanes: dashed lane dividers, right half then left half
lanes:
        lda CFG_LANES
        sec
        sbc #1
        bne :+
        rts
:       sta lcnt0
        ldx #$FF
        stx lite
        jsr lanes_pass
        lda FLAGS
        and #$7F
        sta FLAGS
        ldx #0
        jsr set_half
        lda lcnt0
; 8552 lanes_pass: A = number of dividers
lanes_pass:
        sta lcnt
        lda #<$76FC
        ldx #>$76FC
la_rec: sta RECSP
        stx RECSP+1
        jsr pop_line
        lda SEGP
        sta pp
        lda SEGP+1
        sta pp+1
        ldy #0
        lda (pp),y
        tax
        INC16 pp
        lda DASH
        sta kb                  ; b = phase
        lda #7
        sta kc
        lda SEGU
        sta ka
        txa
        bpl :+
        jmp la_cd
:       and #7
        bne la_92
        lda ka                  ; [never seen in real play]
        beq la_8a
        lda JFLAGS
        and #3
        beq la_92
        lda ka
la_7f:  sta kb                  ; L857F
        sta ka
        tax
        beq :+
        jsr line_off
:       lda ik
        cmp #HORIZON
        beq la_aa
la_8a:  lda #0                  ; L858A
        sta ka
        sta kb
        dec kc
        beq la_aa
la_92:                          ; L8592 / L8595
la_l:     INC16 pp
        lda ka
        sta kd
        ldy #0
        lda (pp),y
        tax
        and #$40
        bne la_c3
        txa
        and #7
        beq la_b2
la_9f:  INC16 pp
        lda kd
        ldy #0
        clc
        adc (pp),y
        sta ka
        dec kc
        bne la_l
la_a7:  lda ka
        jsr dashes
la_aa:  dec lcnt
        bne :+
        rts
:       lda #<$76DC
        ldx #>$76DC
        jmp la_rec
la_b2:  lda JFLAGS
        and #$33
        beq la_9f
        INC16 pp                ; [never seen in real play]
        lda kd
        beq :+
        jsr dashes
:       ldy #0
        lda (pp),y
        jmp la_7f
la_c3:  lda kd
        beq la_aa
        sec
        sbc #1
        beq la_aa
        sta ka
        jmp la_a7
la_cd:  ; L85CD [never seen in real play]
@l:     ldy #1
        lda (pp),y
        bpl @x
        INC16 pp
        INC16 pp
        lda ka
        clc
        ldy #0
        adc (pp),y
        sta ka
        dec kc
        bne @l
        rts
@x:     lda ka
        jmp la_7f

; 85E5 dashes: A = length in units, kb = phase
dashes:
        tax
        lsr a
        lsr a
        sta dn
        txa
        and #3
        beq :+
        inc dn
:       lda kb
        cmp #4
        bcs @g
        eor #$FF                ; 4 - phase
        sec
        adc #4
        tax
@d:     jsr line_on
        dec dn
        beq @r
        ldx #4
@gp:    ldy ik
        lda IY0,y
        cmp #$23
        bcc @s
        jsr line_off
        dec dn
        beq @r
        ldx #4
        jmp @d
@s:     stx t3                  ; near the horizon every gap is drawn
        lda dn                  ; solid, and so is everything after it:
        sec                     ; one call for X + 4 * (dn - 1) units
        sbc #1
        cmp #64
        bcs @all
        asl a
        asl a
        adc t3
        bcs @all
        tax
        jmp line_on
@all:   ldx #255                ; (more than the 58 records)
        jmp line_on
@g:     eor #$FF                ; 8 - phase
        sec
        adc #8
        tax
        jmp @gp
@r:     rts

; ============================================================================
; 7D3E patch_half: X = 0 left (outward = left), 1 right
set_half:
        lda OPIA,x
.repeat nIA, I
        sta .ident(.sprintf("sIA%d", I))
.endrepeat
        lda OPIB,x
.repeat nIB, I
        sta .ident(.sprintf("sIB%d", I))
.endrepeat
        lda OPIC,x
.repeat nIC, I
        sta .ident(.sprintf("sIC%d", I))
.endrepeat
        lda OPIA+1,x            ; outward = the other half's inward
.repeat nOA, I
        sta .ident(.sprintf("sOA%d", I))
.endrepeat
        lda OPIB+1,x
.repeat nOB, I
        sta .ident(.sprintf("sOB%d", I))
.endrepeat
        lda OPIC+1,x
.repeat nOC, I
        sta .ident(.sprintf("sOC%d", I))
.endrepeat
        lda FOLO,x
.repeat nFD, I
        sta .ident(.sprintf("sFD%d", I))+1
.endrepeat
        lda FOHI,x
.repeat nFD, I
        sta .ident(.sprintf("sFD%d", I))+2
.endrepeat
        lda FFLO,x
        sta fill_ff+1
        lda FFHI,x
        sta fill_ff+2
        rts
;                left right left
OPIA:   .byte $46, $06, $46     ; lsr zp / asl zp
OPIB:   .byte $66, $26, $66     ; ror zp / rol zp
OPIC:   .byte $C8, $88, $C8     ; iny / dey
FOLO:   .byte <fill_left, <fill_right
FOHI:   .byte >fill_left, >fill_right
FFLO:   .byte <fill_lff, <fill_rff
FFHI:   .byte >fill_lff, >fill_rff
