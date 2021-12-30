; 16-bit Stereo HD Audio detector for HMIDET.386

	.386
	.model	small
	include	comdecs.inc

_TEXT	segment	use32
	assume	ds:nothing,es:nothing,gs:nothing,fs:_TEXT

	.code
	org 0
hda16sd:
	jmp	entry

align 4
	include	comdata.inc

; env strings - keys
kBus	db "HDA_BUS",0
kDevice	db "HDA_DEVICE",0
kFunc	db "HDA_FUNCTION",0

kIrq	db "HDA_IRQ",0

kCodec	db "HDA_CODEC",0
kWidget	db "HDA_WIDGET",0

pEnvStringKeys:
	dd offset kBus
	dd offset kDevice
	dd offset kFunc
	dd offset kIrq
	dd offset kCodec
	dd offset kWidget
	dd -1

; env strings - values (pointers thereto)
lpEnvStringVals:
lpvBus		df ?
lpvDevice	df ?
lpvFunc		df ?
lpvIrq		df ?
lpvCodec	df ?
lpvWidget	df ?
		dw 3 dup (-1)

; Bit 0 = Bus specified
; Bit 1 = Device specified
; Bit 2 = Function specified
; Bit 3 = IRQ specified
; Bit 4 = Codec specified
; Bit 5 = Widget specified
; Bit 6 = XMS status checked
; Bit 7 = XMS needed (linear addresses != physical)
; Bit 8 = CORB/RIRB up and running
statusword	dw 1 SHL 7

CHECK_XMS_NEEDED	macro
	bts	[statusword],6
	jc	@F
	call	check_paging
	jc	@F
	btr	[statusword],7
@@:
	bt	[statusword],7
endm

; Detector function table
ftable	dd offset det_exists
	dd offset det_getsettings
	dd offset drv_capabilities	; same as the main driver
	dd offset det_verifysettings
	dd offset det_envstringinit

	include	comfuncs.inc

; ------------------------------------------------------- ;
; ENUM functions from here (called from host application) ;
; ------------------------------------------------------- ;
	assume	ds:_TEXT	; always called from within DS-set portion of entry point

; Tell the host application if the HD Audio hardware is available
; Takes no parameters
; Returns the "port" (i.e. PCI Bus/Device/Function combo) or zero if unavailable
; (Technically zero is a valid PCI B/D/F, but only for a host bridge...)
det_exists		proc near	uses gs
if	?DEBUGLOG
	invoke	openlog, CStr("HDD_EXST.LOG"),0
	invoke	printtolog, CStr("parsing env variables...",0Dh,0Ah)
endif

	lgs	esi,[lpvBus]
	test	esi,esi
	jz	@F
	
	call	parseenvstring
	mov	[pci_bus],bl
	bts	[statusword],0

@@:
	lgs	esi,[lpvDevice]
	test	esi,esi
	jz	@F
	
	call	parseenvstring
	shl	bl,3	; bits 7-3 of lower byte are device number
	mov	[pci_dev_func],bl
	bts	[statusword],1

@@:
	lgs	esi,[lpvFunc]
	test	esi,esi
	jz	@F
	
	call	parseenvstring
	and	bl,111b	; bits 2-0 of lower byte are function number
	mov	bh,[pci_dev_func]
	and	bh,not 111b
	or	bl,bh
	mov	[pci_dev_func],bl
	bts	[statusword],2

@@:
	lgs	esi,[lpvIrq]
	test	esi,esi
	jz	@F
	
	call	parseenvstring
	mov	[irq],bl
	bts	[statusword],3

@@:
	lgs	esi,[lpvCodec]
	test	esi,esi
	jz	@F
	
	call	parseenvstring
	and	bl,0Fh	; only a nibble
	mov	[codec],bl
	bts	[statusword],4

@@:
	lgs	esi,[lpvWidget]
	test	esi,esi
	jz	@F
	
	call	parseenvstring
	mov	[node],bl
	bts	[statusword],5

@@:
if	?DEBUGLOG
	invoke	printbinword,[statusword]
	invoke	printtolog, CStr("b is env variable status word",0Dh,0Ah,"now filling 'port' list...",0Dh,0Ah)
endif

	xor	eax,eax	; get ready to return nothing...
	call	fill_portlist
	jc	@@done
if	?DEBUGLOG
	invoke	printtolog, CStr("'port' list filled",0Dh,0Ah)
endif

	cmp	PortList[0],-1
	je	@@done
if	?DEBUGLOG
	invoke	printtolog, CStr("at least one device present!",0Dh,0Ah)
endif

	xor	ecx,ecx
@@nextdev:
	movsx	eax,PortList[ecx*2]
	.if	eax == -1
if	?DEBUGLOG
	   invoke printtolog, CStr("no device matches env variables!",0Dh,0Ah)
endif
	   xor	eax,eax
	   jmp	@@done
	.endif
	test	[statusword],111b
	jz	@@done	; Bus/Device/Function not specified, return first one
	inc	ecx

	bt	[statusword],0	; Bus specified?
	jnc	@F
if	?DEBUGLOG
	invoke	printtolog, CStr("checking Bus against env variable...",0Dh,0Ah)
endif
	cmp	ah,[pci_bus]
	jne	@@nextdev	; wrong Bus!

@@:
	bt	[statusword],1	; Device specified?
	jnc	@F
if	?DEBUGLOG
	invoke	printtolog, CStr("checking Device against env variable...",0Dh,0Ah)
endif
	mov	bh,[pci_dev_func]
	mov	bl,al
	and	bx,not 707h
	cmp	bh,bl
	jne	@@nextdev	; wrong Device!

@@:
	bt	[statusword],2	; Function specified?
	jnc	@@done
if	?DEBUGLOG
	invoke	printtolog, CStr("checking Function against env variable...",0Dh,0Ah)
endif
	mov	bh,[pci_dev_func]
	mov	bl,al
	and	bx,707h
	cmp	bh,bl
	jne	@@nextdev	; wrong Function!

@@done:
	.if	eax
	   mov	[wPort],ax	; make sure B/D/F are fully specified
	   or	[statusword],111b
	.endif
if	?DEBUGLOG
	invoke	closelog
endif
	ret
det_exists		endp

; Get the settings for the selected HD Audio device
; Takes no parameters
; Returns AX = port, CL = IRQ, CH = DMA channel, DX = param
det_getsettings		proc near	uses es
	mov	ax,[statusword]
	and	ax,111b
	.if	ax != 111b
	   call	det_exists
	   xor	eax,eax
	.endif
if	?DEBUGLOG
	invoke	openlog, CStr("HDD_GETS.LOG"),0
	.if	!eax
	   invoke printtolog, CStr("det_exists had to be called from det_getsettings!",0Dh,0Ah,"Did the host application request settings without ensuring hardware existed?",0Dh,0Ah)
	.endif
endif

	bts	[statusword],3
	jc	@F
if	?DEBUGLOG
	invoke	printtolog, CStr("IRQ not specified, using default...",0Dh,0Ah)
endif
	mov	ax,IRQList[0]
	mov	[irq],al
@@:

	bts	[statusword],4
	jc	@@codec_set
if	?DEBUGLOG
	invoke	printtolog, CStr("codec not specified, querying hardware...",0Dh,0Ah)
endif

	call	get_hdareg_ptr
	jc	@@codec_set
	btr	es:[edi].HDAREGS.gctl,0
	jnc	@@in_reset
if	?DEBUGLOG
	invoke printtolog, CStr("Resetting HDA controller...",0Dh,0Ah)
endif
	mov	ecx,10000h
@@:
	call	wait_timerch2
	test	es:[edi].HDAREGS.gctl,1
	loopnz	@B

@@in_reset:
if	?DEBUGLOG
	invoke	printtolog, CStr("HDA controller in reset",0Dh,0Ah)
endif
	call	wait_timerch2
	call	init_cntrlr
if	?DEBUGLOG
	invoke	printtolog, CStr("waiting for codecs to appear in STATESTS...",0Dh,0Ah)
endif
	call	wait_timerch2	; TODO: long enough?

	mov	ecx,0Fh		; there may be up to 15 codecs
	mov	bx,es:[edi].HDAREGS.statests
@@codec_loop:
	shr	bx,1
	jnc	@@next_codec
if	?DEBUGLOG
	invoke	printtolog, CStr("codec found, checking if widget is already set...",0Dh,0Ah)
endif
	bt	[statusword],5
	jc	@@widget_set

	call	find_output_pin
	jc	@@next_codec
	mov	[node],al
	bts	[statusword],5
	jmp	@@widget_set

@@next_codec:
	inc	[codec]
	loop	@@codec_loop
	
@@codec_set:
	cmp	[codec],0Eh
	ja	@@widget_set	; it's no good...

	bts	[statusword],5
	jc	@@widget_set

if	?DEBUGLOG
	invoke	printtolog, CStr("widget not specified, querying hardware...",0Dh,0Ah)
endif
	call	init_cntrlr
	call	find_output_pin
	mov	[node],al

@@widget_set:
if	?DEBUGLOG
	invoke	printtolog, CStr("settings obtained, checking if there's any cleanup to do...",0Dh,0Ah)
endif
	cmp	[hdareg_seg],0
	jz	@@done

	call	get_hdareg_ptr
	btr	[statusword],8
	jnc	@@corbstopped

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

	mov	eax,[dwCorbSelHdl]
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

@@corbstopped:
	btr	es:[edi].HDAREGS.gctl,0
	jnc	@@cntrlr_done
if	?DEBUGLOG
	invoke printtolog, CStr("Resetting HDA controller...",0Dh,0Ah)
endif
	mov	ecx,10000h
@@:
	call	wait_timerch2
	test	es:[edi].HDAREGS.gctl,1
	loopnz	@B

@@cntrlr_done:
	mov	ebx,es
	call	free_selector
	xor	eax,eax
	mov	[hdareg_seg],ax
if	?DEBUGLOG
	invoke printtolog, CStr("far pointer to HDA device registers freed",0Dh,0Ah)
endif
	mov	ecx,[hdareg_linaddr]
	mov	ebx,ecx
	shr	ebx,10h
	call	unmap_physmem
	xor	eax,eax
	mov	[hdareg_linaddr],eax
if	?DEBUGLOG
	invoke printtolog, CStr("linear address of HDA device registers unmapped",0Dh,0Ah)
endif

@@done:
	mov	ax,[wPort]
	mov	cx,[wIrqDma]
	mov	dx,[wParam]
if	?DEBUGLOG
	invoke	closelog
endif
	ret
det_getsettings		endp

; Get the settings for the selected HD Audio device
; Takes AX = port, CL = DMA channel, CH = IRQ (yes, CL/CH are swapped...)
; Returns an error code
; Does NOT take a param, so there's no need to query the hardware...
; (Pity, because there's no way to cross-check the user specs...)
det_verifysettings	proc near
	cmp	PortList[0],-1
	jne	@F

	call	fill_portlist

@@:
	xor	ebx,ebx
@@:
	mov	dx,PortList[ebx*2]
	.if	dx == -1
	   mov	eax,10h	; _ERR_INVALID_PORT
	   ret
	.endif
	cmp	ax,dx
	je	@F
	inc	ebx
	jmp	@B

@@:
	movzx	ax,ch
	xor	ebx,ebx
@@:
	mov	dx,PortList[ebx*2]
	.if	dx == -1
	   mov	eax,11h	; _ERR_INVALID_IRQ
	   ret
	.endif
	cmp	ax,dx
	je	@F
	inc	ebx
	jmp	@B

@@:
	xor	eax,eax	; _ERR_NO_ERROR
	ret
det_verifysettings	endp

; Get the environment variables needed by this detector
; Takes no parameters
; Returns pointer to list of keys in ESI, and to list of value pointers in EDI
det_envstringinit	proc near
if	?DEBUGLOG
	invoke	openlog, CStr("HDD_ENV.LOG"),0
endif

	mov	esi,pEnvStringKeys
	mov	edi,lpEnvStringVals

if	?DEBUGLOG
	invoke	closelog
endif
	ret
det_envstringinit	endp

; ------------------------------------------------------------------------------ ;
; INTERNAL functions from here (called from within ENUM and interrupt functions) ;
; ------------------------------------------------------------------------------ ;

; Search for a pin widget of type lineout/headphone/speaker on the current codec
; If found, returns it in AL, with CF clear
; If not found, CF is set
find_output_pin		proc near	uses ebx edi esi ebp
if	?DEBUGLOG
	invoke	printtolog, CStr("widget not specified, looking for a suitable one on this codec...",0Dh,0Ah)
endif

	xor	ebx,ebx		; keep latest candidate here
	xor	edi,edi		; and its default device type here

	bts	[statusword],8
	jc	@F
	call	set_busmaster	; busmaster needed for CORB/RIRB DMA
	jc	@@failed
	call	alloc_CORB_RIRB
	jc	@@failed
	call	start_CORB_RIRB
	jc	@@failed

@@:
	mov	[node],0	; query root node
	call	get_subnodes
	mov	ebp,edx
	mov	[node],al
@@fgloop:
	mov	ax,0F00h	; get parameter
	mov	edx,5		; function group type
	call	send_cmd_wait
	and	al,7Fh
	cmp	al,1		; audio function group
	jne	@@next_fg

	call	get_subnodes
	push	[wParam]
	mov	ecx,edx
	mov	[node],al

@@nodeloop:
	mov	ax,0F00h	; get parameter
	mov	edx,9		; audio widget capabilities
	call	send_cmd_wait
	bt	eax,0		; stereo?
	jnc	@@next_node

	shr	eax,20
	and	al,0Fh
	cmp	al,WTYPE_PIN
	jne	@@next_node

	mov	ax,0F1Ch	; get default configuration
	xor	edx,edx
	call	send_cmd_wait
	shr	eax,12
	and	ah,0Fh		; default device type
	.if	ah != DEFDEV_LINEOUT && ah != DEFDEV_SPEAKER && ah != DEFDEV_HEADPHONE && ah != DEFDEV_SPDIFOUT && ah != DEFDEV_DIGOUT
	   jmp	@@next_node
	.endif
	and	al,0Fh		; colour
	movzx	esi,ah

	cmp	ah,DEFDEV_LINEOUT
	jne	@F		; prefer speakers / headphones / etc.

	test	edi,edi
	jz	@F		; first one we've found

	cmp	esi,edi
	jne	@@next_node	; don't prefer a line-out to something else

	cmp	al,4
	jne	@@next_node	; prefer "green" line-outs

@@:
if	?DEBUGLOG
	invoke	printtolog, CStr("found a stereo output pin, checking if anything's plugged in...",0Dh,0Ah)
endif
	mov	ax,0F09h	; pin sense
	xor	edx,edx
	call	send_cmd_wait
	bt	eax,1Fh		; presence detect
	jnc	@@next_node

if	?DEBUGLOG
	invoke	printtolog, CStr("got a candidate!",0Dh,0Ah)
endif
	mov	bl,[node]
	mov	edi,esi

@@next_node:
	inc	[node]
	dec	ecx
	jnz	@@nodeloop
	pop	[wParam]

@@next_fg:
	inc	[node]
	dec	ebp
	jnz	@@fgloop

	test	bl,bl
	jnz	@F

if	?DEBUGLOG
	invoke	printtolog, CStr("couldn't find any output widget!",0Dh,0Ah)
endif
	stc
	jmp	@@failed

@@:
	mov	al,bl
	clc
@@failed:
	ret
find_output_pin		endp

; Takes pointer to hex string in GS:ESI and returns numeric value in EBX
parseenvstring		proc near
	xor	ebx,ebx
@@:
	lodsb	gs:[esi]
	.if	al >= '0' && al <= '9'
	   sub	al,'0'
	.elseif	al >= 'A' && al <= 'F'
	   sub	al,'A'-0Ah
	.elseif	al >= 'a' && al <= 'f'
	   sub	al,'a'-0Ah
	.else
	   jmp	@F	; non-hex character - we're done
	.endif
	or	bl,al
	shl	ebx,4
	jmp	@B

@@:
	ret
parseenvstring		endp

_TEXT	ends

; make sure the assembler knows all the CStrs are in the right segment!
DGROUP	group	_TEXT, CONST

end	hda16sd
