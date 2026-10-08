; snd.s - AY-3-8912 sound engine (driven from the 50Hz interrupt)
        .include "hw.inc"
        .export snd_tick
        .code
snd_tick:
        rts
