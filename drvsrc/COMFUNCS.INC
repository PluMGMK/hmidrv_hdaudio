; Common code for detector and driver

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

; check if HDATSR is installed
; returns pointer to buffer in EBX, CF set if needed but not present
check_TSR	proc near
if	?DEBUGLOG
	invoke	printtolog, CStr("Checking if HDATSR is installed...",0Dh,0Ah)
endif
	
ifdef	?FLASHTEK
	mov	cl,9Ch
	mov	ax,2503h	; Phar Lap / FlashTek: get RM interrupt vector
	int	21h
	mov	cx,bx
	test	ebx,ebx
else
	mov	ax,200h		; get real mode interrupt vector
	mov	bl,9Ch
	int	31h
	or	cx,dx
endif
	jz	@F
	int	9Ch
@@:
	.if	cx == 0C0DEh	; if there's no int 9Ch, it'll be 0, not C0DEh
if	?DEBUGLOG
	   invoke printtolog, CStr("HDATSR installed, using its arena @ ")
	   invoke printbinword,bx
	   invoke printbinword,ax
	   invoke printtolog, CStr("b",0Dh,0Ah)
endif
	   shl	ebx,10h
	   mov	bx,ax
	   add	ebx,7Fh	; ensure 128-byte alignment
	   and	bl,80h
	   clc
	.else
	   xor	ebx,ebx	; clears carry - OK since in RATIONAL, we don't need TSR
ifdef	?FLASHTEK
if	?DEBUGLOG
	   invoke printtolog, CStr("HDATSR unavailable, need to allocate our own buffers - checking for DPMI...",0Dh,0Ah)
endif
	   mov	ax,1686h	; DPMI - detect mode
	   int	2Fh
	   test	ax,ax
	   clc
	   jz	@F
	   stc
endif
	.endif
@@:
	ret
check_TSR	endp

; check if paging is enabled - CF set if yes, clear if no
check_paging	proc near
if	?DEBUGLOG
	invoke	printtolog, CStr("Checking if paging is enabled...",0Dh,0Ah)
endif
	mov	eax,cs
	test	eax,3
	jnz	@F

if	?DEBUGLOG
	invoke	printtolog, CStr("Operating in Ring 0, checking CR0...",0Dh,0Ah)
endif
	mov	eax,cr0
	bt	eax,1Fh	; CR0.PG
	jc	@F

if	?DEBUGLOG
	invoke	printtolog, CStr("Paging is off!",0Dh,0Ah)
	clc
endif
	ret

@@:
	stc
	ret
check_paging	endp

alloc_CORB_RIRB	proc near
	call	check_TSR
	jc	@F
	mov	[dwTSRbuf],ebx

if	?DEBUGLOG
	invoke	printtolog, CStr("Allocating CORB/RIRB buffer...",0Dh,0Ah)
endif
	mov	eax,0C20h	; 1 kiB for CORB + 2 kiB for RIRB + 32 bytes for BDL
	call	alloc_dma_buf
	jc	@F
if	?DEBUGLOG
	invoke	printtolog, CStr("CORB/RIRB buffer allocated successfully",0Dh,0Ah)
endif
	mov	[dwCorbSelHdl],eax
	mov	[dwCorbPhys],edx
	.if	!((eax & 0FFFF0000h) || [dwTSRbuf])
	   mov	[dwCorbDpmiHdl],ebx
if	?DEBUGLOG
	   invoke printtolog, CStr("CORB/RIRB physical address == ")
	   ror	edx,10h
	   invoke printbinword,dx
	   ror	edx,10h
	   invoke printbinword,dx
	   invoke printtolog, CStr("b",0Dh,0Ah,"DPMI handle == ")
	   ror	ebx,10h
	   invoke printbinword,bx
	   ror	ebx,10h
	   invoke printbinword,bx
	   invoke printtolog, CStr("b",0Dh,0Ah)
endif
	.endif

	clc
@@:
	ret
alloc_CORB_RIRB	endp

init_cntrlr	proc near	uses es edi
	call	get_hdareg_ptr
	jc	@@failed

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
@@failed:
	stc
	ret

@@hda_running:
if	?DEBUGLOG
	invoke	printtolog, CStr("GCAP == ")
	invoke	printbinword,es:[edi].HDAREGS.gcap
	invoke	printtolog, CStr("b",0Dh,0Ah,"Version == ")
	invoke	printbinword,word ptr es:[edi].HDAREGS.vminor
	invoke	printtolog, CStr("b",0Dh,0Ah)
endif
	clc
	ret
init_cntrlr	endp

set_busmaster	proc near
if	?DEBUGLOG
	invoke	printtolog, CStr("Device initialized, ensuring it can act as busmaster...",0Dh,0Ah)
endif
	mov	ax,0B109h	; read configuration word
	mov	bx,[wPort]
	mov	edi,4		; command register
	int	1Ah
	jc	@F
	bts	cx,2		; bit 2 = bus master enabled
	jc	@@busmaster_ok

if	?DEBUGLOG
	invoke	printtolog, CStr("Setting busmaster flag...",0Dh,0Ah)
endif
	mov	ax,0B10Ch	; write configuration word
	int	1Ah
	jc	@F

@@busmaster_ok:
if	?DEBUGLOG
	invoke	printtolog, CStr("Busmaster flag set",0Dh,0Ah)
endif
	clc

@@:
	ret
set_busmaster	endp

start_CORB_RIRB	proc near	uses es edi
	call	get_hdareg_ptr
	jc	@@failed

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
	jmp	@@failed

@@:
	mov	edx,[dwCorbPhys]
	mov	dword ptr es:[edi].HDAREGS.corbbase,edx
	mov	dword ptr es:[edi].HDAREGS.corbbase+4,0
	add	edx,[dwRirbOff]
	mov	dword ptr es:[edi].HDAREGS.rirbbase,edx
	mov	dword ptr es:[edi].HDAREGS.rirbbase+4,0

if	?DEBUGLOG
	invoke	printtolog, CStr("CORB write pointer == ")
	invoke	printbinword, es:[edi].HDAREGS.corbwp
	invoke	printtolog, CStr("b",0Dh,0Ah)
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
	invoke	printtolog, CStr("Timed out initializing CORB/RIRB!",0Dh,0Ah)
endif
@@failed:
	stc
	ret

@@:
	clc
	ret
start_CORB_RIRB	endp

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
; If the handle in the upper half of EAX is returned as zero, then check EBX instead for a DPMI memory block handle!
alloc_dma_buf	proc near
	mov	edx,[dwTSRbuf]
	test	edx,edx
	jz	@@try_xms_dpmi

	push	ecx
	push	edi
	push	esi
	push	ebx

	mov	edi,eax
	add	eax,7Fh
	and	al,80h
	add	edx,[dwTSRbufoffset]
	add	eax,[dwTSRbufoffset]	; bump allocation with 128-byte align
	.if	eax > MAXTSRBUFOFFSET
if	?DEBUGLOG
	   invoke printtolog, CStr("out of TSR arena memory!",0Dh,0Ah)
	   ror	eax,10h
	   invoke printbinword,ax
	   ror	eax,10h
	   invoke printbinword,ax
	   invoke printtolog, CStr("b > ")
	   mov	ebx,MAXTSRBUFOFFSET
	   ror	ebx,10h
	   invoke printbinword,bx
	   ror	ebx,10h
	   invoke printbinword,bx
	   invoke printtolog, CStr("b",0Dh,0Ah)
endif
	   xor	eax,eax
	   stc
	.else
	   mov	[dwTSRbufoffset],eax

	   mov	ecx,edx
	   mov	ebx,edx
	   shr	ebx,10h			; get physical base into BX:CX
	   mov	esi,edi
	   shr	esi,10h			; get desired buffer size into SI:DI
	   call	alloc_phys_sel
	   jc	@@dpmiselfail
	.endif

	pop	ebx
	pop	esi
	pop	edi
	pop	ecx
	ret

@@try_xms_dpmi:
	CHECK_XMS_NEEDED
	jnc	@@use_dpmi

	push	ebp
	sub	esp,size RMCS
	mov	ebp,esp
	mov	[ebp].RMCS.resvrd,0
	mov	[ebp].RMCS.rSSSP,0

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


; If we're in Ring 0 with no paging, we don't need to go through XMS to get 
; a physical address. Just use what the DOS extender provides.
@@use_dpmi:
	push	ecx
	push	edi
	push	esi

	push	eax		; save size for later
	add	eax,7Fh		; ensure enough room for 128-byte alignment
	mov	cx,ax
	mov	ebx,eax
	shr	ebx,10h
	mov	ax,0501h	; allocate memory block
	int	31h
	jc	@@dpmiallocfail

	xchg	di,[esp]	; get the size back and store the DPMI handle
	xchg	si,[esp+2]	; get the size back and store the DPMI handle
	xor	eax,eax
	add	cx,7Fh
	adc	bx,0
	and	cl,80h		; ensure 128-byte alignment
	push	bx
	push	cx
	call	alloc_phys_sel
	pop	edx		; get the address
	jc	@@dpmiselfail

	pop	ebx		; get the DPMI handle
@@dpmi_retpoint:
	pop	esi
	pop	edi
	pop	ecx
	ret

@@dpmiallocfail:
if	?DEBUGLOG
	invoke	printtolog, CStr("DPMI memory allocation failed",0Dh,0Ah)
endif
	pop	eax		; get the size back
	jmp	@@dpmifail
@@dpmiselfail:
if	?DEBUGLOG
	invoke	printtolog, CStr("physical-memory selector allocation failed",0Dh,0Ah)
endif
	pop	ebx		; get the DPMI handle
@@dpmifail:
	stc
	jmp	@@dpmi_retpoint
alloc_dma_buf	endp

; Free a 128-byte-aligned DMA buffer in Extended Memory
; Takes XMS handle and selector in upper and lower halves of EAX, respectively.
; If needed, takes DPMI handle in EBX.
free_dma_buf	proc near
	cmp	[dwTSRbuf],0
	jz	@@try_xms_dpmi

	mov	bx,ax
	jmp	free_phys_sel

@@try_xms_dpmi:
	CHECK_XMS_NEEDED
	jnc	@@use_dpmi

	push	ebp
	sub	esp,size RMCS
	mov	ebp,esp
	mov	[ebp].RMCS.resvrd,0
	mov	[ebp].RMCS.rSSSP,0

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


@@use_dpmi:
	push	esi
	push	edi

	mov	bx,ax			; get selector
	call	free_selector

	push	ebx
	pop	di
	pop	si
	mov	ax,0502h		; free memory block
	int	31h

	pop	edi
	pop	esi
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
	   ;invoke	printtolog, CStr("Reading BAR0...",0Dh,0Ah)
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
;if	?DEBUGLOG
;	 invoke	printtolog, CStr("BAR0 == ")
;	 invoke	printbinword,bx
;	 invoke	printbinword,cx
;	 invoke	printtolog, CStr("b",0Dh,0Ah)
;endif
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
;if	?DEBUGLOG
;	 invoke	printtolog, CStr("hdareg_linaddr == ")
;	 invoke	printbinword,bx
;	 invoke	printbinword,cx
;	 invoke	printtolog, CStr("b",0Dh,0Ah)
;endif

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
	invoke	printtolog, CStr("alloc_phys_sel: base address == ")
	invoke	printbinword,bx
	invoke	printbinword,cx
	invoke	printtolog, CStr("b",0Dh,0Ah,"alloc_phys_sel: size == ")
	invoke	printbinword,si
	invoke	printbinword,di
	invoke	printtolog, CStr("b",0Dh,0Ah)
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
ifdef	?FLASHTEK
	mov	ax,3504h		; FlashTek - get base address
	int	21h
	mov	dx,cx
	shr	ecx,10h
else
	mov	ax,6			; get segment base address
	int	31h
endif
	jc	@F

if	?DEBUGLOG
	invoke	printtolog, CStr("free_phys_sel: base address == ")
	invoke	printbinword,cx
	invoke	printbinword,dx
	invoke	printtolog, CStr("b",0Dh,0Ah)
endif
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

	CHECK_XMS_NEEDED
	jnc	@F			; return the phys address as linear

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
ifdef	?FLASHTEK
	mov	bx,cx
	mov	ecx,eax
	mov	ax,350Ah		; FlashTek - physical address mapping
	int	21h
	push	ebx
	pop	cx
	pop	bx
else
	shr	ebx,10h
	mov	di,ax
	mov	esi,eax
	shr	esi,10h
	mov	ax,0800h		; physical address mapping
	int	31h
endif
	jc	@F

	and	edx,0FFFh		; get back the offset into the page
	or	ecx,edx
	clc
@@:
	ret
map_physmem	endp

unmap_physmem	proc near
ifndef	?FLASHTEK			; FlashTek has no "unmap" function...
	CHECK_XMS_NEEDED
	jnc	@F			; this is a no-op

	; BX:CX = linear address
	and	cx,0F000h		; address passed here may not be page-aligned...
	mov	ax,801h
	int	31h
@@:
endif
	ret
unmap_physmem	endp

alloc_selector	proc near
	; BX:CX = base
	; SI:DI = size
	; returns selector in AX
	push	edx
ifdef	?FLASHTEK
	push	bx
	push	cx
	pop	ecx
	mov	ax,3501h	; FlashTek - allocate selector
	int	21h
else
	mov	dx,cx
	xor	ax,ax		; allocate selector
	mov	cx,1		; one selector
	int	31h
endif
	jc	@F

ifdef	?FLASHTEK
	mov	ax,3503h	; FlashTek - set base address
	int	21h
else
	mov	cx,bx
	mov	bx,ax
	mov	ax,7		; set segment base address
	int	31h
endif
	jc	@F

ifdef	?FLASHTEK
	push	si
	push	di
	pop	ecx
	dec	ecx		; change size to limit
	mov	ax,3505h	; FlashTek - set limit
	int	21h
else
	mov	dx,di
	mov	cx,si
	mov	ax,8		; set segment limit
	dec	dx		; change size to limit
	sbb	cx,0
	int	31h
endif
	jc	@F

	mov	ax,bx		; return the selector
	clc
@@:
	pop	edx
	ret
alloc_selector	endp

free_selector	proc near
	; BX = selector
ifdef	?FLASHTEK
	mov	ax,3502h
	int	21h
else
	mov	ax,1
	int	31h
endif
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
