; hw.s - Oric Atmos hardware layer
;
; The game owns the machine: the ROM is never called after start-up.  The
; VIA's timer 1 raises a 50Hz interrupt that drives the AY sound engine and
; a frame counter; the keyboard is scanned on demand.

        .include "hw.inc"

        .export hw_init, kbd_scan, ay_reg, ay_val, ay_set
        .export keys, frames, irq_hook
        .export key_row, Z_F37A, any_key
        .import snd_tick

        .zeropage
frames: .res 1                  ; 50Hz frame counter
kacc:   .res 1
krow:   .res 1

        .bss
keys:   .res 8                  ; key matrix, keys+row bit col = 1 when down
irq_hook: .res 2                ; extra 50Hz handler (rts if none)

        .code

; hw_init: take over the machine.  Interrupts are off on return; the caller
; enables them (cli) once the IRQ vector is set up.
hw_init:
        sei
        cld
        lda #$7F
        sta VIA_IER             ; disable every VIA interrupt source
        lda #$F7
        sta VIA_DDRB            ; PB3 = keyboard sense input
        lda #$FF
        sta VIA_DDRA
        lda #$DD
        sta VIA_PCR             ; AY bus inactive
        lda #$40
        sta VIA_ACR             ; T1 continuous
        lda #<19998
        sta VIA_T1CL
        lda #>19998
        sta VIA_T1CH            ; 20ms period
        lda #$C0
        sta VIA_IER             ; enable T1 interrupt
        ; Overlay RAM: the ROM is switched off for good (Microdisc control
        ; register: bit 1 = 0 maps the RAM at $C000, bit 7 = 1 keeps the disk
        ; EPROM out), so the 6502 takes its vectors from RAM.
        lda #$84                ; (drive 0, side 0, as the boot stub left it)
        sta MDCTRL
        lda #<irq
        sta $FFFE
        lda #>irq
        sta $FFFF
        lda #<nmi
        sta $FFFA
        lda #>nmi
        sta $FFFB
        lda #<no_hook
        sta irq_hook
        lda #>no_hook
        sta irq_hook+1
        ; mixer: everything off, port A output (needed for the keyboard)
        lda #7
        ldx #$7F
        jsr ay_set
        ldx #0
        lda #8
        jsr ay_set
        lda #9
        jsr ay_set
        lda #10
        jmp ay_set

; 50Hz interrupt
irq:    pha
        txa
        pha
        tya
        pha
        lda VIA_T1CL            ; acknowledge
        inc frames
        jsr snd_tick
        jsr hookj
        pla
        tay
        pla
        tax
        pla
nmi:    rti
hookj:  jmp (irq_hook)
no_hook:
        rts

; ---------------------------------------------------------------------------
; AY access.  ay_reg: A = register number.  ay_val: A = value.
; ay_set: A = register, X = value.  All preserve X and Y.
ay_reg: sta VIA_ORA
        lda #$FF
        sta VIA_PCR
        lda #$DD
        sta VIA_PCR
        rts
ay_val: sta VIA_ORA
        lda #$FD
        sta VIA_PCR
        lda #$DD
        sta VIA_PCR
        rts
ay_set: php
        sei
        jsr ay_reg
        txa
        jsr ay_val
        plp
        rts

; ---------------------------------------------------------------------------
; kbd_scan: read the 8x8 key matrix into keys[row] (bit = column, 1 = down)
kbd_scan:
        php
        sei
        lda #14
        jsr ay_reg
        ldx #7
@row:   stx krow
        lda VIA_ORB
        and #$F8
        ora krow
        sta VIA_ORB
        lda #0
        sta kacc
        ldy #7
@col:   lda colmask,y
        sta VIA_ORA
        lda #$FD
        sta VIA_PCR
        lda #$DD
        sta VIA_PCR
        nop
        nop
        nop
        nop
        lda VIA_ORB
        and #$08
        cmp #$08                ; C = 1 when the key is down
        rol kacc
        dey
        bpl @col
        lda kacc
        sta keys,x
        dex
        bpl @row
        plp
        rts

colmask: .byte $FE,$FD,$FB,$F7,$EF,$DF,$BF,$7F

; ---------------------------------------------------------------------------
; key_row: X = matrix row 0-7 -> A = columns held (bit set = key down).
; Preserves X and Y.
key_row:
        php
        sei
        lda #14
        jsr ay_reg
        lda VIA_ORB
        and #$F8
        stx krow
        ora krow
        sta VIA_ORB
        tya
        pha
        lda #0
        sta kacc
        ldy #7
@col:   lda colmask,y
        sta VIA_ORA
        lda #$FD
        sta VIA_PCR
        lda #$DD
        sta VIA_PCR
        nop
        nop
        lda VIA_ORB
        and #$08
        cmp #$08
        rol kacc
        dey
        bpl @col
        pla
        tay
        lda kacc
        plp
        cmp #0                  ; Z set when no key in the row
        rts

; Z_F37A: test the key described by the 3-byte key-table entry at (zl,zh):
; byte 0 = Oric matrix row, byte 1 = column mask, byte 2 = 0.  (The Spectrum
; table held port low/high + bit mask.)  On return zl,zh point at byte 2 as
; on the Spectrum, and Z is set when the key is DOWN (A = 0), clear otherwise.
.importzp zl, zh
Z_F37A:
        tya
        pha
        ldy #0
        lda (zl),y
        tax
        jsr key_row
        iny
        and (zl),y              ; non-zero = down
        sta kacc
        clc
        lda zl
        adc #2
        sta zl
        bcc @nc
        inc zh
@nc:    pla
        tay
        lda kacc
        beq @up
        lda #0                  ; down: A = 0, Z set
        rts
@up:    lda #1                  ; up: A = 1, Z clear
        rts

; any_key: Z clear (A != 0) when any key is held
any_key:
        ldx #7
@r:     jsr key_row
        bne @yes
        dex
        bpl @r
        lda #0
@yes:   rts
