; main.s - start-up, the main game step and the game/life flow
; (Spectrum 0x7300-0x74F4).
;
; Turbo Esprit (c) 1986 Durell Software, by Mike Richardson.
; Oric Atmos conversion.

        .include "hw.inc"
        .include "zx.inc"
        .include "snd.inc"
        .include "disk.inc"

        .import hw_init, view_init, gfx_textinit, gfx_squeeze
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
        .import __HIBSS_START__
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
        sta __HIBSS_START__+$000,x      ; ($9C00-$9DCD is loaded data)
        sta __HIBSS_START__+$100,x
        sta __HIBSS_START__+$132,x
        inx
        bne @z
        ldx #0
@p2:    sta $0200,x
        sta $0180,x             ; (overlaps; $0180-$02FF cleared)
        inx
        bne @p2
        jsr hw_init
        ; the tables at $9C00 (beyond the Oric font at $9900, which the
        ; program file must not overwrite) come from the disk
        lda #HID_TRACK
        sta D_TRK
        lda #1
        sta D_SEC
        lda #2
        sta D_CNT
        lda #<$9C00
        sta D_DEST
        lda #>$9C00
        sta D_DEST+1
        jsr DREAD
        ; HIRES, the three text lines below it blank (black); the character
        ; set at $9800 is part of the program file
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
        lda #1                  ; menus/copyright: 32 columns squeezed to fit
        sta gfx_squeeze
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
        ldx #0                  ; the game draws with the exact mapping
        stx gfx_squeeze
        jsr Z_7347
        jsr menu_load
        lda #1                  ; (gfx_squeeze needs the menu blob in memory)
        sta gfx_squeeze
        rts

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
        jsr view_init           ; A-pillar next to the 3D view (Oric screen)
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
; S728D: the original showed two legal/copyright pages here (and a loading
; screen came first); the Oric version starts straight at the city select.
Z_728D:
        rts

        .bss
dtmp:   .res 1
dc:     .res 1
