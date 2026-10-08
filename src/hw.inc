; hw.inc - Oric Atmos hardware addresses
VIA_ORB  = $0300
VIA_DDRB = $0302
VIA_DDRA = $0303
VIA_T1CL = $0304
VIA_T1CH = $0305
VIA_T2CL = $0308
VIA_T2CH = $0309
VIA_ACR  = $030B
VIA_PCR  = $030C
VIA_IFR  = $030D
VIA_IER  = $030E
VIA_ORA  = $030F

HIRES    = $A000                ; 240x200 HIRES screen, 40 bytes per line
TEXTLINES= $BF68                ; the 3 text lines below the HIRES picture
MODEREG  = $BFDF                ; last byte of screen RAM: $1E = HIRES 50Hz
CHARSET  = $9800                ; standard character set in HIRES mode
MDCTRL   = $0314                ; Microdisc control: bit1 ROM on, bit7 EPROM off
