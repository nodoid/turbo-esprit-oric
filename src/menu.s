; menu.s - program entry, city select, main menu and its options, score and
; penalty tables, key input helpers (Spectrum F757-FD5F + the city table).
;
; Translated from the original (R8 sections 5-7).  The screens are drawn by
; the graphics engine (Z_A4C9 inline streams, kept byte for byte), the music
; and beeps come from snd.s (non-blocking AY).  Oric-specific changes:
;  * keys: the Oric matrix is read with key_row (hw.s); the key table at
;    $7524 holds Oric codes (row, column mask, 0); the Kempston joystick
;    option of ALTER PLAYING KEYS is dropped.
;  * the flashing cursor (Spectrum FLASH attribute) is an inverse-video block
;    that blinks at the Spectrum's flash rate (16 frames).
;  * SAVE/LOAD SCORE TABLES: no tape I/O on the Oric version (the game owns
;    the machine and the Atmos ROM's tape code conflicts with the 50Hz IRQ
;    and the zero page); both options end in the original's ERROR path.
;  * the music plays from the interrupt; it is stopped where the original
;    stopped calling the player (key definition, save/load, game start).

        .include "zx.inc"
        .include "snd.inc"
        .include "hw.inc"

        .import key_row
        .importzp frames

        ZIMPORT $A4C9           ; text/graphics stream engine (inline stream)
        ZIMPORT $A526           ; set text cursor: zc = x, zb = y
        ZIMPORT $A695           ; print character/token A
        ZIMPORT $728D           ; program initialisation (lead)
        ZIMPORT $7347           ; play a game: A = lives char, zc = skill char
        ZVIMPORT $9282          ; city block (0x153 bytes, world)
        ZVIMPORT $BACC          ; 16-char city map title (gfx)
        ZVIMPORT $9560          ; random seed (world)
        .import gfx_cls         ; CLS: A = Spectrum attribute (SA8EB)
        .import gfx_attr_rows   ; A = attribute, X = first char row, Y = rows
        .import gfx_recolour    ; A = attribute, X/Y = first/last char column,
        .import gfx_rc_row, gfx_rc_n ;  over Spectrum pixel rows rc_row, rc_n

        .zeropage
mp:     .res 2                  ; general pointer
mq:     .res 2                  ; second pointer
inp:    .res 2                  ; INPUT_LINE buffer pointer

        .data
held:   .byte 0                 ; DE6A7: a key was down when the wait started
cur_x:  .byte 0                 ; text cursor as set by set_cursor/print_char
cur_y:  .byte 0
in_max: .byte 0
in_left: .byte 0
sv_x:   .byte 0
sv_y:   .byte 0
mcnt:   .byte 0
mtmp:   .byte 0
body:   .byte 0
ki:     .byte 0                 ; ALTER KEYS: key number 0..6
ky:     .byte 0                 ; ALTER KEYS: print y
kn0:    .byte 0                 ; key name chars
kn1:    .byte 0
krow:   .byte 0
kmask:  .byte 0
dF7F7:  .word 0                 ; insert: entry 1 of the table (temp)
dFB98:  .byte 0                 ; tape header byte
; flashing cursor
fl_on:  .byte 0                 ; cursor active
fl_vis: .byte 0                 ; currently inverted
fl_t0:  .byte 0
fl_x:   .byte 0
fl_y:   .byte 0
fl_n:   .byte 0                 ; cells
fl_b0:  .byte 0
fl_b1:  .byte 0
fl_l:   .byte 0

; ---------------------------------------------------------------------------
; F756-F7F6: display work byte + the SCORE and PENALTY tables (160 bytes,
; 8 entries x 10: name(7) skill(1) value(2); entry 0 = LAST).
        ZLABEL $F756, 1
        .byte 0
        ZLABEL $F757, 160
tables:
        .byte " LAST  ",'1',1,0
        .repeat 7
        .byte "DURELL ",'1',1,0
        .endrepeat
        .byte " LAST  ",'1',1,0
        .repeat 7
        .byte "DURELL ",'1',1,0
        .endrepeat
        .res 10                 ; "entry 8" read (never kept) by the insert
SCORE1  = tables+10
PEN1    = tables+90

        .code

; ===========================================================================
; FD11 - program entry (RANDOMIZE USR 64785): city select
ZPROC $FD11
        lda frames              ; FRAMES -> random seed
        sta ZV_9560
        GET_R
        sta ZV_9560+1
        jsr Z_728D
        ldx #20                 ; default keys J L K A S M T, Oric codes
@kd:    lda keys_def,x          ; (the Spectrum table in the RAM image
        sta $7524,x             ; holds Spectrum port/mask codes)
        dex
        bpl @kd
        jsr Z_A4C9
        .byte $8F,$20,$41,$FF,$50,$18,"SELECT A CITY",$FF,$48,$40,"1",$FE,$20
        .byte "WELLINGTON",$FF,$48,$50,"2",$FE,$20,"GAMESBOROUGH",$FF,$48,$60
        .byte "3",$FE,$20,"ROMFORD",$FF,$48,$70,"4",$FE,$20,"MINSTER"
        .byte $FF,$50,$98,"ENTER 1 TO 4",$00
ZPROC $FD7C
        jsr new_key             ; LAST-K: a newly pressed key
        sec
        sbc #'1'
        bcc Z_FD7C
        cmp #4
        bcs Z_FD7C
        jsr Z_FD91
        ldx #$FF                ; SP = 0x7300
        txs
        jmp Z_FA1B

; FD91 - A = city 0..3: copy its 0x153-byte block to D9282 and its title
; to DBACC.
ZPROC $FD91
        asl
        tax
        lda city_data,x
        sta mp
        lda city_data+1,x
        sta mp+1
        lda city_title,x
        sta mq
        lda city_title+1,x
        sta mq+1
        ldy #0
@c1:    lda (mp),y
        sta ZV_9282,y
        iny
        bne @c1
        inc mp+1
@c2:    lda (mp),y
        sta ZV_9282+256,y
        iny
        cpy #$53
        bne @c2
        ldy #15
@c3:    lda (mq),y
        sta ZV_BACC,y
        dey
        bpl @c3
        rts

        .rodata
keys_def: .byte 1,$01,0, 7,$02,0, 3,$01,0, 6,$20,0, 6,$40,0, 2,$01,0, 1,$02,0
city_data:  .addr $686B, $69BE, $6B11, $6C64
city_title: .addr ct1, ct2, ct3, ct4
ct1:    .byte " WELLINGTON MAP "
ct2:    .byte "GAMESBOROUGH MAP"
ct3:    .byte "   ROMFORD MAP  "
ct4:    .byte "   MINSTER MAP  "
        .code

; ===========================================================================
; F9FD - start a random menu tune (R & 4 picks tune A or B)
ZPROC $F9FD
        GET_R
        and #4
        lsr
        lsr
        jmp music_start

; FA1B - main menu with a new tune; FA1E without restarting the music
ZPROC $FA1B
        jsr Z_F9FD
ZPROC $FA1E
        jsr Z_A4C9
        .byte $8F,$30,$3D,$FF,$28,$08,$8F,"MENU *",$FF,$28,$20,"1",$FE,$20
        .byte $8D,$91," ("
        ZLABEL $FA38, 1
        .byte "1"
        .byte ")",$FF,$28,$30,"2",$FE,$20,$8D,$8E,$97,$93,"S",$FF,$28,$40
        .byte "3",$FE,$20,$95,$8B,$94,$FF,$28,$50,"4",$FE,$20,$95," ",$8C,$94
        .byte $FF,$28,$60,"5",$FE,$20,"SAVE",$8B,$94,"S",$FF,$28,$70,"6",$FE,$20
        .byte "LOAD",$8B,$94,"S",$FF,$28,$80,"7",$FE,$20,$96,$FF,$28,$90,"8",$FE
        .byte $20,$8E,$FF,$48,$A8,"ENTER 1 TO 8",$00
ZPROC $FA90
        jsr Z_F9C4
        sec
        sbc #'1'
        bcc Z_FA90
        cmp #8
        bcs Z_FA90
        tax
        lda #>(Z_FA1B-1)        ; push FA1B: the options return to the menu
        pha
        lda #<(Z_FA1B-1)
        pha
        lda opt_hi,x
        pha
        lda opt_lo,x
        pha
        rts

        .rodata
opt_lo: .lobytes Z_FB23-1, Z_FBD6-1, Z_F85D-1, Z_F84E-1, Z_FB99-1, Z_FB51-1, Z_FB19-1, Z_FABC-1
opt_hi: .hibytes Z_FB23-1, Z_FBD6-1, Z_F85D-1, Z_F84E-1, Z_FB99-1, Z_FB51-1, Z_FB19-1, Z_FABC-1
        .code

; ---------------------------------------------------------------------------
; 7 PRACTICE: no enemy cars, 1 life, skill 1, not recorded
ZPROC $FB19
        lda #0
        sta $7611
        lda #'1'
        sta zc
        jsr music_stop
        lda #'1'
        jmp Z_7347

; 8 PLAY, then record the result (FACA)
ZPROC $FABC
        lda #$FF
        sta $7611
        lda ZV_FA38
        sta zc
        jsr music_stop
        lda #'4'
        jsr Z_7347
ZPROC $FACA
        lda ZV_FA38
        sta tables+7            ; F75E, F7AE: skill of the LAST entries
        sta tables+87
        lda #0
        sta tables+8            ; F75F, F7AF = 0
        sta tables+9
        sta tables+88
        sta tables+89
        sec                     ; HL = SCORE - PENALTY
        lda $750B
        sbc $750D
        sta zl
        lda $750C
        sbc $750E
        sta zh
        bcc @neg
        lda zl
        sta tables+8
        lda zh
        sta tables+9
        lda #<SCORE1
        sta zixl
        lda #>SCORE1
        sta zixh
        jsr Z_F7F9
        bcc @hs
        rts                     ; not a high score: back to FA1B
@hs:    pla                     ; drop the FA1B return
        pla
        jsr Z_F9FD
        jsr Z_F85D              ; (does not return: ends at FA1E)
@neg:   sec                     ; HL = -net
        lda #0
        sbc zl
        sta zl
        sta tables+88
        lda #0
        sbc zh
        sta zh
        sta tables+89
        lda #<PEN1
        sta zixl
        lda #>PEN1
        sta zixh
        jsr Z_F7F9
        bcc @hp
        rts
@hp:    pla
        pla
        jsr Z_F9FD
        jsr Z_F84E

; ---------------------------------------------------------------------------
; F7F9 - insert HL (zl/zh) into the table whose entry 1 is at IX (zix).
; C = not a high score.  Otherwise the new entry gets name 0x80 x 7 (to be
; entered), the skill digit and the value; NC.
ZPROC $F7F9
        lda zixl
        sta dF7F7
        sta mp
        lda zixh
        sta dF7F7+1
        sta mp+1
        ldy #8
        lda zl
        cmp (mp),y
        iny
        lda zh
        sbc (mp),y
        bcs @ok
        sec                     ; HL < entry1: C (not a high score)
        rts
@ok:    ldx #7
@find:  ldy #8
        lda zl
        cmp (mp),y
        iny
        lda zh
        sbc (mp),y
        bcc @brk
        clc
        lda mp
        adc #10
        sta mp
        bcc @n
        inc mp+1
@n:     dex
        bne @find
@brk:   sec                     ; slot = IX - 10
        lda mp
        sbc #10
        sta mp
        bcs @s
        dec mp+1
@s:     stx mtmp                ; count = (7-b)*10
        lda #7
        sec
        sbc mtmp
        beq @nocopy
        sta mtmp
        asl
        asl
        adc mtmp
        asl
        sta mcnt
        lda dF7F7               ; LDIR entry2.. -> entry1..
        sta mq
        clc
        adc #10
        sta inp
        lda dF7F7+1
        sta mq+1
        adc #0
        sta inp+1
        ldy #0
@cp:    lda (inp),y
        sta (mq),y
        iny
        cpy mcnt
        bne @cp
@nocopy:
        ldy #0
        lda #$80
@nm:    sta (mp),y
        iny
        cpy #7
        bne @nm
        lda ZV_FA38
        sta (mp),y
        iny
        lda zl
        sta (mp),y
        iny
        lda zh
        sta (mp),y
        clc
        rts

; ---------------------------------------------------------------------------
; F84E / F85D - show the PENALTY / SCORE table, then back to FA1E
ZPROC $F84E
        lda #<(tables+150)      ; F7ED: penalty entry 7
        ldx #>(tables+150)
        ldy #$8C
        sty mtmp
        ldy #$0F                ; body attribute
        sty body
        ldy #$20                ; header attribute
        bne tab_show
ZPROC $F85D
        lda #<(tables+70)       ; F79D: score entry 7
        ldx #>(tables+70)
        ldy #$8B
        sty mtmp
        ldy #$20
        sty body
        ldy #$0F
tab_show:
        jsr Z_F867
        pla                     ; drop the return to FA1B
        pla
        jmp Z_FA1E

; F867 - A/X = entry 7, mtmp = title token, body = body attribute,
; Y = header attribute.
ZPROC $F867
        sta mp
        stx mp+1
        lda mtmp
        sta hdr_tok1
        sta hdr_tok2
        sty hdr_attr
        jsr Z_A4C9
        .byte $8F
hdr_attr:
        .byte $00,$09,$FF,$08,$10,$8F
hdr_tok1:
        .byte $8B,$94,$20,$2A,$FF,$30,$28,$90,$FE,$18,$91,$20
hdr_tok2:
        .byte $8B,$00
        lda #$07                ; attributes: char rows 4-17 = 07
        ldx #4
        ldy #14
        jsr gfx_attr_rows
        lda #6*8                ; 9 rows x 24 cells from row 6, col 4 = body
        sta gfx_rc_row
        lda #9*8
        sta gfx_rc_n
        lda body
        ldx #4
        ldy #27
        jsr gfx_recolour
        lda #$38
t_row:  sta ZV_F756
        sta zb
        lda #$30
        sta zc
        jsr set_cursor
        ldy #0
        lda (mp),y
        bpl @named
        jsr Z_F910              ; enter the name here
@named: ldy #6
@cn:    lda (mp),y
        sta row_name,y
        dey
        bpl @cn
        ldy #7
        lda (mp),y
        sta row_skill
        iny
        lda (mp),y
        sta zl
        iny
        lda (mp),y
        sta zh
        jsr Z_A4C9
        .byte $09
row_name:
        .byte "AAAAAAA",$FE,$18
row_skill:
        .byte "1",$FE,$18,$FC,$00,$A0,"0",$00
        sec
        lda mp
        sbc #10
        sta mp
        bcs t_p
        dec mp+1
t_p:    lda ZV_F756
        clc
        adc #8
        cmp #$78
        bcc t_row
ZPROC $F8F5
        jsr Z_A4C9
        .byte $02,$FF,$50,$98,$98,$93,$00
; F8FF - wait for a newly pressed key, with menu music (tunes restart)
ZPROC $F8FF
        jsr anykey
        sta held
@l:     lda music_busy
        bne @m
        jsr Z_F9FD
@m:     jsr wait_frame
        jsr anykey
        beq @up
        lda held
        bne @l
        rts
@up:    sta held
        beq @l

; F90B - new tune, then wait for a key
ZPROC $F90B
        jsr Z_F9FD
        jmp Z_F8FF

; ---------------------------------------------------------------------------
; F910 - enter a 7-char name at (mp) at the current cursor; the cursor is
; restored afterwards.  Preserves mp.
ZPROC $F910
        lda mp
        pha
        lda mp+1
        pha
        lda cur_x
        sta sv_x
        lda cur_y
        sta sv_y
        lda mp
        sta zl
        lda mp+1
        sta zh
        lda #7
        sta zb
        jsr Z_F938
        lda sv_x
        sta zc
        lda sv_y
        sta zb
        jsr set_cursor
        pla
        sta mp+1
        pla
        sta mp
        rts

; F938 - INPUT_LINE: zl/zh = buffer, zb = length.  Flashing cursor; printable
; keys are stored and printed, DELETE removes the last one, ENTER pads the
; rest of the buffer with spaces and returns.
ZPROC $F938
        lda zl
        sta inp
        lda zh
        sta inp+1
        lda zb
        sta in_max
        sta in_left
@loop:  lda #1
        jsr cursor_on
@get:   jsr Z_F9C4
        cmp #$80
        bcs @del
        cmp #$20
        bcc @ctl
        pha
        jsr cursor_off
        pla
        ldx in_left
        beq @loop               ; full: ignored
        dec in_left
        ldy #0
        sta (inp),y
        inc inp
        bne @pr
        inc inp+1
@pr:    jsr print_char
        jmp @loop
@ctl:   cmp #$0D
        bne @get
        jsr cursor_off
        ldx in_left
        beq @ret
        lda #' '
        ldy #0
@pad:   sta (inp),y
        iny
        dex
        bne @pad
@ret:   rts
@del:   bne @get                ; only 0x80 (DELETE)
        jsr cursor_off
        lda in_left
        cmp in_max
        beq @loop               ; nothing typed yet
        lda inp
        bne @d1
        dec inp+1
@d1:    dec inp
        inc in_left
        jsr Z_F98F
        lda #' '
        jsr print_char
        jsr Z_F98F
        jmp @loop

; F98F - text cursor back one character
ZPROC $F98F
        lda cur_x
        sec
        sbc #8
        sta zc
        lda cur_y
        sta zb
        jmp set_cursor

; ---------------------------------------------------------------------------
; F99F - read the keyboard like ROM KEY-SCAN + the 0205 table.
; C = 1: no key down.  C = 0: A = ASCII (A-Z, 0-9, space, 0x0D ENTER,
; 0x80 DELETE), or A = 0 (Z) when only keys without a character are down
; (shift, control, arrows, punctuation: ignored like CAPS SHIFT alone).
; Unlike the Spectrum, a character key held with SHIFT still counts.
ZPROC $F99F
        lda #0
        sta mtmp                ; a key was seen
        ldx #7
@r:     jsr key_row
        cmp #0                  ; (key_row's flags are not its result)
        beq @nx
        sta mcnt
        inc mtmp
        txa
        asl
        asl
        asl
        tay
@c:     lsr mcnt
        bcc @nc
        lda asc_tab,y
        bne @got
@nc:    iny
        lda mcnt
        bne @c
@nx:    dex
        bpl @r
        lda mtmp
        beq @none
        lda #0
@got:   clc
        rts
@none:  sec
        rts

; F9C4 - GET_KEY_MUSIC: wait for a newly pressed character key while the
; menu music plays (a new random tune starts when one ends).  A = ASCII.
ZPROC $F9C4
        jsr anykey
        sta held
@l:     lda music_busy
        bne @m
        jsr Z_F9FD
@m:     jsr wait_frame
        jsr blink
        jsr Z_F99F
        bcc @key
        lda #0
        sta held
        beq @l
@key:   beq @l                  ; no character: ignored
        ldx held
        bne @l                  ; still the key that was down on entry
        rts

; new_key - (city select, no music) wait for a newly pressed character key
new_key:
        jsr anykey
        sta held
@l:     jsr wait_frame
        jsr Z_F99F
        bcc @key
        lda #0
        sta held
        beq @l
@key:   beq @l
        ldx held
        bne @l
        rts

; F9F2 / F9F4 - delays (B=C=100: 38 ms = 2 frames; B=0: 0.25 s = 13 frames)
ZPROC $F9F2
        ldx #2
        bne delay
ZPROC $F9F4
        ldx #13
delay:  jsr wait_frame
        dex
        bne delay
        rts

; anykey: A != 0 (and Z clear) when any key is down.  (hw.s any_key only
; looks at row 7: key_row returns the caller's flags, not Z of A.)
anykey: ldx #7
@r:     jsr key_row
        cmp #0
        bne @y
        dex
        bpl @r
        lda #0
@y:     rts

wait_frame:
        lda frames
@w:     cmp frames
        beq @w
        rts

; ---------------------------------------------------------------------------
; 1 ALTER SKILL
ZPROC $FB23
        jsr Z_A4C9
        .byte $01,$FF,$A0,$A8,"4",$00
        jmp @in
@bad:   lda #SND_BADKEY         ; S10
        jsr snd_fx
@in:    lda #$B8
        sta zc
        lda #$20
        sta zb
        jsr set_cursor
        lda #<ZV_FA38
        sta zl
        lda #>ZV_FA38
        sta zh
        lda #1
        sta zb
        jsr Z_F938
        lda ZV_FA38
        sec
        sbc #'1'
        bcc @bad
        cmp #4
        bcs @bad
        pla
        pla
        jmp Z_FA1E

; ---------------------------------------------------------------------------
; 6 LOAD / 5 SAVE SCORE TABLES.  No tape on the Oric: the original's ERROR
; path (it was taken whenever the ROM tape routine failed).
ZPROC $FB51
        jsr music_stop
        lda #7
        jsr gfx_cls
        jmp tape_err
ZPROC $FB99
        lda #7
        jsr gfx_cls
        jsr Z_F8F5              ; PRESS ANY KEY (with music)
        jsr music_stop
        lda #7
        jsr gfx_cls
        jsr Z_F9F4              ; 0.25 s
ZPROC $FB77
tape_err:
        jsr Z_A4C9
        .byte $05,$FF,$68,$58,"ERROR",$00
        lda #SND_TAPEERR        ; S11, 0.24 s
        jsr snd_fx
        ldx #12
        jmp delay

; ---------------------------------------------------------------------------
; 2 ALTER PLAYING KEYS
ZPROC $FBD6
        jsr music_stop          ; the original's music stopped here
        jsr Z_A4C9
        .byte $8F,$28,$38,$FF,$38,$10,$8D,$8E,$97,$93,"S",$FF,$60,$28,"LEFT ",$FE,$18
        ZLABEL $FBFB, 2
        .byte "J "
        .byte $FF,$60,$38,"RIGHT",$FE,$18
        ZLABEL $FC07, 2
        .byte "L "
        .byte $FF,$60,$48,"FIRE ",$FE,$18
        ZLABEL $FC13, 2
        .byte "K "
        .byte $FF,$60,$58,"SLOW ",$FE,$18
        ZLABEL $FC1F, 2
        .byte "A "
        .byte $FF,$60,$68,"FAST ",$FE,$18
        ZLABEL $FC2B, 2
        .byte "S "
        .byte $FF,$60,$78,"MAP  ",$FE,$18
        ZLABEL $FC37, 2
        .byte "M "
        .byte $FF,$60,$88,"QUIT ",$FE,$18
        ZLABEL $FC43, 2
        .byte "T "
        .byte $FF,$50,$A0,$98,$93,$00
        lda #0
        sta ki
        lda #$28
        sta ky
@key:   lda #$A0
        sta zc
        lda ky
        sta zb
        jsr set_cursor
        lda #SND_KEYBLIP        ; S9
        jsr snd_fx
        lda #2
        jsr cursor_on
        jsr Z_FCA4
        ldx ki                  ; name into the text
        lda kname_lo,x
        sta mq
        lda kname_hi,x
        sta mq+1
        ldy #0
        lda kn0
        sta (mq),y
        iny
        lda kn1
        sta (mq),y
        txa                     ; table entry: row, column mask, 0
        asl
        adc ki
        tax
        lda krow
        sta $7524,x
        lda kmask
        sta $7525,x
        lda #0
        sta $7526,x
        jsr cursor_off
        lda kn0
        jsr print_char
        lda kn1
        jsr print_char
        lda ky
        clc
        adc #16
        sta ky
        inc ki
        lda ki
        cmp #7
        bne @key
        pla                     ; drop the FA1B return
        pla
        jsr Z_F90B
        jmp Z_FA1E

        .rodata
kname_lo: .lobytes ZV_FBFB, ZV_FC07, ZV_FC13, ZV_FC1F, ZV_FC2B, ZV_FC37, ZV_FC43
kname_hi: .hibytes ZV_FBFB, ZV_FC07, ZV_FC13, ZV_FC1F, ZV_FC2B, ZV_FC37, ZV_FC43
        .code

; FCA4 - wait for a key to define: all keys released, 38 ms, then the first
; key found (rows 0..7, columns 0..7).  Returns krow, kmask and the 2-char
; name kn0/kn1.
ZPROC $FCA4
@rel:   jsr wait_frame
        jsr blink
        jsr anykey
        bne @rel
        jsr Z_F9F2
@scan:  jsr wait_frame
        jsr blink
        ldx #0
@r:     jsr key_row
        cmp #0
        bne @found
@nr:    inx
        cpx #8
        bne @r
        beq @scan
@found: sta mcnt
        stx krow
        txa
        asl
        asl
        asl
        sta mtmp
        lda #1
@c:     bit mcnt
        bne @col
@nc:    inc mtmp
        asl
        bne @c
        beq @nr
@col:   sta kmask
        lda mtmp                ; name: 2 bytes per key
        asl
        tay
        lda kname_tab,y
        beq @skip
        sta kn0
        lda kname_tab+1,y
        sta kn1
        rts
@skip:  lda kmask               ; a matrix position without a key
        bne @nc

; ---------------------------------------------------------------------------
; helpers

; set_cursor: zc = x, zb = y (Spectrum pixels), remembered for the cursor
set_cursor:
        lda zc
        sta cur_x
        lda zb
        sta cur_y
        jmp Z_A526

print_char:
        jsr Z_A695
        lda cur_x
        clc
        adc #8
        sta cur_x
        rts

; Flashing cursor (the Spectrum FLASH bit on 1 or 2 cells at the text
; cursor): the cells' screen bytes are shown in inverse video, toggled every
; 16 frames while waiting for keys.  A = number of cells.
cursor_on:
        sta fl_n
        lda cur_x
        sta fl_x
        lda cur_y
        sta fl_y
        lda frames
        sta fl_t0
        lda #1
        sta fl_on
        lda #0
        sta fl_vis
        jmp inv_toggle
cursor_off:
        lda fl_on
        beq @r
        lda #0
        sta fl_on
        lda fl_vis
        bne inv_toggle
@r:     rts
blink:
        lda fl_on
        beq @r
        lda frames
        sec
        sbc fl_t0
        and #16
        cmp #16                 ; C = 1: off phase
        lda fl_vis
        bcs @off
        beq inv_toggle
@r:     rts
@off:   bne inv_toggle
        rts

; inv_toggle: invert the screen bytes covering fl_n cells at (fl_x, fl_y):
; Oric lines y+4..y+11, byte columns (x+6)/6 .. (x+6+8n-1)/6.
inv_toggle:
        lda fl_vis
        eor #1
        sta fl_vis
        lda fl_x
        clc
        adc #6
        jsr div6
        sta fl_b0
        lda fl_n
        asl
        asl
        asl
        adc #5
        adc fl_x
        jsr div6
        sta fl_b1
        lda fl_y
        clc
        adc #4
        sta fl_l
        lda #8
        sta mcnt
@line:  lda fl_l                ; mq = HIRES + line*40
        sta mq
        lda #0
        sta mq+1
        asl mq                  ; *8
        rol mq+1
        asl mq
        rol mq+1
        asl mq
        rol mq+1
        lda mq
        ldx mq+1
        asl mq                  ; *32
        rol mq+1
        asl mq
        rol mq+1
        clc
        adc mq
        sta mq
        txa
        adc mq+1
        adc #>HIRES
        sta mq+1
        ldy fl_b0
@b:     lda (mq),y
        and #$40
        beq @attr               ; never touch an attribute byte
        lda (mq),y
        eor #$80
        sta (mq),y
@attr:  cpy fl_b1
        iny
        bcc @b
        inc fl_l
        dec mcnt
        bne @line
        rts

; div6: A = A / 6 (A < 256)
div6:   ldx #0
        sec
@d:     sbc #6
        bcc @e
        inx
        bcs @d
@e:     txa
        rts

        .rodata
; Oric matrix -> ASCII for text input (0 = no character)
asc_tab:
        .byte "7N5V",0,"1X3"
        .byte "JTRF",0,0,"QD"
        .byte "M6B4",0,"Z2C"
        .byte "K9",0,0,0,0,0,0
        .byte " ",0,0,0,0,0,0,0
        .byte "UIOP",0,$80,0,0
        .byte "YHGE",0,"ASW"
        .byte "8L0",0,0,$0D,0,0
; Oric matrix -> 2-char key name for ALTER PLAYING KEYS (0 = no key)
kname_tab:
        .byte "7 N 5 V CT1 X 3 "
        .byte "J T R F ",0,0,"ESQ D "
        .byte "M 6 B 4 CTZ 2 C "
        .byte "K 9 ; - ",0,0,0,0,"\ ' "
        .byte "SP, . UPLSLTDNRT"
        .byte "U I O P FNDL] [ "
        .byte "Y H G E ",0,0,"A S W "
        .byte "8 L 0 / RSEN",0,0,"= "
