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
; and stores each voice as a run list (data/snd_data.s).  On the Spectrum
; the two voices took turns on the beeper (one frame each); here both sound
; at once, each note starting on the frame it started in the original.  A
; simple software envelope (attack/decay/sustain + a softer last frame)
; replaces the beeper's constant square wave.  music_busy stays non-zero for
; exactly as long as the original tune ran.
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

; Everything else is initialised data so the engine is sane before the
; first call (the zero page is not loaded; `inited` guards music_busy).
        .data
inited: .byte 0
; per-voice state, indexed by X = 0 (voice 0) / 2 (voice 1)
von:    .byte 0,0,0             ; voice active
vleft:  .byte 0,0,0             ; frames left in the current run (0 = fetch)
vnote:  .byte 0,0,0             ; note index, bit 7 = this frame is the gap
vage:   .byte 0,0,0             ; frames since the attack
vlen:   .byte 0,0,0             ; length of the current run
fxon:   .byte 0                 ; priority of the running effect, 0 = none
fxram:  .byte 0,0,0,0,$FF       ; one-step script for the computed effects
eng_on: .byte 0
eng_tlo: .byte 0                ; engine target period
eng_thi: .byte 0
eng_lo: .byte 0                 ; engine current period (glides to the target)
eng_hi: .byte 0
; AY register images: computed this frame / last written
reg:    .byte 0,0,0,0,0,0,0,$78,0,0,0
wr:     .byte $FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF

        .rodata
; software volume envelope by frames since the attack
env:    .byte 14,13,12,12,11,11,10,10

        .code

chk_init:
        lda inited
        bne @ok
        lda #0
        sta music_busy
        lda #1
        sta inited
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
        lda snd_tunes,y
        sta vptr
        lda snd_tunes+1,y
        sta vptr+1
        lda snd_tunes+2,y
        sta vptr+2
        lda snd_tunes+3,y
        sta vptr+3
        lda #0
        sta vleft
        sta vleft+2
        sta vnote
        sta vnote+2
        lda #1
        sta von
        sta von+2
        sta music_busy
        ldy stmp
        plp
        rts

; music_stop: silence the music (the voices go quiet on the next tick).
music_stop:
        php
        sei
        lda #0
        sta von
        sta von+2
        sta music_busy
        lda #1
        sta inited
        plp
        rts

; snd_engine: A = revs (0 = off).  Preserves X and Y.
snd_engine:
        php
        sei
        sty stmp
        tay
        beq @off
        cpy #32
        bcc @r
        ldy #31
@r:     lda eng_plo,y
        sta eng_tlo
        lda eng_phi,y
        sta eng_thi
        lda eng_on
        bne @on
        lda eng_tlo             ; starting: no glide from a stale pitch
        sta eng_lo
        lda eng_thi
        sta eng_hi
@on:    lda #1
@off:   sta eng_on
        ldy stmp
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
        lda stmp
        cmp #SND_CRASH
        beq @crash
        cmp #SND_REV
        beq @rev
        cmp #SND_TICK
        beq @tick
        asl
        tay
        lda fx_tab-2,y
        sta fxptr
        lda fx_tab-1,y
        sta fxptr+1
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
        sta fxptr
        lda fx_crashtab+1,y
        sta fxptr+1
        jmp @done
@rev:   ; S4: half-period 96C+47 T -> AY period ~ 3C + C/2 - C/16 + 2
        stx stmp
        txa
        lsr
        lsr
        lsr
        lsr
        eor #$FF
        sec
        adc #2                  ; 2 - C/16
        sta fxram+1
        txa
        lsr
        clc
        adc fxram+1
        adc stmp
        adc stmp
        adc stmp
        sta fxram+1
        lda #0
        sta fxram+2
        lda #9
        bne @one
@tick:  ; S8: half-period 434C+47 T -> AY period ~ 16C - C/2 + 2
        lda #0
        sta fxram+2
        txa
        asl
        asl
        asl
        asl
        rol fxram+2
        clc
        adc #2
        bcc @t1
        inc fxram+2
@t1:    sta fxram+1
        txa
        lsr
        sta stmp
        lda fxram+1
        sec
        sbc stmp                ; - C/2
        sta fxram+1
        bcs @t2
        dec fxram+2
@t2:    lda #10
@one:   sta fxram
        lda #<fxram
        sta fxptr
        lda #>fxram
        sta fxptr+1
        jmp @done

; ---------------------------------------------------------------------------
; snd_tick: one 50Hz frame (called from the IRQ; uses A, X, Y).
snd_tick:
        lda inited
        bne @i
        jsr chk_init
@i:     lda #$78                ; mixer: tones on, noise off, port A output
        sta reg+7
        ldx #0
        jsr voice
        ldx #2
        jsr voice

        ; --- engine drone on C
        lda #0
        ldx eng_on
        beq @eng
        sec                     ; glide: cur += (target - cur) / 2
        lda eng_tlo
        sbc eng_lo
        sta stmp
        lda eng_thi
        sbc eng_hi
        cmp #$80
        ror
        ror stmp
        tay
        ora stmp
        bne @g
        lda eng_tlo
        sta eng_lo
        lda eng_thi
        sta eng_hi
        jmp @g2
@g:     clc
        lda eng_lo
        adc stmp
        sta eng_lo
        tya
        adc eng_hi
        sta eng_hi
@g2:    lda eng_lo
        sta reg+4
        lda eng_hi
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
@fx:    ldx #1                  ; X = channel 1 (B) or 2 (C)
        ldy von+2
        beq @ch
        inx
@ch:    sta reg+8,x
        txa
        asl
        tax                     ; X = 2*channel: period registers
        ldy #1
        lda (fxptr),y
        sta reg,x
        iny
        lda (fxptr),y
        and #$0F
        sta reg+1,x
        txa
        lsr
        tax                     ; channel again
        lda (fxptr),y
        asl                     ; C = noise flag, N = tone-off flag
        php
        bpl @tone
        lda reg+7
        ora chbit,x
        sta reg+7
@tone:  plp
        bcc @nonz
        lda chbit,x
        asl
        asl
        asl
        eor #$FF
        and reg+7
        sta reg+7
        iny
        lda (fxptr),y
        sta reg+6
@nonz:  clc
        lda fxptr
        adc #4
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

chbit:  .byte 1,2,4

; voice: advance music voice X (0 or 2) by one frame and set its registers.
voice:
        lda von,x
        bne @act
@mute:  txa
        lsr
        tay
        lda #0
        sta reg+8,y
        rts
@act:   lda vleft,x
        bne @play
        lda (vptr,x)            ; next run
        cmp #$FF
        bne @run
        lda #0                  ; end of this voice's list
        sta von,x
        cpx #0
        bne @mute
        sta von+2               ; voice 0 ended: the tune is over
        sta music_busy
        beq @mute
@run:   sta vnote,x
        inc vptr,x
        bne @p1
        inc vptr+1,x
@p1:    lda (vptr,x)
        sta vleft,x
        sta vlen,x
        inc vptr,x
        bne @p2
        inc vptr+1,x
@p2:    lda #0
        sta vage,x
@play:  dec vleft,x
        lda vnote,x
        bmi @gap
        beq @mute
        tay
        lda snd_ptab_lo,y
        sta reg,x
        lda snd_ptab_hi,y
        sta reg+1,x
        ldy vage,x
        cpy #7
        bcc @e
        ldy #7
@e:     lda env,y
        ldy vleft,x
        bne @nr
        ldy vlen,x              ; last frame of a note of 3+ frames: softer
        cpy #3
        bcc @nr
        sbc #4                  ; (C = 1)
@nr:    inc vage,x
        tay
        txa
        lsr
        tax
        tya
        sta reg+8,x
        txa
        asl
        tax
        rts
@gap:   and #$7F                ; silent first frame, the note starts next frame
        sta vnote,x
        jmp @mute
