; hw.s - Oric Atmos hardware layer
;
; The game owns the machine: the ROM is never called after start-up.  The
; VIA's timer 1 raises a 50Hz interrupt that drives the AY sound engine and
; a frame counter; the keyboard is scanned on demand.

        .include "hw.inc"

        .export hw_init, kbd_scan, ay_reg, ay_val, ay_set
        .export keys, frames, irq_hook
        .import snd_tick

        .zeropage
keys:   .res 8                  ; key matrix, keys+row bit col = 1 when down
frames: .res 1                  ; 50Hz frame counter
kacc:   .res 1
krow:   .res 1

        .bss
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
        ; the ROM jumps through page 2 on IRQ ($0244); with RAM at $FFFE we
        ; cannot change the hardware vector, so patch the ROM's indirection
        lda #$4C                ; JMP abs
        sta $0244
        lda #<irq
        sta $0245
        lda #>irq
        sta $0246
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
        rti
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
