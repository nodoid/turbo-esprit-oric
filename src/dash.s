; dash.s - the dashboard (Spectrum 9E1E-A4C1) and the message line
; (BA56-BB1E) of Turbo Esprit.
;
; The static dashboard is a precomputed Oric picture (tools/gen_gfx.py:
; data/gfx_data.s T_DASH, HIRES lines 100-179 = Spectrum rows 96-175); the
; dynamic parts are drawn live by the gfx engine with the original streams:
; speedometer/rev needles (SA36F, XOR), fuel/temperature needles (LA41E),
; steering-wheel animation (SA094), indicator lamps (SA496/SA487: the
; Spectrum BRIGHT toggle becomes green <-> black via T_LAMPL/T_LAMPR).
; The status lines (Spectrum rows 22-23) are the Oric text rows at $BF68.

        .include "zx.inc"
        .include "snd.inc"
        .include "gfx_streams.inc"

        .import gfx_cls, gfx_lz, gfx_textinit, TEXTROW1
        .import T_DASH, T_LAMPL, T_LAMPR, T_A3D6, T_A47B
        .importzp lzs, lzd
        ZIMPORT $A4D6
        ZIMPORT $A526
        ZIMPORT $A8DB
        ZIMPORT $A89B
        ZIMPORT $A903
        ZIMPORT $A911
        ZIMPORT $A955
        ZIMPORT $94E5           ; engine temperature = 0 + LA41E (other module)
        ZVIMPORT $A23F          ; needle parameters inside sub-stream 9 / 10
        ZVIMPORT $A4C3
        ZVIMPORT $A691
        ZVIMPORT $A4F9
        ZVIMPORT $A969
        ZVIMPORT $E968          ; rev-counter dial value (player module)
        ZVIMPORT $9494          ; engine temperature 0..11
        ZVIMPORT $9495          ; fuel 0..11

D9F_A23F = ZV_A23F              ; Spectrum A23F (speedo needle patch point)
D9F_A24B = ZV_A23F + $0C
D9F_A259 = ZV_A23F + $1A
D9F_A25F = ZV_A23F + $20

        .zeropage
ixp:    .res 2                  ; SA399/SA457 patch pointer (the Z80 IX)
mp:     .res 2                  ; message data pointer

        .segment "DATA"
        ZVAR $A093, 1           ; steering wheel turned (0 or the D used)
        ZLABEL $5A24, 1         ; left indicator lamp attribute (Spectrum)
        .byte $60
        ZLABEL $5A39, 1         ; right indicator lamp attribute
        .byte $60
lampshow:.byte $40, $40         ; BRIGHT bit shown on the Oric (L, R)
tmpa:   .byte 0

        .code
; ===========================================================================
; S9E1E: draw the dashboard (game start)
        ZPROC $9E1E
        lda #$28
        jsr gfx_cls             ; 8F 28 (and border variable)
        jsr gfx_textinit
        lda #<T_DASH
        sta lzs
        lda #>T_DASH
        sta lzs+1
        lda #<($A000 + 100*40)
        sta lzd
        lda #>($A000 + 100*40)
        sta lzd+1
        jsr gfx_lz              ; lines 100-179
        ; lines 180-199 black (the status lines are text rows)
        ldx #20
@bl:    ldy #0
        lda #$10
        sta (lzd),y
        lda #$40
:       iny
        sta (lzd),y
        cpy #39
        bne :-
        lda lzd
        clc
        adc #40
        sta lzd
        bcc :+
        inc lzd+1
:       dex
        bne @bl
        ; the needles with their current parameters and the score line,
        ; exactly as the tail of the 9E21 stream draws them
        jsr Z_A4D6
        .byte $8C, $80, $09, $80, $0A, $8B
        .byte $07, $FF, $10, $B0, $8C, $20, $92, $20, $8B, $20, $92, $00
        lda #$60                ; attribute code 9F2B: lamps bright
        sta ZV_5A24
        sta ZV_5A39
        lda #$40
        sta lampshow
        sta lampshow+1
        lda #0
        sta ZV_A093
        jsr Z_A903              ; border 0
        jmp Z_94E5

; ===========================================================================
; steering wheel
L9FBC:  jsr Z_A4D6
        STREAM_9FBF
        rts
L9FFF:  jsr Z_A4D6
        STREAM_A002
        rts
LA043:  jsr Z_A4D6
        STREAM_A046
        rts
LA069:  jsr Z_A4D6
        STREAM_A06C
        rts

; SA094: D (zd) = 3 left / 1 right.  Toggles the turned wheel.
        ZPROC $A0B1             ; (wrapper preserving IX HL BC DE: nothing
        ZPROC $A094             ;  else is touched here)
        lda ZV_A093
        beq @draw
        ldx #0
        stx ZV_A093
        and #2
        beq :+
        jmp LA043
:       jmp LA069
@draw:  lda zd
        sta ZV_A093
        and #2
        beq :+
        jmp L9FBC
:       jmp L9FFF

; ===========================================================================
; SA36F: A = right dial index (0..17); left dial = DE968 (at least 1).
; The original XORs the old needles away and the new ones in.  When the
; parameters do not change that is an identity, so the port then skips both
; passes and only sets the engine state the passes would leave (screen mode,
; OR, line mode, ROM font, cursor at the end of the last needle line).
        ZPROC $A36F
        pha
        ldx #23
:       lda D9F_A23F,x          ; save the old parameters
        sta oldp,x
        dex
        bpl :-
        pla
        jsr a36f_set            ; new parameters into the stream
        ldx #23
:       lda D9F_A23F,x
        cmp oldp,x
        bne @chg
        dex
        bpl :-
        ; unchanged: the state after "8C 80 09 00" (sub 9 ends with 82)
        jsr Z_A4D6
        .byte $8C, $82, $00
        ldx #0
        lda D9F_A24B+7
        ldy D9F_A24B+10
        jsr smadd
        sta ZV_A691
        lda D9F_A24B+8
        ldy D9F_A24B+11
        jsr smadd
        sta ZV_A691+1
        rts
@chg:   ldx #23                 ; old back in, new aside
:       lda D9F_A23F,x
        pha
        lda oldp,x
        sta D9F_A23F,x
        pla
        sta oldp,x
        dex
        bpl :-
        jsr Z_A4D6
        STREAM_A373             ; XOR old needles away
        ldx #23
:       lda oldp,x
        sta D9F_A23F,x
        dex
        bpl :-
        jsr Z_A4D6
        STREAM_A394             ; XOR new needles
        rts
; A = coordinate, Y = sign-magnitude delta -> A + delta
smadd:  sta tmpd
        tya
        bmi :+
        clc
        adc tmpd
        rts
:       and #$7F
        eor #$FF
        sec
        adc tmpd
        rts
a36f_set:
        ldx #<D9F_A23F
        ldy #>D9F_A23F
        stx ixp
        sty ixp+1
        ldx #$64
        stx zb
        jsr a399
        lda ZV_E968
        bne :+
        lda #1
:       ldx #<D9F_A24B
        ldy #>D9F_A24B
        stx ixp
        sty ixp+1
        ldx #$3C
        stx zb
        jmp a399
oldp:   .res 24

; SA399: A = index, B (zb) = x base, IX (zix) = patch point (Oric address)
        ZPROC $A399
        ldx zixl
        stx ixp
        ldx zixh
        stx ixp+1
a399:   ldx #$FF                ; d
        stx tmpd
        ldx #0                  ; e
        cmp #7
        bcc :+
        cmp #$0C
        bcs :+
        stx tmpd
        inx
:       stx tmpe
        asl
        asl
        tax
        lda T_A3D6,x
        ldy #4
        sta (ixp),y
        ldy #10
        sta (ixp),y
        lda T_A3D6+1,x
        ldy #5
        sta (ixp),y
        ldy #11
        sta (ixp),y
        lda T_A3D6+2,x
        clc
        adc zb
        ldy #1
        sta (ixp),y
        clc
        adc tmpe
        ldy #7
        sta (ixp),y
        lda T_A3D6+3,x
        clc
        adc #$60
        ldy #2
        sta (ixp),y
        clc
        adc tmpd
        ldy #8
        sta (ixp),y
        rts
tmpd:   .byte 0
tmpe:   .byte 0

; ===========================================================================
; LA41E: fuel / temperature gauges (D9494 temp, D9495 fuel); IX = 75E1 on exit
        ZPROC $A41E
        jsr Z_A4D6
        STREAM_A421             ; erase old needles, redraw the faces
        ldx #<D9F_A259
        ldy #>D9F_A259
        stx ixp
        sty ixp+1
        lda #$AD
        sta zb
        lda ZV_9494
        jsr a457
        ldx #<D9F_A25F
        ldy #>D9F_A25F
        stx ixp
        sty ixp+1
        lda #$51
        sta zb
        lda ZV_9495
        jsr a457
        jsr Z_A4D6
        STREAM_A44E             ; new needles
        lda #$E1
        sta zixl
        lda #$75
        sta zixh
        rts

; SA457: A = value 0..11, B (zb) = pivot x, IX (zix) = patch point
        ZPROC $A457
        ldx zixl
        stx ixp
        ldx zixh
        stx ixp+1
a457:   ldx #0
        cmp #6
        bcc :+
        eor #$FF
        clc
        adc #12                 ; 11 - A
        inc zb
        ldx #$80
:       stx tmpe
        asl
        tax
        lda zb
        ldy #1
        sta (ixp),y
        lda T_A47B,x
        eor tmpe
        ldy #4
        sta (ixp),y
        lda T_A47B+1,x
        ldy #5
        sta (ixp),y
        rts

; ===========================================================================
; turn indicator lamps (IY = 7792 -> flags at 7793)
        ZPROC $A487             ; indicator off
        lda $7793
        and #$FB
        sta $7793
        lda ZV_5A24
        eor ZV_5A39
        bne Z_A49B
        rts
        ZPROC $A496             ; flash (every other pass)
        lda $75F8
        lsr
        bcs Z_A49B
        rts
        ZPROC $A49B
        ldx #1
        lda $7793
        and #8
        bne :+
        dex
:       lda ZV_5A24,x           ; ZV_5A24 / ZV_5A39 are adjacent
        eor #$40
        sta ZV_5A24,x
        sta tmpa
        and #$40
        cmp lampshow,x
        beq @tick
        sta lampshow,x
        lda lamptab,x
        sta lzs
        lda lamptab+2,x
        sta lzs+1
        ldy #0
@p:     lda (lzs),y
        sta lzd
        iny
        lda (lzs),y
        beq @tick
        sta lzd+1
        iny
        lda (lzs),y
        iny
        sty mp
        ldy #0
        eor (lzd),y
        sta (lzd),y
        ldy mp
        bne @p
@tick:  lda tmpa
        lsr
        lsr
        lsr
        and #$0F
        clc
        adc #4
        tax
        lda #$20                ; SA95F sets the beeper delay N
        sta ZV_A969
        lda #SND_TICK
        jmp snd_fx
lamptab:.byte <T_LAMPL, <T_LAMPR, >T_LAMPL, >T_LAMPR

; ===========================================================================
; message line (Spectrum char row 23 -> Oric text row 1)
; BA56: temporary message, timer A (IX = 75E1)
        ZPROC $BA56
        tax
        lda $760E
        ora #4
        sta $760E
        stx $760F
        jmp Z_BA72
; BA5F: temporary message with number HL, beep
        ZPROC $BA5F
        lda zl
        sta ZV_A4C3
        lda zh
        sta ZV_A4C3+1
        lda $760E
        ora #4
        sta $760E
        lda #$28
        sta $760F
; BA6A: beep (SA97C 02 01 64 02 3C), then BA72
        ZPROC $BA6A
        lda #$20                ; SA97C sets the beeper delay N
        sta ZV_A969
        lda #SND_BEEP
        jsr snd_fx
; BA72: clear the message line and print the inline message C, N, items
        ZPROC $BA72
        ldx #31
        lda #$20
:       sta TEXTROW1+4,x
        dex
        bpl :-
        jsr Z_A8DB
        jsr Z_A89B
        pla
        sta mp
        pla
        sta mp+1
        jsr mget
        sta zc
        lda #$B8
        sta zb
        jsr Z_A526
        jsr mget
        sta zb                  ; item count
@it:    jsr mget
        cmp #$C0
        bcs @num
        jsr Z_A955
@n:     dec zb
        bne @it
        inc mp
        bne :+
        inc mp+1
:       jmp (mp)
@num:   jsr mget
        sta ze
        jsr mget
        pha
        lda ZV_A4C3
        sta zl
        lda ZV_A4C3+1
        sta zh
        pla
        jsr Z_A911
        jmp @n
mget:   inc mp
        bne :+
        inc mp+1
:       ldy #0
        lda (mp),y
        rts

; BAB8: main loop, message timer expired
        ZPROC $BAB8
        lda $760E
        and #4
        bne :+
        rts
:       lda $760E
        and #$FB
        sta $760E
; LBAC1: redraw the status message ("<CITY> MAP" or "<DIR> VIEW")
        ZPROC $BAC1
        lda $7610
        lsr
        bcc bac1_view
        jsr Z_BA72
        .byte $40, $10
        ZLABEL $BACC, 16        ; city name, patched at init (FDAD)
        .byte " WELLINGTON MAP "
        rts
bac1_view:  lda $75F0
        and #3
        clc
        adc #$81
        sta ZV_BB02
        sta ZV_BB0D
        lda $7504
        ora $7505
        and #$E0
        beq bac1_v
        sta tmpa
        lda $75F0
        lsr
        bcc :+
        ora #$80
:       lsr
        bcc :+
        ora #$80
:       eor tmpa
        bpl bac1_exit
bac1_v:     jsr Z_BA72
        .byte $58, $05
        ZLABEL $BB02, 1
        .byte $00, "VIEW"
        rts
bac1_exit:  jsr Z_BA6A
        .byte $40, $0A
        ZLABEL $BB0D, 1
        .byte $00, "EXIT ROAD"
        rts

; BB18: redraw the status line unless a temporary message is up
        ZPROC $BB18
        lda $760E
        and #4
        beq Z_BAC1
        rts
