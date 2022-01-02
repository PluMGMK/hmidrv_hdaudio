; Some game installers refuse to run from the hard drive, so we need to redirect
; file opens of HMID{ET,RV}.386 to a known folder with our patched version.
; This is a little TSR to do just that.
	.8086
	.model	tiny

fn_record	struc
	len	db ?
	fn	db 0Ch dup (?)	; 8.3 is at most 0Ch = 12 characters!
fn_record	ends

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
	push	bx

	mov	di,ds
	mov	es,di
	mov	di,dx

	xor	cx,cx
	dec	cx
	xor	al,al
	cld
	repne	scasb

	mov	bx,offset fn_records
	mov	cx,cs
	mov	es,cx
	lea	si,[di-2]
@@fn_loop:
	push	si
	mov	cl,cs:[bx].fn_record.len
	xor	ch,ch
	lea	di,[bx].fn_record.fn - 1
	add	di,cx
	std
@@:
	lodsb
	or	al,20h	; make sure it's lowercase
	scasb
	loope	@B
	pop	si
	jne	@F

	mov	di,cs:[directory_end]
	lea	si,[bx].fn_record.fn
	mov	cl,cs:[bx].fn_record.len
	xor	ch,ch
	cld
	rep	movsb es:[di],cs:[si]
	xor	al,al
	stosb
	jmp	@@redirect

@@:
	lea	bx,[bx+size fn_record]
	cmp	bx,offset end_fn_records
	jnb	@@passthrough
	cmp	cs:[bx].fn_record.len,0
	je	@@passthrough
	jmp	@@fn_loop

@@redirect:
	pop	bx
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
	pop	bx
	pop	si
	pop	cx
	pop	ax
	pop	di
	pop	es

	jmp	cs:[old_int21]
handler	endp

fn_records:
drv_fnrec	fn_record <0Ah,"hmidrv.386">
det_fnrec	fn_record <0Ah,"hmidet.386">
more_fnrecs	fn_record 8 dup (<?>)
end_fn_records:

align		4
old_int21	label dword
old_int21_off	dw ?
old_int21_seg	dw ?
dirlen		db ?
directory	db 80h dup (?)
directory_end	dw ?

align		10h
entrypoint:
	xor	cx,cx
	mov	cl,byte ptr ds:[80h]	; number of characters in cmdline args
	mov	di,81h
	mov	bx,offset dirlen

@@next_arg:
	test	cx,cx
	jbe	@@args_done

	mov	al,20h
	repe	scasb
	lea	si,[di-1]		; beginning of current argument
	repne	scasb
	mov	dx,di			; save current position
	mov	bp,cx			; and number of chars left

	cmp	byte ptr [di],0Dh	; at the end?
	je	@F
	dec	di
@@:
	sub	di,si
	mov	cx,di			; length of current argument
	.if	bx != offset dirlen
	   cmp	cx,0Ch
	   ja	@@skip_arg		; skip if too long to be a filename...
	.endif

	mov	[bx].fn_record.len,cl
	lea	di,[bx].fn_record.fn
@@:
	lodsb
	.if	al >= 'A' && al <= 'Z'
	   or	al,20h	; make sure it's lowercase
	.endif
	stosb
	loop	@B
	.if	bx == offset dirlen
	   xor	al,al
	   stosb	; null-terminate
	.endif

@@skip_arg:
	mov	di,dx
	mov	cx,bp

	cmp	bx,offset dirlen
	jne	@F
	mov	bx,offset more_fnrecs
	jmp	@@next_arg

@@:
	cmp	[bx].fn_record.len,0
	jz	@@next_arg
	lea	bx,[bx+size fn_record]
	cmp	bx,end_fn_records
	jb	@@next_arg

@@args_done:
	cmp	[dirlen],0
	jz	@@usage

	cmp	[directory+1],':'
	jne	@@usage

	mov	dx,offset directory
	mov	ah,3Bh			; CHDIR (make sure it's a valid dirspec)
	int	21h
	jc	@@usage

	mov	di,dx
	mov	cl,[dirlen]
	xor	ch,ch
	add	di,cx
	mov	al,'\'
	sub	di,1
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
	db	0Dh,0Ah,"You may also specify up to eight additional files to redirect."
	db	0Dh,0Ah,"(Above and beyond the usual HMID*.386 files)"
	db	0Dh,0Ah,"$"

end	hmiredir
