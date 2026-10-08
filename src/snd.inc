; snd.inc - sound interface (implemented in snd.s, AY-3-8912, non-blocking).
;
; The Spectrum's beeper routines blocked the CPU while they played; on the
; Oric every effect is started and runs from the 50Hz interrupt.
;
;   jsr snd_fx      A = effect id, X = parameter (see below).  Preserves Y.
;   jsr music_start A = tune id.          music_busy (zp) != 0 while playing
;   jsr music_stop
;   jsr snd_engine  A = revs (0 = engine off) - continuous engine note
;                   (an addition: the Spectrum had no engine drone)

.global snd_fx, music_start, music_stop, snd_engine
.globalzp music_busy

SND_BEEP     = 1    ; S3 message beep (BA6A)
SND_REV      = 2    ; S4 accelerator blip, X = the original's delay C (33-(speed+revs))
SND_SCREECH  = 3    ; S5 tyre screech (one main-loop pass)
SND_CRASH    = 4    ; S6 crash noise, X = B (5 gunshot, 10 crash/bump/bang, 20 object struck)
SND_CHIRP    = 5    ; S7 penalty chirp
SND_TICK     = 6    ; S8 indicator tick, X = the original's delay C (8 or 16)
SND_KEYBLIP  = 7    ; S9 key-definition prompt
SND_BADKEY   = 8    ; S10 invalid skill digit
SND_TAPEERR  = 9    ; S11 tape error

TUNE_MENU_A  = 0    ; S1 menu tunes (E6D8..)
TUNE_MENU_B  = 1
TUNE_START   = 2    ; S2 game-start jingle (E82B)
