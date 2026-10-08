; zx.inc - shared definitions for code translated from the Spectrum original.
;
; See docs/PORTING.md.  Z80 registers that cross routine boundaries live in
; zero page; register pairs are little-endian so (zl),y etc. work as pointers.

.globalzp zc, zb, ze, zd, zl, zh, zixl, zixh, ziyl, ziyh
.globalzp zc2, zb2, ze2, zd2, zl2, zh2, za2, za, zf
.global   rnd_r

zbc = zc                        ; BC pair (zc = low byte)
zde = ze
zhl = zl
zix = zixl
ziy = ziyl
zbc2 = zc2
zde2 = ze2
zhl2 = zl2

; GET_R: replacement for the Z80 "ld a,r" (used by the original as a cheap
; random number).  Result in A, X and Y preserved.
.macro GET_R
        jsr rnd_r
.endmacro

; Spectrum addresses $5B00-$7BBD are identical on the Oric (segment ZXRAM).
ZX_LO = $5B00
ZX_HI = $7BBE

; ZPROC $xxxx  - define and export the label Z_xxxx for the translation of the
;                Spectrum routine/label at $xxxx (so tests and other modules
;                can find it).
.macro ZPROC addr
        .ident(.sprintf("Z_%04X", addr)):
        .export .ident(.sprintf("Z_%04X", addr))
.endmacro

; ZVAR $xxxx, n  - allocate n bytes (zero) for the relocated Spectrum variable
;                  at $xxxx (address >= $7BBE).  Exports ZV_xxxx and ZVS_xxxx=n
;                  so the test harness copies/compares it.
; ZLABEL $xxxx, n - same, but allocates nothing: put your own .byte data after.
.macro ZLABEL addr, size
        .ident(.sprintf("ZV_%04X", addr)):
        .export .ident(.sprintf("ZV_%04X", addr))
        .export .ident(.sprintf("ZVS_%04X", addr)) = size
.endmacro
.macro ZVAR addr, size
        ZLABEL addr, size
        .res size
.endmacro

; ZIMPORT $xxxx - import Z_xxxx (a routine translated in another module).
.macro ZIMPORT addr
        .import .ident(.sprintf("Z_%04X", addr))
.endmacro
; ZVIMPORT $xxxx - import a relocated variable ZV_xxxx from another module.
.macro ZVIMPORT addr
        .import .ident(.sprintf("ZV_%04X", addr))
.endmacro
