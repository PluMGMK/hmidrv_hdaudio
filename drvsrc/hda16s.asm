; 16-bit Stereo HD Audio driver for HMIDRV.386

	.386
	.model	small
	include	comdecs.inc

?CDAUDIO	equ 1

_TEXT	segment	use32
	assume	ds:nothing,es:nothing,gs:nothing,fs:_TEXT

	.code
	org 0
hda16s:
	jmp	entry

align 4
	include	comdata.inc
lpAuxBufFilled	label	fword	; Far pointer to aux buffer when main one not 128-byte-aligned
dwLastFillEAX	dd 0		; Value returned in EAX at last call to timer function
dwAuxSelHdl	label	dword
wAuxSel		dw 0
wAuxHdl		dw 0
dwAuxDpmiHdl	dd 0

firststreamoff	dd 0

dwMainBufPhys	dd 0		; Physical address of DMA buffer passed from host application
dwMainBufSize	dd 0		; Size of DMA buffer passed from host application

mPICeoi		db 0		; EOI signal to send to master PIC
sPICeoi		db 0		; EOI signal (if any) to send to slave PIC

oldIRQhandler	label	fword
oldIRQ_off	dd 0
oldIRQ_seg	dw 0
ifdef	?FLASHTEK
oldIRQ_RM	dd 0
endif

irqvec		db 0		; the actual interrupt vector corresponding to our IRQ
oldpciirq	db 0		; the interrupt line of the controller before we set it

if	?CDAUDIO
?CDBUFSIZE	equ 10h		; size in sectors
?CDVOLCTL	equ 0
?AGGRESSIVEIRQ0	equ 0		; unmask IRQ0 upon any "PLAY AUDIO" request

CDSECTORSIZE	equ 930h	; a constant, defined in the Red Book standard
CDBUFSIZEDWORDS	equ ?CDBUFSIZE * CDSECTORSIZE SHR 2

IOCTLRW	struc			; IOCTL read/write request
	bLen	db ?		; 3 for read, 12 for write
	bUnit	db ?
	bCmd	db ?
	wStatus	dw ?
	_resd	dq ?
	_resd1	db ?		; media descriptor byte = 0 for MSCDEX
	wBufOff	dw ?
	wBufSeg	dw ?
	wCount	dw ?
	_resd2	dw ?		; starting sector number = 0 for MSCDEX
	_resd3	dd ?		; volume ID = 0 for MSCDEX
IOCTLRW	ends

ReadL	struc
	bLen	db ?
	bUnit	db ?
	bCmd	db ?
	wStatus	dw ?
	_resd	dq ?
	bAMode	db ?		; addressing mode (RedBook / High Sierra)
	wBufOff	dw ?
	wBufSeg	dw ?
	wSectors dw ?
	dwStart	dd ?		; first sector
	bRMode	db ?		; read mode (cooked / raw) - use raw to get 930h
	bISize	db ?		; interleave size
	bISkip	db ?		; interleave skip factor
ReadL	ends

PlayReq	struc
	bLen	db ?
	bUnit	db ?
	bCmd	db ?
	wStatus	dw ?
	_resd	dq ?
	bAMode	db ?		; addressing mode (RedBook / High Sierra)
	dwStart	dd ?		; first sector
	dwSectors dd ?
PlayReq	ends

OutChanInfo	struc
	bInChan	db ?		; input channel for this output channel
	bVolume	db ?		; volume knob for this output channel
OutChanInfo	ends

AudInfo		struc
	bCode	db ?		; 4 for read, 3 for write
	Info	OutChanInfo 4 dup (<?>)
AudInfo		ends

AudStat		struc
	bCode	db ?		; 15 for read
	wStatus	dw ?		; Bit 0 = paused, all others reserved
	dwStart	dd ?
	dwEnd	dd ?
AudStat		ends

; dwStat meaning:
; Bit 0 = door open
; Bit 1 = door unlocked
; Bit 2 = supports raw reading (needed to be useful to us)
; Bit 3 = writeable
; Bit 4 = can play audio/video
; Bit 5 = interleaving supported
; Bit 6 = reserved
; Bit 7 = supports prefetching (needed to be useful to us)
; Bit 8 = supports audio channel manipulation
; Bit 9 = supports Red Book addressing mode
DevStat		struc
	bCode	db ?		; 6 for read
	dwStat	dd ?
DevStat		ends

QInfo		struc
	bCode	db ?		; 12 for read
	bCtlADR	db ?
	bTrack	db ?
	bPoint	db ?
	bMinute	db ?
	bSecond	db ?
	bFrame	db ?
	_resd	db ?		; zero
	bPMin	db ?
	bPSec	db ?
	bPFrame	db ?
QInfo		ends

; layout of our first conventional-memory buffer for querying CD drives
CdRmHeadBuf	struc
	wFirstS	dw ?		; selector of first buffer in linked list
	bDrives	db ?		; number of drives available
	sReq	IOCTLRW<?>
	sInfo	DevStat<?>
	sRmCall	RMCS <>
CdRmHeadBuf	ends

; layout of our per-drive conventional-memory buffers for talking to MSCDEX
CdRmDriveBuf	struc
	wNextS	dw ?		; selector of next buffer in linked list
	bDrive	db ?		; index of drive associated with this buffer
	sReq	ReadL<?>
	sInfo	AudInfo<?>
	sStat	AudStat<?>
	sQChan	QInfo<?>
	wStatus	dw ?		; set bit 9 to indicate we're playing
				; also bit 0 to indicate prefetch possible...
	dwBufPos dd ?
	dwBufEnd dd ?
	align	10h		; make it its own segment...
	Samples	dd CDBUFSIZEDWORDS dup (?)
CdRmDriveBuf	ends

; Pointer to head buffer
wCdRmBufSel	dw ?
wCdRmBufSeg	dw ?

; selector for entire MiB of Real Mode memory
wRmMemSel	dw ?

; real-mode callback to set the busy bit on return from an intercepted int 2F
dwSetBusyCB	label dword
wSetBusyCBOff	dw ?
wSetBusyCBSeg	dw ?

dwOldInt2F	label dword
wOldInt2FOff	dw ?
wOldInt2FSeg	dw ?

bCdDivider	db 1	; set to 2 if running at 96 kHz (to simulate 32 kHz)
endif

; Bit 0 = successfully initialized
; Bit 1 = timer entered
; Bit 2 = IRQ entered
; Bit 3 = Timer entered
; Bit 4 = Sound paused
; Bit 5 = Sound temporarily stopped (e.g. for setting rate)
; Bit 6 = CD Audio possible
; Bit 7 = XMS needed (linear addresses != physical)
statusword	dw 1 SHL 7
; bitmap representing rates supported by the currently-selected DAC node
ratebitmap	dw 0

CHECK_XMS_NEEDED	macro
	bt	[statusword],7
endm

; software rate divider
soft_divider	db 1

pinnode		db 0
afgnode		db 0
dacnode		db 0

; number of Controller/Stream Resets attempted during the current timer period
; (in response to error interrupts)
crst_count	db 0
srst_count	db 0
; give up after this many:
?CRST_MAX	equ 3
?SRST_MAX	equ 3

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

	include	comfuncs.inc

if	?CDAUDIO and ?DEBUGLOG
; Print nth drive letter to the debug log
curdriveletter	db ?
		db 0
printdriveletter	proc near stdcall	uses eax	bOut:byte
	mov	al,[bOut]
	add	al,'A'
	mov	[curdriveletter],al

	invoke	printtolog, offset curdriveletter
	ret
printdriveletter	endp
endif

if	?DEBUGLOG
announcecopy	proc near
	invoke	printtolog, CStr("copying ")
	ror	edx,10h
	invoke	printbinword,dx
	ror	edx,10h
	invoke	printbinword,dx

	invoke	printtolog, CStr("b dwords;",0Dh,0Ah,"    from: ")
	ror	esi,10h
	invoke	printbinword,si
	ror	esi,10h
	invoke	printbinword,si

	invoke	printtolog, CStr("b (main buffer)",0Dh,0Ah,"      to: ")
	ror	edi,10h
	invoke	printbinword,di
	ror	edi,10h
	invoke	printbinword,di
	invoke	printtolog, CStr("b (aux buffer);",0Dh,0Ah,"   limit: ")

	push	edi
	mov	edi,es
	lsl	edi,edi
	ror	edi,10h
	invoke	printbinword,di
	ror	edi,10h
	invoke	printbinword,di
	invoke	printtolog, CStr("b (aux buffer)",0Dh,0Ah)
	pop	edi

	ret
announcecopy	endp
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

	call	check_paging
	jc	@F
	btr	[statusword],7

@@:
	call	alloc_CORB_RIRB
	jc	@@init_failed_esok

	push	es
	call	get_hdareg_ptr
	jc	@@init_failed

	call	init_cntrlr
	jc	@@init_failed

@@:
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
	call	set_busmaster
	jc	@@init_failed

	call	start_CORB_RIRB
	jc	@@init_failed

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
	invoke	printtolog, CStr("b is not a DAC (it is a ")
	invoke	printnodetype,al
	invoke	printtolog, CStr(")",0Dh,0Ah)
endif
	jmp	@@init_failed

@@:
if	?DEBUGLOG
	invoke	printtolog, CStr("DAC found at codec/node ")
	invoke	printbinword,[wParam]
	invoke	printtolog, CStr("b, unmuting...",0Dh,0Ah)
endif
	xor	eax,eax		; only the output amplifier
	call	unmute
	mov	ax,0705h	; set power state
	xor	edx,edx		; D0
	call	send_cmd_wait

	mov	al,[pinnode]
	mov	[node],al
	; no need to unmute pin because it already happened during the search
	mov	ax,0707h	; set pin widget control
	mov	edx,40h		; only out enable
	call	send_cmd_wait

if	?DEBUGLOG
	invoke	printtolog, CStr("DAC unmuted, pin configured, now resetting output streams",0Dh,0Ah)
endif

	call	get_hdareg_ptr
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
ifdef	?FLASHTEK
	mov	cl,al
	mov	ax,2503h	; Phar Lap / FlashTek: get RM interrupt vector
	int	21h
	mov	[oldIRQ_RM],ebx
	mov	ax,2502h	; Phar Lap / FlashTek: get interrupt vector
else
	mov	ah,35h		; get interrupt vector
endif
	int	21h
	mov	[oldIRQ_off],ebx
	mov	[oldIRQ_seg],es

	push	ds
	push	cs
	pop	ds
	mov	edx,offset irq_handler
ifdef	?FLASHTEK
	mov	ax,2506h	; Phar Lap / FlashTek: set interrupt to gain control in PM
else
	mov	ah,25h		; set interrupt vector
endif
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
	 mov	es:[edi].HDAREGS.statests,ax	; write 1s back to clear
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

	   mov	al,[irqvec]
ifdef	?FLASHTEK
	   mov	cl,al
	   mov	ebx,[oldIRQ_RM]
	   mov	ax,2507h	; Phar Lap / FlashTek: set RM/PM int vectors
else
	   mov	ah,25h		; set interrupt vector
endif
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

	mov	ebx,[dwCorbDpmiHdl]
	call	free_dma_buf
	xor	eax,eax
	mov	[dwCorbPhys],eax
	mov	[dwCorbSelHdl],eax
	.if	[dwTSRbuf]
	   mov	[dwTSRbufoffset],eax	; reset the bump allocator
	.endif
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
	invoke	printtolog, CStr("requested rate: ")
	invoke	printbinword,bx
	invoke	printtolog, CStr("b",0Dh,0Ah)
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
	invoke	printtolog, CStr("[rate support bitmap: ")
	invoke	printbinword,[ratebitmap]
	invoke	printtolog, CStr("; rate index: ")
	invoke	printbinword,ax
	invoke	printtolog, CStr("b]",0Dh,0Ah)
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
	invoke	printtolog, CStr("b, unmuting...",0Dh,0Ah)
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
if	?CDAUDIO
	mov	bl,bh
	shr	bl,3
	and	bl,7		; three middle bits = multiplier
	inc	bl		; convert zero to one, etc.
	mov	[bCdDivider],bl
endif
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
	jna	@F

if	?DEBUGLOG
	invoke	printtolog, CStr("software divider in operation (")
	movzx	ax,[soft_divider]
	invoke	printbinword,ax
	invoke	printtolog, CStr("b), creating new buffer...",0Dh,0Ah,"[")
	invoke	printbinword,word ptr [dwMainBufSize+2]
	invoke	printbinword,word ptr [dwMainBufSize]
	invoke	printtolog, CStr("b --> ")
endif
	mov	eax,ecx
	movzx	ecx,[soft_divider]
	mul	ecx		; destroys EDX, but alloc_dma_buf sets it anyway
	mov	ecx,eax
if	?DEBUGLOG
	ror	ecx,10h
	invoke	printbinword,cx
	ror	ecx,10h
	invoke	printbinword,cx
	invoke	printtolog, CStr("b]",0Dh,0Ah)
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
	mov	[dwAuxDpmiHdl],ebx
if	?DEBUGLOG
	invoke	printtolog, CStr("128-byte-aligned aux buffer created, clearing...",0Dh,0Ah)
endif

	xor	eax,eax
	push	edi
	push	es
	push	ecx
	les	edi,[lpAuxBufFilled]
	xor	edi,edi	; just in case...
	shr	ecx,2
	rep	stosd
	pop	ecx
	pop	es
	pop	edi
if	?DEBUGLOG
	invoke	printtolog, CStr("aux buffer cleared",0Dh,0Ah)
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

if	?CDAUDIO
ifdef	?FLASHTEK
	; FlashTek doesn't have functions for dynamically allocating Real-Mode
	; memory and callbacks, so this stuff will only work if there's DPMI
	; running behind it...
if	?DEBUGLOG
	invoke	printtolog, CStr("checking if running under DPMI...",0Dh,0Ah)
endif
	mov	ax,1686h	; DPMI - detect mode
	int	2Fh
	test	ax,ax
	jnz	@@skip
endif

if	?DEBUGLOG
	invoke	printtolog, CStr("checking if MSCDEX is available...",0Dh,0Ah)
endif
	mov	ax,1500h	; MSCDEX installation check
	xor	bx,bx
	int	2Fh
	test	bx,bx
	jz	@@skip

if	?DEBUGLOG
	invoke	printtolog, CStr("MSCDEX installed with ")
	invoke	printbinword,bx
	invoke	printtolog, CStr("b drives, beginning on ")
	invoke	printdriveletter,cl
	invoke	printtolog, CStr(":",0Dh,0Ah,"checking the version...",0Dh,0Ah)
endif

	mov	si,bx		; save number of drives
	mov	ax,150Ch
	xor	bx,bx
	int	2Fh
	cmp	bx,20Ah		; 2.10 needed for IOCTL requests
	jb	@@skip
if	?DEBUGLOG
	invoke	printtolog, CStr("MSCDEX > 2.10 installed, allocating buffer to check drives...",0Dh,0Ah)
endif

	mov	bx,(size CdRmHeadBuf + 0Fh) SHR 4
	mov	ax,100h		; allocate DOS memory block
	int	31h

if	?DEBUGLOG
	jnc	@F
	cmp	ax,8
	jne	@@skip
	invoke	printtolog, CStr("Insufficient memory - largest MCB is ")
	invoke	printbinword,bx
	invoke	printtolog, CStr("b paragraphs",0Dh,0Ah)
	jmp	@@skip
@@:
else
	jc	@@skip
endif

	mov	[wCdRmBufSeg],ax
	mov	[wCdRmBufSel],dx
	mov	es,dx
	push	gs
	mov	gs,dx

	mov	dx,cx		; save first drive
if	?DEBUGLOG
	invoke	printtolog, CStr("buffer allocated, clearing...",0Dh,0Ah)
endif
	xor	edi,edi
	xor	eax,eax
	mov	ecx,(size CdRmHeadBuf + 3) SHR 2
	rep	stosd
if	?DEBUGLOG
	invoke	printtolog, CStr("buffer cleared, checking drives...",0Dh,0Ah)
endif

	mov	ax,[wCdRmBufSeg]
	mov	es:[CdRmHeadBuf.sRmCall.rCX],dx
	mov	es:[CdRmHeadBuf.sRmCall.rES],ax
	mov	es:[CdRmHeadBuf.sRmCall.rBX],CdRmHeadBuf.sReq

	mov	es:[CdRmHeadBuf.sInfo.bCode],6		; device status

	push	ebp
	.while	si
if	?DEBUGLOG
	  invoke printtolog, CStr("checking drive ")
	  invoke printdriveletter,byte ptr es:[CdRmHeadBuf.sRmCall.rCX]
	  invoke printtolog, CStr(": for suitability...",0Dh,0Ah)
endif
	  mov	ax,[wCdRmBufSeg]
	  mov	es:[CdRmHeadBuf.sReq.bLen],size IOCTLRW
	  mov	es:[CdRmHeadBuf.sReq.bCmd],3		; IOCTL read
	  mov	es:[CdRmHeadBuf.sReq.wBufSeg],ax
	  mov	es:[CdRmHeadBuf.sReq.wBufOff],CdRmHeadBuf.sInfo
	  mov	es:[CdRmHeadBuf.sReq.wCount],size DevStat

	  mov	es:[CdRmHeadBuf.sRmCall.rAX],1510h	; send device request 
	  mov	ax,300h		; simulate real mode interrupt
	  mov	bx,2Fh
	  xor	cx,cx
	  mov	edi,CdRmHeadBuf.sRmCall
	  int	31h
	  jc	@@next
	  bt	es:[CdRmHeadBuf.sRmCall.rFlags],0
	  jc	@@next

if	?DEBUGLOG
	  invoke printtolog, CStr("drive status request sent...",0Dh,0Ah)
endif
	  mov	eax,es:[CdRmHeadBuf.sInfo.dwStat]
	  bt	eax,2
	  jnc	@@next
if	?DEBUGLOG
	  invoke printtolog, CStr("supports raw reading",0Dh,0Ah)
endif
	  xor	ebp,ebp
	  bt	eax,7
	  jnc	@F
if	?DEBUGLOG
	  invoke printtolog, CStr("supports prefetching",0Dh,0Ah)
endif
	  mov	ebp,1

@@:
	  mov	ax,100h		; allocate DOS memory block
	  mov	bx,(size CdRmDriveBuf + 0Fh) SHR 4
	  int	31h
if	?DEBUGLOG
	  jnc	@F
	  cmp	ax,8
	  jne	@@skip
	  invoke printtolog, CStr("Insufficient memory for drive buffer - largest MCB is ")
	  invoke printbinword,bx
	  invoke printtolog, CStr("b paragraphs",0Dh,0Ah)
	  jmp	@@next
@@:
else
	  jc	@@next
endif

	  push	es
	  mov	es,dx
	  mov	bx,ax
if	?DEBUGLOG
	  invoke printtolog, CStr("drive buffer allocated, clearing...",0Dh,0Ah)
endif
	  xor	edi,edi
	  xor	eax,eax
	  mov	ecx,(size CdRmDriveBuf + 3) SHR 2
	  rep	stosd
if	?DEBUGLOG
	  invoke printtolog, CStr("drive buffer cleared, saving audio channel info...",0Dh,0Ah)
endif
	  pop	es

	  mov	gs:[CdRmDriveBuf.wNextS],dx	; or CdRmHeadBuf.wFirstS
	  mov	gs,dx

	  mov	ax,es:[CdRmHeadBuf.sRmCall.rCX]
	  mov	gs:[CdRmDriveBuf.bDrive],al
	  mov	gs:[CdRmDriveBuf.wStatus],bp	; save prefetch ability

	  mov	gs:[CdRmDriveBuf.sReq.bLen],size ReadL
	  ;mov	gs:[CdRmDriveBuf.sReq.bCmd],80h		; READ LONG
	  mov	gs:[CdRmDriveBuf.sReq.wBufOff],CdRmDriveBuf.Samples
	  mov	gs:[CdRmDriveBuf.sReq.wBufSeg],bx
	  mov	gs:[CdRmDriveBuf.sReq.bRMode],1		; raw

	  mov	gs:[CdRmDriveBuf.sInfo.bCode],4		; audio channel info
	  mov	gs:[CdRmDriveBuf.sQChan.bCode],0Ch	; audio Q-Channel info
	  mov	gs:[CdRmDriveBuf.sStat.bCode],0Fh	; audio status info

	  ;mov	es:[CdRmHeadBuf.sReq.bLen],size IOCTLRW
	  ;mov	es:[CdRmHeadBuf.sReq.bCmd],3		; IOCTL read
	  mov	es:[CdRmHeadBuf.sReq.wBufSeg],bx
	  mov	es:[CdRmHeadBuf.sReq.wBufOff],CdRmDriveBuf.sInfo
	  mov	es:[CdRmHeadBuf.sReq.wCount],size AudInfo

	  mov	es:[CdRmHeadBuf.sRmCall.rAX],1510h	; send device request 
	  mov	ax,300h		; simulate real mode interrupt
	  mov	bx,2Fh
	  xor	cx,cx
	  mov	edi,CdRmHeadBuf.sRmCall
	  int	31h
if	?DEBUGLOG
	  invoke printtolog, CStr("audio channel info saved, stopping any current playback...",0Dh,0Ah)
endif

	  ; TODO: Seamlessly take over any ongoing audio playback?
	  ; (Would need to fill sStat and sQChan, and set wStatus and dwBufPos)
	  mov	es:[CdRmHeadBuf.sReq.bLen],0Dh
	  mov	es:[CdRmHeadBuf.sReq.bCmd],133		; STOP AUDIO
	  mov	es:[CdRmHeadBuf.sRmCall.rAX],1510h	; send device request 
	  mov	ax,300h		; simulate real mode interrupt
	  int	31h
if	?DEBUGLOG
	  invoke printtolog, CStr("drive ready to use!",0Dh,0Ah)
endif
	  inc	es:[CdRmHeadBuf.bDrives]

@@next:
	  ; next drive
	  inc	es:[CdRmHeadBuf.sRmCall.rCX]
	  dec	si
	.endw
	pop	ebp

@@cddone:
	pop	gs
	.if	es:[CdRmHeadBuf.bDrives]
if	?DEBUGLOG
	   invoke printtolog, CStr("drive(s) set up, installing interrupt handler...",0Dh,0Ah)
endif
	   xor	cx,cx
	   mov	bx,cx
	   mov	di,cx
	   mov	si,10h		; SI:DI = 100000h = 1 MiB
	   call	alloc_selector
	   jc	@@skip
	   mov	[wRmMemSel],ax
if	?DEBUGLOG
	   invoke printtolog, CStr("allocated selector for real-mode memory",0Dh,0Ah)
endif

	   mov	ax,200h		; get real mode interrupt vector
	   mov	bl,2Fh
	   int	31h
	   mov	[wOldInt2FOff],dx
	   mov	[wOldInt2FSeg],cx

	   mov	ax,303h		; allocate real-mode callback
	   push	ds
	   push	cs
	   pop	ds
	   mov	esi,offset int2f_setbusy
	   mov	edi,CdRmHeadBuf.sRmCall
	   int	31h
	   pop	ds
	   jc	@@skip
if	?DEBUGLOG
	   invoke printtolog, CStr("real-mode callback created to set busy bit",0Dh,0Ah)
endif
	   mov	[wSetBusyCBOff],dx
	   mov	[wSetBusyCBSeg],cx

	   mov	ax,303h		; allocate real-mode callback
	   push	ds
	   push	cs
	   pop	ds
	   mov	esi,offset int2f_handler
	   mov	edi,CdRmHeadBuf.sRmCall
	   int	31h
	   pop	ds
	   jc	@@skip
if	?DEBUGLOG
	   invoke printtolog, CStr("real-mode callback created for int 2F handler",0Dh,0Ah)
endif

	   mov	ax,201h		; set real mode interrupt vector
	   mov	bl,2Fh
	   int	31h
if	?DEBUGLOG
	   invoke printtolog, CStr("handler installed!",0Dh,0Ah)
endif

	   bts	[statusword],6
	.else
if	?DEBUGLOG
	   invoke printtolog, CStr("no usable drives, freeing buffer...",0Dh,0Ah)
endif
	   mov	ax,101h		; free DOS memory block
	   mov	dx,es
	   xor	cx,cx
	   mov	es,cx	; nullify ES so we don't end up with an invalid selector
	   int	31h
if	?DEBUGLOG
	   invoke printtolog, CStr("buffer freed",0Dh,0Ah)
endif
	   xor	eax,eax
	   mov	dword ptr [wCdRmBufSel],eax
	.endif
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
	;invoke	logtostderr
	invoke	printtolog, CStr("checking if driver is initialized...",0Dh,0Ah)
endif
	bt	[statusword],0
	jnc	@@failed

if	?DEBUGLOG
	invoke	printtolog, CStr("resetting pause status",0Dh,0Ah)
endif
	btr	[statusword],4

if	?CDAUDIO
if	?DEBUGLOG
	invoke	printtolog, CStr("checking if CD audio is set up...",0Dh,0Ah)
endif
	btr	[statusword],6
	jnc	@F

if	?DEBUGLOG
;	invoke	printtolog, CStr("fillcdbuf last ran at ")
;	invoke	printbinword,[lasttimertick_hi]
;	invoke	printbinword,[lasttimertick_lo]
;	invoke	printtolog, CStr("b ticks;",0Dh,0Ah)
;
;	invoke	printtolog, CStr("i.e. ")
;	xor	ah,ah		; GET SYSTEM TIME
;	int	1Ah
;	sub	dx,[lasttimertick_lo]
;	sbb	cx,[lasttimertick_hi]
;	.if	al	; Midnight
;	   add	dx,0B0h
;	   adc	cx,18h
;	.endif
;	invoke	printbinword,cx
;	invoke	printbinword,dx
;	invoke	printtolog, CStr("b ticks ago",0Dh,0Ah)

	invoke	printtolog, CStr("freeing callbacks...",0Dh,0Ah)
endif
	mov	ax,200h		; get real mode interrupt vector
	mov	bl,2Fh
	int	31h
	mov	ax,304h		; free real mode callback
	int	31h
	mov	dx,[wSetBusyCBOff]
	mov	cx,[wSetBusyCBSeg]
	mov	ax,304h		; free real mode callback
	int	31h
if	?DEBUGLOG
	invoke	printtolog, CStr("callbacks freed, resetting vector...",0Dh,0Ah)
endif

	mov	dx,[wOldInt2FOff]
	mov	cx,[wOldInt2FSeg]
	mov	ax,201h		; set real mode interrupt vector
	mov	bl,2Fh
	int	31h
if	?DEBUGLOG
	invoke	printtolog, CStr("handler uninstalled",0Dh,0Ah)
endif

@@:
	mov	bx,[wRmMemSel]
	test	bx,bx
	jz	@F
if	?DEBUGLOG
	invoke printtolog, CStr("freeing selector for real-mode memory...",0Dh,0Ah)
endif
	call	free_selector

@@:
if	?DEBUGLOG
	invoke	printtolog, CStr("checking if CD audio linked list exists...",0Dh,0Ah)
endif
	cmp	dword ptr [wCdRmBufSel],0
	jz	@@cddone

if	?DEBUGLOG
	invoke	printtolog, CStr("freeing CD buffers...",0Dh,0Ah)
endif
	push	gs
	mov	gs,[wCdRmBufSel]
@@:
	mov	dx,gs
	mov	gs,gs:[CdRmDriveBuf.wNextS]	; or CdRmHeadBuf.wFirstS
	mov	ax,101h				; free DOS memory block
	int	31h
	mov	eax,gs
	test	eax,eax
	jnz	@B

	mov	dword ptr [wCdRmBufSel],eax
if	?DEBUGLOG
	invoke	printtolog, CStr("CD buffers freed",0Dh,0Ah)
endif
	pop	gs
@@cddone:
endif

	push	es
	call	get_hdareg_ptr
	mov	edi,[firststreamoff]
if	?DEBUGLOG
	invoke	printtolog, CStr("checking if sound is playing...",0Dh,0Ah)
	invoke	printtolog, CStr("wCtl == ")
	invoke	printbinword,es:[edi].STREAM.wCtl
	invoke	printtolog, CStr("b",0Dh,0Ah)
endif
	btr	es:[edi].STREAM.wCtl,1	; RUN bit
	jnc	@@skip

	xor	ecx,ecx
	mov	[dwMainBufPhys],ecx
	mov	[dwMainBufSize],ecx

if	?DEBUGLOG
	invoke	printtolog, CStr("Waiting for DMA engine to stop...",0Dh,0Ah)
	invoke	printtolog, CStr("wCtl == ")
	invoke	printbinword,es:[edi].STREAM.wCtl
	invoke	printtolog, CStr("b",0Dh,0Ah)
endif
	mov	ecx,1000h
@@:
	call	wait_timerch2
	test	es:[edi].STREAM.wCtl,2	; RUN bit
	loopnz	@B

if	?DEBUGLOG
	invoke	printtolog, CStr("wCtl == ")
	invoke	printbinword,es:[edi].STREAM.wCtl
	invoke	printtolog, CStr("b",0Dh,0Ah,"Saving format and resetting stream...",0Dh,0Ah)
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
	invoke	printtolog, CStr("wCtl == ")
	invoke	printbinword,es:[edi].STREAM.wCtl
	invoke	printtolog, CStr("b",0Dh,0Ah)
endif
	pop	es:[edi].STREAM.wFormat

	xor	eax,eax
	cmp	eax,[dwAuxSelHdl]
	jz	@@skip

if	?DEBUGLOG
	invoke	printtolog, CStr("Freeing aux buffer...",0Dh,0Ah)
endif
	xchg	eax,[dwAuxSelHdl]
	mov	ebx,[dwAuxDpmiHdl]
	call	free_dma_buf
if	?DEBUGLOG
	invoke	printtolog, CStr("Done",0Dh,0Ah)
endif

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
	invoke	printtolog,CStr("b is: ")
	invoke	printbinword,dx
	invoke	printtolog,CStr("b",0Dh,0Ah)
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
	invoke	printtolog,CStr("b is: ")
	invoke	printbinword,dx
	invoke	printtolog,CStr("b",0Dh,0Ah)
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
	invoke	printtolog,CStr("b of type ")
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
if	?CDAUDIO
	and	si,not 11111b	; don't support any rates slower than 44100
endif
@@retpoint:
	ret
find_dac_node	endp

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
if	?DEBUGLOG
	invoke	logtostderr
endif
	invoke	printstderr, CStr(33o,"[31m","CORB Memory Error, attempting reset...",33o,"[37m",0Dh,0Ah)
	call	drv_reset
	invoke	printstderr, CStr(33o,"[31m","Reset complete",33o,"[37m",0Dh,0Ah)
if	?DEBUGLOG
	call	wait_timerch2
	invoke	closelog
endif
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
if	?DEBUGLOG
	invoke	logtostderr
endif
	invoke	printstderr, CStr(33o,"[31m","Stream Descriptor Error, attempting reset...",33o,"[37m",0Dh,0Ah)
	call	stream_reset
	invoke	printstderr, CStr(33o,"[31m","Stream Reset complete",33o,"[37m",0Dh,0Ah)
if	?DEBUGLOG
	call	wait_timerch2
	invoke	closelog
endif
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

if	?CDAUDIO
; Takes segment pointing to a CdRmDriveBuf in GS
fillcdbuf	proc near
	push	ebp
	sub	esp,size RMCS
	mov	ebp,esp
	mov	[ebp].RMCS.resvrd,0
	mov	[ebp].RMCS.rSSSP,0

	mov	[ebp].RMCS.rESI,eax	; stash EAX
	mov	[ebp].RMCS.rEDX,ebx	; stash EBX
	mov	[ebp].RMCS.rEBP,ecx	; stash ECX
	mov	[ebp].RMCS.rEDI,edi	; stash EDI
	push	es

	mov	[ebp].RMCS.rAX,1510h	; send device driver request
	movzx	ax,gs:[CdRmDriveBuf.bDrive]
	mov	bx,gs:[CdRmDriveBuf.sReq.wBufSeg]
	mov	ecx,[dwOldInt2F]
	mov	[ebp].RMCS.rCX,ax
	mov	[ebp].RMCS.rES,bx
	mov	[ebp].RMCS.rBX,CdRmDriveBuf.sReq
	mov	[ebp].RMCS.rCSIP,ecx

	mov	ecx,gs:[CdRmDriveBuf.sStat.dwEnd]
	sub	ecx,gs:[CdRmDriveBuf.sReq.dwStart]
	.if	ecx > ?CDBUFSIZE
	   mov	ecx,?CDBUFSIZE
	.endif

	push	gs
	pop	es

	; fill the buffer with a well-known scratch pattern so we can check
	; afterwards how much of it actually got filled in by the CD driver...
	push	ecx
	mov	ecx,CDBUFSIZEDWORDS
	mov	edi,CdRmDriveBuf.Samples
	mov	eax,0DEADBEEFh
	rep	stosd
	pop	ecx

	.if	!ecx
	   ; reset the "playing" status
	   btr	gs:[CdRmDriveBuf.wStatus],9	; busy bit = playing
	   jmp	@@done
	.endif
	mov	gs:[CdRmDriveBuf.sReq.wSectors],cx

	push	ss
	pop	es

	push	ecx
	mov	gs:[CdRmDriveBuf.sReq.bCmd],80h	; READ LONG
	mov	gs:[CdRmDriveBuf.sReq.wBufOff],CdRmDriveBuf.Samples
	mov	gs:[CdRmDriveBuf.sReq.bRMode],1		; raw
	mov	gs:[CdRmDriveBuf.sReq.bISize],0		; no interleave
	mov	gs:[CdRmDriveBuf.sReq.bISkip],0		; no interleave
	mov	edi,ebp
	xor	bx,bx
	mov	cx,bx
	mov	ax,0302h		; call real-mode interrupt procedure
	int	31h
	pop	ecx

if	?DEBUGLOG
	bt	gs:[CdRmDriveBuf.sReq.wStatus],15
	jnc	@F
	invoke	logtostderr
	invoke	printbinword,gs:[CdRmDriveBuf.sReq.wStatus]
	int	3
	invoke	closelog

@@:
endif

	push	gs
	pop	es

	; check for the scratch pattern...
	push	edx
	mov	ecx,CDBUFSIZEDWORDS
	mov	edi,CdRmDriveBuf.Samples
	mov	eax,0DEADBEEFh
@@:
	repne	scasd
	mov	edx,ecx	; EDX = number of dwords with scratch pattern
	jecxz	@F
	repe	scasd	; make sure it's not a fluke...
	jecxz	@F
	jmp	@B	; we found more data after the scratch pattern
@@:
	lea	eax,[edx+1]
	xor	edx,edx	; EAX:EDX = number of dwords with scratch pattern plus
			; one since the driver may have filled a partial dword
	mov	ecx,CDSECTORSIZE SHR 2
	div	ecx	; EAX = number of full sectors with scratch pattern
	.if	edx	; EDX = number of dwords in last non-full sector
	   inc	eax	; round up the number of sectors
	.endif
	pop	edx
	sub	eax,?CDBUFSIZE
	neg	eax	; EAX = number of good sectors in buffer

	imul	ecx,eax,CDSECTORSIZE
	add	ecx,CdRmDriveBuf.Samples
	mov	gs:[CdRmDriveBuf.dwBufEnd],ecx

	push	ss
	pop	es
	mov	edi,ebp

	add	gs:[CdRmDriveBuf.sReq.dwStart],eax
	;cmp	ecx,?CDBUFSIZE
	;jb	@@done

	; check if driver advertised prefetch support
	; if not, there is no point in doing READ LONG PREFETCH, as it will just
	; seek, to a location which has already been reached by the above read.
	bt	gs:[CdRmDriveBuf.wStatus],0
	jnc	@F

	; encourage MSCDEX to prefetch the next N sectors so as not to block
	mov	gs:[CdRmDriveBuf.sReq.bCmd],82h	; READ LONG PREFETCH
	mov	ax,0302h		; call real-mode interrupt procedure
	mov	cx,bx
	int	31h

@@:
	; update Q-Channel info
	mov	ax,gs:[CdRmDriveBuf.sReq.wBufSeg]
	mov	cx,[wCdRmBufSeg]

	push	fs
	mov	fs,[wCdRmBufSel]
	mov	fs:[CdRmHeadBuf.sReq.bCmd],3	; IOCTL Read
	mov	fs:[CdRmHeadBuf.sReq.wCount],size QInfo
	mov	fs:[CdRmHeadBuf.sReq.wBufOff],CdRmDriveBuf.sQChan
	mov	fs:[CdRmHeadBuf.sReq.wBufSeg],ax
	pop	fs

	mov	[ebp].RMCS.rES,cx
	mov	[ebp].RMCS.rBX,CdRmHeadBuf.sReq
	mov	ax,0302h		; call real-mode interrupt procedure
	mov	cx,bx
	int	31h

@@done:
; if	?DEBUGLOG
; 	xor	ah,ah		; GET SYSTEM TIME
; 	push	edx
; 	int	1Ah
; 	mov	[lasttimertick_lo],dx
; 	mov	[lasttimertick_hi],cx
; 	pop	edx
; endif

	; when the system is not in VM86 mode, the CD driver may carelessly
	; mask IRQ0, effectively disabling our driver - counteract this here!
	; (this had me scratching my head for over a week!)
	in	al,21h
	btr	ax,0		; unmask IRQ0 = timer
	out	21h,al

	mov	ebx,[ebp].RMCS.rEDX	; restore EBX
	mov	ecx,[ebp].RMCS.rEBP	; restore ECX
	mov	edi,[ebp].RMCS.rEDI	; restore EDI
	mov	eax,[ebp].RMCS.rESI	; restore EAX
	pop	es

	lea	esp,[ebp+size RMCS]
	pop	ebp

	ret
fillcdbuf	endp

; ES:EDI = buffer into which to mix the CD Audio stream
; ECX = number of sample pairs to mix
mixincdaudio	proc near	uses gs esi ebx eax edx
	mov	gs,[wCdRmBufSel]
	push	ebp

	test	ecx,ecx
	jz	@@done				; prevent hangs / crashes!

@@driveloop:
	mov	ax,gs:[CdRmDriveBuf.wNextS]	; or wFirstS for head buffer
	test	ax,ax				; end of linked list?
	jz	@@done
	mov	gs,ax

	bt	gs:[CdRmDriveBuf.wStatus],9	; audio playing?
	jnc	@@driveloop			; if not, move to next drive

	mov	bl,gs:CdRmDriveBuf.sInfo.Info.bVolume[2]
	mov	bh,bl	; BX = multiplication factor for right channel
	shr	bx,1	; FFFFh --> 7FFFh, etc. (for signed multiplication)
	ror	ebx,10h
	mov	bl,gs:CdRmDriveBuf.sInfo.Info.bVolume[0]
	mov	bh,bl	; BX = multiplication factor for left channel
	shr	bx,1	; FFFFh --> 7FFFh, etc. (for signed multiplication)

	push	ecx
	push	edi
	mov	ebp,ecx
	mov	esi,gs:[CdRmDriveBuf.dwBufPos]
@@loadloop:
	.if	esi >= gs:[CdRmDriveBuf.dwBufEnd]
	   call	fillcdbuf
	   mov	esi,CdRmDriveBuf.Samples
	   ; TODO: read Q-channel to see how to arrange the samples
	.endif
	lodsd	gs:[esi]
if	?CDVOLCTL
	xor	edx,edx
	imul	bx
	shld	dx,ax,1	; undo the SHR we did on BX earlier
	bt	ax,0Eh
	adc	dx,0	; increment DX if second-MSB of AX set (i.e. round up)

	ror	eax,10h	; move to right channel
	ror	edx,10h	; move to right channel
	ror	ebx,10h	; move to right channel

	imul	bx
	shld	dx,ax,1	; undo the SHR we did on BX earlier
	bt	ax,0Eh
	adc	dx,0	; increment DX if second-MSB of AX set (i.e. round up)

	ror	edx,10h	; back to left channel
	ror	ebx,10h	; back to left channel
else
	mov	edx,eax
endif

	movzx	ecx,[bCdDivider]
@@mixloop:
	mov	eax,[es:edi]
	add	ax,dx	; mix left channel
	jno	@F
	; handle clipping
	bt	ax,0Fh	; check sign bit after overflow
	mov	ax,8000h
	sbb	ax,0	; if sign bit was 1, AX becomes 7FFFh, otherwise 8000h

@@:
	ror	eax,10h	; move to right channel
	ror	edx,10h	; move to right channel
	add	ax,dx	; mix right channel
	jno	@F
	; handle clipping
	bt	ax,0Fh	; check sign bit after overflow
	mov	ax,8000h
	sbb	ax,0	; if sign bit was 1, AX becomes 7FFFh, otherwise 8000h

@@:
	ror	eax,10h	; back to left channel
	ror	edx,10h	; back to left channel
	stosd
	dec	ebp
	jz	@F
	loop	@@mixloop
	jmp	@@loadloop

@@:
	mov	gs:[CdRmDriveBuf.dwBufPos],esi
	pop	edi
	pop	ecx
	jmp	@@driveloop

@@done:
	pop	ebp
	ret
mixincdaudio	endp
endif

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

;if	?DEBUGLOG
;lasttimertick_lo	dw ?
;lasttimertick_hi	dw ?
;endif
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
	shr	eax,1		; Fill halfway through the DMA buffer
	add	eax,edx
	cmp	eax,ecx
	jb	@F
	sub	eax,ecx		; Wrap around through beginning of buffer
@@:

	and	eax,not 3	; Ensure timer driver fills aligned dwords
	and	edx,not 3	; Ensure timer driver fills aligned dwords

	cmp	[dwAuxSelHdl],0
	jz	@@noaux		; No aux buffer, OK to return what we have

	push	gs
	push	esi

	;call	logtostderr

	lgs	esi,[lpAuxBufFilled]
	and	esi,not 3	; ensure we're copying full dwords
	mov	[dwLastFillEAX],eax
	mov	ecx,eax
	sub	ecx,esi
	jnb	@@nowrap

	push	es
	push	edx
	push	eax

	mov	ecx,es:[edi].STREAM.dwBufLen
	sub	ecx,esi		; get the distance to the end of the buffer
	shr	ecx,2		; convert to dwords

	push	gs
	pop	es		; ES points to aux buffer
	mov	edi,esi
	mov	eax,esi
	xor	edx,edx
	movzx	esi,[soft_divider]
	;invoke	printtolog, CStr("soft divider is ")
	;invoke	printbinword,si
	;invoke	printtolog, CStr("b, starting pre-wraparound copy",0Dh,0Ah)
	div	esi
	mov	esi,eax

	mov	edx,ecx
	and	esi,not 3	; ensure we're copying full dwords
	;call	announcecopy

if	?CDAUDIO
	push	edx
	push	edi
endif
@@:
	movzx	ecx,[soft_divider]
	.if	edx < ecx
	  mov	ecx,edx
	.endif
	lodsd	fs:[esi]
	sub	edx,ecx
	rep	stosd		; copy what's been filled in, to the aux buffer
	ja	@B		; flags set by subtraction above

if	?CDAUDIO
	pop	edi
	pop	ecx
	bt	[statusword],6
	jnc	@F
	call	mixincdaudio
@@:
endif

	;invoke	printtolog, CStr("pre-wraparound copy done",0Dh,0Ah)
	pop	eax
	pop	edx
	pop	es

	xor	esi,esi		; back to start of the buffer
	mov	ecx,eax

@@nowrap:
	push	es
	push	edx
	push	eax

	and	esi,not 3	; ensure we're copying full dwords
	shr	ecx,2		; convert to dwords
	push	gs
	pop	es		; ES points to aux buffer
	mov	edi,esi
	mov	eax,esi
	xor	edx,edx
	movzx	esi,[soft_divider]
	;invoke	printtolog, CStr("soft divider is ")
	;invoke	printbinword,si
	;invoke	printtolog, CStr("b, starting post-wraparound copy",0Dh,0Ah)
	div	esi
	mov	esi,eax

	mov	edx,ecx
	and	esi,not 3	; ensure we're copying full dwords
	;call	announcecopy

if	?CDAUDIO
	push	edx
	push	edi
endif
@@:
	movzx	ecx,[soft_divider]
	.if	edx < ecx
	  mov	ecx,edx
	.endif
	lodsd	fs:[esi]
	sub	edx,ecx
	rep	stosd		; copy what's been filled in to the aux buffer
	ja	@B		; flags set by subtraction above

if	?CDAUDIO
	pop	edi
	pop	ecx
	bt	[statusword],6
	jnc	@F
	call	mixincdaudio
@@:
endif

	;invoke	printtolog, CStr("post-wraparound copy done",0Dh,0Ah)
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

	and	eax,not 3	; Ensure timer driver fills aligned dwords
	and	edx,not 3	; Ensure timer driver fills aligned dwords

	;invoke	closelog
	jmp	@@done

@@noaux:
if	?CDAUDIO
	bt	[statusword],6
	jnc	@@cddone
	push	es:[edi].STREAM.dwBufLen

	push	fs
	pop	es		; restore main buffer in ES
	mov	edi,[dwLastFillEAX]
	mov	ecx,eax
	sub	ecx,edi
	jnb	@F

	mov	ecx,[esp]	; load saved buffer length
	sub	ecx,edi		; get the distance to the end of the buffer
	shr	ecx,2
	call	mixincdaudio
	xor	edi,edi
@@:
	add	esp,4		; remove saved buffer length from stack
	shr	ecx,2
	call	mixincdaudio
@@cddone:
endif
	mov	[dwLastFillEAX],eax
@@done:
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

if	?CDAUDIO
; Takes RedBook M:S:F address in EAX and returns HSG sector in EAX
redbook2hsg	proc near	uses edx ecx
	mov	edx,eax
	shr	edx,10h	; EDX = minutes
	imul	edx,edx,60
	movzx	ecx,ah	; seconds
	add	edx,ecx
	imul	edx,edx,75
	movzx	ecx,al	; frames
	lea	eax,[ecx+edx-150]
	ret
redbook2hsg	endp

int2f_handler	proc
	; Remember: on entry, ES is set to our head buffer, and EDI points to
	; sRmCall therein. So we have a readymade pointer to the head buffer!
	; On the downside, this function is not reentrant, so we can't do any
	; debug logging (since int 21h may re-call int 2Fh internally). :/
	mov	ax,es:[edi.RMCS.rAX]
	cmp	ah,15h				; MSCDEX
	jne	@@passthrough

	cmp	al,8				; absolute disc read
	je	@F
	cmp	al,10h				; send device request 
	jne	@@passthrough			; don't care about anything else

@@:
	mov	cx,es:[edi.RMCS.rCX]		; drive number
	mov	gs,cs:[wCdRmBufSel]
@@:
	mov	ax,gs:[CdRmDriveBuf.wNextS]	; or CdRmHeadBuf.wFirstS
	test	ax,ax
	jz	@@passthrough			; we didn't hook this drive
	mov	gs,ax
	cmp	cl,gs:[CdRmDriveBuf.bDrive]
	jne	@B

	mov	bp,gs:[CdRmDriveBuf.wStatus]
	.if	es:[edi.RMCS.rAX] == 1508h	; absolute read
	   bt	bp,9				; busy?
	   jnc	@@passthrough

	   bts	es:[edi.RMCS.rFlags],0		; set carry
	   mov	es:[edi.RMCS.rAX],15h		; not ready
	   jmp	@@return
	.endif

	mov	fs,cs:[wRmMemSel]
	movzx	eax,es:[edi.RMCS.rBX]
	movzx	ebx,es:[edi.RMCS.rES]
	shl	ebx,4
	add	ebx,eax				; FS:EBX = device request

	.if	fs:[ebx.IOCTLRW.bCmd] == 3	; IOCTL READ
	  push	ebx
	  movzx	eax,fs:[ebx.IOCTLRW.wBufOff]
	  movzx	ebx,fs:[ebx.IOCTLRW.wBufSeg]
	  shl	ebx,4
	  add	ebx,eax				; FS:EBX = read request

	  .if	byte ptr fs:[ebx] == 0Fh	; Audio Status Info
	    mov	ax,gs:[CdRmDriveBuf.sStat.wStatus]
	    mov	ecx,gs:[CdRmDriveBuf.sStat.dwStart]
	    mov	edx,gs:[CdRmDriveBuf.sStat.dwEnd]
	    mov	fs:[ebx.AudStat.wStatus],ax
	    mov	fs:[ebx.AudStat.dwStart],ecx
	    mov	fs:[ebx.AudStat.dwEnd],edx

	    pop	ebx				; FS:EBX = device request
	    mov	fs:[ebx.IOCTLRW.wStatus],100h	; done
	    or	fs:[ebx.IOCTLRW.wStatus],bp	; busy?
	    jmp	@@return

	  .endif
	  pop	ebx				; FS:EBX = device request
	.elseif	fs:[ebx.IOCTLRW.bCmd] == 0Ch	; IOCTL WRITE
	  push	ebx
	  movzx	eax,fs:[ebx.IOCTLRW.wBufOff]
	  movzx	ebx,fs:[ebx.IOCTLRW.wBufSeg]
	  shl	ebx,4
	  add	ebx,eax				; FS:EBX = write request

	  .if	byte ptr fs:[ebx] == 3		; Audio Channel Control
	    mov	eax, dword ptr fs:[ebx.AudInfo.Info]
	    mov	edx, dword ptr fs:[ebx.AudInfo.Info+4]
	    mov	dword ptr gs:[CdRmDriveBuf.sInfo.Info],eax
	    mov	dword ptr gs:[CdRmDriveBuf.sInfo.Info+4],edx
	  .elseif byte ptr fs:[ebx] == 0		; Eject Disc
	    pop	ebx				; FS:EBX = device request
	    jmp	@@failifbusy

	  .endif
	  pop	ebx				; FS:EBX = device request
	.elseif fs:[ebx.IOCTLRW.bCmd] == 80h	; READ LONG
@@failifbusy:
	  bt	bp,9
	  jnc	@@passthrough
	  mov	fs:[ebx.IOCTLRW.wStatus],8202h	; error, busy, code=2=not ready
	  jmp	@@return

	.elseif fs:[ebx.IOCTLRW.bCmd] == 82h	; READ LONG PREFETCH
	  jmp	@@failifbusy
	.elseif fs:[ebx.IOCTLRW.bCmd] == 83h	; SEEK
	  jmp	@@failifbusy

	.elseif fs:[ebx.IOCTLRW.bCmd] == 84h	; PLAY AUDIO
	  mov	eax,fs:[ebx.PlayReq.dwStart]
	  .if	fs:[ebx.PlayReq.bAMode]		; RedBook?
	   call	redbook2hsg
	  .endif
	  mov	edx,fs:[ebx.PlayReq.dwSectors]
	  add	edx,eax
	  mov	gs:[CdRmDriveBuf.sStat.wStatus],0
	  mov	gs:[CdRmDriveBuf.sStat.dwStart],eax
	  mov	gs:[CdRmDriveBuf.sStat.dwEnd],edx
	  mov	gs:[CdRmDriveBuf.sReq.dwStart],eax	; start reading here
	  bts	gs:[CdRmDriveBuf.wStatus],9		; we're busy now!
	  mov	gs:[CdRmDriveBuf.dwBufPos],0
	  mov	gs:[CdRmDriveBuf.dwBufEnd],0		; force refill
	  mov	fs:[ebx.PlayReq.wStatus],300h		; done and busy

if	?AGGRESSIVEIRQ0
	  in	al,21h
	  btr	ax,0		; unmask IRQ0 = timer
	  out	21h,al
endif

	  jmp	@@return

	.elseif fs:[ebx.IOCTLRW.bCmd] == 85h	; STOP AUDIO
	  btr	gs:[CdRmDriveBuf.wStatus],9
	  jnc	@F
	  mov	eax,gs:[CdRmDriveBuf.sReq.dwStart]
	  bts	gs:[CdRmDriveBuf.sStat.wStatus],0	; paused
	  jmp	@@setresume
@@:
	  xor	eax,eax
	  btr	gs:[CdRmDriveBuf.sStat.wStatus],ax	; paused
	  mov	gs:[CdRmDriveBuf.sStat.dwEnd],eax
@@setresume:
	  mov	gs:[CdRmDriveBuf.sStat.dwStart],eax	; (un)set resume point
	  mov	fs:[ebx.PlayReq.wStatus],100h		; done, not busy
	  jmp	@@return

	.elseif fs:[ebx.IOCTLRW.bCmd] == 88h	; RESUME AUDIO
	  btr	gs:[CdRmDriveBuf.sStat.wStatus],0	; paused
	  jnc	@F
	  mov	eax,gs:[CdRmDriveBuf.sStat.dwStart]	; get resume point
	  bts	gs:[CdRmDriveBuf.wStatus],9		; playing
	  mov	gs:[CdRmDriveBuf.sReq.dwStart],eax
	  mov	gs:[CdRmDriveBuf.dwBufPos],0
	  mov	gs:[CdRmDriveBuf.dwBufEnd],0		; force refill
	  mov	fs:[ebx.PlayReq.wStatus],100h		; done, not busy

if	?AGGRESSIVEIRQ0
	  in	al,21h
	  btr	ax,0		; unmask IRQ0 = timer
	  out	21h,al
endif

	  jmp	@@return

@@:
	  mov	fs:[ebx.IOCTLRW.wStatus],8002h	; error, code=2=not ready
	  or	fs:[ebx.IOCTLRW.wStatus],bp	; busy?
	  jmp	@@return

	.endif

@@callthrough:
	bt	bp,9
	jnc	@@passthrough	; return normally and don't set busy bit

	; create a new IRET frame resulting in a return to int2f_setbusy
	sub	es:[edi.RMCS.rSP],6
	mov	eax,cs:[dwSetBusyCB]
	mov	bx,[esi+4]	; get flags
	mov	[esi-6],eax
	mov	[esi-2],bx
	jmp	@@passthrough

@@return:
	lodsd			; get return address from stack
	add	es:[edi.RMCS.rSP],6
	btr	es:[edi.RMCS.rFlags],0	; clear carry (pretend we called driver)
	jmp	@F
@@passthrough:
	mov	eax,cs:[dwOldInt2F]
@@:
	mov	es:[edi.RMCS.rCSIP],eax
	iretd
int2f_handler	endp

int2f_setbusy	proc
	; last stop on the return path from the old int 2F handler, to set the
	; busy bit in a device IOCTL request if needed

	mov	fs,cs:[wRmMemSel]
	movzx	eax,es:[edi.RMCS.rBX]
	movzx	ebx,es:[edi.RMCS.rES]
	shl	ebx,4
	add	ebx,eax				; FS:EBX = device request

	bts	fs:[ebx.IOCTLRW.wStatus],9	; busy

	lodsd			; get return address from stack
	add	es:[edi.RMCS.rSP],6
	mov	es:[edi.RMCS.rCSIP],eax
	iretd
int2f_setbusy	endp
endif

_TEXT	ends

; make sure the assembler knows all the CStrs are in the right segment!
DGROUP	group	_TEXT, CONST

end	hda16s
