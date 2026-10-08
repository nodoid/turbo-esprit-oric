; Turbo Esprit - Oric Atmos conversion
        .include "hw.inc"
        .import hw_init, kbd_scan
        .importzp keys, frames
        .segment "STARTUP"
start:  sei
        cld
        ldx #$FF
        txs
        jsr hw_init
        cli
        lda #$1E
        sta MODEREG
@h:     jmp @h
        lda frames
        ldx #0
@f:     sta $A000,x
        sta $A100,x
        sta $A200,x
        sta $A300,x
        inx
        bne @f
        jmp @h
