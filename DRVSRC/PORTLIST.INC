; Code to fill the "port" list using the PCI BIOS

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
