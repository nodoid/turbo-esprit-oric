; main.s - start-up, the main game step and the game/life flow
; (Spectrum 0x7300-0x74F4).
;
; Turbo Esprit (c) 1986 Durell Software, by Mike Richardson.
; Oric Atmos conversion.

        .include "hw.inc"
        .include "zx.inc"
        .include "snd.inc"
        .include "disk.inc"

        .import hw_init, view_init, any_key, gfx_cls, gfx_textinit
        ZIMPORT $A526
        ZIMPORT $A695
        .importzp frames

        ; routines translated in other modules
        ZIMPORT $FD11           ; entry: legal screens, city select, menus
        ZIMPORT $EAE2           ; player controls / physics
        ZIMPORT $F6E3           ; hazard check
        ZIMPORT $DDF4           ; drug-car missions
        ZIMPORT $7BBE           ; road renderer
        ZIMPORT $E0FF           ; map view
        ZIMPORT $876F           ; sky / building colours
        ZIMPORT $881F           ; objects
        ZIMPORT $E96A           ; accelerator / gearbox
        ZIMPORT $E0AA           ; M key
        ZIMPORT $862E           ; view -> screen
        ZIMPORT $8F23           ; pedestrians
        ZIMPORT $AB47           ; traffic
        ZIMPORT $8EE2           ; traffic lights
        ZIMPORT $BAB8           ; status line
        ZIMPORT $93D5           ; engine temperature / fuel (main-step tail)
        ZIMPORT $9E1E           ; dashboard
        ZIMPORT $E01D           ; mission set-up
        ZIMPORT $A0B1           ; steering wheel back to straight
        ZIMPORT $A36F           ; speed/rev needles
        ZIMPORT $94E5           ; engine reset
        ZIMPORT $E0C0           ; leave map view
        ZIMPORT $E0F2           ; fill the view colours
        ZIMPORT $E0F1
        ZIMPORT $A4C9           ; text/graphics engine
        ZIMPORT $BA5F           ; status-line message
        ZIMPORT $DA80
        ZIMPORT $DC5F
        ZIMPORT $9907           ; rebuild the lane grid
        ZIMPORT $F2FE
        ZIMPORT $F2D1
        ZIMPORT $F37A           ; key test (hw.s)
        ZVIMPORT $9282          ; current city map (+$140 = start column)
        ZVIMPORT $A093          ; steering-wheel animation flag
        ZVIMPORT $E965          ; accelerator table pointer
        ZVIMPORT $E967          ; speed / revs
        .import T_EAB5          ; gear table

        .export Z_728D
        .import __MENU_START__, __MENU_LAST__

        .segment "STARTUP"
start:  sei
        cld
        ldx #$7F                ; stack $0100-$017F; $0180-$02FF holds data
        txs
        ; clear zero page and the BSS areas
        lda #0
        tax
@z:     sta $00,x
        sta $0400,x
        sta $9C00,x
        sta $9D00,x
        sta $9E00,x
        sta $9F00,x
        inx
        bne @z
        ldx #0
@p2:    sta $0200,x
        sta $0180,x             ; (overlaps; $0180-$02FF cleared)
        inx
        bne @p2
        jsr hw_init
        ; HIRES, the three text lines below it blank (black)
        ldx #7
@sp:    sta CHARSET + $20*8,x   ; space glyph
        dex
        bpl @sp
        ldx #119
        lda #$20
@t:     sta TEXTLINES,x
        dex
        bpl @t
        lda #$10
        sta TEXTLINES
        sta TEXTLINES+40
        sta TEXTLINES+80
        lda #$1E
        sta MODEREG
        cli
        jsr gfx_textinit
        jsr view_init
        jsr menu_load
        jmp Z_FD11

        .code
; menu_load: (re)load the menu blob (menus, score tables, copyright screen;
; linked to run at $5C00 in RAM the game uses while playing) from the disk
menu_load:
        lda #MENU_TRACK
        sta D_TRK
        lda #1
        sta D_SEC
        lda #>(__MENU_LAST__ - __MENU_START__ + 255)
        sta D_CNT
        lda #<__MENU_START__
        sta D_DEST
        lda #>__MENU_START__
        sta D_DEST+1
        jmp DREAD

; play_game: the menu's PLAY/PRACTICE.  A, zc as for S7347.  The game
; overwrites the menu blob, so it is loaded again before returning into it.
        .export play_game
play_game:
        jsr Z_7347
        jmp menu_load

        .code

; ---------------------------------------------------------------------------
; D7300: one game step
        ZPROC $7300
        jsr Z_EAE2
        jsr Z_F6E3
        jsr Z_DDF4
        jsr Z_7BBE
        lda $7610
        lsr a
        bcc @3d
        jsr Z_E0FF
        jmp @both
@3d:    jsr Z_876F
        jsr Z_881F
        lda $7793
        and #2
        bne @both
        jsr Z_E96A
@both:  jsr Z_E0AA
        jsr Z_862E
        jsr Z_8F23
        jsr Z_AB47
        inc $75F8
        dec $75F9
        bne @l
        jsr Z_8EE2
@l:     dec $760F
        bne @m
        jsr Z_BAB8
@m:     jmp Z_93D5

; ---------------------------------------------------------------------------
; S7347: start a game.  A = lives character, zc = skill character.
; Returns when the game is over.
        ZPROC $7347
        sta $73FF
        lda zc
        sta $73F3
        sec
        sbc #'1'
        asl a
        asl a
        tax
        ldy #0
@sk:    lda $7514,x
        sta $7510,y
        inx
        iny
        cpy #4
        bne @sk
        lda #$F0
        sta $7508
        lda ZV_9282 + ($93C2 - $9282)
        sta $7504
        lda #0
        sta $7505
        sta $75F0
        sta $760E
        lda #$32
        sta $7798
        lda #$80
        sta $7793
        jsr Z_9E1E
        jsr Z_E01D
        lda #0
        sta $750B
        sta $750C
        sta $750D
        sta $750E
        jsr Z_8EE2
        ; fall into the start of a life

; L7392: start of every life
L7392:  lda ZV_A093
        beq @nw
        jsr Z_A0B1
@nw:    lda #<(T_EAB5 + 8)
        sta ZV_E965
        lda #>(T_EAB5 + 8)
        sta ZV_E965+1
        lda #0
        sta ZV_E967
        lda #1
        sta ZV_E967+1
        lda #0
        jsr Z_A36F
        jsr Z_94E5
        lda $7610
        lsr a
        bcc @nm
        jsr Z_E0C0
@nm:    lda #$0F                ; flash the view: white on blue ...
        ldx #8
        stx zc
        jsr Z_E0F2
        jsr Z_862E
        lda #$38                ; ... then black on white
        ldx #8
        stx zc
        jsr Z_E0F2
        jsr Z_862E
        lda #$38
        jsr Z_E0F1
        ; "DRIVING PRACTICE" or "SKILL - n / LIVES - n": the print programs
        ; stay where the original had them ($73DA / $73EB, with the skill and
        ; lives digits at $73F3 / $73FF); the engine returns to the 6502 jump
        ; placed after each of them ($73E6 / $7401).
        lda #$4C                ; JMP L7401
        sta $73E6
        sta $7401
        lda #<L7401
        sta $73E7
        sta $7402
        lda #>L7401
        sta $73E8
        sta $7403
        lda $7611
        bne @play
        lda #>($73DA - 1)
        pha
        lda #<($73DA - 1)
        pha
        jmp Z_A4C9
@play:  lda #>($73EB - 1)
        pha
        lda #<($73EB - 1)
        pha
        jmp Z_A4C9

L7401:  lda #TUNE_START         ; start jingle; wait for it to finish
        jsr music_start
@w:     lda music_busy
        bne @w
        ; drug-car records (3 x 10 bytes at $785E)
        ldx #0
@dr:    lda $785E,x
        sta dc
        and #$40
        beq @d1
        lda $785E,x             ; finished: mark removed
        ora #$80
        sta $785E,x
        jmp @dn
@d1:    lda dc
        bmi @dn
        and #4
        beq @dn
        stx dtmp
        txa
        clc
        adc #<$785E
        sta zixl
        lda #>$785E
        adc #0
        sta zixh
        jsr Z_DA80
        jsr Z_DC5F
        ldx dtmp
        lda dc
        and #$FB
        ora #$08
        sta $785E,x
@dn:    txa
        clc
        adc #10
        tax
        cpx #30
        bne @dr
        ; deactivate the pedestrians and the traffic cars
        lda $770F
        and #$7F
        sta $770F
        lda $771B
        and #$7F
        sta $771B
        lda $7727
        and #$7F
        sta $7727
        ldx #0
@cars:  lda $779F,x
        and #$7F
        sta $779F,x
        txa
        clc
        adc #12
        tax
        cpx #16*12
        bne @cars
        lda $75FD
        bpl @nf
        lda #5
        sta $75F1
@nf:    jsr Z_9907
        lda #<$7792
        sta ziyl
        lda #>$7792
        sta ziyh
        jsr Z_F2FE
        sta $74D9
        ldx #11
@pc:    lda $74D3,x
        sta $7792,x
        dex
        bpl @pc
        jsr Z_F2D1
        lda $760E
        and #4
        sta $760E
        lda #0
        sta $760B

; L748D: the main loop
L748D:  jsr Z_7300
        jsr Z_74DF
        bne L74A8
        lda $760E
        and #8
        bne @crash
        lda #<$7536             ; T = give up this life
        sta zl
        lda #>$7536
        sta zh
        jsr Z_F37A
        bne L748D
        lda #1
        bne @lose
@crash: lda #10
@lose:  sta zb
        dec $73FF
        lda $73FF
        cmp #'0'
        beq L74A8
        jsr Z_74B8
        jmp L7392

L74A8:  jsr Z_BA5F
        .byte $60, $09, "GAME OVER"
        lda #$19
        sta zb
        ; fall into S74B8

; S74B8: run zb game steps
        ZPROC $74B8
@l:     lda zb
        pha
        jsr Z_7300
        pla
        sta zb
        dec zb
        bne @l
        rts

; S74DF: NZ when the game is over (PLAY: all three drug cars dealt with)
        ZPROC $74DF
        lda $7611
        beq @r
        lda #$C0
        and $785E
        beq @r
        lda #$C0
        and $7868
        beq @r
        lda #$C0
        and $7872
@r:     rts

; ---------------------------------------------------------------------------
        .segment "MCODE"
; S728D: the copyright screen shown at start-up.  The original printed two
; texts with the ROM's PR-STRING; the first (copyright notice) is shown here
; from the original data at $6DB7 (still in memory at this point): control
; codes AT/INK/PAPER/BRIGHT, CR, ROM-font characters and the UDG logo
; ($90-$9D, graphics at $71CD).  The second text (the 1986 cassette-forgery
; reward offer) is not shown.
LEGAL     = $6DB7
LEGAL_LEN = $0174
UDG       = $71CD
Z_728D:
        lda #$0F                ; white ink on blue paper
        jsr gfx_cls
        jsr Z_A4C9              ; text mode, screen, ROM font, overwrite
        .byte 0
        lda #0
        sta lcol
        sta lrow
        lda #<LEGAL
        sta zl2
        lda #>LEGAL
        sta zh2
        ldx #<LEGAL_LEN
        stx lcnt
        ldx #>LEGAL_LEN
        stx lcnt+1
@next:  lda lcnt
        ora lcnt+1
        beq @key
        jsr lget
        cmp #$16                ; AT row, col
        bne @n1
        jsr lget
        sta lrow
        jsr lget
        sta lcol
        jmp @next
@n1:    cmp #$10                ; INK / PAPER / BRIGHT n: colours fixed
        bcc @n2
        cmp #$14
        bcs @n2
        jsr lget
        jmp @next
@n2:    cmp #$0D                ; CR
        bne @n3
        lda #0
        sta lcol
        inc lrow
        jmp @next
@n3:    cmp #$90                ; UDG logo
        bcc @chr
        sec
        sbc #$90
        jsr udg
        jmp @adv
@chr:   pha
        jsr lpos
        pla
        jsr Z_A695
@adv:   inc lcol
        lda lcol
        cmp #32                 ; the ROM wraps lazily: col 32, then CR = 1 line
        bne @next
        lda #0
        sta lcol
        inc lrow
        ; a CR straight after a wrap only completes the wrap
        lda lcnt
        ora lcnt+1
        beq @key
        ldy #0
        lda (zl2),y
        cmp #$0D
        bne @next
        jsr lget
        jmp @next
@key:   jsr Z_A4C9              ; lower screen: "PRESS ANY KEY TO CONTINUE."
        .byte 26, $FF, 24, 184
        .byte "PRESS ANY KEY TO CONTINUE."
        .byte 0
@up:    jsr any_key             ; wait for all keys up, then a key
        bne @up
@dn:    jsr any_key
        beq @dn
@up2:   jsr any_key
        bne @up2
        rts

lget:   ldy #0
        lda (zl2),y
        inc zl2
        bne :+
        inc zh2
:       pha
        lda lcnt
        bne :+
        dec lcnt+1
:       dec lcnt
        pla
        rts

; lpos: print position = Spectrum (8*col, 8*row)
lpos:   lda lcol
        asl a
        asl a
        asl a
        sta zc
        lda lrow
        asl a
        asl a
        asl a
        sta zb
        jmp Z_A526

; udg: draw UDG A (0-13) at (lcol, lrow) straight onto the Oric screen
; (white ink pixels on the blue line set up by gfx_cls)
udg:    asl a
        asl a
        asl a
        adc #<UDG
        sta zl
        lda #>UDG
        adc #0
        sta zh
        lda #0
        sta urow
@row:   ldy urow
        lda (zl),y
        sta ubits
        ; Spectrum x of the first pixel, +6 for the Oric
        lda lcol
        asl a
        asl a
        asl a
        clc
        adc #6
        sta upx
        lda #8
        sta ucnt
@pix:   asl ubits
        bcc @skip
        ; Oric line = 8*row + urow + 4
        lda lrow
        asl a
        asl a
        asl a
        adc urow
        adc #4
        tax
        lda upx
        jsr gfx_setpix
@skip:  inc upx
        dec ucnt
        bne @pix
        inc urow
        lda urow
        cmp #8
        bne @row
        rts

; gfx_setpix: X = HIRES line, A = Oric pixel x -> set the pixel (ink)
gfx_setpix:
        ldy #0
@d:     cmp #6
        bcc @m
        sbc #6
        iny
        bne @d
@m:     sty ucol
        tay
        lda pixbit,y
        sta umask
        lda #0
        sta ve+1
        txa                     ; line * 40 = line*32 + line*8
        asl a
        rol ve+1
        asl a
        rol ve+1
        asl a
        rol ve+1
        sta ve
        lda ve+1
        sta vt2
        lda ve
        asl a
        rol vt2
        asl a
        rol vt2
        clc
        adc ve
        sta ve
        lda vt2
        adc ve+1
        adc #>HIRES
        sta ve+1
        ldy ucol
        lda (ve),y
        ora umask
        sta (ve),y
        rts
pixbit: .byte $20, $10, $08, $04, $02, $01

        .zeropage
ve:     .res 2
        .bss
lcol:   .res 1
lrow:   .res 1
lcnt:   .res 2
urow:   .res 1
ubits:  .res 1
upx:    .res 1
ucnt:   .res 1
ucol:   .res 1
umask:  .res 1
vt2:    .res 1
dtmp:   .res 1
dc:     .res 1
