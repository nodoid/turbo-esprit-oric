; snd.s - AY-3-8912 sound engine, driven from the 50Hz interrupt (hw.s).
;
; Replaces the Spectrum's beeper code: the music player E441/E69C (tunes
; E6D8-E832) and the effects S3-S11 of the R8 catalogue.  Nothing here
; blocks: the main code only sets variables (with interrupts masked) and
; snd_tick, called from the IRQ, writes the AY.
;
; Channels:  A = music voice 0 (ch0 of the original player)
;            B = music voice 1, or the current effect when voice 1 is idle
;            C = engine drone (an addition), or the effect while voice 1 plays
;
; The music: tools/gen_snd.py re-runs the original bytecode frame by frame
; and stores each voice as a run list (note, frames) with back references
; (data/snd_data.s).  On the Spectrum the two voices took turns on the beeper
; (one frame each); here both sound at once, each note starting on the frame
; it started in the original.  A software envelope replaces the beeper's
; constant square wave.  music_busy stays non-zero for exactly as long as the
; original tune ran.
;
; The AY is only written from snd_tick (inside the IRQ), so it never
; disturbs the keyboard scan (register 14 / port A), which runs with
; interrupts masked; the mixer always keeps port A as an output (bit 6).

        .include "hw.inc"
        .include "snd.inc"

        .export snd_tick
        .import ay_reg, ay_val
        .importzp frames

        .include "snd_data.s"

; ---------------------------------------------------------------------------
        .zeropage
music_busy: .res 1              ; != 0 while a tune plays
vptr:   .res 4                  ; voice 0/1 run-list pointers (index X = 0/2)
fxptr:  .res 2                  ; current effect script step
stmp:   .res 2

; Initialised data, so the engine is sane before the first call (the zero
; page is not loaded; `inited` guards music_busy).
        .data
inited: .byte 0
; per-voice state, indexed by X = 0 (voice 0) / 2 (voice 1)
von:    .byte 0,0,0             ; voice active
vleft:  .byte 0,0,0             ; frames left in the current run (0 = fetch)
vnote:  .byte 0,0,0             ; note index, bit 7 = this frame is the gap
vage:   .byte 0,0,0             ; frames since the attack
vref:   .byte 0,0,0             ; runs left in a back reference
vret:   .byte 0,0,0,0           ; list position after the reference
fxon:   .byte 0                 ; priority of the running effect, 0 = none
fxcnt:  .byte 0                 ; frames played of the current step
fxram:  .byte 0,0,$FF           ; one-step script for the computed effects
eng_on: .byte 0
eng_tlo: .byte 0                ; engine period
eng_thi: .byte 0
; AY register images: computed this frame / last written
reg:    .byte 0,0,0,0,0,0,0,$78,0,0,0
wr:     .byte $FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF

        .rodata
env:    .byte 14,13,12,12,11,11,10,10   ; volume by frames since the attack
chbit:  .byte 1,2,4

        .code

chk_init:
        lda inited
        bne @ok
        sta music_busy
        inc inited
@ok:    rts

; ---------------------------------------------------------------------------
; music_start: A = tune id (TUNE_MENU_A, TUNE_MENU_B, TUNE_START).
; Preserves X and Y.
music_start:
        php
        sei
        sty stmp
        pha
        jsr chk_init
        pla
        asl
        asl
        tay
        lda #0
        sta vleft
        sta vleft+2
        sta vref
        sta vref+2
        lda #1
        sta von
        sta von+2
        sta music_busy
        stx stmp+1
        ldx #0
@p:     lda snd_tunes,y
        sta vptr,x
        iny
        inx
        cpx #4
        bne @p
        ldx stmp+1
        ldy stmp
        plp
        rts

; music_stop: silence the music (the voices go quiet on the next tick).
music_stop:
        php
        sei
        jsr chk_init
        lda #0
        sta von
        sta von+2
        sta music_busy
        plp
        rts

; snd_engine: A = revs (0 = off).  Period = 31250 / (25 + 4*revs),
; i.e. f = 50 + 8*revs Hz.  Preserves Y.
snd_engine:
        php
        sei
        tax
        beq @off
        asl
        asl
        adc #25
        sta stmp+1              ; divisor
        lda #<31250
        sta eng_tlo
        lda #>31250
        sta eng_thi
        lda #0
        ldx #16
@d:     asl eng_tlo
        rol eng_thi
        rol
        bcs @s
        cmp stmp+1
        bcc @n
@s:     sbc stmp+1
        inc eng_tlo
@n:     dex
        bne @d
        ldx #1
@off:   stx eng_on
        plp
        rts

; snd_fx: A = effect id (SND_xxx), X = parameter.  Preserves X and Y.
; A running effect is only replaced by one of equal or higher priority.
snd_fx:
        php
        sei
        sty stmp+1
        sta stmp
        jsr chk_init
        ldy stmp
        lda fx_prio-1,y
        ldy fxon
        beq @go
        cmp fxon
        bcc @done               ; lower priority than the running one: dropped
@go:    sta fxon
        lda #0
        sta fxcnt
        lda stmp
        cmp #SND_CRASH
        beq @crash
        cmp #SND_REV
        beq @rev
        cmp #SND_TICK
        beq @tick
        asl
        tay
        lda fx_tab-1,y
        sta fxptr+1
        lda fx_tab-2,y
        sta fxptr
        bne @done
@set:   sta fxptr
        sty fxptr+1
@done:  ldy stmp+1
        plp
        rts
@crash: ldy #0                  ; B = 5 gunshot, 10 crash/bump/bang, 20 struck
        cpx #8
        bcc @c1
        ldy #2
        cpx #15
        bcc @c1
        ldy #4
@c1:    lda fx_crashtab,y
        pha
        lda fx_crashtab+1,y
        tay
        pla
        jmp @set
@rev:   ; S4: half-period 96C+47 T -> AY period ~ 3C + C/2 - C/16 + 2
        txa
        lsr
        lsr
        lsr
        lsr
        sta stmp
        txa
        lsr
        clc
        adc #2
        sec
        sbc stmp
        sta stmp
        txa
        asl
        adc stmp
        stx stmp
        clc
        adc stmp
        sta fxram+1
        lda #9
        bne @one
@tick:  ; S8: half-period 434C+47 T -> AY period ~ 15C + C/2 + 2
        stx stmp
        txa
        asl
        asl
        asl
        asl
        sec
        sbc stmp
        sta fxram+1
        txa
        lsr
        clc
        adc #2
        clc
        adc fxram+1
        sta fxram+1
        lda #10
@one:   sta fxram
        lda #<fxram
        ldy #>fxram
        bne @set

; ---------------------------------------------------------------------------
; snd_tick: one 50Hz frame (called from the IRQ; uses A, X, Y).
snd_tick:
        jsr chk_init
        lda #$78                ; mixer: tones on, noise off, port A output
        sta reg+7
        ldx #0
        jsr voice
        ldx #2
        jsr voice

        ; --- engine drone on C
        lda #0
        ldx eng_on
        beq @eng
        lda eng_tlo
        sta reg+4
        lda eng_thi
        sta reg+5
        lda frames              ; a gentle 25Hz throb
        and #1
        eor #5
@eng:   sta reg+10

        ; --- effect on B (voice 1 idle) or C
        lda fxon
        beq @write
        ldy #0
        lda (fxptr),y
        cmp #$FF
        bne @fx
        sty fxon                ; script ended
        beq @write
@fx:    sta stmp
        ldx #1                  ; X = channel 1 (B) or 2 (C)
        ldy von+2
        beq @ch
        inx
@ch:    and #$0F
        sta reg+8,x
        txa
        asl
        tay
        sty stmp+1
        ldy #1
        lda (fxptr),y
        ldy stmp+1
        sta reg,y
        lda #0
        sta reg+1,y
        bit stmp
        bvc @tone
        lda reg+7               ; tone off
        ora chbit,x
        sta reg+7
@tone:  bit stmp
        bpl @nonz
        lda chbit,x             ; noise on
        asl
        asl
        asl
        eor #$FF
        and reg+7
        sta reg+7
        ldy #2
        lda (fxptr),y
        sta reg+6
@nonz:  lda stmp                ; hold the step for 1 + bits 4-5 frames
        lsr
        lsr
        lsr
        lsr
        and #3
        cmp fxcnt
        beq @adv
        inc fxcnt
        bne @write
@adv:   lda #0
        sta fxcnt
        lda stmp
        asl                     ; C = noise byte present
        lda #2
        adc fxptr
        sta fxptr
        bcc @write
        inc fxptr+1

        ; --- write the registers that changed
@write: ldx #10
@w:     lda reg,x
        cmp wr,x
        beq @n
        sta wr,x
        txa
        jsr ay_reg
        lda reg,x
        jsr ay_val
@n:     dex
        bpl @w
        rts

; getb: next byte of voice X's list
getb:   lda (vptr,x)
        inc vptr,x
        bne @r
        inc vptr+1,x
@r:     rts

; voice: advance music voice X (0 or 2) by one frame and set its registers.
voice:
        lda von,x
        bne @act
        jmp @mute
@act:   lda vleft,x
        bne @play
        jsr getb                ; next run
        cmp #$FE
        bcc @run
        beq @ref
        jmp @end
@ref:
        jsr getb                ; $FE lo hi n: n runs from lo hi
        pha
        jsr getb
        pha
        jsr getb
        sta vref,x
        lda vptr,x
        sta vret,x
        lda vptr+1,x
        sta vret+1,x
        pla
        sta vptr+1,x
        pla
        sta vptr,x
        jsr getb
@run:   ldy #8                  ; +$40: an 8-frame run
        cmp #$C0
        bcs @r8
        cmp #$40
        bcc @rl
        cmp #$80
        bcs @rl
@r8:    eor #$40
        sta vnote,x
        tya
        bne @rs
@rl:    sta vnote,x
        jsr getb
@rs:    sta vleft,x
        lda #0
        sta vage,x
        lda vref,x
        beq @play
        dec vref,x
        bne @play
        lda vret,x
        sta vptr,x
        lda vret+1,x
        sta vptr+1,x
@play:  dec vleft,x
        lda vnote,x
        bmi @gap
        beq @mute
        tay
        lda snd_ptab,y
        sta reg,x
        cpy #2                  ; period high byte: 1 for note index 1 only
        lda #0
        adc #0
        eor #1
        sta reg+1,x
        ldy vage,x
        cpy #7
        bcc @e
        ldy #7
@e:     inc vage,x
        lda env,y
        pha
        txa
        lsr
        tay
        pla
        sta reg+8,y
        rts
@gap:   and #$7F                ; silent first frame, the note starts next frame
        sta vnote,x
        bpl @mute
@end:   lda #0                  ; $FF: end of this voice's list
        sta von,x
        cpx #0
        bne @mute
        sta von+2               ; voice 0 ended: the tune is over
        sta music_busy
@mute:  txa
        lsr
        tay
        lda #0
        sta reg+8,y
        rts
