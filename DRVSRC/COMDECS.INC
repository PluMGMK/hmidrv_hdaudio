; Common declarations for driver and detector

	include	HDA.INC	; from Japheth's MIT-licensed HDAutils

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

ifdef	?FLASHTEK
; Phar Lap / FlashTek Real-Mode interrupt structure
RMIS	struc
	intn	dw ?
	rDS	dw ?
	rES	dw ?
	rFS	dw ?
	rGS	dw ?
	union
		rEAX	dd ?
		rAX	dw ?
	ends
	union
		rEDX	dd ?
		rDX	dw ?
	ends
RMIS	ends
endif

DEVSTOENUMERATE	equ 10h
