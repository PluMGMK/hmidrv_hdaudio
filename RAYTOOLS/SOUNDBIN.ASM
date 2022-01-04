; A tool to add a descriptor for our HD Audio driver to Rayman's SOUND.BIN file,
; used by some versions of that game's installer.
; Other games may well need analogous tools!

	.8086
	.model	tiny

?OVERWRITE	equ 1	; overwrite the last descriptor instead of adding one
NUM_DESCRIPTORS	equ 20
DEVSTOENUMERATE	equ 10	; set by the Ubisoft structure
XOR_KEY		equ 4Dh

UbiDescriptor	struc
	wID		dw ?
	num_ports	db ?
	num_irqs	db ?
	num_dmas	db ?
	device_name	db 40 dup (?)
	ports		dw DEVSTOENUMERATE dup (?)
	irqs		dw 15 dup (?)
	dmas		dw 10 dup (?)
	wParam		dw ?	; used by game installer at runtime
	port_idx	db ?	; used by game installer at runtime
	irq_idx		db ?	; used by game installer at runtime
	dma_idx		db ?	; used by game installer at runtime
UbiDescriptor	ends

	.code
	org	100h

soundbin:
	xor	cx,cx
	mov	cl,byte ptr ds:[80h]	; number of characters in cmdline args
	mov	di,81h			; start of cmdline buffer
	mov	dx,offset input_filename

@@next_arg:
	test	cx,cx
	jbe	@@usage

	mov	al,20h
	repe	scasb
	lea	si,[di-1]		; beginning of current argument
	repne	scasb
	mov	bx,di			; save current position
	mov	bp,cx			; and number of chars left

	cmp	byte ptr [di],0Dh	; at the end?
	je	@F
	dec	di
@@:
	sub	di,si
	mov	cx,di			; length of current argument

	mov	di,dx
	rep	movsb
	xor	al,al
	stosb	; null-terminate

	mov	di,bx
	mov	cx,bp

	cmp	dx,offset input_filename
	jne	@F
	mov	dx,offset output_filename
	jmp	@@next_arg

@@:
	mov	dx,offset openingmsg1
	mov	ah,9
	int	21h
	mov	dx,offset input_filename
	mov	ax,3D00h		; open read-only
	int	21h
	jc	@@failure

	mov	bx,ax
	mov	dx,offset readingmsg
	mov	ah,9
	int	21h

	mov	ah,3Fh			; read
	mov	cx,dataend - databuf
	mov	dx,offset databuf
	int	21h
	jc	@@failure

	mov	ah,3Eh			; close
	int	21h

	mov	dx,offset decryptingmsg
	mov	ah,9
	int	21h

	mov	si,offset payload
	mov	di,si
	mov	cx,dataend - payload
@@:
	lodsb
	sub	[checksum],al
	xor	al,XOR_KEY
	stosb
	loop	@B

	mov	bl,[checksum]
	test	bl,bl
	mov	dx,offset badchecksum
	jnz	@@failure_custommsg

	cmp	[numdrivers],NUM_DESCRIPTORS
	mov	dx,offset toomanymsg
	jnb	@@printandfail

	mov	dx,offset filllistmsg
	mov	ah,9
	int	21h

	call	fill_portlist
	mov	dx,offset nopcimsg
	jc	@@printandfail
	cmp	PortList[0],-1
	mov	dx,offset nohdaudiomsg
	je	@@printandfail

	mov	dx,offset makedescmsg
	mov	ah,9
	int	21h

	mov	al,[numdrivers]
if	?OVERWRITE
else
	inc	[numdrivers]
endif
	mov	cl,sizeof UbiDescriptor
	mul	cl
	mov	bx,offset descriptors
	add	bx,ax

if	?OVERWRITE
	mov	si,bx
	lea	di,[bx-size UbiDescriptor]
	mov	cx,sizeof UbiDescriptor
	rep	movsb			; copy an empty descriptor
	lea	bx,[bx-size UbiDescriptor]
endif

	mov	[bx].UbiDescriptor.wID,0E040h

	; calculate number of ports
	mov	di,offset PortList
	xor	dx,dx
	mov	ax,-1
@@:
	scasw
	je	@F
	inc	dx
	jmp	@B

@@:
	mov	[bx].UbiDescriptor.num_ports,dl
	mov	[bx].UbiDescriptor.num_irqs,NUM_IRQs
	mov	[bx].UbiDescriptor.num_dmas,NUM_DMAs

	mov	si,offset our_devname
	mov	cx,sizeof our_devname
	lea	di,[bx].UbiDescriptor.device_name
	rep	movsb

	mov	si,offset PortList
	mov	cl,[bx].UbiDescriptor.num_ports
	lea	di,[bx].UbiDescriptor.ports
	rep	movsw

	mov	si,offset IRQList
	mov	cl,[bx].UbiDescriptor.num_irqs
	lea	di,[bx].UbiDescriptor.irqs
	rep	movsw

	mov	si,offset DMAList
	mov	cl,[bx].UbiDescriptor.num_dmas
	lea	di,[bx].UbiDescriptor.dmas
	rep	movsw

	mov	dx,offset encryptingmsg
	mov	ah,9
	int	21h

	mov	si,offset payload
	mov	di,si
	mov	cx,dataend - payload
@@:
	lodsb
	xor	al,XOR_KEY
	add	[checksum],al
	stosb
	loop	@B

	mov	dx,offset openingmsg2
	mov	ah,9
	int	21h
	mov	dx,offset output_filename
	mov	ah,3Ch			; create
	xor	cx,cx			; no special attributes
	int	21h
	jc	@@failure

	mov	bx,ax
	mov	dx,offset writingmsg
	mov	ah,9
	int	21h

	mov	ah,40h			; write
	mov	cx,dataend - databuf
	mov	dx,offset databuf
	int	21h
	jc	@@failure

	mov	ah,3Eh			; close
	int	21h
	mov	ax,4C00h		; exit with success
	int	21h

@@usage:
	mov	dx,offset usagemsg
	jmp	@@printandfail

@@failure:
	mov	dx,offset failuremsg
	mov	bx,ax			; save error code
@@failure_custommsg:
	mov	ah,9
	int	21h

@@print_bl:
	mov	dl,bl
	mov	cl,4
	shr	dl,cl
	.if	dl > 9
	   add	dl,'A' - 0Ah
	.else
	   add	dl,'0'
	.endif
	mov	ah,2			; character output
	int	21h

	mov	dl,bl
	and	dl,0Fh
	.if	dl > 9
	   add	dl,'A' - 0Ah
	.else
	   add	dl,'0'
	.endif
	mov	ah,2			; character output
	int	21h

	mov	dl,'h'
	mov	ah,2			; character output
	int	21h

	mov	dx,offset eol

@@printandfail:
	mov	ah,9
	int	21h
	mov	ax,4CFFh		; exit with failure
	int	21h

	.386				; PCI BIOS code uses 32-bit regs...
	include	PORTLIST.INC

usagemsg:
	db	"You need to specify two arguments on the command line.",0Dh,0Ah
	db	"The first is an input file to be patched.",0Dh,0Ah
	db	"The second is the output file to receive the patched data."
eol:
	db	0Dh,0Ah,"$"

failuremsg:
	db	"Syscall failed - error code: ","$"

openingmsg1:
	db	"Opening input file...",0Dh,0Ah,"$"
openingmsg2:
	db	"Creating output file...",0Dh,0Ah,"$"

readingmsg:
	db	"Reading input file...",0Dh,0Ah,"$"
writingmsg:
	db	"Writing output file...",0Dh,0Ah,"$"

decryptingmsg:
	db	"Decrypting...",0Dh,0Ah,"$"

encryptingmsg:
	db	"Re-encrypting...",0Dh,0Ah,"$"

badchecksum:
	db	"Input file has bad checksum:",0Dh,0Ah
	db	"Should have ended up with zero, but got ","$"

toomanymsg:
	db	"Input file is full - no room to add extra driver",0Dh,0Ah,"$"

filllistmsg:
	db	"Detecting HD Audio hardware...",0Dh,0Ah,"$"

makedescmsg:
	db	"Creating new descriptor...",0Dh,0Ah,"$"

nopcimsg:
	db	"No PCI BIOS available, cannot detect HD Audio hardware!",0Dh,0Ah,"$"

nohdaudiomsg:
	db	"No HD Audio hardware detected!",0Dh,0Ah,"$"

our_devname db	"Intel High Definition Audio",0

	include	CAPLISTS.INC

	.data?

input_filename	db 80h dup (?)
output_filename	db 80h dup (?)

databuf	label	byte
ubiheader1	db 5 dup (?)
ubiheader2	db 5 dup (?)
ubiheaderword	dw ?
checksum	db ?

payload	label	byte
numdrivers	db ?
runtimeidx	db ?	; not used here

descriptors	UbiDescriptor NUM_DESCRIPTORS dup (<?>)
dataend	label	byte

end	soundbin
