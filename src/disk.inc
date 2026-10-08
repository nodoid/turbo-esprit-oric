; disk.inc - layout of the raw (non-Sedoric) data on the disk and the
; resident sector reader left at $0500 by the boot stub (src/boot/boot.s).
; tools/mkdsk.py reads the *_TRACK values from this file.

OVL_TRACK   = 40        ; overlay part of the game ($C000..), 64 sectors
MENU_TRACK  = 44        ; menus / score tables / copyright screen ($5C00..)
DASH_TRACK  = 46        ; packed dashboard picture ($6900..)
CITY_TRACK  = 47        ; the four city maps ($686B.., 6 sectors)
HID_TRACK   = 48        ; tables at $9C00 (alternate charset area), 2 sectors

; resident reader: set the request, then jsr DREAD.  Interrupts are masked
; while it reads; it returns with the I flag as it found it.
D_TRK       = $05F0     ; track
D_SEC       = $05F1     ; first sector (1-17)
D_CNT       = $05F2     ; number of sectors
D_DEST      = $05F3     ; destination address (2 bytes)
DREAD       = $0530
