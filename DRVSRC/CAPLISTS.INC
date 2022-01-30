; Lists pointed to by capabilities structure
PortList	dw (DEVSTOENUMERATE+1) dup (-1)
DMAList		dw 0,-1		; unused
NUM_DMAs	equ (($-DMAList) SHR 1) - 1
IRQList		dw 3,5,7,0Ah,-1	; same ones SB16 can use except with 3 instead of 2
NUM_IRQs	equ (($-IRQList) SHR 1) - 1
