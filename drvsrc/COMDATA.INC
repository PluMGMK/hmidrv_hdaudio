; Common data to detector and driver

; Capabilities structure to be returned by function call
sCaps:
szDeviceName	db "HD Audio 16 Stereo"
	NAMELEN	equ $-szDeviceName
		db (20h - NAMELEN) dup (0)
wDeviceVersion	dd 1	; Working fairly satisfactorily at this point...
wBitsPerSample	dd 16	; 16-bit driver
wChannels	dd (FORMATLOBYTE AND 0Fh) ; CHAN
wMinRate	dd 8000
wMaxRate	dd 48000
wMixerOnBoard	dd 0	; Perhaps, but can't guarantee this
wMixerFlags	dd 0
wFlags		dd 300h	; Pseudo-DMA, detector needs env strings
lpPortList	label	fword
		dd offset PortList
lpPortList_seg	label	word
		dd ?	; Fill in segment @ runtime
lpDMAList	label	fword
		dd offset DMAList
lpDMAList_seg	label	word
		dd ?	; Fill in segment @ runtime
lpIRQList	label	fword
		dd offset IRQList
lpIRQList_seg	label	word
		dd ?	; Fill in segment @ runtime
lpRateList	label	fword
		dd offset RateList
lpRateList_seg	label	word
		dd ?	; Fill in segment @ runtime
fBackground	dd 1
wID		dd 0E040h	; an unused ID...
wTimerID	dd 100Dh	; 16-bit stereo pseudo-DMA timer

; Lists pointed to by capabilities structure
PortList	dw (DEVSTOENUMERATE+1) dup (-1)
DMAList		dw 0,-1		; unused
IRQList		dw 2,5,7,0Ah,-1	; same ones SB16 can use...
; List from HDA spec, in order from R1-R7 (i.e. reduced to only those that'll fit inside a word...)
RateList	dw 8000,11025,16000,22050,32000,44100,48000,-1
NUM_RATES	equ ($ - RateList) SHR 1
FormatHiBytes	db 00000101b ; TYPE=0=PCM, BASE=0=48kHz, MULT=000=1, DIV=101=6
		db 01000011b ; TYPE=0=PCM, BASE=1=44.1kHz, MULT=000=1, DIV=011=4
		db 00000010b ; TYPE=0=PCM, BASE=0=48kHz, MULT=000=1, DIV=010=3
		db 01000001b ; TYPE=0=PCM, BASE=1=44.1kHz, MULT=000=1, DIV=001=2
		db 00001010b ; TYPE=0=PCM, BASE=0=48kHz, MULT=001=2, DIV=010=3
		db 01000000b ; TYPE=0=PCM, BASE=1=44.1kHz, MULT=000=1, DIV=000=1
		db 00000000b ; TYPE=0=PCM, BASE=0=48kHz, MULT=000=1, DIV=000=1
FORMATLOBYTE	equ 0010001b ; BITS=001=16, CHAN=0001=2

; Basic parameters set by calling application
wPort		label	word	; for the "port":
pci_dev_func	db -1		; PCI device/function in low byte (7-3 device, 2-0 func)
pci_bus		db -1		; PCI bus in high byte
wIrqDma		label	word	; set these together...
irq		db 0
dma		db 0
wParam		label	word
node		db 0
codec		db 0		; technically only a nibble!

; Other internal data
hdareg_ptr	label	fword
		dd 0
hdareg_seg	label	word
		dd 0
hdareg_linaddr	dd 0

dwTSRbuf	dd 0
MAXTSRBUFOFFSET	equ	100000h	; 1 MiB

dwCorbDpmiHdl	label	dword	; only one of these three dwords will be needed
dwTSRbufoffset	label	dword
xmsentry	label	dword
xmsentry_ip	dw 0
xmsentry_cs	dw 0

lpRirb		label	fword
dwRirbOff	dd 400h		; RIRB is always at offset 256*4 in our CORB/RIRB/BDL buffer
dwCorbSelHdl	label	dword
wCorbSel	dw 0
wCorbHdl	dw 0
dwBdlOff	dd 0C00h	; BDL is always 256*8 beyond the RIRB

dwCorbPhys	dd 0		; Physical address of CORB/RIRB/BDL buffer

corbwpmask	db 0FFh
rirbwpmask	db 0FFh

CStr macro text:vararg	;define a string in .code
local sym
	.const
sym db text,0
	.code
	exitm <offset sym>
endm

if	?DEBUGLOG
debuglog_hdl	dd -1
endif
