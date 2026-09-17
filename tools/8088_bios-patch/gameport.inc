;=========================================================================
; gameport.inc - Game adapter (joystick port) detection
;-------------------------------------------------------------------------
;
; Copyright (C) 2010 - 2023 Sergey Kiselev.
; Game port detection added 2026 for the PCXT-EGA MEGA65 port.
; Provided for hobbyist use under the terms of GPL version 3 or later.
;
; This program is free software: you can redistribute it and/or modify
; it under the terms of the GNU General Public License as published by
; the Free Software Foundation, either version 3 of the License, or
; (at your option) any later version.
;
; This program is distributed in the hope that it will be useful,
; but WITHOUT ANY WARRANTY; without even the implied warranty of
; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
; GNU General Public License for more details.
;
; You should have received a copy of the GNU General Public License
; along with this program.  If not, see <http://www.gnu.org/licenses/>.
;
;=========================================================================

gameport_reg	equ	201h		; game adapter I/O port
gameport_wait	equ	400		; poll cycles of ~15 us: about 6 ms,
					; longer than any axis pulse

;=========================================================================
; detect_gameport - detect a game adapter with a joystick and print findings
; Input:
;	none
; Output:
;	none (sets the "game adapter installed" bit in the equipment word)
; Notes:
;	Writing to the port fires the axis one-shots; their bits (0..3) then
;	stay set for a time set by the joystick potentiometers and clear.
;	Without an adapter the ISA bus floats and the bits never change;
;	with an adapter but no joystick the timing capacitors never charge
;	and the bits never clear. So "a set bit that clears within the
;	timeout" means a usable joystick, which is what programs that trust
;	the equipment word (INT 11h bit 12) want to know. A stick held in
;	the far up-left corner at power-on reads as absent; centre it.
;-------------------------------------------------------------------------
detect_gameport:
	push	ax
	push	cx
	push	dx
	push	si
	mov	si,msg_gameport
	call	print
	mov	dx,gameport_reg
	out	dx,al			; strobe: any value fires the one-shots
	mov	cx,gameport_wait
	xor	ah,ah			; AH = a set axis bit was seen
.poll:
	in	al,dx
	and	al,0Fh			; axis bits only
	jz	.cleared		; all one-shots finished
	or	ah,al			; remember that they fired
	call	delay_15us
	loop	.poll
	jmp	.absent			; still set after the timeout

.cleared:
	test	ah,ah
	jz	.absent			; never fired: nothing timing anything
	or	word [equipment_list],1000h ; game adapter installed
	mov	si,msg_present
	call	print
	jmp	.exit

.absent:
	mov	si,msg_absent
	call	print

.exit:
	pop	si
	pop	dx
	pop	cx
	pop	ax
	ret
