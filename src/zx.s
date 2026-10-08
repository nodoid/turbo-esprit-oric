; zx.s - shared zero-page "Z80 register file", the R-register replacement and
; the Spectrum working-RAM image.
        .include "hw.inc"
        .include "zx.inc"

        .zeropage
zc:     .res 1
zb:     .res 1
ze:     .res 1
zd:     .res 1
zl:     .res 1
zh:     .res 1
zixl:   .res 1
zixh:   .res 1
ziyl:   .res 1
ziyh:   .res 1
zc2:    .res 1
zb2:    .res 1
ze2:    .res 1
zd2:    .res 1
zl2:    .res 1
zh2:    .res 1
za2:    .res 1
za:     .res 1
zf:     .res 1

        .code
; rnd_r: A = a fast-changing value, like the Z80 refresh register.  The VIA
; timer 2 low byte counts down at 1MHz (it keeps running after its one-shot
; time-out and is otherwise unused), so it is effectively random whenever game
; code samples it.  Timer 1 must not be read: that would acknowledge the 50Hz
; interrupt.  (Test builds patch this to replay recorded values.)
rnd_r:  lda VIA_T2CL
        and #$7F                ; R is 7 bits on the Z80
        rts

        .segment "ZXRAM"
        .incbin "zxram.bin"
