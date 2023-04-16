; Lists pointed to by capabilities structure
PortList	dw (DEVSTOENUMERATE+1) dup (-1)
DMAList		dw 1,-1		; unused
NUM_DMAs	equ (($-DMAList) SHR 1) - 1
IRQList		dw 2,3,4,5,6,7,8,9,0Ah,0Bh,0Ch,0Dh,0Eh,0Fh,-1 ; can use any
NUM_IRQs	equ (($-IRQList) SHR 1) - 1
