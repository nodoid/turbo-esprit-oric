; boot.s - loaded by Sedoric as BOOT.BIN at $0500 and CALLed after the main
; part of the game: switches the ROM (and Sedoric) off, reads the overlay
; part of the game from raw sectors into the RAM under the ROM and starts the
; game.  The sector reader DREAD stays resident: the game loads the menu and
; dashboard blobs with it.
        .include "../disk.inc"
        .include "../hw.inc"

FDC_CMD = $0310
FDC_TRK = $0311
FDC_SEC = $0312
FDC_DAT = $0313
FDC_DRQ = $0318

        .org $0500
boot:   sei
        lda #$84                ; ROM off, disk EPROM off, drive 0 side 0
        sta MDCTRL
        lda #OVL_TRACK
        sta D_TRK
        lda #1
        sta D_SEC
        lda #64
        sta D_CNT
        lda #$00
        sta D_DEST
        lda #$C0
        sta D_DEST+1
        jsr DREAD
        jmp $0600
        .res DREAD - *

; DREAD: read D_CNT sectors from D_TRK/D_SEC on to D_DEST.. (whole pages)
        php
        sei
        lda D_DEST
        sta @st+1
        lda D_DEST+1
        sta @st+2
@seek:  lda D_TRK
        sta FDC_DAT
        lda #$18                ; seek, head loaded, no verify
        sta FDC_CMD
        jsr @wait
@rd:    lda D_SEC
        sta FDC_SEC
        lda #$80                ; read sector
        sta FDC_CMD
        ldy #0
@drq:   lda FDC_DRQ
        bmi @drq                ; DRQ is active low
        lda FDC_DAT
@st:    sta $FFFF,y
        iny
        bne @drq
        jsr @wait
        inc @st+2
        dec D_CNT
        beq @done
        inc D_SEC
        lda D_SEC
        cmp #18
        bne @rd
        lda #1
        sta D_SEC
        inc D_TRK
        jmp @seek
@done:  plp
        rts
@wait:  ldx #16                 ; let BUSY come up, then wait for it to drop
@d:     dex
        bne @d
@b:     lda FDC_CMD
        and #1
        bne @b
        rts
        .res D_TRK - *
