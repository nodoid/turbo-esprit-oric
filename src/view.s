; view.s - S862E: show the 3D view on the Oric screen.
;
; The original renders the 3D view into a Spectrum-format buffer at $6400
; (32 bytes per line, bytes 2..29 = the 224 visible pixels) with Spectrum
; colour attributes for each 8x8 cell at $7040.  S862E copied both to the
; Spectrum screen and cleared them.  Here each line is converted to the Oric
; HIRES layout (6 pixels per byte, docs/PORTING.md section 5): three Spectrum
; bytes give four Oric bytes.  Line y goes to HIRES line y+4, Spectrum x to
; Oric pixel x+6, so buffer byte i (x = 8i) starts in Oric column 1.
;
; Colour, per character row (8 lines), from the 28 attribute cells:
;  * all cells equal: column 0 sets the paper, inverse video gives black ink;
;  * sky rows (only blue-paper cells and 0x38 cells): blue paper, white ink;
;    the 0x38 cells are inverted so their building wall shows white with
;    blue detail lines (the Spectrum shows them black on white);
;  * anything else (coloured cars, the map view): serial attributes are
;    inserted at the column where a run of cells with other colours starts.
; Afterwards the buffers are cleared exactly like the original, which the
; renderer relies on (0 pixels, $FF margins and bottom row, 0x38 colours).

        .include "zx.inc"
        .include "hw.inc"

        .export Z_862E, view_init
        .import pillar

BUF     = $6400                 ; Spectrum-format view buffer (row -1)
ROW0    = $6420                 ; first visible line
ATTRS   = $7040                 ; colour cells, char row R at ATTRS+32R+2

        .zeropage
base:   .res 1                  ; $40 or $C0 for the current char row
vrow:   .res 1                  ; current line 0..95
crow:   .res 1                  ; current char row 0..11
dptr:   .res 2                  ; Oric line address
vt:     .res 2
lcnt:   .res 1                  ; line counter in a char row
gt:     .res 1                  ; converter temp
g0:     .res 1
g1:     .res 1
novr:   .res 1                  ; number of overrides for this char row
hasx:   .res 1                  ; bit 7: the row has non-zero xor masks
ecbase: .res 1                  ; value of the empty-group constants ($FF: masks)

        .segment "TABLES"       ; page aligned (first segment at $0600)
; 8->6 conversion: group of Spectrum bytes s0 s1 s2 -> Oric columns
;   c1 = s0>>2   c2 = (s0&3)<<4 | s1>>4   c3 = (s1&15)<<2 | TE[s2]   c4 = s2&63
TE:     .repeat 256, i
        .byte i >> 6
        .endrep

        .segment "RODATAH1"
; Spectrum colour number -> Oric colour number
zx2oric: .byte 0, 4, 1, 5, 2, 6, 3, 7

; top of the steering wheel, copied into the bottom lines of the view (D86BD)
wheel95: .byte $FF,$FF,$FF,$FF,$FF,$FF
wheel94: .byte $1F,$FF,$FF,$FF,$FF,$F8
wheel93: .byte $00,$FF,$FF,$FF,$FF,$00
wheel92: .byte $01,$FF,$FF,$80

        .segment "DATA"
; colours used for the view cells after a copy (0x38; the map view sets
; 0x30) and for the steering-wheel cells: set by SE0F1 (mission/map module)
        ZLABEL $8699, 1
        .byte $38
        ZLABEL $86D3, 6
        .byte $38, $38, $38, $38, $38, $38

        .segment "LOBSS"
xlast:  .res 28                 ; masks the converter is patched for
ecbase2: .res 1
        .bss
xorm:   .res 28                 ; xor mask per Spectrum byte for this char row
ovcol:  .res 16                 ; overrides: Oric column
ovval:  .res 16                 ;            byte
col0:   .res 1                  ; column 0 byte of this char row
cplan:  .res 28                 ; colours the current patched code was set up for

        .code

; ---------------------------------------------------------------------------
; view_init: fill the A-pillar columns 38/39 of the view lines (static)
view_init:
        lda #<(HIRES + 4*40)
        sta dptr
        lda #>(HIRES + 4*40)
        sta dptr+1
        ldx #0
@l:     ldy #38
        lda #$91                ; inverse paper red = cyan
        sta (dptr),y
        iny
        lda pillar,x
        sta (dptr),y
        clc
        lda dptr
        adc #40
        sta dptr
        bcc @n
        inc dptr+1
@n:     inx
        cpx #96
        bne @l
        ldx #27
        lda #$FF
@x:     sta cplan,x             ; force the first set-up
        dex
        bpl @x
        rts

; ---------------------------------------------------------------------------
        ZPROC $862E
        ; steering-wheel overlay (rows 92..95, columns 13..18) and colours
        ldx #5
@w:     lda wheel95,x
        sta ROW0 + 95*32 + 2 + 13,x
        lda wheel94,x
        sta ROW0 + 94*32 + 2 + 13,x
        lda wheel93,x
        sta ROW0 + 93*32 + 2 + 13,x
        lda ZV_86D3,x
        sta ATTRS + 11*32 + 2 + 13,x
        dex
        bpl @w
        ldx #3
@w2:    lda wheel92,x
        sta ROW0 + 92*32 + 2 + 14,x
        dex
        bpl @w2
        lda #0
        sta ROW0 + 91*32 + 2 + 15
        sta ROW0 + 91*32 + 2 + 16

        lda #0
        sta vrow
        sta crow
        lda #<(HIRES + 4*40)
        sta dptr
        lda #>(HIRES + 4*40)
        sta dptr+1
@crow:  jsr plan_row
        ldx #8
@line:  stx lcnt
        jsr conv_line
        ; overrides (attribute bytes inside the line)
        ldx novr
        beq @no
@ov:    dex
        ldy ovcol,x
        lda ovval,x
        sta (dptr),y
        txa
        bne @ov
@no:    ldy #0
        lda col0
        sta (dptr),y
        clc
        lda dptr
        adc #40
        sta dptr
        bcc @nc
        inc dptr+1
@nc:    inc vrow
        ldx lcnt
        dex
        bne @line
        inc crow
        lda crow
        cmp #12
        bne @crow

        ; margins of every line, the bottom row and row -1, like the original
        lda #<ROW0
        sta vt
        lda #>ROW0
        sta vt+1
        ldx #96
@m:     lda #$FF
        ldy #0
        sta (vt),y
        iny
        sta (vt),y
        ldy #30
        sta (vt),y
        iny
        sta (vt),y
        clc
        lda vt
        adc #32
        sta vt
        bcc @mn
        inc vt+1
@mn:    dex
        bne @m
        ldx #31
        lda #$FF
@b:     sta ROW0 + 96*32,x      ; row 96 (and $701E/$701F set above)
        dex
        bpl @b
        ldx #27
        lda #0
@t:     sta BUF + 2,x           ; row -1
        dex
        bpl @t
        lda #$FF
        sta BUF
        sta BUF + 1
        rts

; ---------------------------------------------------------------------------
; plan_row: work out the colours of char row `crow` from its 28 cells, set
; col0/base/xorm/overrides, reset the cells to 0x38 and re-patch the eor
; immediates of the converter where the mask changed.
plan_row:
        lda crow
        asl a
        asl a
        asl a
        asl a
        asl a                   ; 32 * crow (crow < 8 here) ...
        tax
        lda crow
        cmp #8
        bcc @lo
        ; char rows 8..11 live in the next page
        lda #<(ATTRS + 2 + 256)
        sta vt
        lda #>(ATTRS + 2 + 256)
        sta vt+1
        jmp @go
@lo:    lda #<(ATTRS + 2)
        sta vt
        lda #>(ATTRS + 2)
        sta vt+1
@go:    txa
        clc
        adc vt
        sta vt
        bcc @g2
        inc vt+1
@g2:    lda #0
        sta novr
        ; uniform?
        ldy #0
        lda (vt),y
        sta cur
        ldy #27
@u:     lda (vt),y
        cmp cur
        bne @notuni
        dey
        bne @u
        lda cur
        jsr attr_scheme         ; col0, base, ink override
        lda #0
        jsr fill_xor
        jmp @reset
@notuni:
        lda crow
        cmp #4
        bcs @general
        ; sky row?  only 0x08 / 0x0F / 0x38 allowed
        ldy #27
@s:     lda (vt),y
        cmp #$08
        beq @sk
        cmp #$0F
        beq @sk
        cmp #$38
        bne @general
@sk:    dey
        bpl @s
        lda #16 + 4             ; blue paper, white ink
        sta col0
        lda #$40
        sta base
        ldy #27
@sx:    lda (vt),y
        cmp #$38
        beq @inv
        lda #0
        .byte $2C               ; bit abs: skip
@inv:   lda #$FF
        sta xorm,y
        dey
        bpl @sx
        jmp @reset
@general:
        ; inverse polarity throughout; column 0 = paper of cell 0
        lda #$C0
        sta base
        lda #0
        jsr fill_xor
        ldy #0
        lda (vt),y
        sta cur
        jsr paper_of
        sta curp
        ora #$90                ; inverse, paper attribute
        sta col0
        lda cur
        jsr ink_of
        sta curk
        cmp #7
        beq @g0
        ldx novr
        lda #1
        sta ovcol,x
        lda curk
        ora #$80
        sta ovval,x
        inc novr
@g0:    ldy #1
@gl:    lda (vt),y
        cmp cur
        beq @gn
        sta cur
        ; Oric column of this cell's first pixel: (8y+6) div 6
        tya
        asl a
        asl a
        asl a
        clc
        adc #6
        jsr div6
        sta ocol
        lda cur
        jsr paper_of
        cmp curp
        beq @gk
        sta curp
        ldx novr
        cpx #16
        bcs @gn
        ora #$90
        sta ovval,x
        lda ocol
        sta ovcol,x
        inc ocol
        inc novr
@gk:    lda cur
        jsr ink_of
        cmp curk
        beq @gn
        sta curk
        ldx novr
        cpx #16
        bcs @gn
        ora #$80
        sta ovval,x
        lda ocol
        sta ovcol,x
        inc novr
@gn:    iny
        cpy #28
        bne @gl
@reset: ldy #27
        lda ZV_8699
@r:     sta (vt),y
        dey
        bpl @r
        jmp patch_xor

; A = Spectrum attribute -> col0/base for a uniform row, ink override in
; column 1 when the ink is neither black nor white.
attr_scheme:
        sta cur
        jsr ink_of              ; inverse ink value (7 = black shown)
        cmp #0
        bne @notw
        ; white ink: normal video
        lda cur
        jsr paper_of
        eor #7                  ; real paper
        ora #16
        sta col0
        lda #$40
        sta base
        rts
@notw:  sta curk
        lda cur
        jsr paper_of
        ora #$90
        sta col0
        lda #$C0
        sta base
        lda curk
        cmp #7
        beq @done
        ldx novr
        lda #1
        sta ovcol,x
        lda curk
        ora #$80
        sta ovval,x
        inc novr
@done:  rts

; paper_of: A = Spectrum attribute -> 7 - Oric paper colour (inverse value)
paper_of:
        lsr a
        lsr a
        lsr a
        and #7
        tax
        lda zx2oric,x
        eor #7
        rts
; ink_of: A = Spectrum attribute -> 7 - Oric ink colour
ink_of: and #7
        tax
        lda zx2oric,x
        eor #7
        rts

; div6: A (0..255) -> A div 6
div6:   ldx #0
@d:     cmp #6
        bcc @e
        sbc #6
        inx
        bne @d
@e:     txa
        rts

fill_xor:
        ldx #27
@f:     sta xorm,x
        dex
        bpl @f
        rts

        .bss
cur:    .res 1
curp:   .res 1
curk:   .res 1
ocol:   .res 1

        .code
; ---------------------------------------------------------------------------
; conv_line: convert buffer line `vrow` to the Oric line at dptr, columns
; 1..37, and clear the buffer bytes.  The unrolled converter reads the
; buffer with X = low byte of the line address and writes with Y = low byte
; of the Oric line address; the high bytes are patched into the operands
; when they change.
conv_line:
        ; source: line address = $6400 + 32*(vrow+1)
        ldx vrow
        inx
        txa
        lsr a
        lsr a
        lsr a                   ; (vrow+1) / 8
        clc
        adc #>BUF
        cmp srcpage
        beq @sp
        sta srcpage
        jsr patch_src
@sp:    ldx vrow
        inx
        txa
        asl a
        asl a
        asl a
        asl a
        asl a                   ; 32*(vrow+1) mod 256
        tax
        lda dptr+1
        cmp dstpage
        beq @dp
        sta dstpage
        jsr patch_dst
@dp:    ldy dptr
        jmp converter

        .bss
srcpage: .res 1
dstpage: .res 1

; ---------------------------------------------------------------------------
; The unrolled converter.  Group g handles Spectrum bytes 3g..3g+2 (buffer
; offsets 2+3g..4+3g) -> Oric columns 4g+1..4g+4.  Byte 27 -> column 37.
        .segment "DATA2"         ; (HIGH area)

.macro SRCB i                   ; load buffer byte i, eor with its mask
        .ident(.sprintf("ls%d", i)):
        lda a:$0002 + i,x
        .ident(.sprintf("lx%d", i)):
        eor #0
.endmacro
.macro RAWL i                   ; raw load (zero test)
        .ident(.sprintf("lr%d", i)):
        lda a:$0002 + i,x
.endmacro
.macro RAWO i                   ; raw ora (zero test)
        .ident(.sprintf("or%d", i)):
        ora a:$0002 + i,x
.endmacro
.macro CLRB i
        .ident(.sprintf("cs%d", i)):
        sta a:$0002 + i,x
.endmacro
.macro DST c
        .ident(.sprintf("ds%d", dsn)):
        sta a:$0000 + c,y
        dsn .set dsn + 1
.endmacro
.macro EMPTY g, k               ; empty-group constant for column 4g+1+k
        .ident(.sprintf("ec%d_%d", g, k)):
        lda #$40
        DST 4*g+1+k
.endmacro

dsn     .set 0

converter:
.repeat 9, g
        RAWL 3*g
        RAWO 3*g+1
        RAWO 3*g+2
        bne .ident(.sprintf("full%d", g))
        bit hasx                ; rows with masks: do it in full
        bmi .ident(.sprintf("full%d", g))
        lda base                ; all paper
        DST 4*g+1
        DST 4*g+2
        DST 4*g+3
        DST 4*g+4
        jmp .ident(.sprintf("next%d", g))
.ident(.sprintf("full%d", g)):
        SRCB 3*g                ; c1 = s0 >> 2
        sta g0
        lsr a
        lsr a
        ora base
        DST 4*g+1
        SRCB 3*g+1
        sta g1
        lsr a
        lsr a
        lsr a
        lsr a
        sta gt
        SRCB 3*g+2              ; c4 = s2 & 63
        sta .ident(.sprintf("pe%d", g))+1
        and #63
        ora base
        DST 4*g+4
        lda #0
        CLRB 3*g
        CLRB 3*g+1
        CLRB 3*g+2
        lda g0
        and #3
        asl a
        asl a
        asl a
        asl a
        ora gt
        ora base
        DST 4*g+2
        lda g1
        and #15
        asl a
        asl a
.ident(.sprintf("pe%d", g)):
        ora TE
        ora base
        DST 4*g+3
.ident(.sprintf("next%d", g)):
.endrep
        ; byte 27 -> column 37 (its last 2 pixels fall under the A-pillar)
        SRCB 27
        lsr a
        lsr a
        ora base
        DST 37
        lda #0
        CLRB 27
        rts

NDST = dsn

; ---------------------------------------------------------------------------
        .code
; patch_src: srcpage -> high byte of every buffer operand
patch_src:
        lda srcpage
.repeat 28, i
        sta .ident(.sprintf("ls%d", i))+2
        sta .ident(.sprintf("cs%d", i))+2
.if i < 27
.if i .mod 3 = 0
        sta .ident(.sprintf("lr%d", i))+2
.else
        sta .ident(.sprintf("or%d", i))+2
.endif
.endif
.endrep
        rts

; patch_dst: dstpage -> high byte of every screen operand
patch_dst:
        lda dstpage
.repeat NDST, i
        sta .ident(.sprintf("ds%d", i))+2
.endrep
        rts

; patch_xor: copy xorm into the eor immediates and set the constants the
; converter writes for all-zero groups (base, or the converted masks).
; Skipped when nothing changed since the last char row.
patch_xor:
        lda #0
        ldx #27
@o:     ora xorm,x
        dex
        bpl @o
        sta vt
        ora hasx
        bne @p
        rts                     ; masks zero before and after
@p:     lda vt
        bne @nz
        lda #$FF                ; patching zeros: forget the cached masks
        sta ecbase2
        lda #0
        beq @z
@nz:    ; same masks (and base) as the code was last patched for?  skip
        lda base
        cmp ecbase2
        bne @chg
        ldx #27
@cmp:   lda xorm,x
        cmp xlast,x
        bne @chg
        dex
        bpl @cmp
        lda #$80
        sta hasx
        rts
@chg:   lda base
        sta ecbase2
        ldx #27
@cp:    lda xorm,x
        sta xlast,x
        dex
        bpl @cp
        lda #$80
@z:     sta hasx

        ; the eor immediates of the 28 loads
        ldx #27
@lx:    lda lxlo,x
        sta zl2
        lda lxhi,x
        sta zh2
        lda xorm,x
        ldy #1
        sta (zl2),y
        dex
        bpl @lx
        rts


        .segment "RODATAH2"
; operand addresses for patch_xor
lxlo:
.repeat 28, i
        .byte <.ident(.sprintf("lx%d", i))
.endrep
lxhi:
.repeat 28, i
        .byte >.ident(.sprintf("lx%d", i))
.endrep
