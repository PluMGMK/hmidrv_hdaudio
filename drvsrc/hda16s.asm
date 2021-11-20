	.386
	.model	small

	include	hda.inc	; from Japheth's MIT-licensed HDAutils

RMCS struct	;real mode call structure
union
rEDI	dd ?
rDI	dw ?
ends
union
rESI	dd ?
rSI	dw ?
ends
union
rEBP	dd ?
rBP	dw ?
ends
resvrd	dd ?
union
rEBX	dd ?
rBX 	dw ?
ends
union
rEDX	dd ?
rDX 	dw ?
ends
union
rECX	dd ?
rCX	dw ?
ends
union
rEAX	dd ?
rAX	dw ?
ends
rFlags	dw ?
rES 	dw ?
rDS 	dw ?
rFS 	dw ?
rGS 	dw ?
union
rCSIP	dd ?
struct
rIP 	dw ?
rCS 	dw ?
ends
ends
union
rSSSP	dd ?
struct
rSP 	dw ?
rSS 	dw ?
ends
ends
RMCS ends

DEVNAME		equ 
DEVSTOENUMERATE	equ 10h
?DEBUGLOG	equ 1

_TEXT	segment	use32
	assume	ds:nothing,es:nothing,gs:nothing,fs:_TEXT

	.code
	org 0
start:
	jmp	entry

align 4
; Capabilities structure to be returned by function call
sCaps:
szDeviceName	db "HD Audio 16 Stereo"
	NAMELEN	equ $-szDeviceName
		db (20h - NAMELEN) dup (0)
wDeviceVersion	dd 0	; Not production yet! XD
wBitsPerSample	dd 16	; 16-bit driver
wChannels	dd (FORMATLOBYTE AND 0Fh) ; CHAN
wMinRate	dd 8000
wMaxRate	dd 48000
wMixerOnBoard	dd 0	; Perhaps, but can't guarantee this
wMixerFlags	dd 0
wFlags		dd 200h	; Pseudo-DMA
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
FormatHiBytes	db 00000101b	; TYPE=0=PCM, BASE=0=48kHz, MULT=000=1, DIV=101=6
		db 01000011b	; TYPE=0=PCM, BASE=1=44.1kHz, MULT=000=1, DIV=011=4
		db 00000010b	; TYPE=0=PCM, BASE=0=48kHz, MULT=000=1, DIV=010=3
		db 01000001b	; TYPE=0=PCM, BASE=1=44.1kHz, MULT=000=1, DIV=001=2
		db 00001010b	; TYPE=0=PCM, BASE=0=48kHz, MULT=001=2, DIV=010=3
		db 01000000b	; TYPE=0=PCM, BASE=1=44.1kHz, MULT=000=1, DIV=000=1
		db 00000000b	; TYPE=0=PCM, BASE=0=48kHz, MULT=000=1, DIV=000=1
FORMATLOBYTE	equ 0010001b	; BITS=001=16, CHAN=0001=2

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

xmsentry	label	dword
xmsentry_ip	dw 0
xmsentry_cs	dw 0

lpRirb		label	fword
dwRirbOff	dd 400h		; RIRB is always at offset 256*4 in our CORB/RIRB/BDL buffer
dwCorbSelHdl	label	dword
wCorbSel	dw 0
wCorbHdl	dw 0
dwBdlOff	dd 0C00h	; BDL is always 256*8 beyond the RIRB

lpAuxBufFilled	label	fword	; Far pointer to aux buffer when main one not 128-byte-aligned
dwLastFillEAX	dd 0		; Value returned in EAX at last call to timer function
dwAuxSelHdl	label	dword
wAuxSel		dw 0
wAuxHdl		dw 0

firststreamoff	dd 0

dwCorbPhys	dd 0		; Physical address of CORB/RIRB/BDL buffer

dwMainBufPhys	dd 0		; Physical address of DMA buffer passed from host application
dwMainBufSize	dd 0		; Size of DMA buffer passed from host application

mPICeoi		db 0		; EOI signal to send to master PIC
sPICeoi		db 0		; EOI signal (if any) to send to slave PIC

oldIRQhandler	label	fword
oldIRQ_off	dd 0
oldIRQ_seg	dw 0

irqvec		db 0		; the actual interrupt vector corresponding to our IRQ
oldpciirq	db 0		; the interrupt line of the controller before we set it

oldDEhandler	label	fword
oldDE_off	dd 0
oldDE_seg	dw 0

; Bit 0 = successfully initialized
; Bit 1 = timer entered
; Bit 2 = IRQ entered
; Bit 3 = Timer entered
; Bit 4 = Sound paused
; Bit 5 = Sound temporarily stopped (e.g. for setting rate)
statusword	dw 0
; bitmap representing rates supported by the currently-selected DAC node
ratebitmap	dw 0

; software rate divider
soft_divider	db 1

pinnode		db 0
afgnode		db 0
dacnode		db 0

corbwpmask	db 0FFh
rirbwpmask	db 0FFh

; number of Controller/Stream Resets attempted during the current timer period
; (in response to error interrupts)
crst_count	db 0
srst_count	db 0
; give up after this many:
?CRST_MAX	equ 3
?SRST_MAX	equ 3

if	?DEBUGLOG
CStr macro text:vararg	;define a string in .code
local sym
	.const
sym db text,0
	.code
	exitm <offset sym>
endm

debuglog_hdl	dd -1
endif

; Function table
ftable	dd offset drv_init
	dd offset drv_uninit
	dd offset drv_setrate
	dd offset drv_setaction
	dd offset drv_start
	dd offset drv_stop
	dd offset drv_pause
	dd offset drv_resume
	dd offset drv_capabilities
	dd offset drv_foreground
	dd offset drv_fillinfo
	dd offset drv_getcallfn
	dd offset drv_setcallfn

entry	proc far
	push	ds
	push	fs

	pop	ds
	assume	ds:_TEXT

	; Fill in segments of all far pointers in caps structure
	mov	[lpPortList_seg],ds
	mov	[lpDMAList_seg], ds
	mov	[lpIRQList_seg], ds
	mov	[lpRateList_seg],ds

	; Function number is in AX, and less than 15 for sure
	and	eax,0Fh
	call	[ftable+eax*4]

	pop	ds
	assume	ds:nothing

	retf
entry	endp

printstderr	proc near stdcall	uses ebx edx	pszOutStr:dword
	mov	ebx,2
	mov	edx,[pszOutStr]
	call	printtofile
	ret
printstderr	endp

if	?DEBUGLOG
; ---------------------------------- ;
; INTERNAL DEBUG functions from here ;
; ---------------------------------- ;
	assume	ds:_TEXT	; always called from within DS-set portion of entry point

openlog		proc near stdcall	uses eax ecx edx	pszFilename:dword,append:byte
	.if	[append]
	  mov	ax,3D02h	; OPEN R/W
	.else
	  mov	ah,3Ch		; CREAT
	.endif
	xor	ecx,ecx		; no special attributes
	mov	edx,[pszFilename]
	int	21h
	jc	@F
	mov	[debuglog_hdl],eax
@@:
	ret
openlog		endp

oldvidmode	db ?
logtostderr	proc near		uses eax ebx
	mov	ah,0Fh		; get current video mode
	int	10h
	mov	[oldvidmode],al
	mov	ax,3		; switch to VGA text mode
	int	10h
	mov	[debuglog_hdl],2
	ret
logtostderr	endp

printtolog	proc near stdcall	uses ebx edx	pszOutStr:dword
	mov	ebx,cs:[debuglog_hdl]
	cmp	ebx,-1
	je	@F

	mov	edx,[pszOutStr]
	call	printtofile
@@:
	ret
printtolog	endp

; Print 16 bits to the debug log
curbinword	db 16 dup (?)
		db 0
printbinword	proc near stdcall	uses es edi ecx ebx eax	wOut:word
	mov	ebx,ds
	mov	es,ebx
	pushf
	cld
	mov	edi,offset curbinword

	mov	bx,[wOut]
	mov	ecx,size curbinword
@@:
	shl	bx,1
	setc	al
	add	al,'0'		; AL = '0' if not carry, '1' if carry
	stosb
	loop	@B

	invoke	printtolog, offset curbinword
	popf
	ret
printbinword	endp

printnodetype	proc near stdcall	bNodeType:byte
	.if	[bNodeType] == WTYPE_AUDIOOUT
	 invoke	printtolog, CStr("DAC")
	.elseif	[bNodeType] == WTYPE_AUDIOIN
	 invoke	printtolog, CStr("ADC")
	.elseif	[bNodeType] == WTYPE_MIXER
	 invoke	printtolog, CStr("mixer")
	.elseif	[bNodeType] == WTYPE_SELECTOR
	 invoke	printtolog, CStr("selector")
	.elseif	[bNodeType] == WTYPE_PIN
	 invoke	printtolog, CStr("pin")
	.elseif	[bNodeType] == WTYPE_POWER
	 invoke	printtolog, CStr("power widget")
	.elseif	[bNodeType] == WTYPE_VOLKNOB
	 invoke	printtolog, CStr("volume widget")
	.elseif	[bNodeType] == WTYPE_BEEPGEN
	 invoke	printtolog, CStr("beep generator")
	.endif
	ret
printnodetype	endp

closelog	proc near	uses eax ebx
	mov	ah,3Eh		; CLOSE
	mov	ebx,[debuglog_hdl]
	cmp	ebx,-1
	je	@F
	.if	ebx == 2
	  movzx	ax,[oldvidmode]	; Reset video mode
	  int	10h
	.else
	  int	21h
	  jc	@F
	.endif
	mov	[debuglog_hdl],-1
@@:
	ret
closelog	endp

endif

; ------------------------------------------------------- ;
; ENUM functions from here (called from host application) ;
; ------------------------------------------------------- ;
	assume	ds:_TEXT	; always called from within DS-set portion of entry point

; Initialize driver
; Called with BX = port, CL = IRQ, CH = DMA channel, SI = param
; Returns nothing
drv_init	proc near
if	?DEBUGLOG
	invoke	openlog, CStr("HDA_INIT.LOG"),0
endif
	; fill in the data that the caller gives us
	mov	[wPort],bx
	mov	[wIrqDma],cx
	mov	[wParam],si
if	?DEBUGLOG
	invoke	printtolog, CStr("Initializing driver: successfully set port/irq/dma/param",0Dh,0Ah)
endif
	and	[codec],0Fh

if	?DEBUGLOG
	invoke	printtolog, CStr("Allocating CORB/RIRB buffer...",0Dh,0Ah)
endif
	mov	eax,0C20h	; 1 kiB for CORB + 2 kiB for RIRB + 32 bytes for BDL
	call	alloc_dma_buf
	jc	@@init_failed_esok
if	?DEBUGLOG
	invoke	printtolog, CStr("CORB/RIRB buffer allocated successfully",0Dh,0Ah)
endif
	mov	[dwCorbSelHdl],eax
	mov	[dwCorbPhys],edx

	push	es
	call	get_hdareg_ptr
	jc	@@init_failed
	bts	es:[edi].HDAREGS.gctl,0
	jc	@@hda_running

if	?DEBUGLOG
	invoke	printtolog, CStr("Initializing HDA controller...",0Dh,0Ah)
endif
	mov	ecx,10000h
@@:
	call	wait_timerch2
	test	es:[edi].HDAREGS.gctl,1
	loopz	@B
	jnz	@@hda_running

if	?DEBUGLOG
	invoke	printtolog, CStr("Timed out initializing HDA controller!",0Dh,0Ah)
endif
	jmp	@@init_failed

@@hda_running:
if	?DEBUGLOG
	invoke	printtolog, CStr("Bits in GCTL register: ")
	invoke	printbinword,word ptr es:[edi+2].HDAREGS.gctl
	invoke	printbinword,word ptr es:[edi].HDAREGS.gctl
	invoke	printtolog, CStr(0Dh,0Ah)
endif
	; make sure interrupts are off until we set up IRQ...
	xor	eax,eax
	bt	es:[edi].HDAREGS.intctl,31
	mov	es:[edi].HDAREGS.intctl,eax
	jnc	@@interrupts_off

	mov	ecx,10000h
@@:
	call	wait_timerch2
	cmp	es:[edi].HDAREGS.intctl,eax
	loopnz	@B

@@interrupts_off:
if	?DEBUGLOG
	invoke	printtolog, CStr("Device initialized, ensuring it can act as busmaster...",0Dh,0Ah)
endif
	mov	ax,0B109h	; read configuration word
	mov	edi,4		; command register
	int	1Ah
	jc	@@init_failed
	bts	cx,2		; bit 2 = bus master enabled
	jc	@@busmaster_ok

if	?DEBUGLOG
	invoke	printtolog, CStr("Setting busmaster flag...",0Dh,0Ah)
endif
	mov	ax,0B10Ch	; write configuration word
	int	1Ah
	jc	@@init_failed

@@busmaster_ok:
if	?DEBUGLOG
	invoke	printtolog, CStr("Busmaster flag set",0Dh,0Ah)
endif

	call	get_hdareg_ptr
if	?DEBUGLOG
	invoke	printtolog, CStr("Resetting CORB/RIRB...",0Dh,0Ah)
endif
	and	es:[edi].HDAREGS.corbctl,not 2
	and	es:[edi].HDAREGS.rirbctl,not 2
	mov	ecx,1000h
@@:
	call	wait_timerch2
	test	es:[edi].HDAREGS.corbctl,2
	loopnz	@B
	jz	@F

if	?DEBUGLOG
	invoke	printtolog, CStr("Timed out stopping CORB DMA Engine!",0Dh,0Ah)
endif
	jmp	@@init_failed

@@:
	mov	edx,[dwCorbPhys]
	mov	dword ptr es:[edi].HDAREGS.corbbase,edx
	mov	dword ptr es:[edi].HDAREGS.corbbase+4,0
	add	edx,[dwRirbOff]
	mov	dword ptr es:[edi].HDAREGS.rirbbase,edx
	mov	dword ptr es:[edi].HDAREGS.rirbbase+4,0

if	?DEBUGLOG
	invoke	printtolog, CStr("Bits in CORB write pointer: ")
	invoke	printbinword, es:[edi].HDAREGS.corbwp
	invoke	printtolog, CStr(0Dh,0Ah)
endif
	mov	es:[edi].HDAREGS.corbwp,0	; reset CORB write pointer
	mov	es:[edi].HDAREGS.rirbwp,8000h	; reset RIRB write pointer
	mov	es:[edi].HDAREGS.rirbric,1	; raise an IRQ on *every* response!

if	?DEBUGLOG
	invoke	printtolog, CStr("Resetting CORB read pointer...",0Dh,0Ah)
endif
	bts	es:[edi].HDAREGS.corbrp,15
	jc	@@corb_in_reset
	mov	ecx,1000h
@@:
	call	wait_timerch2
	cmp	es:[edi].HDAREGS.corbrp,0
	jz	@F
	test	byte ptr es:[edi].HDAREGS.corbrp+1,80h
	loopz	@B
	jnz	@@corb_in_reset

if	?DEBUGLOG
	invoke	printtolog, CStr("Timed out resetting CORB read pointer, continuing anyway...",0Dh,0Ah)
endif
	jmp	@F

@@corb_in_reset:
if	?DEBUGLOG
	invoke	printtolog, CStr("Reset bit on, turning it back off...",0Dh,0Ah)
endif
@@:
	btr	es:[edi].HDAREGS.corbrp,15
	mov	ecx,1000h
@@:
	call	wait_timerch2
	test	byte ptr es:[edi].HDAREGS.corbrp+1,80h
	loopnz	@B
	jz	@F

if	?DEBUGLOG
	invoke	printtolog, CStr("Timed out taking CORB read pointer out of reset, continuing anyway...",0Dh,0Ah)
endif

@@:
	mov	ax,es:[edi].HDAREGS.corbrp
	mov	es:[edi].HDAREGS.corbwp,ax

	mov	al,es:[edi].HDAREGS.corbsize
	mov	ah,al
	and	al,3				; two bits setting the size
	and	ah,0F0h				; four bits indicating size capability

	bt	ax,0Eh				; 256 entries possible?
	jnc	@F
if	?DEBUGLOG
	invoke	printtolog, CStr("CORB supports 256 entries",0Dh,0Ah)
endif
	cmp	al,2				; 256 entries set?
	je	@@corbsizeok
	mov	al,2
	jmp	@@setcorbsize

@@:
	bt	ax,0Dh				; 16 entries possible?
	jnc	@F
if	?DEBUGLOG
	invoke	printtolog, CStr("CORB supports 16 entries",0Dh,0Ah)
endif
	cmp	al,1				; 16 entries set?
	mov	[corbwpmask],0Fh		; CORB WP wraps every 16 entries!
	je	@@corbsizeok
	mov	al,1
	jmp	@@setcorbsize

@@:
	; if we're here, then only 2 entries are possible, and must already be set
if	?DEBUGLOG
	invoke	printtolog, CStr("CORB only supports 2 entries",0Dh,0Ah)
endif
	mov	[corbwpmask],1			; wraps every second entry!
	jmp	@@corbsizeok

@@setcorbsize:
if	?DEBUGLOG
	invoke	printtolog, CStr("setting CORB size...",0Dh,0Ah)
endif
	or	al,ah
	mov	es:[edi].HDAREGS.corbsize,al
	mov	ecx,1000h
@@:
	call	wait_timerch2
	cmp	es:[edi].HDAREGS.corbsize,al
	loopne	@B

@@corbsizeok:
if	?DEBUGLOG
	invoke	printtolog, CStr("CORB size set",0Dh,0Ah)
endif
	mov	al,es:[edi].HDAREGS.rirbsize
	mov	ah,al
	and	al,3				; two bits setting the size
	and	ah,0F0h				; four bits indicating size capability

	bt	ax,0Eh				; 256 entries possible?
	jnc	@F
if	?DEBUGLOG
	invoke	printtolog, CStr("RIRB supports 256 entries",0Dh,0Ah)
endif
	cmp	al,2				; 256 entries set?
	je	@@rirbsizeok
	mov	al,2
	jmp	@@setrirbsize

@@:
	bt	ax,0Dh				; 16 entries possible?
	jnc	@F
if	?DEBUGLOG
	invoke	printtolog, CStr("RIRB supports 16 entries",0Dh,0Ah)
endif
	cmp	al,1				; 16 entries set?
	mov	[rirbwpmask],0Fh		; RIRB WP wraps every 16 entries!
	je	@@rirbsizeok
	mov	al,1
	jmp	@@setrirbsize

@@:
	; if we're here, then only 2 entries are possible, and must already be set
if	?DEBUGLOG
	invoke	printtolog, CStr("RIRB only supports 2 entries",0Dh,0Ah)
endif
	mov	[rirbwpmask],1			; wraps every second entry!
	jmp	@@rirbsizeok

@@setrirbsize:
if	?DEBUGLOG
	invoke	printtolog, CStr("setting RIRB size...",0Dh,0Ah)
endif
	or	al,ah
	mov	es:[edi].HDAREGS.rirbsize,al
	mov	ecx,1000h
@@:
	call	wait_timerch2
	cmp	es:[edi].HDAREGS.rirbsize,al
	loopne	@B

@@rirbsizeok:
if	?DEBUGLOG
	invoke	printtolog, CStr("RIRB size set",0Dh,0Ah)
endif

if	?DEBUGLOG
	invoke	printtolog, CStr("Starting CORB/RIRB DMA engines...",0Dh,0Ah)
endif
	or	es:[edi].HDAREGS.corbctl,3	; turn on and enable interrupts
	or	es:[edi].HDAREGS.rirbctl,6	; turn on and enable overrun interrupt
	mov	ecx,1000h
@@:
	call	wait_timerch2
	test	es:[edi].HDAREGS.corbctl,2
	loopz	@B
	jnz	@F

if	?DEBUGLOG
	invoke	printtolog, CStr("Timed out initializing HDA controller!",0Dh,0Ah)
endif
	jmp	@@init_failed

@@:
if	?DEBUGLOG
	invoke	printtolog, CStr("CORB/RIRB up and running!",0Dh,0Ah,"Checking attributes of selected widget...",0Dh,0Ah)
endif

	mov	ax,0F00h	; get parameter
	mov	edx,9		; audio widget capabilities
	call	send_cmd_wait
	bt	eax,0
	jnc	@@init_failed
if	?DEBUGLOG
	invoke	printtolog, CStr("selected widget is stereo",0Dh,0Ah)
endif

	shr	eax,20
	and	al,0Fh
	cmp	al,WTYPE_PIN
	jne	@@init_failed
if	?DEBUGLOG
	invoke	printtolog, CStr("selected widget is a pin",0Dh,0Ah)
endif

	; OK, we won't be sending commands to this again for a while...
	mov	bl,[node]
	mov	[pinnode],bl

	mov	[node],0	; root node
	call	get_subnodes
	mov	ecx,edx
	mov	[node],al
@@:
	call	get_subnodes
	mov	ah,bl
	sub	ah,al
	cmp	ah,dl
	jb	@F		; the pin widget belongs to this functional group
	inc	[node]
	loop	@B

if	?DEBUGLOG
	invoke	printtolog, CStr("couldn't find function group containing selected widget, aborting",0Dh,0Ah)
endif
	jmp	@@init_failed

@@:
if	?DEBUGLOG
	invoke	printtolog, CStr("found function group containing selected widget",0Dh,0Ah)
endif
	; now, [node] should be a functional group, which contains our [pinnode]
	mov	ax,0F00h	; get parameter
	mov	edx,5		; function group type
	call	send_cmd_wait
	and	al,7Fh
	cmp	al,1		; audio function group
	jne	@@init_failed
if	?DEBUGLOG
	invoke	printtolog, CStr("it is an audio function group",0Dh,0Ah)
endif

	mov	al,[node]
	mov	[afgnode],al

	mov	ax,0705h	; set power state
	xor	edx,edx		; D0
	call	send_cmd_wait
	mov	ax,07FFh	; reset
	xor	edx,edx
	call	send_cmd_wait

if	?DEBUGLOG
	invoke	printtolog, CStr("audio function group reset, now looking for a DAC...",0Dh,0Ah)
endif

	mov	al,[pinnode]
	mov	[node],al
	mov	al,WTYPE_PIN
	mov	si,7		; just look for 48 kHz since we've no more specific instructions for now...
	call	find_dac_start
	mov	[dacnode],al
	mov	[ratebitmap],si
	test	al,al
	jnz	@F

if	?DEBUGLOG
	invoke	printtolog, CStr("could not route a DAC to selected widget, aborting",0Dh,0Ah)
endif
	jmp	@@init_failed

@@:
	mov	[node],al
	mov	ax,0F00h	; get parameter
	mov	edx,9		; widget type
	call	send_cmd_wait
	shr	eax,20
	and	al,0Fh
	cmp	al,WTYPE_AUDIOOUT
	je	@F

if	?DEBUGLOG
	invoke	printtolog, CStr("BUGBUG: codec/node ")
	invoke	printbinword,[wParam]
	invoke	printtolog, CStr(" is not a DAC (it is a ")
	invoke	printnodetype,al
	invoke	printtolog, CStr(")",0Dh,0Ah)
endif
	jmp	@@init_failed

@@:
if	?DEBUGLOG
	invoke	printtolog, CStr("DAC found at codec/node ")
	invoke	printbinword,[wParam]
	invoke	printtolog, CStr(", unmuting...",0Dh,0Ah)
endif
	xor	eax,eax		; only the output amplifier
	call	unmute
	mov	ax,0705h	; set power state
	xor	edx,edx		; D0
	call	send_cmd_wait

	mov	al,[pinnode]	; EAX != 0, so unmute both input and output amplifiers
	mov	[node],al
	; no need to unmute pin because it already happened during the search
	mov	ax,0707h	; set pin widget control
	mov	edx,40h		; only out enable
	call	send_cmd_wait

if	?DEBUGLOG
	invoke	printtolog, CStr("DAC unmuted, now resetting output streams",0Dh,0Ah)
endif

	movzx	eax,es:[edi].HDAREGS.gcap
	mov	ecx,eax
	shr	eax,8
	and	eax,0Fh		; number of input streams
	bts	es:[edi].HDAREGS.intctl,eax	; get interrupts from the first output stream

	shr	ecx,0Ch
	and	ecx,0Fh		; number of output streams
	shl	eax,5		; EAX *= 32 (size STREAM)

	lea	esi,[edi+eax+HDAREGS.stream0]
	mov	[firststreamoff],esi
@@resetstreams:
	push	ecx
	mov	ecx,1000h
	or	es:[esi].STREAM.wCtl,1
@@:
	call	wait_timerch2
	test	es:[esi].STREAM.wCtl,1
	loopz	@B
	mov	ecx,1000h
	and	es:[esi].STREAM.wCtl, not 1
@@:
	call	wait_timerch2
	test	es:[esi].STREAM.wCtl,1
	loopnz	@B
	pop	ecx
	lea	esi,[esi+size STREAM]
	loop	@@resetstreams

if	?DEBUGLOG
	invoke	printtolog, CStr("output streams all reset, setting up IRQ...",0Dh,0Ah)
endif
	call	mask_irq
if	?DEBUGLOG
	invoke	printtolog, CStr("IRQ masked",0Dh,0Ah)
endif

	mov	ax,0B108h	; read configuration byte
	mov	bx,[wPort]
	mov	edi,3Ch		; interrupt line
	int	1Ah
	jc	@@init_failed
	mov	[oldpciirq],cl

	mov	ax,0B10Bh	; write configuration byte
	mov	bx,[wPort]
	mov	cl,[irq]
	mov	edi,3Ch		; interrupt line
	int	1Ah
	jc	@@init_failed
if	?DEBUGLOG
	invoke	printtolog, CStr("PCI IRQ line set",0Dh,0Ah)
endif

	mov	bl,[irq]
	mov	al,bl
	add	al,8		; IRQs 0-7 based at interrupt 8
	or	bl,60h		; EOI for specific interrupt
	mov	[mPICeoi],bl
	cmp	al,10h
	jb	@F

	add	al,60h		; IRQs 8-F based at interrupt 70h
	and	bl,67h		; clear upper bit of first nibble (subtract 8)
	mov	[sPICeoi],bl
	mov	[mPICeoi],62h	; EOI for IRQ2 (cascaded interrupt)
@@:
	mov	[irqvec],al
	mov	ah,35h		; get interrupt vector
	int	21h
	mov	[oldIRQ_off],ebx
	mov	[oldIRQ_seg],es

	mov	ah,25h		; set interrupt vector
	push	ds
	push	cs
	pop	ds
	mov	edx,offset irq_handler
	int	21h
	pop	ds
if	?DEBUGLOG
	invoke	printtolog, CStr("protected-mode IRQ handler set",0Dh,0Ah)
endif

	xor	eax,eax		; zero wakeen - we don't want interrupts for this...
	call	get_hdareg_ptr
	xchg	es:[edi].HDAREGS.wakeen,ax
	.if	ax
if	?DEBUGLOG
	 invoke	printtolog, CStr("blanking WAKEEN...",0Dh,0Ah)
endif
	 mov	ecx,1000h
@@:
	 call	wait_timerch2
	 movzx	eax,es:[edi].HDAREGS.wakeen
	 test	eax,eax
	 loopnz	@B
	.endif
if	?DEBUGLOG
	invoke	printtolog, CStr("WAKEEN blanked",0Dh,0Ah)
endif

	movzx	eax,es:[edi].HDAREGS.statests
	.if	eax
if	?DEBUGLOG
	 invoke	printtolog, CStr("blanking STATESTS...",0Dh,0Ah)
endif
	 mov	es:[edi].HDAREGS.statests,ax	; write 1s back to clear the bits
	 mov	ecx,1000h
@@:
	 call	wait_timerch2
	 movzx	eax,es:[edi].HDAREGS.statests
	 test	eax,eax
	 loopnz	@B
	.endif
if	?DEBUGLOG
	invoke	printtolog, CStr("STATESTS blank",0Dh,0Ah)
endif

	or	es:[edi].HDAREGS.intctl,0C0000000h	; GIE + CIE
	mov	ecx,1000h
@@:
	call	wait_timerch2
	test	es:[edi].HDAREGS.intctl,0C0000000h
	loopz	@B
if	?DEBUGLOG
	invoke	printtolog, CStr("interrupts enabled",0Dh,0Ah)
endif

	bts	[statusword],0
if	?DEBUGLOG
	invoke	printtolog, CStr("initialization completed successfully!",0Dh,0Ah)
endif

	call	unmask_irq
if	?DEBUGLOG
	invoke	printtolog, CStr("interrupts unmasked (in case we're sharing)",0Dh,0Ah)
endif

@@init_failed:
	pop	es
@@init_failed_esok:
if	?DEBUGLOG
	invoke	closelog
endif

	bt	[statusword],0
	jnc	drv_uninit	; if we didn't successfully init, then clean up our mess!
	ret
drv_init	endp

; Un-initialize driver
; Takes no parameters
; Returns nothing
drv_uninit	proc near
if	?DEBUGLOG
	invoke	openlog, CStr("HDA_FINI.LOG"),0
	invoke	printtolog, CStr("masking interrupts...",0Dh,0Ah)
endif
	call	mask_irq
	btr	[statusword],0

if	?DEBUGLOG
	invoke	printtolog, CStr("checking if HDA register far pointer exists...",0Dh,0Ah)
endif
	xor	eax,eax
	.if	[hdareg_seg] != ax
	   push	es
	   call	get_hdareg_ptr

	   mov	es:[edi].HDAREGS.intctl,eax		; EAX = 0 from above
	   mov	ecx,1000h
@@:
	   call	wait_timerch2
	   test	es:[edi].HDAREGS.intctl,080000000h	; GIE
	   loopnz @B
if	?DEBUGLOG
	   invoke printtolog, CStr("interrupts disabled",0Dh,0Ah)
endif

	   cmp	[oldIRQ_seg],ax				; AX = 0 from above
	   je	@F

	   mov	ah,25h		; set interrupt vector
	   mov	al,[irqvec]
	   push	ds
	   lds	edx,[oldIRQhandler]
	   int	21h
	   pop	ds
if	?DEBUGLOG
	   invoke printtolog, CStr("protected-mode IRQ handler reset",0Dh,0Ah)
endif

	   xor	eax,eax
	   mov	[oldIRQ_seg],ax
	   mov	[oldIRQ_off],eax

@@:
	   ; no need for these anymore...
	   mov	[mPICeoi],al
	   mov	[sPICeoi],ah

	   cmp	[oldpciirq],al
	   je	@F

	   mov	ax,0B10Bh	; write configuration byte
	   mov	bx,[wPort]
	   mov	cl,[oldpciirq]
	   mov	edi,3Ch		; interrupt line
	   int	1Ah
if	?DEBUGLOG
	   invoke printtolog, CStr("PCI IRQ line reset",0Dh,0Ah)
endif

	   xor	eax,eax
	   mov	[oldpciirq],al

@@:
	   call	unmask_irq
if	?DEBUGLOG
	   invoke printtolog, CStr("IRQ unmasked",0Dh,0Ah)
endif

	   and	es:[edi].HDAREGS.corbctl,not 2
	   and	es:[edi].HDAREGS.rirbctl,not 2
	   mov	ecx,10000h
@@:
	   call	wait_timerch2
	   test	es:[edi].HDAREGS.corbctl,2
	   loopnz	@B
if	?DEBUGLOG
	   invoke printtolog, CStr("CORB/RIRB stopped",0Dh,0Ah)
endif

	   btr	es:[edi].HDAREGS.gctl,0
if	?DEBUGLOG
	   invoke printtolog, CStr("Resetting HDA controller...",0Dh,0Ah)
endif
	   mov	ecx,10000h
@@:
	   call	wait_timerch2
	   test	es:[edi].HDAREGS.gctl,1
	   loopnz @B
if	?DEBUGLOG
	   invoke printtolog, CStr("HDA controller reset",0Dh,0Ah)
endif

	   mov	ebx,es
	   call	free_selector
	   xor	eax,eax
	   mov	[hdareg_seg],ax
if	?DEBUGLOG
	   invoke printtolog, CStr("far pointer to HDA device registers freed",0Dh,0Ah)
endif

	   pop	es
	.endif

if	?DEBUGLOG
	invoke	printtolog, CStr("checking if HDA register linear map exists...",0Dh,0Ah)
endif
	mov	ecx,[hdareg_linaddr]
	cmp	ecx,eax
	jz	@F

	mov	ebx,ecx
	shr	ebx,10h
	call	unmap_physmem
	xor	eax,eax
	mov	[hdareg_linaddr],eax
if	?DEBUGLOG
	invoke printtolog, CStr("linear address of HDA device registers unmapped",0Dh,0Ah)
endif

@@:
	mov	eax,[dwCorbSelHdl]
	test	eax,eax
	jz	@F

	call	free_dma_buf
	mov	[dwCorbPhys],eax
	mov	[dwCorbSelHdl],eax
if	?DEBUGLOG
	invoke printtolog, CStr("CORB/RIRB buffer freed",0Dh,0Ah)
endif
@@:

if	?DEBUGLOG
	invoke	closelog
endif
	ret
drv_uninit	endp

; Set PCM sample rate - only called immediately after init (i.e. not when sound is playing)
; Takes sample rate in BX
; Returns nothing
drv_setrate	proc near
if	?DEBUGLOG
	invoke	openlog, CStr("HDA_RATE.LOG"),0
	invoke	printtolog, CStr("checking if driver is initialized...",0Dh,0Ah)
endif
	bt	[statusword],0
	jnc	@@failed

if	?DEBUGLOG
	invoke	printtolog, CStr("finding rate index...",0Dh,0Ah)
	invoke	printtolog, CStr("Bits in requested rate: ")
	invoke	printbinword,bx
	invoke	printtolog, CStr(0Dh,0Ah)
endif
	mov	ax,bx
	.if	ax == 10000	; Rayman 1 uses this non-standard rate...
	  mov	ax,11025	; So sneakily speed it up to this standard one!
	.endif			; (Rayman Designer uses 11025 - so that's why I always thought Rayman 1's sounds were lower-pitched...)
	call	get_rate_idx
	cmp	ax,-1
	je	@@failed

if	?DEBUGLOG
	invoke	printtolog, CStr("checking if DAC supports this rate...",0Dh,0Ah)
	invoke	printtolog, CStr("[bits in rate support bitmap: ")
	invoke	printbinword,[ratebitmap]
	invoke	printtolog, CStr("; bits in rate index: ")
	invoke	printbinword,ax
	invoke	printtolog, CStr("]",0Dh,0Ah)
endif
	bt	[ratebitmap],ax
	movzx	ebx,ax
	jc	@F

if	?DEBUGLOG
	invoke	printtolog, CStr("nope, searching for another DAC...",0Dh,0Ah)
endif
	mov	si,ax
	mov	al,[pinnode]
	mov	[node],al
	mov	al,WTYPE_PIN
	call	find_dac_start
	test	al,al
	jnz	@@dacfound

if	?DEBUGLOG
	invoke	printtolog, CStr("no DAC found, setting up software conversion...",0Dh,0Ah)
endif
	mov	bh,FormatHiBytes[ebx-1]
	mov	bl,bh
	and	bl,7		; three lowest bits = divider
	inc	bl		; convert zero to one, etc.
	mov	[soft_divider],bl
	and	bh,not 7	; nullify the divider
	jmp	@@setformatlobyte

@@dacfound:
	mov	[dacnode],al
	mov	[ratebitmap],si
	mov	[node],al
if	?DEBUGLOG
	invoke	printtolog, CStr("DAC found at codec/node ")
	invoke	printbinword,[wParam]
	invoke	printtolog, CStr(", unmuting...",0Dh,0Ah)
endif
	xor	eax,eax		; only the output amplifier
	call	unmute
	mov	ax,0705h	; set power state
	xor	edx,edx		; D0
	call	send_cmd_wait

@@:
if	?DEBUGLOG
	invoke	printtolog, CStr("rate supported, configuring stream...",0Dh,0Ah)
endif
	mov	bh,FormatHiBytes[ebx-1]
@@setformatlobyte:
	mov	bl,FORMATLOBYTE
if	?DEBUGLOG
	invoke	printbinword,bx
	invoke	printtolog, CStr(" is the new stream format word",0Dh,0Ah)
endif

	push	es
	call	get_hdareg_ptr
	mov	edi,[firststreamoff]
	mov	es:[edi].STREAM.wFormat,bx
	pop	es

if	?DEBUGLOG
	invoke	printtolog, CStr("stream configured, programming DAC...",0Dh,0Ah)
endif
	mov	al,[dacnode]
	mov	[node],al
	mov	ax,2		; set converter format
	movzx	edx,bx
	call	send_cmd_wait

@@failed:
if	?DEBUGLOG
	invoke	closelog
endif
	ret
drv_setrate	endp

; Set DMA "action" of driver
; Takes "action" (4 or 8) in BX
; Returns nothing
drv_setaction	proc near
if	?DEBUGLOG
	invoke	openlog, CStr("HDA_ACT.LOG"),0
endif
	cmp	bx,8	; TRA1 = reading from memory (an ISA DMA mode - see osdev wiki)
	je	@F

	; nothing we can do really, apart from complaining in the debug log...
if	?DEBUGLOG
	invoke	printtolog, CStr("Attempted to configure driver for something other than device reading host memory - not supported!",0Dh,0Ah)
endif

@@:
if	?DEBUGLOG
	invoke	closelog
endif
	ret
drv_setaction	endp

; Start playing sound
; Takes physical address of DMA buffer in EDI, and its size in ECX
; Returns nothing
drv_start	proc near
if	?DEBUGLOG
	invoke	openlog, CStr("HDA_STRT.LOG"),0
	;call	logtostderr
	invoke	printtolog, CStr("checking if driver is initialized...",0Dh,0Ah)
endif
	bt	[statusword],0
	jnc	@@failed

if	?DEBUGLOG
	invoke	printtolog, CStr("checking if sound is paused...",0Dh,0Ah)
endif
	bt	[statusword],4
	jc	@@failed

	mov	edx,edi
	push	es

	call	get_hdareg_ptr
	mov	edi,[firststreamoff]
if	?DEBUGLOG
	invoke	printtolog, CStr("checking if sound is playing...",0Dh,0Ah)
endif
	bt	es:[edi].STREAM.wCtl,1	; RUN bit
	jc	@@skip

	mov	[dwMainBufPhys],edx
	mov	[dwMainBufSize],ecx

	cmp	[soft_divider],1
	;jna	@F
	jmp	@F

if	?DEBUGLOG
	invoke	printtolog, CStr("software divider in operation (")
	movzx	ax,[soft_divider]
	invoke	printbinword,ax
	invoke	printtolog, CStr("), creating new buffer...",0Dh,0Ah)
endif
	mov	eax,ecx
	movzx	ecx,[soft_divider]
	mul	ecx		; destroys EDX, but alloc_dma_buf sets it anyway
	mov	ecx,eax

	push	es
	push	ebx
	mov	ax,3500h	; get interrupt vector 0 (#DE)
	int	21h
	mov	[oldDE_off],ebx
	mov	[oldDE_seg],es
	pop	ebx
	pop	es

	mov	ax,2500h	; set interrupt vector 0 (#DE)
	push	ds
	push	edx
	push	cs
	pop	ds
	mov	edx,offset div0_handler
	int	21h
	pop	edx
	pop	ds
if	?DEBUGLOG
	invoke	printtolog, CStr("divide-by-zero handler set",0Dh,0Ah)
endif

	jmp	@@createauxbuf

@@:
	test	edx,7Fh		; 128-byte aligned?
	jz	@F

if	?DEBUGLOG
	invoke	printtolog, CStr("buffer not 128-byte aligned, creating new one...",0Dh,0Ah)
endif
	mov	eax,ecx
@@createauxbuf:
	call	alloc_dma_buf
	jc	@@skip
	mov	[dwAuxSelHdl],eax
if	?DEBUGLOG
	invoke	printtolog, CStr("128-byte-aligned aux buffer created",0Dh,0Ah)
endif

@@:
	push	gs
	lgs	esi,[lpRirb]
	mov	esi,[dwBdlOff]
if	?DEBUGLOG
	invoke	printtolog, CStr("setting up BDL entries...",0Dh,0Ah)
endif
	xor	eax,eax
	mov	dword ptr gs:[esi].BDLENTRY.qwAddr,edx
	mov	dword ptr gs:[esi+4].BDLENTRY.qwAddr,eax
	mov	gs:[esi].BDLENTRY.dwLen,ecx
	mov	gs:[esi].BDLENTRY.dwFlgs,eax			; no IOC (for now)
	mov	dword ptr gs:[esi+size BDLENTRY].BDLENTRY.qwAddr,edx
	mov	dword ptr gs:[esi+size BDLENTRY+4].BDLENTRY.qwAddr,eax
	mov	gs:[esi+size BDLENTRY].BDLENTRY.dwLen,ecx
	mov	gs:[esi+size BDLENTRY].BDLENTRY.dwFlgs,eax	; no IOC (for now)
	pop	gs

if	?DEBUGLOG
	invoke	printtolog, CStr("setting up stream descriptor...",0Dh,0Ah)
endif
	add	esi,[dwCorbPhys]		; get BDL physical address
	mov	dword ptr es:[edi].STREAM.qwBuffer,esi
	mov	dword ptr es:[edi+4].STREAM.qwBuffer,0
	mov	es:[edi].STREAM.dwBufLen,ecx
	mov	es:[edi].STREAM.bCtl2316,10h	; Stream 1
	mov	es:[edi].STREAM.dwLinkPos,eax	; start at the beginning
	mov	es:[edi].STREAM.wLastIdx,1	; only two BDL entries
if	?DEBUGLOG
	invoke	printtolog, CStr("starting stream",0Dh,0Ah)
endif
	or	es:[edi].STREAM.wCtl,11110b	; RUN bit, plus all Interrupt Enable bits

if	?DEBUGLOG
	invoke	printtolog, CStr("connecting stream to DAC",0Dh,0Ah)
endif
	mov	al,[dacnode]
	mov	[node],al
	mov	ax,706h		; set stream and channel
	mov	edx,10h		; Stream 1, on channel 0
	call	send_cmd_wait
if	?DEBUGLOG
	invoke	printtolog, CStr("stream initialized",0Dh,0Ah)
endif

@@skip:
	pop	es

@@failed:
if	?DEBUGLOG
	invoke	closelog
endif
	ret
drv_start	endp

; Stop playing sound
; Takes no parameters
; Returns nothing
drv_stop	proc near
if	?DEBUGLOG
	invoke	openlog, CStr("HDA_STOP.LOG"),0
	invoke	printtolog, CStr("checking if driver is initialized...",0Dh,0Ah)
endif
	bt	[statusword],0
	jnc	@@failed

if	?DEBUGLOG
	invoke	printtolog, CStr("resetting pause status",0Dh,0Ah)
endif
	btr	[statusword],4

	push	es
	call	get_hdareg_ptr
	mov	edi,[firststreamoff]
if	?DEBUGLOG
	invoke	printtolog, CStr("checking if sound is playing...",0Dh,0Ah)
	invoke	printtolog, CStr("Bits in wCtl: ")
	invoke	printbinword,es:[edi].STREAM.wCtl
	invoke	printtolog, CStr(0Dh,0Ah)
endif
	btr	es:[edi].STREAM.wCtl,1	; RUN bit
	jnc	@@skip

	xor	ecx,ecx
	mov	[dwMainBufPhys],ecx
	mov	[dwMainBufSize],ecx

if	?DEBUGLOG
	invoke	printtolog, CStr("Waiting for DMA engine to stop...",0Dh,0Ah)
	invoke	printtolog, CStr("Bits in wCtl: ")
	invoke	printbinword,es:[edi].STREAM.wCtl
	invoke	printtolog, CStr(0Dh,0Ah)
endif
	mov	ecx,1000h
@@:
	call	wait_timerch2
	test	es:[edi].STREAM.wCtl,2	; RUN bit
	loopnz	@B

if	?DEBUGLOG
	invoke	printtolog, CStr("Bits in wCtl: ")
	invoke	printbinword,es:[edi].STREAM.wCtl
	invoke	printtolog, CStr(0Dh,0Ah)
	invoke	printtolog, CStr("Saving format and resetting stream...",0Dh,0Ah)
endif
	push	es:[edi].STREAM.wFormat

	mov	ecx,1000h
	bts	es:[edi].STREAM.wCtl,0	; SRST bit
@@:
	call	wait_timerch2
	test	es:[edi].STREAM.wCtl,1
	loopz	@B
	mov	ecx,1000h
	btr	es:[edi].STREAM.wCtl,0	; SRST bit
@@:
	call	wait_timerch2
	test	es:[edi].STREAM.wCtl,1
	loopnz	@B

if	?DEBUGLOG
	invoke	printtolog, CStr("Stream reset, restoring format",0Dh,0Ah)
	invoke	printtolog, CStr("Bits in wCtl: ")
	invoke	printbinword,es:[edi].STREAM.wCtl
	invoke	printtolog, CStr(0Dh,0Ah)
endif
	pop	es:[edi].STREAM.wFormat

	xor	eax,eax
	cmp	eax,[dwAuxSelHdl]
	jz	@@skip

if	?DEBUGLOG
	invoke	printtolog, CStr("Freeing aux buffer...",0Dh,0Ah)
endif
	xchg	eax,[dwAuxSelHdl]
	call	free_dma_buf

if	?DEBUGLOG
	invoke	printtolog, CStr("Checking if divide-by-zero handler is set...",0Dh,0Ah)
endif
	cmp	[oldDE_seg],0
	jz	@@skip

if	?DEBUGLOG
	invoke printtolog, CStr("yes, resetting it...",0Dh,0Ah)
endif
	mov	ax,2500h	; set interrupt vector 0 (#DE)
	push	ds
	lds	edx,[oldDEhandler]
	int	21h
	pop	ds
if	?DEBUGLOG
	invoke printtolog, CStr("#DE handler reset",0Dh,0Ah)
endif

	xor	eax,eax
	mov	[oldDE_seg],ax
	mov	[oldDE_off],eax

@@skip:
	pop	es

@@failed:
if	?DEBUGLOG
	invoke	closelog
endif
	ret
drv_stop	endp

; Pause sound
; Takes no parameters
; Returns nothing
drv_pause	proc near
if	?DEBUGLOG
	invoke	openlog, CStr("HDAPAUSE.LOG"),0
	invoke	printtolog, CStr("checking if driver is initialized...",0Dh,0Ah)
endif
	bt	[statusword],0
	jnc	@@failed

if	?DEBUGLOG
	invoke	printtolog, CStr("checking if already paused...",0Dh,0Ah)
endif
	bts	[statusword],4
	jc	@@failed

	push	es
	call	get_hdareg_ptr
	mov	edi,[firststreamoff]
if	?DEBUGLOG
	invoke	printtolog, CStr("checking if sound is playing...",0Dh,0Ah)
endif
	btr	es:[edi].STREAM.wCtl,1	; RUN bit
	jnc	@@skip

if	?DEBUGLOG
	invoke	printtolog, CStr("Waiting for DMA engine to pause...",0Dh,0Ah)
endif
	mov	ecx,1000h
@@:
	call	wait_timerch2
	test	es:[edi].STREAM.wCtl,2	; RUN bit
	loopnz	@B

@@skip:
	pop	es

@@failed:
if	?DEBUGLOG
	invoke	closelog
endif
	ret
drv_pause	endp

; Resume sound
; Takes no parameters
; Returns nothing
drv_resume	proc near
if	?DEBUGLOG
	invoke	openlog, CStr("HDA_RSM.LOG"),0
	invoke	printtolog, CStr("checking if driver is initialized...",0Dh,0Ah)
endif
	bt	[statusword],0
	jnc	@@failed

if	?DEBUGLOG
	invoke	printtolog, CStr("checking if paused...",0Dh,0Ah)
endif
	btr	[statusword],4
	jnc	@@failed

	push	es
	call	get_hdareg_ptr
	mov	edi,[firststreamoff]
if	?DEBUGLOG
	invoke	printtolog, CStr("checking if sound is playing...",0Dh,0Ah)
endif
	bts	es:[edi].STREAM.wCtl,1	; RUN bit
	jnc	@@skip

if	?DEBUGLOG
	invoke	printtolog, CStr("Waiting for DMA engine to resume...",0Dh,0Ah)
endif
	mov	ecx,1000h
@@:
	call	wait_timerch2
	test	es:[edi].STREAM.wCtl,2	; RUN bit
	loopz	@B

@@skip:
	pop	es

@@failed:
if	?DEBUGLOG
	invoke	closelog
endif
	ret
drv_resume	endp

; Get device capabilities
; Takes no parameters
; Returns pointer to capabilities structure in EDX
drv_capabilities proc near
if	?DEBUGLOG
	invoke	openlog, CStr("HDA_CAPS.LOG"),0
	invoke	printtolog, CStr("capabilities requested, filling 'port' list...",0Dh,0Ah)
endif
	call	fill_portlist
if	?DEBUGLOG
	jc	@F
	invoke	printtolog, CStr("'port' list filled",0Dh,0Ah)
@@:
endif
	mov	edx,offset sCaps
if	?DEBUGLOG
	invoke	closelog
endif
	ret
drv_capabilities endp

; Empty functions
drv_foreground:
drv_fillinfo:
drv_setcallfn:
	retn

; Get far pointer to timer callback
; Takes no parameters
; Returns far pointer in DX:EAX
drv_getcallfn	proc near
	mov	eax,offset timer_handler
	mov	edx,cs
	ret
drv_getcallfn	endp

; ------------------------------------------------------------------------------ ;
; INTERNAL functions from here (called from within ENUM and interrupt functions) ;
; ------------------------------------------------------------------------------ ;

; Takes file handle in EBX, zero-terminated string in EDX
printtofile	proc near	uses eax ecx es ds edi
	xor	ecx,ecx
	dec	ecx
	push	cs
	pop	es
	mov	edi,edx
	xor	eax,eax
	repne	scasb
	not	ecx		; ECX now has the string length plus one
	dec	ecx

	push	cs
	pop	ds
	mov	eax,4000h	; WRITE
	int	21h
	ret
printtofile	endp

; Unmute and set the amplifier gain to 0 dB for [node]
; If EAX is zero, only does the output amp, otherwise does both input and output
unmute		proc near	uses eax edx
	test	eax,eax
	jz	@F

	mov	ax,0F00h	; get parameter
	mov	edx,0Dh		; input amplifier capabilities
	call	send_cmd_wait
	movzx	edx,ah	; get the "numsteps" (i.e. max) gain value (bits 8-14)
if	?DEBUGLOG
	invoke	printtolog,CStr("input amp max gain of codec/node ")
	invoke	printbinword,[wParam]
	invoke	printtolog,CStr(" is: ")
	invoke	printbinword,dx
	invoke	printtolog,CStr(0Dh,0Ah)
endif

	mov	ax,3		; set amplifier
	mov	dh,70h		; bits 12-14 - set input amp, left and right
	call	send_cmd_wait

@@:
	mov	ax,0F00h	; get parameter
	mov	edx,12h		; output amplifier capabilities
	call	send_cmd_wait
	movzx	edx,ah	; get the "numsteps" (i.e. max) gain value (bits 8-14)
if	?DEBUGLOG
	invoke	printtolog,CStr("output amp max gain of codec/node ")
	invoke	printbinword,[wParam]
	invoke	printtolog,CStr(" is: ")
	invoke	printbinword,dx
	invoke	printtolog,CStr(0Dh,0Ah)
endif

	mov	ax,3		; set amplifier
	mov	dh,0B0h		; bits 12-13/15 - set output amp, left and right
	call	send_cmd_wait

	ret
unmute		endp

; Take a sample rate in AX, and return its index in the rate list in AX, or -1 if absent.
get_rate_idx	proc near	uses ecx edi es
	push	ds
	pop	es

	mov	edi,offset RateList
	mov	ecx,NUM_RATES
	repne	scasw
	sub	edi,2
	xor	eax,eax
	not	eax	; EAX = -1
	scasw		; ES:[EDI] == -1? (This instruction also increments the index, which we want since we count from 1!)
	je @F

	sub	edi,offset RateList
	mov	ax,di
	shr	ax,1

@@:
	ret
get_rate_idx	endp

; Find an audio output converter node attached to the pin widget selected by [node],
; with type given by AL, and return the found node in AL.
; Index of desired rate can be given in SI, and supported rate bitmap is returned in SI.
nodes_seen_bmap	dd 8 dup (?)
find_dac_start	proc near
	; clear the bitmap of nodes we've seen
	push	es
	push	edi
	push	ecx
	push	eax
	mov	ecx,ds
	mov	edi,offset nodes_seen_bmap
	mov	es,ecx
	mov	ecx,8
	xor	eax,eax
	rep	stosd
	pop	eax
	pop	ecx
	pop	edi
	pop	es

	call	find_dac_node
	ret
find_dac_start	endp
find_dac_node	proc near	uses ebx ecx edx edi
	; Local variables:
	; BL = current node (potential return value)
	; BH = current node's type (potential argument to recursive call)
	push	eax		; save the node type

	; establish that we've seen the currently-selected node
	movzx	eax,[node]
	mov	edi,eax
	and	eax,1Fh
	shr	edi,5
	bts	[nodes_seen_bmap+edi*4],eax
	jc	@@found_bupkis	; if we've already seen it, don't run again

	mov	ax,0F00h	; get parameter
	mov	edx,0Eh		; number of connections
	call	send_cmd_wait

	mov	ecx,eax
	xor	eax,eax
	xor	edx,edx
@@:
	.if	!eax
	   mov	ax,0F02h	; get connection nodes
	   call	send_cmd_wait
	   mov	edi,eax
	.endif

	push	[wParam]	; save current node
	push	edx
	mov	[node],al
	mov	bl,al
	mov	ax,0F00h	; get parameter
	mov	edx,9		; widget type
	call	send_cmd_wait
	shr	eax,20
	and	al,0Fh
	cmp	al,WTYPE_AUDIOOUT
	mov	bh,al
	pop	edx
	jne	@@not_dac

	push	edx
	mov	ax,0F00h	; get parameter
	mov	edx,0Ah		; supported PCM size / rates
	call	send_cmd_wait
	bt	eax,17		; supports 16-bit format?
	pop	edx
	jnc	@@not_suitable_dac

	and	si,7		; only look for rates up to number 7 (i.e. 48 kHz)
	dec	si		; R1 <=> Bit 0, etc.
	bt	ax,si		; supports desired rate?
	lea	esi,[esi+1]	; restore value without affecting flags
	jnc	@@not_suitable_dac

	mov	si,ax
	mov	al,bl
	jmp	@@found_one

@@not_dac:
	mov	al,bh
	call	find_dac_node	; recurse
	test	al,al
	jnz	@@found_one

@@not_suitable_dac:
	mov	eax,edi
	shr	eax,8
	inc	edx
	pop	[wParam]
	loop	@B

@@found_bupkis:
	xor	al,al
	lea	esp,[esp+4]	; get rid of the node type on the stack
	jmp	@@retpoint

@@found_one:
	pop	[wParam]	; restore current node

	xchg	[esp],eax	; save the node we've found, and pull up our node's type
if	?DEBUGLOG
	invoke	printtolog,CStr("unmuting codec/node ")
	invoke	printbinword,[wParam]
	invoke	printtolog,CStr(" of type ")
	invoke	printnodetype,al
	invoke	printtolog,CStr("...",0Dh,0Ah)
endif
	cmp	al,WTYPE_MIXER
	je	@F

	lea	eax,[edx+ecx]	; total number of connections
	cmp	eax,1
	jg	@F

	; there's more than one connection and it's not a mixer,
	; so we need to select the connection correctly.
	mov	ax,701h		; select connection
	call	send_cmd_wait

@@:
	mov	eax,1		; include input amp
	call	unmute
	mov	ax,705h		; set power state
	xor	edx,edx		; D0
	call	send_cmd_wait

	pop	eax
@@retpoint:
	ret
find_dac_node	endp

; Get the subordinate nodes of the currently-selected [node]
; Returns the start node in EAX, and the count in EDX
get_subnodes	proc near
	mov	ax,0F00h	; get parameter
	mov	edx,4		; subordinate node count
	call	send_cmd_wait

	movzx	edx,al
	shr	eax,10h
	xor	ah,ah

	ret
get_subnodes	endp

; Allocate a 128-byte-aligned DMA buffer in Extended Memory
; Takes size in EAX, returns XMS handle and selector in upper and lower halves of EAX, and physical address in EDX.
alloc_dma_buf	proc near
	push	ebp
	sub	esp,size RMCS
	mov	ebp,esp
	mov	[ebp].RMCS.resvrd,0

	mov	[ebp].RMCS.rEBP,eax	; stash the size on the stack for now...
	mov	eax,[xmsentry]
	test	eax,eax
	jnz	@F

	; check if XMS is available
	mov	ax,4300h
	int	2Fh
	cmp	al,80h
	jne	@@noxms

	mov	[ebp].RMCS.rAX,4310h	; get XMS driver address
	mov	[ebp].RMCS.rEDX,ebx	; stash EBX
	mov	[ebp].RMCS.rECX,ecx	; stash ECX
	mov	[ebp].RMCS.rEDI,edi	; stash EDI
	push	es

	push	ss
	pop	es
	mov	edi,ebp
	mov	bx,2Fh
	xor	cx,cx
	mov	ax,0300h		; simulate real-mode interrupt
	int	31h

	pop	es
	mov	ebx,[ebp].RMCS.rEDX	; restore EBX
	mov	ecx,[ebp].RMCS.rECX	; restore ECX
	mov	edi,[ebp].RMCS.rEDI	; restore EDI
	jc	@@simfail

	mov	ax,[ebp].RMCS.rES
	shl	eax,10h
	mov	ax,[ebp].RMCS.rBX	; entry point in real-mode ES:BX
	mov	[xmsentry],eax

@@:
	mov	[ebp].RMCS.rCSIP,eax
	mov	[ebp].RMCS.rAX,900h	; allocate EMB

	mov	eax,[ebp].RMCS.rEBP
	add	eax,7Fh			; ensure enough room for 128-byte alignment
	add	eax,3FFh		; round up to nearest kiB
	shr	eax,10			; convert to kiB
	test	eax,0FFFF0000h		; 32-bit number of kiB needed?
	jz	@F
	mov	[ebp].RMCS.rAX,8900h	; allocate any extended memory (XMS 3.0)
@@:
	mov	[ebp].RMCS.rEDX,eax

	mov	[ebp].RMCS.rESI,ebx	; stash EBX
	mov	[ebp].RMCS.rECX,ecx	; stash ECX
	mov	[ebp].RMCS.rEDI,edi	; stash EDI
	push	es

	push	ss
	pop	es
	mov	edi,ebp
	xor	bx,bx
	xor	cx,cx
	mov	ax,0301h		; call real-mode far function
	int	31h

	pop	es
	mov	ebx,[ebp].RMCS.rESI	; restore EBX
	mov	ecx,[ebp].RMCS.rECX	; restore ECX
	mov	edi,[ebp].RMCS.rEDI	; restore EDI
	jc	@@simfail

	cmp	[ebp].RMCS.rAX,1
	jne	@@xmsfail
	mov	ax,[ebp].RMCS.rDX	; get the handle
	push	ax

	mov	[ebp].RMCS.rAX,0C00h	; lock EMB
	push	es
	push	ss
	pop	es
	mov	edi,ebp
	xor	bx,bx
	xor	cx,cx
	mov	ax,0301h		; call real-mode far function
	int	31h

	pop	es
	mov	ebx,[ebp].RMCS.rESI	; restore EBX
	mov	ecx,[ebp].RMCS.rECX	; restore ECX
	mov	edi,[ebp].RMCS.rEDI	; restore EDI
	jc	@@simfail

	mov	dx,[ebp].RMCS.rDX	; upper half of physical address
	shl	edx,10h
	mov	dx,[ebp].RMCS.rBX	; lower half of physical address
	add	edx,7Fh
	and	dl,80h			; ensure 128-byte alignment

	mov	[ebp].RMCS.rEBX,ebx	; stash EBX
	mov	[ebp].RMCS.rESI,esi	; stash ESI

	mov	ecx,edx
	mov	ebx,edx
	shr	ebx,10h			; get physical base into BX:CX
	mov	edi,[ebp].RMCS.rEBP
	mov	esi,edi
	shr	esi,10h			; get desired buffer size into SI:DI
	call	alloc_phys_sel

	mov	ebx,[ebp].RMCS.rEBX	; restore EBX
	mov	ecx,[ebp].RMCS.rECX	; restore ECX
	mov	esi,[ebp].RMCS.rESI	; restore ESI
	mov	edi,[ebp].RMCS.rEDI	; restore EDI
	jc	@@physmapfail

	push	ax
	pop	eax			; now EAX contains the XMS handle and the selector
	clc

@@retpoint:
	lea	esp,[ebp+size RMCS]
	pop	ebp
	ret

@@physmapfail:
	pushw	0
	pop	eax
if	?DEBUGLOG
	invoke	printtolog, CStr("Physical address mapping failed",0Dh,0Ah)
	jmp	@@retpoint_fail

@@noxms:
	invoke	printtolog, CStr("No XMS available, can't allocate DMA buffer",0Dh,0Ah)
	jmp	@@retpoint_fail

@@xmsfail:
	invoke	printtolog, CStr("XMS allocation failed",0Dh,0Ah)
	jmp	@@retpoint_fail

@@simfail:
	invoke	printtolog, CStr("Failed to call real-mode procedure, can't allocate DMA buffer",0Dh,0Ah)
else
@@noxms:
@@xmsfail:
@@simfail:
endif
@@retpoint_fail:
	stc
	jmp	@@retpoint
alloc_dma_buf	endp

; Free a 128-byte-aligned DMA buffer in Extended Memory
; Takes XMS handle and selector in upper and lower halves of EAX, respectively.
free_dma_buf	proc near
	push	ebp
	sub	esp,size RMCS
	mov	ebp,esp
	mov	[ebp].RMCS.resvrd,0

	mov	bx,ax			; get selector
	shr	eax,10h
	mov	[ebp].RMCS.rEDX,eax	; save XMS handle
	call	free_phys_sel

	mov	eax,[xmsentry]
	test	eax,eax
	jz	@F	; if we don't know the XMS entry point, we can't have a valid handle!
	push	es

	mov	[ebp].RMCS.rCSIP,eax
	mov	[ebp].RMCS.rAX,0D00h	; unlock EMB

	push	ss
	pop	es
	mov	edi,ebp
	xor	bx,bx
	xor	cx,cx
	mov	ax,0301h		; call real-mode far function
	int	31h

	mov	[ebp].RMCS.rAX,0A00h	; free EMB
	mov	ax,0301h		; call real-mode far function
	int	31h

	pop	es
@@:
	lea	esp,[ebp+size RMCS]
	pop	ebp
	ret
free_dma_buf	endp

; Take verb in AX and payload in EDX, and return a fully-formed HDA command in EAX
formulate_cmd	proc near
	cwde
	.if	ah		; 12-bit command?
	   shl	eax,8
	.else
	   shl	eax,16
	.endif
	or	eax,edx		; combined verb and payload

	movzx	edx,[wParam]	; codec address and node ID
	shl	edx,20
	or	eax,edx		; combined codec address, node ID, verb and payload

	ret
formulate_cmd	endp

; Take verb in AX and payload in EDX, and send command out on CORB
; Returns pre-command RIRB write pointer in EAX
send_cmd	proc near	uses es gs edi esi
	call	formulate_cmd
	push	eax

	lgs	esi,[lpRirb]
	call	get_hdareg_ptr

	mov	ax,es:[edi].HDAREGS.rirbwp
	shl	eax,10h
	mov	ax,es:[edi].HDAREGS.corbwp
	inc	al
	and	al,[corbwpmask]
	movzx	esi,ax
	pop	dword ptr gs:[esi*4]	; pop command into CORB:[(CORBWP+1)*4]
	mov	es:[edi].HDAREGS.corbwp,si

	shr	eax,10h
	ret
send_cmd	endp

; Take verb in AX and payload in EDX, send command out on CORB,
; and return the response in EAX when it comes in on RIRB
send_cmd_wait	proc near	uses es gs edi
	call	send_cmd
	; now we play the waiting game...
	call	get_hdareg_ptr
	.while	ax == es:[edi].HDAREGS.rirbwp
	   call	wait_timerch2
	.endw

	movzx	eax,es:[edi].HDAREGS.rirbwp
	lgs	edi,[lpRirb]
	mov	eax,gs:[edi+eax*8]

	ret
send_cmd_wait	endp

; wait a bit (copied from "dowait" in Japheth's MIT-licensed hdaplay)
wait_timerch2	proc near	uses eax ecx
	mov	ecx,100h
@@:
	db	0F3h,90h	; pause (mnemonic not accepted by uasm in "386" mode...)
	in	al,61h
	and	al,10h
	cmp	al,ah
	mov	ah,al
	jz	@B
	loop	@B
	ret
wait_timerch2	endp

; get far pointer to HD Audio device's registers in ES:EDI
; spoils EAX/EBX/ECX/EDX/ESI on first call, but not on subsequent calls
get_hdareg_ptr	proc near
	.if	[hdareg_seg] == 0
if	?DEBUGLOG
	 invoke	printtolog, CStr("Creating far pointer to HDA device registers...",0Dh,0Ah)
endif
	 .if	[hdareg_linaddr] == 0
	   call	check_pci_bios
	   jc	@F

if	?DEBUGLOG
	   invoke	printtolog, CStr("Creating linear map to HDA device registers...",0Dh,0Ah)
endif
	   mov	ax,0B10Ah	; read configuration dword
	   mov	di,14h		; BAR1 (upper dword)
	   mov	bx,[wPort]
	   int	1Ah
	   jc	@F
	   test	ecx,ecx		; if upper dword not zero, we're toast! (since we're 32-bit)
	   stc
	   jnz	@F

if	?DEBUGLOG
	   invoke	printtolog, CStr("Reading BAR0...",0Dh,0Ah)
endif
	   mov	ax,0B10Ah	; read configuration dword
	   mov	di,10h		; BAR0 (lower dword)
	   mov	bx,[wPort]
	   int	1Ah
	   jc	@F

if	?DEBUGLOG
	   invoke	printtolog, CStr("Mapping page(s) containing BAR0...",0Dh,0Ah)
endif
	   and	cl,0F0h		; prevent off-by-four errors and the like
	   mov	ebx,ecx
	   shr	ebx,10h		; get the full address into BX:CX
if	?DEBUGLOG
	 invoke	printtolog, CStr("Bits in BAR0: ")
	 invoke	printbinword,bx
	 invoke	printbinword,cx
	 invoke	printtolog, CStr(0Dh,0Ah)
endif
	   xor	esi,esi
	   mov	edi,size HDAREGS
	   call	map_physmem
	   jc	@F

if	?DEBUGLOG
	   invoke	printtolog, CStr("Page map successful",0Dh,0Ah)
endif
	   mov	[hdareg_linaddr],ecx
	   mov	word ptr [hdareg_linaddr+2],bx
	 .else
	   mov	ecx,[hdareg_linaddr]
	   mov	ebx,ecx
	   shr	ebx,10h
	 .endif
if	?DEBUGLOG
	 invoke	printtolog, CStr("Bits in hdareg_linaddr: ")
	 invoke	printbinword,bx
	 invoke	printbinword,cx
	 invoke	printtolog, CStr(0Dh,0Ah)
endif

if	?DEBUGLOG
	 invoke	printtolog, CStr("Allocating selector...",0Dh,0Ah)
endif
	 mov	edi,size HDAREGS
	 xor	esi,esi
	 call	alloc_selector
	 jc	@F
	 mov	[hdareg_seg],ax
if	?DEBUGLOG
	 invoke	printtolog, CStr("Far pointer created successfully",0Dh,0Ah)
endif
	.endif

	les	edi,[hdareg_ptr]
	clc
@@:
	ret
get_hdareg_ptr	endp

alloc_phys_sel	proc near
	; BX:CX = base physical address
	; SI:DI = size
	; returns selector in AX pointing to the physical address in BX:CX
if	?DEBUGLOG
	invoke	printtolog, CStr("alloc_phys_sel: Bits in base address: ")
	invoke	printbinword,bx
	invoke	printbinword,cx
	invoke	printtolog, CStr(0Dh,0Ah,"alloc_phys_sel: Bits in size: ")
	invoke	printbinword,si
	invoke	printbinword,di
	invoke	printtolog, CStr(0Dh,0Ah)
endif
	call	map_physmem
	jc	@F
if	?DEBUGLOG
	invoke	printtolog, CStr("Physical mapping successful",0Dh,0Ah)
endif
	call	alloc_selector
if	?DEBUGLOG
	jc	@F
	invoke	printtolog, CStr("Selector creation successful",0Dh,0Ah)
endif
@@:
	ret
alloc_phys_sel	endp

free_phys_sel	proc near
	; BX = selector
	mov	ax,6			; get segment base address
	int	31h
	jc	@F

	xchg	bx,cx
	xchg	cx,dx			; save the selector in DX
	call	unmap_physmem

	mov	bx,dx
	call	free_selector

@@:
	ret
free_phys_sel	endp

map_physmem	proc near	uses eax edx esi edi
	; BX:CX = base
	; SI:DI = size (preserved after call)
	; returns linear address in BX:CX

	; figure out which pages need to be mapped, and how many
	mov	ax,bx
	shl	eax,10h
	mov	ax,cx
	mov	edx,eax			; EDX points to the beginning of the map

	mov	ax,si
	shl	eax,10h
	mov	ax,di
	add	eax,edx			; EAX points to the end

	and	dx,0F000h		; EDX now points to the first page
	and	ax,0F000h		; EAX now points to the last page
	sub	eax,edx
	add	eax,1000h		; EAX now has the number of pages we need to map (SHL 12)

	xchg	cx,dx
	mov	ebx,edx
	shr	ebx,10h
	mov	di,ax
	mov	esi,eax
	shr	esi,10h
	mov	ax,0800h		; physical address mapping
	int	31h
	jc	@F

	and	edx,0FFFh		; get back the offset into the page
	add	ecx,edx
	clc
@@:
	ret
map_physmem	endp

unmap_physmem	proc near
	; BX:CX = linear address
	and	cx,0F000h		; address passed here may not be page-aligned...
	mov	ax,801h
	int	31h
	ret
unmap_physmem	endp

alloc_selector	proc near
	; BX:CX = base
	; SI:DI = size
	; returns selector in AX
	push	edx
	mov	dx,cx
	xor	ax,ax		; allocate selector
	mov	cx,1		; one selector
	int	31h
	jc	@F

	mov	cx,bx
	mov	bx,ax
	mov	ax,7		; set segment base address
	int	31h
	jc	@F

	mov	dx,di
	mov	cx,si
	mov	ax,8		; set segment limit
	dec	dx		; change size to limit
	sbb	cx,0
	int	31h
	jc	@F

	mov	ax,bx		; return the selector
	clc
@@:
	pop	edx
	ret
alloc_selector	endp

free_selector	proc near
	; BX = selector
	mov	ax,1
	int	31h
	ret
free_selector	endp

fill_portlist	proc near	; fill in the "port" list with all PCI audio devices detected
	push	eax
	push	ebx
	push	ecx
	push	edx

	call	check_pci_bios
	jc	@@noPCI

	push	esi
	xor	esi,esi
	xor	eax,eax
	.while	(esi < DEVSTOENUMERATE) && (ah != 86h)
	   mov	ax,0B103h	; find PCI class code
	   mov	ecx,040300h	; class=4 (multimedia), subclass=3 (audio), no progif
	   int	1Ah
	   jc	@F
	   mov	[PortList+esi*2],bx
	   inc	esi
	@@:
	.endw

	pop	esi
	clc

@@noPCI:
	pop	edx
	pop	ecx
	pop	ebx
	pop	eax
	ret
fill_portlist	endp

check_pci_bios	proc near	; Spoils EAX,EBX,ECX,EDX...
	push	edi

	mov	ax,0B101h
	int	1Ah
	test	ah,ah
	stc
	jnz	@F

	cmp	edx," ICP"
	stc
	jne	@F

	clc
@@:
	pop	edi
	ret
check_pci_bios	endp

mask_irq	proc near	uses eax ecx edx
	movzx	cx,[irq]
	bt	cx,3		; high IRQ?
	jnc	@F
	mov	dx,0A1h
	in	al,dx
	mov	ah,al
@@:
	mov	dx,21h
	in	al,dx
	bts	ax,cx

	bt	cx,3		; high IRQ?
	jnc	@F
	mov	dx,0A1h
	mov	al,ah
@@:
	out	dx,al

	ret
mask_irq	endp

unmask_irq	proc near	uses eax ecx edx
	movzx	cx,[irq]
	bt	cx,3		; high IRQ?
	jnc	@F
	mov	dx,0A1h
	in	al,dx
	mov	ah,al
@@:
	mov	dx,21h
	in	al,dx
	btr	ax,cx

	bt	cx,3		; high IRQ?
	jnc	@F
	btr	ax,2
	out	dx,al		; unmask cascaded interrupt
	mov	dx,0A1h
	mov	al,ah
@@:
	out	dx,al

	ret
unmask_irq	endp

send_eoi	proc near
	mov	al,[mPICeoi]
	mov	dx,20h
	out	dx,al

	mov	al,[sPICeoi]
	test	al,al
	jz	@F
	mov	dx,0A0h
	out	dx,al
@@:

	ret
send_eoi	endp

handle_rirbois	proc near
	; This may not even show up on the terminal if a game is being played!
	invoke	printstderr, CStr(33o,"[31m","Non-fatal: RIRB overrun",33o,"[37m",0Dh,0Ah)
	ret
handle_rirbois	endp

; Hope we never need this...
drv_reset	proc near
	mov	eax,[dwMainBufPhys]
	push	eax
	push	[dwMainBufSize]

	test	eax,eax		; buffer set iff start has been called (i.e. sound playing)
	jz	@F
	pushad
	call	drv_stop
	popad
@@:
	pushad
	call	drv_uninit

	cmp	[crst_count],?CRST_MAX
	jb	@F
	
	; This may not even show up on the terminal if a game is being played!
	invoke	printstderr, CStr(33o,"[31m","FATAL: Too many HDA controller resets!",33o,"[37m",0Dh,0Ah)
	popad
	lea	esp,[esp+8]
	ret

@@:	
	mov	bx,[wPort]
	mov	cx,[wIrqDma]
	mov	al,[pinnode]
	mov	[node],al
	mov	si,[wParam]
	call	drv_init
	popad

	xchg	edi,[esp+4]
	xchg	ecx,[esp]
	test	edi,edi
	jz	@F
	pushad
	call	drv_start
	popad

@@:
	inc	[crst_count]
	pop	ecx
	pop	edi
	ret
drv_reset	endp

handle_cmei	proc near
	invoke	printstderr, CStr(33o,"[31m","CORB Memory Error, attempting reset...",33o,"[37m",0Dh,0Ah)
	call	drv_reset
	invoke	printstderr, CStr(33o,"[31m","Reset complete",33o,"[37m",0Dh,0Ah)
	ret
handle_cmei	endp

; Hope we never need this...
stream_reset	proc near
	mov	eax,[dwMainBufPhys]
	push	eax
	push	[dwMainBufSize]
	pushad
	call	drv_stop
	popad

	cmp	[srst_count],?SRST_MAX
	jb	@F
	
	; This may not even show up on the terminal if a game is being played!
	invoke	printstderr, CStr(33o,"[31m","FATAL: Too many HDA stream resets!",33o,"[37m",0Dh,0Ah)
	popad
	lea	esp,[esp+8]
	ret

@@:	
	xchg	edi,[esp+4]
	xchg	ecx,[esp]
	pushad
	call	drv_start
	popad

	inc	[srst_count]
	pop	ecx
	pop	edi
	ret
stream_reset	endp

handle_dese	proc near
	invoke	printstderr, CStr(33o,"[31m","Stream Descriptor Error, attempting reset...",33o,"[37m",0Dh,0Ah)
	call	stream_reset
	invoke	printstderr, CStr(33o,"[31m","Stream Reset complete",33o,"[37m",0Dh,0Ah)
	ret
handle_dese	endp

handle_fifoe	proc near
	; This may not even show up on the terminal if a game is being played!
	invoke	printstderr, CStr(33o,"[31m","Non-fatal: FIFO underrun",33o,"[37m",0Dh,0Ah)
	ret
handle_fifoe	endp

handle_bcis	proc near
	; This may not even show up on the terminal if a game is being played!
	invoke	printstderr, CStr(33o,"[35m","Unexpected Buffer Completion Interrupt (not programmed for this, at least not yet...)",33o,"[37m",0Dh,0Ah)
	ret
handle_bcis	endp

; ---------------------------------------------------------------------- ;
; EXTERNAL functions from here (called directly from outside our driver) ;
; ---------------------------------------------------------------------- ;
	assume	ds:nothing,fs:nothing

irq_handler	proc
	pushad
	push	ds
	push	es

	mov	ds,cs:[lpPortList_seg]
	assume	ds:_TEXT
	call	get_hdareg_ptr
	movzx	eax,es:[edi].HDAREGS.statests	; don't care about this...
	test	eax,eax
	jz	@F
	mov	es:[edi].HDAREGS.statests,ax	; write 1s back to clear the bits

@@:
	mov	ebx,es:[edi].HDAREGS.intsts
	bt	ebx,31		; GIS
	jnc	@@not_ours

	bts	[statusword],2
	jc	@@skip		; already entered

	bt	ebx,30		; CIS
	jnc	@@not_rirb

	mov	dl,es:[edi].HDAREGS.rirbsts

	bt	dx,2		; RIRBOIS
	jnc	@F
	call	handle_rirbois

@@:
	; don't bother with RINTFL, since we always use send_cmd_wait which polls anyway
	; - this may change in the future...
	;bt	dx,0		; RINTFL
	;jnc	@F
	;call	handle_rintfl

@@:
	; write 1s back to the bits we've addressed
	mov	es:[edi].HDAREGS.rirbsts,dl

	mov	dl,es:[edi].HDAREGS.corbsts
	bt	dx,0		; CMEI
	jnc	@F
	call	handle_cmei
@@:
	; write 1s back to the bits we've addressed
	mov	es:[edi].HDAREGS.corbsts,dl

@@not_rirb:
	movzx	eax,es:[edi].HDAREGS.gcap
	shr	eax,8
	and	eax,0Fh		; number of input streams
	bt	ebx,eax		; SIS from the first output stream
	jnc	@@not_stream

	mov	edi,[firststreamoff]
	mov	dl,es:[edi].STREAM.bSts

	bt	dx,4		; DESE
	jnc	@F
	call	handle_dese

@@:
	bt	dx,3		; FIFOE
	jnc	@F
	call	handle_fifoe

@@:
	bt	dx,2		; BCIS
	jnc	@F
	call	handle_bcis

@@:
	; write 1s back to the bits we've addressed
	mov	es:[edi].STREAM.bSts,dl

@@not_stream:
	call	send_eoi
	btr	[statusword],2

@@skip:
	pop	es
	pop	ds
	assume	ds:nothing
	popad
	iretd

@@not_ours:
	pop	es
	pop	ds
	popad
	jmp	cs:[oldIRQhandler]
irq_handler	endp

; Called from the timer (16-bit stereo pseudo-DMA)
; Takes far pointer to DMA buffer in ES:[EDI]
; Returns the address at which we next want it filled in EAX,
; and the address behind which we want it blanked in EDX.
timer_handler	proc far
	push	ds
	xor	eax,eax		; return zero by default
	mov	edx,eax

	mov	ds,cs:[lpPortList_seg]
	assume	ds:_TEXT
	bts	[statusword],3
	jc	@@donotenter
	bt	[statusword],0
	jnc	@@skip

	mov	[crst_count],al
	mov	[srst_count],al

	push	fs
	push	esi
	push	ecx

	push	es
	pop	fs
	mov	esi,edi		; FS:[ESI] points to the main buffer

	call	get_hdareg_ptr
	mov	edi,[firststreamoff]
	mov	edx,es:[edi].STREAM.dwLinkPos
	mov	eax,es:[edi].STREAM.dwBufLen
	mov	ecx,eax
	shr	eax,1		; Fill halfway through the DMA buffer (like the GUS driver)
	add	eax,edx
	cmp	eax,ecx
	jb	@F
	sub	eax,ecx		; Wrap around through beginning of buffer
@@:

	cmp	[dwAuxSelHdl],0
	jz	@@noaux		; No aux buffer, OK to return what we have

	push	gs
	push	esi

	lgs	esi,[lpAuxBufFilled]
	mov	[dwLastFillEAX],eax
	mov	ecx,eax
	sub	ecx,esi
	jnb	@@nowrap

	mov	ecx,es:[edi].STREAM.dwBufLen
	sub	ecx,esi		; get the distance to the end of the buffer
	shr	ecx,2		; convert to dwords
	push	es

	push	gs
	pop	es		; ES points to aux buffer
	mov	edi,esi

	push	edx
	push	eax
	mov	eax,esi
	xor	edx,edx
	movzx	esi,[soft_divider]
	div	esi
	mov	esi,eax

	mov	edx,ecx
@@:
	movzx	ecx,[soft_divider]
	lodsd	fs:[esi]
	sub	edx,ecx
	rep	stosd		; copy what's been filled in, to the aux buffer
	ja	@B		; flags set by subtraction above
	pop	eax
	pop	edx
	pop	es

	xor	esi,esi		; back to start of the buffer
	mov	ecx,eax

@@nowrap:
	shr	ecx,2		; convert to dwords
	push	es
	push	ds

	push	gs
	pop	es		; ES points to aux buffer
	mov	edi,esi
	push	edx
	push	eax
	mov	eax,esi
	xor	edx,edx
	movzx	esi,[soft_divider]
	div	esi
	mov	esi,eax

	mov	edx,ecx
@@:
	movzx	ecx,[soft_divider]
	lodsd	fs:[esi]
	sub	edx,ecx
	rep	stosd		; copy what's been filled in to the aux buffer
	ja	@B		; flags set by subtraction above
	pop	eax
	pop	edx
	pop	es

	pop	esi
	pop	gs

	; convert buffer positions
	movzx	ecx,[soft_divider]

	push	edx
	xor	edx,edx
	div	ecx
	pop	edx

	push	eax
	mov	eax,edx
	xor	edx,edx
	div	ecx
	mov	edx,eax
	pop	eax

	jmp	@F		; previous position already set above

@@noaux:
	mov	[dwLastFillEAX],eax
@@:
	mov	edi,esi
	push	fs
	pop	es

	pop	ecx
	pop	esi
	pop	fs
@@skip:
	btr	[statusword],3
@@donotenter:
	pop	ds
	assume	ds:nothing
	ret
timer_handler	endp

; handle division errors that pop up,
; at least if DPMI host doesn't have proper exception handling
div0_handler	proc
	mov	ds,cs:[lpPortList_seg]
	assume	ds:_TEXT

	mov	ax,3		; switch to VGA text mode
	int	10h
	invoke	printstderr, CStr(33o,"[31m","FATAL: Division error (")
	mov	eax,cs
	.if	eax != [esp+4]
	 invoke	printstderr, CStr("not ")
	.endif
	invoke	printstderr, CStr("within HD Audio Driver). Quitting...",33o,"[37m",0Dh,0Ah)

	mov	ax,4CFFh	; exit with 255 status code
	sti
	int	21h
div0_handler	endp

; handle protection errors that pop up,
; at least if DPMI host doesn't have proper exception handling
gp_handler	proc
	mov	ds,cs:[lpPortList_seg]
	assume	ds:_TEXT

	mov	ax,3		; switch to VGA text mode
	int	10h
	invoke	printstderr, CStr(33o,"[31m","FATAL: Protection error (")
	mov	eax,cs
	.if	eax != [esp+8]	; since [esp] == error code
	 invoke	printstderr, CStr("not ")
	.endif
	invoke	printstderr, CStr("within HD Audio Driver). Quitting...",33o,"[37m",0Dh,0Ah)

	mov	ax,4CFFh	; exit with 255 status code
	sti
	int	21h
gp_handler	endp

_TEXT	ends

; make sure the assembler knows all the CStrs are in the right segment!
DGROUP	group	_TEXT, CONST

end	start
