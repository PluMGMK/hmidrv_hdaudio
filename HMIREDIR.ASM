; Some game installers refuse to run from the hard drive, so we need to redirect
; file opens of HMID{ET,RV}.386 to a known folder with our patched version.
; This is a little TSR to do just that.
	.8086
	.model	tiny

	.code
	org	100h

hmiredir:
	jmp	entrypoint

handler	proc
	cmp	ax,3D00h	; open read-only
	je	@F
	jmp	cs:[old_int21]

@@:
	push	es
	push	di
	push	ax
	push	cx
	push	si

	mov	di,ds
	mov	es,di
	mov	di,dx

	xor	cx,cx
	dec	cx
	xor	al,al
	cld
	repne	scasb

	mov	cx,cs
	mov	es,cx
	lea	si,[di-2]
	push	si
	mov	cx,drv_fn_len
	mov	di,offset drv_filename + drv_fn_len - 1
	std
@@:
	lodsb
	or	al,20h	; make sure it's lowercase
	scasb
	loope	@B
	pop	si
	jne	@F

	mov	di,cs:[directory_end]
	mov	si,offset drv_filename
	mov	cx,drv_fn_len
	cld
	rep	movsb es:[di],cs:[si]
	xor	al,al
	stosb
	jmp	@@redirect

@@:
	mov	cx,det_fn_len
	mov	di,offset det_filename + det_fn_len - 1
	std
@@:
	lodsb
	or	al,20h	; make sure it's lowercase
	scasb
	loope	@B
	jne	@@passthrough

	mov	di,cs:[directory_end]
	mov	si,offset det_filename
	mov	cx,det_fn_len
	cld
	rep	movsb es:[di],cs:[si]
	xor	al,al
	stosb

@@redirect:
	pop	si
	pop	cx
	pop	ax
	pop	di
	pop	es

	push	ds
	push	dx
	mov	dx,cs
	mov	ds,dx
	mov	dx,offset directory
	pushf
	call	cs:[old_int21]
	pop	dx
	pop	ds

	; propagate up the carry flag
	push	bp
	mov	bp,sp
	jc	@F
	and	byte ptr [bp+6],not 1
	pop	bp
	iret

@@:
	or	byte ptr [bp+6],1
	pop	bp
	iret

@@passthrough:
	pop	si
	pop	cx
	pop	ax
	pop	di
	pop	es

	jmp	cs:[old_int21]
handler	endp

drv_filename	db "hmidrv.386"
drv_fn_len	equ $-drv_filename
det_filename	db "hmidet.386"
det_fn_len	equ $-det_filename
align		4
old_int21	label dword
old_int21_off	dw ?
old_int21_seg	dw ?
directory	db 80h dup (?)
directory_end	dw ?

align		10h
entrypoint:
	xor	cx,cx
	mov	cl,byte ptr ds:[80h]	; number of characters in cmdline args
	test	cx,cx
	jbe	@@usage

	mov	al,20h
	mov	di,81h
	repe	scasb
	lea	si,[di-1]		; beginning of first argument
	repne	scasb
	cmp	byte ptr [di],0Dh	; at the end?
	je	@F
	dec	di
@@:
	sub	di,si
	mov	cx,di			; length of first argument

	mov	di,offset directory
	rep	movsb
	xor	al,al
	stosb	; null-terminate
	cmp	[directory+1],':'
	jne	@@usage

	mov	dx,offset directory
	mov	ah,3Bh			; CHDIR (make sure it's a valid dirspec)
	int	21h
	jc	@@usage

	mov	al,'\'
	sub	di,2
	scasb
	je	@F
	stosb	; add trailing slash if needed
@@:
	mov	[directory_end],di

	mov	ax,3521h		; get int 21h vector
	int	21h
	mov	[old_int21_off],bx
	mov	[old_int21_seg],es

	mov	ax,2521h		; set int 21h vector
	mov	dx,offset handler
	int	21h

	mov	es,word ptr ds:[2Ch]	; env segment
	mov	ah,49h			; free memory
	int	21h

	mov	ax,3100h		; TSR with success code
	mov	dx,offset entrypoint
	mov	cx,4
	shr	dx,cl
	int	21h

@@usage:
	mov	dx,offset usagemsg
	mov	ah,9
	int	21h
	mov	ax,4CFFh
	int	21h

usagemsg:
	db	"You need to specify an absolute directory path on the command line."
	db	0Dh,0Ah,"(No trailing slash unless it's the root of a drive!)"
	db	0Dh,0Ah,"$"

end	hmiredir
