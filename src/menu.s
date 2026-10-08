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
;
; The menu never runs at the same time as the game code, so it keeps its
; zero-page temporaries in the Z80 alternate register set (see below).

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

; zero-page temporaries (Z80 alternate set; nothing else is live in menus)
held    = za                    ; DE6A7: a key was down when the wait started
fl_on   = zf                    ; flashing cursor active (cleared by FD11)
nomus   = za2                   ; bit 7: key wait without music (city select)
cur_x   = zc2                   ; text cursor as set by set_cursor/print_char
cur_y   = zb2
mtmp    = zd2
mcnt    = ze2
mp      = zl2                   ; pointer (zl2/zh2)
mq      = ziyl                  ; pointer (ziyl/ziyh)

        .bss                    ; (all written before use)
in_max: .res 1
in_pos: .res 1
body:   .res 1
toff:   .res 1                  ; table display: offset of the current entry
ki:     .res 1                  ; ALTER KEYS: key number 0..6
ky:     .res 1                  ; ALTER KEYS: print y
kn0:    .res 1                  ; key name
kn1:    .res 1
krow:   .res 1
kmask:  .res 1
e1:     .res 2                  ; insert: entry 1 (DF7F7), IX at the slot
fl_vis: .res 1                  ; cursor shown
fl_t0:  .res 1

; ---------------------------------------------------------------------------
; F756-F7F6: display work byte + the SCORE and PENALTY tables (160 bytes,
; 8 entries x 10: name(7) skill(1) value(2); entry 0 = LAST).
; (in HIBSS: filled with the original's initial contents by FD11)
        .segment "HIBSS"
        ZVAR $F756, 1
        ZLABEL $F757, 160
tables: .res 160
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
        ldx #$FF                ; (the default key table J L K A S M T, in
        stx nomus               ; Oric codes, is in the RAM image at $7524)
        inx
        stx fl_on
        ldy #159                ; tables: 16 x "DURELL ",'1',1,0 ...
@ti:    ldx #9
@te:    lda tab_init,x
        sta tables,y
        dey
        dex
        bpl @te
        cpy #$FF
        bne @ti
        ldx #6                  ; ... entries 0 = " LAST  "
@tl:    lda last_txt,x
        sta tables,x
        sta tables+80,x
        dex
        bpl @tl
        jsr Z_A4C9
city_txt:
        .byte $8F,$20,$41,$FF,$50,$18,"SELECT A CITY",$FF,$48,$40,"1",$FE,$20
cn1:    .byte "WELLINGTON",$FF,$48,$50,"2",$FE,$20
cn2:    .byte "GAMESBOROUGH",$FF,$48,$60,"3",$FE,$20
cn3:    .byte "ROMFORD",$FF,$48,$70,"4",$FE,$20
cn4:    .byte "MINSTER",$FF,$50,$98,"ENTER 1 TO 4",$00
ZPROC $FD7C
        ldx #4                  ; LAST-K: a newly pressed '1'..'4'
        jsr pick
        jsr Z_FD91
        ldx #$FF                ; SP = 0x7300
        txs
        jmp Z_FA1B

; FD91 - A = city 0..3: copy its 0x153-byte block to D9282 and its title
; ("<name> MAP", placed as in the original table FDCB) to DBACC.
ZPROC $FD91
        tax
        lda city_hi,x
        sta mp+1
        lda city_lo,x
        sta mp
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
        lda #' '
@sp:    sta ZV_BACC,y
        dey
        bpl @sp
        ldy city_lead,x
        lda city_name,x
        tax
@cn:    lda city_txt,x
        bmi @map
        sta ZV_BACC,y
        inx
        iny
        bne @cn
@map:   ldx #0
@m:     lda map_txt,x
        sta ZV_BACC+1,y
        iny
        inx
        cpx #3
        bne @m
        rts

        .rodata
tab_init: .byte "DURELL ",'1',1,0
last_txt: .byte " LAST  "
city_lo: .lobytes $686B, $69BE, $6B11, $6C64
city_hi: .hibytes $686B, $69BE, $6B11, $6C64
city_name: .byte cn1-city_txt, cn2-city_txt, cn3-city_txt, cn4-city_txt
city_lead: .byte 1, 0, 3, 3
map_txt: .byte "MAP"
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
        lda #0                  ; with music
        sta nomus
        ldx #8
        jsr pick
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

; FACA: LAST entries get the skill and 0; SCORE-PENALTY >= 0 goes into the
; SCORE table, else -(SCORE-PENALTY) into the PENALTY table.
ZPROC $FACA
        lda ZV_FA38
        sta tables+7            ; F75E, F7AE
        sta tables+87
        ldx #0
        sec                     ; HL = SCORE - PENALTY
        lda $750B
        sbc $750D
        sta zl
        lda $750C
        sbc $750E
        sta zh
        bcs @pos
        txa                     ; HL = -HL (X = 0)
        sbc zl                  ; (C = 0: 0 - zl - 1, fixed below)
        sta zl
        txa
        sbc zh
        sta zh
        inc zl
        bne @n1
        inc zh
@n1:    ldx #80
@pos:   txa                     ; the other LAST value = 0
        eor #80
        tay
        lda #0
        sta tables+8,y
        sta tables+9,y
        lda zl
        sta tables+8,x
        lda zh
        sta tables+9,x
        txa
        pha
        clc
        adc #10
        tax
        jsr ins_x
        pla
        bcs @r                  ; not a high score: back to FA1B
        tax
        jsr Z_F9FD              ; (keeps X)
        txa
        bne @pen
        jmp Z_F85D              ; (drops the FA1B return, ends at FA1E)
@pen:   jmp Z_F84E
@r:     rts

; ---------------------------------------------------------------------------
; F7F9 - insert HL (zl/zh) into the table whose entry 1 is at IX (zix).
; C = not a high score.  Otherwise the new entry gets name 0x80 x 7 (to be
; entered), the skill digit and the value; NC.
ZPROC $F7F9
        lda zixl                ; X = offset of entry 1 in `tables`
        sec
        sbc #<tables
        tax
ins_x:  stx e1
        jsr cmpx
        bcs @ok
        sec                     ; HL < entry1: C (not a high score)
        rts
@ok:    ldy #7
@find:  jsr cmpx
        bcc @brk
        txa                     ; next entry (C = 1: +10)
        adc #9
        tax
        dey
        bne @find
@brk:   stx e1+1                ; LDIR entry2.. -> entry1.., (IX-entry1) bytes
        ldy e1
@cp:    cpy e1+1
        bcs @fill
        lda tables+10,y
        sta tables,y
        iny
        bne @cp
@fill:  txa                     ; slot = IX - 10
        sbc #10                 ; (C = 1)
        tax
        ldy #7
        lda #$80
@nm:    sta tables,x
        inx
        dey
        bne @nm
        lda ZV_FA38
        sta tables,x
        lda zl
        sta tables+1,x
        lda zh
        sta tables+2,x
        clc
        rts

; cmpx: C = HL >= value of the entry at tables+X
cmpx:   lda zl
        cmp tables+8,x
        lda zh
        sbc tables+9,x
        rts

; ---------------------------------------------------------------------------
; F84E / F85D - show the PENALTY / SCORE table, then back to FA1E
ZPROC $F84E
        ldx #1
        .byte $2C               ; (bit abs: skips the ldx)
ZPROC $F85D
        ldx #0
        lda tab_e7,x
        sta toff
        lda tab_tok,x
        sta mtmp
        lda tab_body,x
        sta body
        ldy tab_body+1,x        ; header attribute = the other body attribute
        jsr Z_F867
        pla                     ; drop the return to FA1B
        pla
        jmp Z_FA1E

        .rodata
tab_e7:  .byte 70, 150                         ; F79D / F7ED: entry 7
tab_tok: .byte $8B, $8C                         ; " SCORE" / "PENALTY"
tab_body: .byte $20, $0F, $20                   ; body attr (header: next)
        .code

; F867 - toff = offset of entry 7 in `tables`, mtmp = title token, body = body attribute,
; Y = header attribute.
ZPROC $F867
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
        tay
        ldx #$30
        jsr cursor_xy
        ldx toff
        lda tables,x
        bpl @named
        jsr Z_F910              ; enter the name here
        ldx toff
@named: ldy #0
@cn:    lda tables,x
        sta row_name,y
        inx
        iny
        cpy #7
        bne @cn
        lda tables,x
        sta row_skill
        lda tables+1,x
        sta zl
        lda tables+2,x
        sta zh
        jsr Z_A4C9
        .byte $09
row_name:
        .byte "AAAAAAA",$FE,$18
row_skill:
        .byte "1",$FE,$18,$FC,$00,$A0,"0",$00
        lda toff                ; previous entry
        sec
        sbc #10
        sta toff
        lda ZV_F756
        clc
        adc #8
        cmp #$78
        bcc t_row
ZPROC $F8F5
        jsr Z_A4C9
        .byte $02,$FF,$50,$98,$98,$93,$00
; F8FF - wait for a newly pressed key (any key), with menu music
ZPROC $F8FF
        lda #$40                ; any key, with music
        sta nomus
        jmp getkey

; F90B - new tune, then wait for a key
ZPROC $F90B
        jsr Z_F9FD
        jmp Z_F8FF

; ---------------------------------------------------------------------------
; F910 - enter a 7-char name at tables+toff at the current cursor; the
; cursor is restored afterwards.
ZPROC $F910
        lda cur_x
        pha
        lda cur_y
        pha
        lda toff
        clc
        adc #<tables
        sta zl
        lda #>tables
        adc #0
        sta zh
        lda #7
        sta zb
        jsr Z_F938
        pla
        tay
        pla
        tax
        jmp cursor_xy

; F938 - INPUT_LINE: zl/zh = buffer, zb = length.  Flashing cursor; printable
; keys are stored and printed, DELETE removes the last one, ENTER pads the
; rest of the buffer with spaces and returns.
ZPROC $F938
        lda zb
        sta in_max
        lda #0
        sta in_pos
@loop:  lda #1
        jsr cursor_on
        jsr Z_F9C4
        pha
        jsr cursor_off
        pla
        ldy in_pos
        cmp #$0D
        beq @enter
        cmp #$80
        beq @del
        cmp #$20
        bcc @loop               ; other control keys: ignored
        cpy in_max
        bcs @loop               ; full: ignored
        sta (zl),y
        inc in_pos
        jsr print_char
        jmp @loop
@del:   tya
        beq @loop               ; nothing typed yet
        dec in_pos
        jsr Z_F98F
        lda #' '
        jsr print_char
        jsr Z_F98F
        jmp @loop
@enter: lda #' '                ; pad the rest with spaces
@pad:   cpy in_max
        bcs @ret
        sta (zl),y
        iny
        bne @pad
@ret:   rts

; F98F - text cursor back one character
ZPROC $F98F
        lda cur_x
        sec
        sbc #8
        tax
        ldy cur_y
        ; fall through
; cursor_xy: text cursor to X = x, Y = y (Spectrum pixels), remembered
cursor_xy:
        stx cur_x
        stx zc
        sty cur_y
        sty zb
        jmp Z_A526

print_char:
        jsr Z_A695
        lda cur_x
        clc
        adc #8
        sta cur_x
        rts

; ---------------------------------------------------------------------------
; F99F - read the keyboard like ROM KEY-SCAN + the 0205 table.
; C = 1: no key down.  C = 0: A = ASCII (letters, digits, punctuation,
; space, 0x0D ENTER, 0x80 DELETE), or A = 0 (Z) when only keys without a
; character are down (shift, control, arrows...: ignored like CAPS SHIFT
; alone).  Unlike the Spectrum, a character key held with SHIFT counts.
ZPROC $F99F
        lda #$80                ; character keys only
        jsr scan
        bcc @f
        jsr anykey
        beq @none
        lda #0                  ; only keys without a character
        clc
        rts
@none:  sec
        rts
@f:     bpl @r                  ; a character
        and #3                  ; SP EN DL
        tay
        lda asc2,y
        clc
@r:     rts

; scan: first key down (rows 0-7, columns 0-7) that has a name (A = 0) or
; a character (A = $80).  C = 0: Y = row*8+column, A = its kname_tab entry
; (N flag set from it).  C = 1: none.
scan:   sta mtmp
        ldx #0
@r:     jsr key_row
        sta mcnt
        txa
        asl
        asl
        asl
        tay
@c:     lsr mcnt
        bcc @n
        lda kname_tab,y
        beq @n
        bit mtmp
        bpl @ok
        cmp #$83
        bcc @ok
@n:     iny
        lda mcnt
        bne @c
        inx
        cpx #8
        bne @r
        sec
        rts
@ok:    clc
        tax                     ; (N flag of the entry)
        rts

; F9C4 - GET_KEY_MUSIC: wait for a newly pressed character key while the
; menu music plays (a new random tune starts when one ends).  A = ASCII.
ZPROC $F9C4
        lda #0
        sta nomus
getkey: jsr anykey
        sta held
@l:     jsr music_wait
        jsr blink
        jsr Z_F99F
        bcc @key
        lda #0
        sta held
        beq @l
@key:   bit nomus
        bvs @any
        tax
        beq @l                  ; no character: ignored
@any:   ldx held
        bne @l                  ; still the key that was down on entry
        rts

; pick: wait for a key '1'..'0'+X -> A = 0..X-1 (nomus: music or not)
pick:   stx in_max
@l:     jsr getkey
        sec
        sbc #'1'
        cmp in_max
        bcs @l
        rts

; music_wait: restart the menu music if it ended (unless nomus), then wait
; for the next frame
music_wait:
        bit nomus
        bmi wait_frame
        lda music_busy
        bne wait_frame
        jsr Z_F9FD
wait_frame:
        lda frames
@w:     cmp frames
        beq @w
        rts

; F9F2 / F9F4 - delays (B=C=100: 38 ms = 2 frames; B=0: 0.25 s = 13 frames).
; Use A and X.
ZPROC $F9F2
        ldx #2
        .byte $2C
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

; ---------------------------------------------------------------------------
; 1 ALTER SKILL
ZPROC $FB23
        jsr Z_A4C9
        .byte $01,$FF,$A0,$A8,"4",$00
@in:    ldx #$B8
        ldy #$20
        jsr cursor_xy
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
        cmp #4
        bcc @ok
        lda #SND_BADKEY         ; S10
        jsr snd_fx
        jmp @in
@ok:    pla
        pla
        jmp Z_FA1E

; ---------------------------------------------------------------------------
; 6 LOAD / 5 SAVE SCORE TABLES.  No tape on the Oric: the original's ERROR
; path (it was taken whenever the ROM tape routine failed).
ZPROC $FB99
        lda #7
        jsr gfx_cls
        jsr Z_F8F5              ; PRESS ANY KEY (with music)
        jsr music_stop
        jsr Z_F9F4              ; 0.25 s
ZPROC $FB51
        jsr music_stop
tape_cls:
        lda #7
        jsr gfx_cls
ZPROC $FB77
        jsr Z_A4C9
        .byte $05,$FF,$68,$58,"ERROR",$00
        lda #SND_TAPEERR        ; S11, 0.24 s
        jsr snd_fx
        ldx #12
        bne delay

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
@key:   ldx #$A0
        ldy ky
        jsr cursor_xy
        lda #SND_KEYBLIP        ; S9
        jsr snd_fx
        lda #2
        jsr cursor_on
        jsr Z_FCA4
        lda ki                  ; name into the text: FBFB + 12*i
        asl
        adc ki
        tax                     ; X = 3*i (table entry)
        asl
        asl
        tay                     ; Y = 12*i
        lda kn0
        sta ZV_FBFB,y
        lda kn1
        sta ZV_FBFB+1,y
        lda krow                ; table entry: row, column mask, 0
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
        lda #0
        jsr scan
        bcs @scan
        tax
        tya
        lsr
        lsr
        lsr
        sta krow
        tya
        and #7
        tay
        lda #0
        sec
@m:     rol
        dey
        bpl @m
        sta kmask
        txa
        ldx #' '
        cmp #$80
        bcc @one
        asl
        tay
        lda names2,y
        ldx names2+1,y
@one:   sta kn0
        stx kn1
        rts

; ---------------------------------------------------------------------------
; Flashing cursor (the Spectrum FLASH bit on 1 or 2 cells at the text
; cursor): the engine XOR-prints solid blocks (custom-font glyph $18) over
; the cells, i.e. swaps their ink and paper like FLASH; toggled every 16
; frames while waiting for keys.  A = number of cells.
cursor_on:
        sta fl_n
        lsr                     ; second block, or (1 cell) a harmless
        lda #$82                ; MODE OR command in its place
        bcs @one
        lda #$18
@one:   sta fl_b2
        lda cur_x
        sta fl_x
        lda cur_y
        sta fl_y
        lda frames
        sta fl_t0
        lda #1
        sta fl_on
        lsr
        sta fl_vis
        beq inv_toggle
cursor_off:
        lda fl_on
        beq rts1
        lsr fl_on               ; (1 -> 0)
        lda fl_vis
        bne inv_toggle
rts1:   rts
blink:  lda fl_on
        beq rts1
        lda frames
        sec
        sbc fl_t0
        and #16                 ; on for 16 frames, off for 16
        lsr
        lsr
        lsr
        lsr
        eor #1
        cmp fl_vis
        beq rts1
inv_toggle:
        lda fl_vis
        eor #1
        sta fl_vis
        jsr Z_A4C9
        .byte $84,$8D           ; XOR mode, custom font
fl_n:   .byte 1,$FF
fl_x:   .byte 0
fl_y:   .byte 0,$18
fl_b2:  .byte $18,$8D,$83,$00   ; ROM font, overwrite mode
        ldx cur_x               ; the engine's text cursor back
        ldy cur_y
        jmp cursor_xy

        .rodata
; Oric matrix -> key name: a character (shown with a space after it), $80+i
; = 2-letter name i of names2, 0 = no key.  Also the text input table: the
; characters, and SP EN DL -> ' ', ENTER, DELETE.
kname_tab:
        .byte "7N5V",$83,"1X3"
        .byte "JTRF",0,$84,"QD"
        .byte "M6B4",$83,"Z2C"
        .byte "K9;-",0,0,"\'"
        .byte $80,",.",$85,$86,$87,$88,$89
        .byte "UIOP",$8A,$82,"]["
        .byte "YHGE",0,"ASW"
        .byte "8L0/",$8B,$81,0,"="
names2: .byte "SPENDLCTESUPLSLTDNRTFNRS"
asc2:   .byte ' ', $0D, $80
