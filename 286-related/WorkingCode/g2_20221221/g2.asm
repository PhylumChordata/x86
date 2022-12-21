; Last updated 16 DEC 2022
; Latest update: VGA
; Assembler: NASM
; Target clock: Tested PCB v0.10 with 8-9 MHz CPU clock
;
; *physical memory map*
; -----------------------
; -    ROM  (256 KB)    -
; -   0xC0000-0xFFFFF   -
; -----------------------
; -   VIDEO  (128 KB)   -
; -   0xA0000-0xBFFFF   -
; -----------------------
; -    RAM  (640 KB)    -
; -   0x00000-0x9FFFF   -
; -----------------------
;
; Additional Comments
; PPI/LCD code adapted from "The 80x86 IBM PC and Compatible Computers..., 4th Ed." -- Mazidi & Mazidi
; Sample interrupt code adapted from https://stackoverflow.com/questions/51693306/registering-interrupt-in-16-bit-x86-assembly
; Sample interrupt code adapted from "The 80x86 IBM PC and Compatible Computers..., 4th Ed." -- Mazidi & Mazidi
; https://tiij.org/issues/issues/fall2006/32_Jenkins-PIC/Jenkins-PIC.pdf
; 80286 Hardware Reference Manual, pg. 5-20
; http://www.nj7p.org/Manuals/PDFs/Intel/121500-001.pdf
;
; SPI SD Card routines
; Using HiLetgo Micro SD TF Card Reader - https://www.amazon.com/gp/product/B07BJ2P6X6
; Core logic adapted from George Foot's awesome page at https://hackaday.io/project/174867-reading-sd-cards-on-a-65026522-computer
; https://developpaper.com/sd-card-command-details/
; https://www.kingston.com/datasheets/SDCIT-specsheet-64gb_en.pdf
; RTC supports SPI modes 1 or 2 (not 0 or 4). See https://www.analog.com/en/analog-dialogue/articles/introduction-to-spi-interface.html for modes.

; VGA	320x240x1B (RRRGGGBB)

; ! to do !
; -routine to set specific CS low
; -routine to bring all CS high
; -consolidation of similar procedures
; -improved code commenting
; -improved timing - e.g., reduce delays and nops in SPI-related code -- plenty of room for improvement
; -ensure all routines save register state and restore register state properly
; -...

cpu		286
bits 	16

section .data

	; EQU's

		;PPI1 (1602 LCD)						BUS_ADDR (BUS addresses are shifted one A2-->pin A1, A1-->pin A0)
		;Base address: 0x00E0					11100000
		;PPI1 pin values
		;A1=0, A0=0		PORTA					11100000	0x00E0
		;A1=0, A0=1		PORTB					11100010	0x00E2
		;A1=1, A0=0		PORTC					11100100	0x00E4
		;A1=1, A0=1		CONTROL REGISTER		11100110	0x00E6

		PPI1_PORTA	equ	0x00E0
		PPI1_PORTB	equ	0x00E2
		PPI1_PORTC	equ 0x00E4
		PPI1_CTL	equ	0x00E6

		;PPI2 (PS/2 Keyboard)
		PPI2_PORTA	equ	0x00E8
		PPI2_PORTB	equ	0x00EA
		PPI2_PORTC	equ 0x00EC
		PPI2_CTL	equ	0x00EE
	
	
		; ***** PPI1 Configuration *****
		;							1=I/O Mode	|	00=Mode 0	|	1=PA In		|	0=PC (upper 4) Out	|	0=Mode 0	|	0=PB Out	|	0=PC (lower 4) Out
		CTL_CFG_PA_IN		equ		0b10010000		;0x90

		;							1=I/O Mode	|	00=Mode 0	|	0=PA Out	|	0=PC (uppper 4) Out	|	0=Mode 0	|	0=PB Out	|	0=PC (lower 4) Out
		CTL_CFG_PA_OUT		equ		0b10000000		;0x80

		;							1=I/O Mode	|	00=Mode 0	|	0=PA Out	|	0=PC (uppper 4) Out	|	0=Mode 0	|	1=PB In		|	0=PC (lower 4) Out
		CTL_CFG_PB_IN		equ		0b10000010		;0x82

		RS	equ 0b00000001
		RW 	equ 0b00000010
		E 	equ 0b00000100

		; ***** Interrupt Controller *****
		;Base address: 0x0010						;BUS_A1 connected to pin A0 of PIC
		PICM_P0				equ	0x0010				;PIC Master Port 0		ICW1				OCW2, OCW3
		PICM_P1				equ	0x0012				;PIC Master Port 1		ICW2, ICW3, ICW4	OCW1

		KBD_BUFSIZE			equ 32					; Keyboard Buffer length. Must be a power of 2
		KBD_IVT_OFFSET		 equ 9*4				; Base address of keyboard interrupt (IRQ) in IVT  // 9*4=36=0x24
													; Keyboard: IRQ1, INT number 0x09 (* 4 bytes per INT)

		RELEASE		equ		0b0000000000000001
		SHIFT		equ		0b0000000000000010

		VIA1_PORTB	equ		0x0020			; read and write to port pins on port B
		VIA1_PORTA	equ		0x0022			; read and write to port pins on port A
		VIA1_DDRB	equ		0x0024			; configure read/write on port B
		VIA1_DDRA	equ		0x0026			; configure read/write on port A
		VIA1_IER	equ		0x003c			; modify interrupt information, such as which interrupts are processed

		SPI_MISO    equ		0b00000001     
		SPI_MOSI    equ		0b00000010     
		SPI_CLK     equ		0b00000100     
												; support for 5 SPI devices per VIA port
												; *** PORT B ***								*** PORT A ***
		SPI_CS1     equ		0b10000000			; 8-digit 7-segment display						Arduino Nano serial output
		SPI_CS2		equ		0b01000000			; SD card										tbd
		SPI_CS3		equ		0b00100000			; tbd											tbd
		SPI_CS4		equ		0b00010000			; tbd											tbd
		SPI_CS5		equ		0b00001000			; tbd											tbd


		CMD_RESET							equ 0x0000		; General Reset of Nano
		CMD_PRINT_CHAR						equ 0x0100      ; Print to Serial
		CMD_PRINT_HEX8						equ 0x0200      ; Print to Serial
		CMD_PRINT_BINARY8					equ 0x0300      ; Print to Serial
		CMD_PRINT_HEX16						equ 0x0400      ; Print to Serial
		CMD_PRINT_BINARY16					equ 0x0500		; Print to Serial
		CMD_OLED_RESET						equ	0x0600		; Reset OLED
		CMD_PRINT_CHAR_OLED					equ 0x0700		; Print to OLED
		CMD_PRINT_STATUS_OLED				equ 0x0800		; Print to OLED
		CMD_CLEAR_OLED						equ 0x0900		; Clear OLED
		;xxx								equ 0x0A00		; ...

		OLED_STATUS_RAM_TEST_BEGIN			equ	1;
		OLED_STATUS_RAM_TEST_FINISH			equ	2;
		OLED_STATUS_PPI1_TEST_BEGIN			equ 3;
		OLED_STATUS_PPI1_TEST_FINISH		equ 4;
		OLED_STATUS_PPI2_TEST_BEGIN			equ 5;
		OLED_STATUS_PPI2_TEST_FINISH		equ 6;
		OLED_STATUS_VIA1_TEST_BEGIN			equ 7;
		OLED_STATUS_VIA1_TEST_FINISH		equ 8;
		OLED_STATUS_MATHCO_TEST_BEGIN		equ 9;
		OLED_STATUS_MATHCO_TEST_FINISH		equ 10;
		OLED_STATUS_PIC_TEST_BEGIN			equ 11;
		OLED_STATUS_PIC_TEST_FINISH			equ 12;
		OLED_STATUS_RAM_TEST_FAIL			equ 20;
		OLED_STATUS_PPI1_TEST_FAIL			equ 21;
		OLED_STATUS_PPI2_TEST_FAIL			equ 22;
		OLED_STATUS_VIA1_TEST_FAIL			equ 23;
		OLED_STATUS_MATHCO_TEST_FAIL		equ 24;
		OLED_STATUS_PIC_TEST_FAIL			equ 25;
		OLED_STATUS_POST_COMPLETE			equ 50;
		OLED_STATUS_EXCEPTION				equ 100;

		PIXEL_COL1							equ	0b10000000
		PIXEL_COL2							equ 0b01000000
		PIXEL_COL3							equ 0b00100000
		PIXEL_COL4							equ 0b00010000
		PIXEL_COL5							equ 0b00001000

	; VARs
	varstart:
		ivt times 1024			db		0xaa				; prevent writing in the same space as the IVT
		mem_test_tmp			dw		0x0					; used for RAM testing
		ppi1_ccfg				db		0x0					; current config for PPI1
		ppi2_ccfg				db		0x0					; current config for PPI2
		spi_state_b				db		0x0					; track CS state for spi on via port b
		spi_state_a				db		0x0					; track CS state for spi on via port a

		AREA					dd		0x0					; store result of area calculation

		dec_num					db		0x0
		dec_num100s				db		0x0
		dec_num10s				db		0x0
		dec_num1s				db		0x0

		kb_flags				dw		0x0					; track status of keyboard input
		kb_wptr					dw		0x0					; keyboard buffer write pointer
		kb_rptr					dw		0x0					; keyboard buffer read pointer
		kb_buffer times 256		dw      0x0					; 256-byte keyboard buffer

		current_char			dw		0x0					; current char for VGA output
		cursor_pos_h			dw		0x0					; horizontal position (pixel #) of text cursor
		cursor_pos_v			dw		0x0					; vertical position (pixel #) of text cursor
		pixel_offset_h			dw		0x0
		pixel_offset_v			dw		0x0
		charPixelRowLoopCounter	dw		0x0					; row pos when processing a char
		charpix_line1			db		0x0
		charpix_line2			db		0x0
		charpix_line3			db		0x0
		charpix_line4			db		0x0
		charpix_line5			db		0x0
		charpix_line6			db		0x0
		charpix_line7			db		0x0


		; mouse_pos_h			dw		0x0					; horizontal position (pixel #) of mouse pointer
		; mouse_pos_v			dw		0x0					; vertical position (pixel #) of mouse pointer 
		

		marker times 16		db		0xbb				; just for visibility in the rom
	varend:

;section .bss
	; nothing here yet

section .text
	top:				; physically at 0xC0000

		;*** SETUP REGISTERS **********************************
		xor		ax,	ax
		mov		ds, ax
		mov		sp,	ax				; Start stack pointer at 0. It will wrap around (down) to FFFE.
		mov		ax,	0x0040			; First 1K is reserved for interrupt vector table,
		mov		ss,	ax				; Start stack segment at the end of the IVT.
		mov		ax, 0xf000			; Read-only data in ROM at 0x30000 (0xf0000 in address space  0xc0000+0c30000). 
									; Move es to this by default to easy access to constants.
		mov		es,	ax				; extra segment

		;*** /SETUP REGISTERS *********************************

		cli										; disable interrupts
		call	vga_init
		call	lcd_init						; initialize the two-line 1602 LCD
		call	print_message					; print default prompt to 1602 LCD
		call	keyboard_init					; initialize keyboard (e.g., buffer)
		call	spi_init						; initialize SPI communications, including VIA1
		call	spi_sdcard_init					; initialize the SD Card (SPI)
		call	spi_8char7seg_init				; initialize the 8-char 7-seg LED display
		call	oled_init						; initialize the OLED 128x64 display on the Arduino Nano
		call	post_tests						; call series of power on self tests
		call	pic_init						; initialize PIC1 and PIC2
		sti										; enable interrupts
		call	play_sound
		call	lcd_clear
		call	rtc_getTemp						; get temperature from RTC
		call	rtc_getTime						; get time from RTC
		call	lcd_line2


	; fall into main_loop below

	main_loop:
		cli		; disable interrupts
		mov		ax,		[kb_rptr]
		cmp		ax,		[kb_wptr]
		sti		; enable interrupts
		jne		key_pressed
		jmp		main_loop

vga_init:
	; Video RAM  (128 KB) = 0xA0000-0xBFFFF
	push	ax
	push	bp
	push	si

	mov		bp, 0xfffe				; offset within segment - will start by subtracting 0x01 (i.e., 0xffff down to 0x0000)
	mov		si, 0xb000				; segment start (i.e., 0xb000 as top)
	mov		es, si

	.offset:
		mov		word es:[bp],	0x0000			; write black to the location
		sub		bp,				2				; if pass, drop down a word
		cmp		bp,				0xfffe			; if equal, it wrapped around - done with this segment
		jnz		.offset

		sub		si,	0x1000						; change to other VRAM segment
		mov		es, si

		cmp		si,	0x9000						; if equal, finished with 128 KB of video RAM
		jnz		.offset

	.out:

		call	gfx_draw_rectangle

		mov		word [cursor_pos_h],	0x0
		mov		word [cursor_pos_v],	512*3
		mov		word [pixel_offset_h],	0x0
		mov		word [pixel_offset_v],	0x0

		call	es_point_to_rom

		pop		si
		pop		bp
		pop		ax
		ret

gfx_draw_rectangle:
	; temporary - to make more dynamic later

	push	si
	push	es
	push	bx
	push	ax
	push	cx

	mov		ax,	0x0

	mov		si, 0xa000				; segment start (i.e., 0xb000 as top)
	mov		es, si

	mov		bx, 511
	.topbar:
		mov		byte es:[bx],	0x03
		dec		bx
		cmp		bx,		0xffff
		jne		.topbar

	mov		si, 0xb000				; segment start (i.e., 0xb000 as top)
	mov		es, si

	mov		bx, 511
	.middlebar:
		mov		byte es:[bx],	0x49
		dec		bx
		cmp		bx,		0xffff
		jne		.middlebar


	mov		si, 0xbde0				; segment start (i.e., 0xb000 as top)
	mov		es, si
	mov		bx, 511
	.bottombar:
		mov		byte es:[bx],	0x03
		dec		bx
		cmp		bx,		0xffff
		jne		.bottombar

	mov		si, 0xa000				; segment start (i.e., 0xb000 as top)
	mov		es, si
	mov		bx, 318
	mov		ax, 0
	.rightbar_upper:
		mov		byte es:[bx],	0xe0
		add		bx,		512			;next line
		inc		ax
		cmp		ax,		128
		jne		.rightbar_upper

	mov		si, 0xb000				; segment start (i.e., 0xb000 as top)
	mov		es, si
	mov		bx, 318
	mov		ax, 0
	.rightbar_lower:
		mov		byte es:[bx],	0xe0
		add		bx,		512			;next line
		inc		ax
		cmp		ax,		128
		jne		.rightbar_lower

	mov		si, 0xa000				; segment start (i.e., 0xb000 as top)
	mov		es, si
	mov		bx, 1
	mov		ax, 0
	.leftbar_upper:
		mov		byte es:[bx],	0x1c
		add		bx,		512			;next line
		inc		ax
		cmp		ax,		128
		jne		.leftbar_upper

	mov		si, 0xb000				; segment start (i.e., 0xb000 as top)
	mov		es, si
	mov		bx, 1
	mov		ax, 0
	.leftbar_lower:
		mov		byte es:[bx],	0x1c
		add		bx,		512			;next line
		inc		ax
		cmp		ax,		128
		jne		.leftbar_lower


	mov		si, 0xb400				; segment start (i.e., 0xb000 as top)
	mov		es, si
	mov		bx, 32
	mov		ax, 0
	mov		cx, 0
	.lower_pattern:
		mov		byte es:[bx],	al
		inc		bx
		inc		ax
		cmp		ax,		256
		jne		.lower_pattern
		inc		cx
		cmp		cx,		32
		je		.out
		add		bx,		256			; move to next row, y=32
		mov		ax,		0
		jmp		.lower_pattern

	.out:
		
		pop	cx
		pop	ax
		pop	bx
		pop	es
		pop	si
		ret

print_char_vga:
	; to do
	;	-register save/restore
	;	-...


	; al has ascii value of char to print

	and		ax,								0x00ff							; only care about lower byte (this line should not be needed... safety for now)

	mov		word [charPixelRowLoopCounter],	0x00							; init to zero
	mov		word [pixel_offset_v],			0x0000							; init to zero
	mov		word [pixel_offset_h],			0x0000							; init to zero

	mov		[current_char],					al								; store current char ascii value
	sub		al,								0x20							; translate from ascii value to address in ROM   ;example: 'a' 0x61 minus 0x20 = 0x41 for location in charmap
	
	mov		bx,								0x0008							; multiply by 8 (8 bits per byte)
	mul		bx								

	; add		ax,								[charPixelRowLoopCounter]				; for each loop through rows of pixel, increase this by one, so that following logic fetches the correct char pixel row 
	
	; ax should now be a relative address within charmap to the char to be printed
	
	mov		bx,								ax
	mov		al,								es:[charmap+bx]					; remember row 1 of pixels for char
	mov		[charpix_line1],				ax	
	mov		al,								es:[charmap+bx+1]				; remember row 2
	mov		[charpix_line2],				ax							
	mov		al,								es:[charmap+bx+2]				; remember row 3
	mov		[charpix_line3],				ax						
	mov		al,								es:[charmap+bx+3]				; remember row 4
	mov		[charpix_line4],				ax							
	mov		al,								es:[charmap+bx+4]				; remember row 5
	mov		[charpix_line5],				ax							
	mov		al,								es:[charmap+bx+5]				; remember row 6
	mov		[charpix_line6],				ax							
	mov		al,								es:[charmap+bx+6]				; remember row 7
	mov		[charpix_line7],				ax							
	

	.rows:
		mov		si,								[charPixelRowLoopCounter]	; to track current row in char - init to zero
		mov		di,								0x0000						; to track current col in char -  init to zero
		mov		word [pixel_offset_h],				0x0003
		.charpix_col1:
			mov		al,								[charpix_line1+si]
			test	al,								PIXEL_COL1
			je		.charpix_col2											; pixel not set, go to the next column
			call	draw_pixel
		
		.charpix_col2:
			inc		word [pixel_offset_h]
			mov		al,								[charpix_line1+si]
			test	al,								PIXEL_COL2
			je		.charpix_col3											; pixel not set, go to the next column
			call	draw_pixel
		
		.charpix_col3:
			inc		word [pixel_offset_h]
			mov		al,								[charpix_line1+si]
			test	al,								PIXEL_COL3
			je		.charpix_col4											; pixel not set, go to the next column
			call	draw_pixel
		
		.charpix_col4:
			inc		word [pixel_offset_h]
			mov		al,								[charpix_line1+si]
			test	al,								PIXEL_COL4
			je		.charpix_col5											; pixel not set, go to the next column
			call	draw_pixel
		
		.charpix_col5:
			inc		word [pixel_offset_h]
			mov		al,								[charpix_line1+si]
			test	al,								PIXEL_COL5
			je		.charpix_rowdone										; pixel not set, go to the next column
			call	draw_pixel
		
		.charpix_rowdone:
			add		word [pixel_offset_v],			512
			inc		word [charPixelRowLoopCounter]
			cmp		word [charPixelRowLoopCounter],	0x08
			jne		.rows


	add		word [cursor_pos_h], 6
	call	es_point_to_rom
	
	ret

draw_pixel:
	; to do: add support for bottom 64K of VRAM

	push	es
	push	si
	push	ax
	push	bx
	
	mov		si, 0xa000				; segment start (i.e., 0xa000 as top of video ram)
	mov		es, si

	;mov		bx, 0x0
	mov		bx,	[cursor_pos_h]
	add		bx, [cursor_pos_v]
	add		bx, [pixel_offset_h]
	add		bx, [pixel_offset_v]

	mov		byte es:[bx],	0x1c			; to do: pull color from var

	pop		bx
	pop		ax
	pop		si
	pop		es
	ret

keyboard_init:
	mov	word	[kb_flags],		0
	mov word	[kb_wptr],		0
	mov word	[kb_rptr],		0
	ret

oled_init:
	mov		ax,	CMD_OLED_RESET						; cmd06 = OLED init / reset, no param
	call	spi_send_NanoSerialCmd
	call	delay
	ret

post_tests:
	call	post_RAM
	call	post_PPIs
	call	post_VIA
	call	post_MathCo
	call	post_PIC
	call	post_Complete

	ret

post_RAM:
	; RAM  (640 KB) = 0x00000-0x9FFFF
	push	ax
	push	bx
	push	bp
	push	si

	mov		ax, CMD_PRINT_STATUS_OLED + OLED_STATUS_RAM_TEST_BEGIN
	call	spi_send_NanoSerialCmd

	mov		bx,	0x0009				; counter for LED output
	mov		bp, 0xfffe				; offset within segment - will start by subtracting 0x01 (i.e., 0xffff down to 0x0000)
	mov		si, 0x9000				; segment start (i.e., 0x9000 as top)
	mov		es, si

	mov		ax,						0b00000101_00001001			; digit (0-)4 = '9'
	call	spi_send_LEDcmd

	.offset:
		mov		ax,				es:[bp]			; backup test location
		mov		[mem_test_tmp],	ax

		mov		word es:[bp],	0xdbdb			; write a test value to the location
		mov		ax,				es:[bp]			; read the test value back
		cmp		ax,				0xdbdb			; make sure the value read matches what was written
		mov		ax,				[mem_test_tmp]	; put the original value back in the location being tested
		mov		es:[bp],		ax				; -
		jne		.fail							; if no match, fail

		sub		bp,				2				; if pass, drop down a word
		cmp		bp,				0xfffe			; if equal, it wrapped around - done with this segment
		jnz		.offset

		dec		bx								; shift to the next segment
		sub		si,	0x1000						; process segments 0x9000 down to 0x0000
		mov		es, si

		mov		ax,				0x0500			; desired LED character position
		add		ax,	bx							; add value to display (in al)
		call	spi_send_LEDcmd

		cmp		si,	0xf000						; if equal, it wrapped around- done with all segments
		jnz		.offset
		jmp		.pass

	.fail:
		mov		ax,	CMD_PRINT_STATUS_OLED + OLED_STATUS_RAM_TEST_FAIL
		call	spi_send_NanoSerialCmd
		jmp		.out
	.pass:
		mov		ax, CMD_PRINT_STATUS_OLED + OLED_STATUS_RAM_TEST_FINISH
		call	spi_send_NanoSerialCmd
	.out:
		mov		ax,				0b00000101_00001010	; desired LED character position
		call	spi_send_LEDcmd
		mov		ax,				0b00000100_00001010	; desired LED character position
		call	spi_send_LEDcmd

		call	es_point_to_rom

		pop		si
		pop		bp
		pop		bx
		pop		ax
		ret

es_point_to_rom:
	push	ax
	mov		ax, 0xf000			; Read-only data in ROM at 0x30000 (0xf0000 in address space  0xc0000+0c30000). 
								; Move es to this by default to easy access to constants.
	mov		es,	ax				; extra segment
	pop		ax
	ret

post_PPIs:
	; this testing requires a PPI that supports reading the configuration
	; Intersil 82c55a - yes
	; OKI 82c55a - no
	; NEC pd8255a - no

	push	ax
	push	dx

	; *** PPI1 ***
	mov		ax, CMD_PRINT_STATUS_OLED + OLED_STATUS_PPI1_TEST_BEGIN
	call	spi_send_NanoSerialCmd
	
	; do not currently have a PPI that supports reading control register
	jmp		.pass1

	mov		dx,			PPI1_CTL			; Get control port address
	mov		al,			CTL_CFG_PA_IN		; 0b10010000
	call	print_char_hex					; for debugging
	out		dx,			al					; Write control register on PPI
	in		al,			dx					; Read control register on PPI
	call	print_char_hex					; for debugging
	cmp		al,			CTL_CFG_PA_IN		; Compare to latest config
	
	mov		al,			[ppi1_ccfg]			; Restore value from prior to testing

	jne		.fail1
	jmp		.pass1

	.fail1:
		mov		ax,	CMD_PRINT_STATUS_OLED + OLED_STATUS_PPI1_TEST_FAIL
		call	spi_send_NanoSerialCmd
		jmp		.out1
	.pass1:
		mov		ax,	CMD_PRINT_STATUS_OLED + OLED_STATUS_PPI1_TEST_FINISH
		call	spi_send_NanoSerialCmd
	.out1:


	; *** PPI2 ***
	mov		ax,	CMD_PRINT_STATUS_OLED + OLED_STATUS_PPI2_TEST_BEGIN
	call	spi_send_NanoSerialCmd

	; do not currently have a PPI that supports reading control register
	jmp		.pass2

	mov		dx,			PPI2_CTL			; Get control port address
	in		al,			dx					; Read control register on PPI
	cmp		al,			[ppi2_ccfg]			; Compare to latest config
	jne		.fail2
	jmp		.pass2

	jmp		.pass2
	.fail2:
		mov		ax,	CMD_PRINT_STATUS_OLED + OLED_STATUS_PPI2_TEST_FAIL
		call	spi_send_NanoSerialCmd
		jmp		.out2
	.pass2:
		mov		ax,	CMD_PRINT_STATUS_OLED + OLED_STATUS_PPI2_TEST_FINISH
		call	spi_send_NanoSerialCmd
	.out2:
		pop		dx
		pop		ax
		ret

post_VIA:
	push	ax

	mov		ax, CMD_PRINT_STATUS_OLED + OLED_STATUS_VIA1_TEST_BEGIN
	call	spi_send_NanoSerialCmd

	mov		al,				0b11111111			
	out		VIA1_IER,		al					; enable all interrupts on VIA
	in		al,				VIA1_IER			
	add		al,				0x01				; should be all ones... add one, should be all zeros
	jnz		.fail								; if not all zeros, fail
	mov		al,				0b01111111			
	out		VIA1_IER,		al					; disable all interrupts on VIA
	in		al,				VIA1_IER			; bit 7 will be 1, then 1 for all bits enabled
	cmp		al,				0b10000000			; if all interrupts disabled, should be 0b10000000
	jne		.fail
	jmp		.pass

	.fail:
		mov		ax,	CMD_PRINT_STATUS_OLED + OLED_STATUS_VIA1_TEST_FAIL
		call	spi_send_NanoSerialCmd
		jmp		.out
	.pass:
		mov		ax,	CMD_PRINT_STATUS_OLED + OLED_STATUS_VIA1_TEST_FINISH
		call	spi_send_NanoSerialCmd
	.out:
		pop		ax
		ret

post_MathCo:
	push	ax
	
	mov		ax,	CMD_PRINT_STATUS_OLED + OLED_STATUS_MATHCO_TEST_BEGIN						; cmd08 = print status, 9 = MathCo test begin
	call	spi_send_NanoSerialCmd

	; To test the math coprocessor, calculate the area of a circle
	; R = radius, stored in .rodata =  91.67 = 42b7570a (0a57b742 in ROM)
	
	;mov		ax,		ES:[R+3]				; 42
	;mov		ax,		ES:[R+2]				; b7
	;mov		ax,		ES:[R+1]				; 57
	;mov		ax,		ES:[R]					; 0a

	finit									; Initialize math coprocessor
	fld		dword ES:[R]					; Load radius
	fmul	st0,st0							; Square radius
	fldpi									; Load pi
	fmul	st0,st1							; Multiply pi by radius squared
	
	fstp	dword [AREA]					; Store calculated area
											; Should be 26400.0232375 = 46ce400c (0c40ce46 in RAM)
	
	call	delay							; Some delay required here
	call	delay							; Some delay required here

	; Compare actual result with expected result
	mov		ax,		[AREA+2]
	cmp		ax,		0x46ce
	jne		.fail

	mov		ax,		[AREA]
	cmp		ax,		0x400c
	jne		.fail

	jmp		.pass
	
	.fail:
		mov		ax,	CMD_PRINT_STATUS_OLED + OLED_STATUS_MATHCO_TEST_FAIL			; cmd08 = print status, 24 = MathCo test fail
		call	spi_send_NanoSerialCmd
		jmp		.out
	.pass:
		mov		ax,	CMD_PRINT_STATUS_OLED + OLED_STATUS_MATHCO_TEST_FINISH		; cmd08 = print status, 10 (0x0A) = MathCo test finish
		call	spi_send_NanoSerialCmd
	.out:
		pop		ax
		ret

post_PIC:
	push	dx
	push	ax

	mov		ax,	CMD_PRINT_STATUS_OLED + OLED_STATUS_PIC_TEST_BEGIN
	call	spi_send_NanoSerialCmd

	; write/read warm-up
	mov		dx,		PICM_P1			; address for port 1 (will use ocw1)
	mov		al,		0x0				; set IMR to zero (unmask all interrupts)
	out		dx,		al		
	in		al,		dx				; read IMR
	mov		al,		0xff			; set IMR to zero (unmask all interrupts)
	out		dx,		al		
	in		al,		dx				; read IMR

	
	; *** Test procedure from IBM BIOS Technical Reference
	mov		dx,		PICM_P1			; address for port 1 (will use ocw1)
	mov		al,		0x0				; set IMR to zero (unmask all interrupts)
	out		dx,		al		
	in		al,		dx				; read IMR
	or		al,		al
	jnz		.fail					; if not zero, error
	mov		al,		0xff			
	out		dx,		al				; mask (disable) all interrupts
	in		al,		dx				; read IMR
	add		al,		0x01			; should be all ones... +1 = all zeros
	jnz		.fail					; if not all zeros, error
	jmp		.pass

	.fail:
		mov		ax,	CMD_PRINT_STATUS_OLED + OLED_STATUS_PIC_TEST_FAIL
		call	spi_send_NanoSerialCmd
		jmp		.out
	.pass:
		mov		ax,	CMD_PRINT_STATUS_OLED + OLED_STATUS_PIC_TEST_FINISH
		call	spi_send_NanoSerialCmd
	.out:
		; to do: restore IMR to pre-test state (currently, enabling all interrupts -- could change in the future)
		pop		ax
		pop		dx
		ret

post_Complete:
	mov		ax, CMD_PRINT_STATUS_OLED + OLED_STATUS_POST_COMPLETE
	call	spi_send_NanoSerialCmd
	ret

spi_sdcard_init:
	mov		bx,		msg_sdcard_init
	call	print_string_to_serial

	call	delay			;remove? ...test
	call	delay


	; using SPI mode 0 (cpol=0, cpha=0)
	mov		al,				(SPI_CS1 | SPI_CS2 | SPI_CS3 | SPI_CS4 | SPI_CS5 | SPI_MOSI)					; SPI_CS2 high (not enabled), start with MOSI high and CLK low
	out		VIA1_PORTB,		al	
	
	mov		si,				0x00a0			;80 full clock cycles to give card time to initiatlize
	.init_loop:
		xor		al,				SPI_CLK
		out		VIA1_PORTB,		al
		nop									; nops might not be needed... test reducing/removing
		nop
		nop
		nop
		dec		si
		cmp		si,				0    
		jnz		.init_loop

    .try00:													; GO_IDLE_STATE
		mov		bx,		msg_sdcard_try00
		call	print_string_to_serial

		mov		bx,		cmd0_bytes							; place address of cmd data in bx
		call	spi_sdcard_sendcommand

        ; Expect status response 0x01 (not initialized)
		cmp		al,		0x01
		jne		.try00

		mov		bx,		msg_sdcard_try00_done
		call	print_string_to_serial


		mov		bx,		msg_garbage
		call	print_string_to_serial

	call	delay

	.try08:													; SEND_IF_COND

		mov		bx,		msg_sdcard_try08
		call	print_string_to_serial

		mov		bx,		cmd8_bytes							; place address of cmd data in bx
		call	spi_sdcard_sendcommand

        ; Expect status response 0x01 (not initialized)
		cmp		al,		0x01
		jne		.try08

		mov		bx,		msg_sdcard_try08_done
		call	print_string_to_serial
		
		call	spi_readbyte_port_b							; read four bytes
		call	spi_readbyte_port_b
		call	spi_readbyte_port_b
		call	spi_readbyte_port_b

	.try55:													; APP_CMD
		mov		bx,		msg_sdcard_try55
		call	print_string_to_serial

		mov		bx,		cmd55_bytes							; place address of cmd data in bx
		call	spi_sdcard_sendcommand

        ; Expect status response 0x01 (not initialized)
		cmp		al,		0x01
		jne		.try55

		mov		bx,		msg_sdcard_try55_done
		call	print_string_to_serial

	.try41:													; SD_SEND_OP_COND
		mov		bx,		msg_sdcard_try41
		call	print_string_to_serial

		mov		bx,		cmd41_bytes							; place address of cmd data in bx
		call	spi_sdcard_sendcommand

        ; Expect status response 0x01 (not initialized)
		cmp		al,		0x00
		jne		.try55

		mov		bx,		msg_sdcard_try41_done
		call	print_string_to_serial

	.try18:													; READ_MULTIPLE_BLOCK, starting at 0x0
		mov		bx,		msg_sdcard_try18
		call	print_string_to_serial

		mov		bx,		cmd18_bytes							; place address of cmd data in bx
		call	spi_sdcard_sendcommand_noclose				; start reading SD card at 0x0


		; ** to do --	read bytes until 0xfe is returned
		;				this is where the actual data begins
		;call	spi_readbyte_port_b	
		;cmp		al,		0xfe							; 0xfe = have data
		;jne		.nodata									; if data avail, continue, otherwise jump to .nodata

		call	spi_sdcard_readdata	

		mov		bx,		msg_sdcard_try18_done
		call	print_string_to_serial
	
		jmp		.out

	.nodata:
		mov		bx,		msg_sdcard_nodata
		call	print_string_to_serial
	
	.out:

		mov		bx,		msg_sdcard_init_out
		call	print_string_to_serial

	ret

spi_sdcard_readdata:
	;call	lcd_clear

	call	send_garbage
	mov		al,				(SPI_CS1|			SPI_CS3 | SPI_CS4 | SPI_CS5 | SPI_MOSI)					; drop SPI_CS2 low to enable, start with MOSI high and CLK low
	mov		[spi_state_b],	al
	out		VIA1_PORTB,		al		
	call	send_garbage

	mov		si, 1024
	.loop:
		; first real data from card is the byte after 0xfe is read... usually the first byte
		call	spi_readbyte_port_b	
		; call	print_char_hex
		mov		ah,	0x02		; cmd02 = print hex
		call	spi_send_NanoSerialCmd
		dec		si
		jnz		.loop

		mov		ax,	0x010a		; cmd01 = print char - newline
		call	spi_send_NanoSerialCmd


	.out:
		call	send_garbage
		mov		al,				(SPI_CS1| SPI_CS2 |	SPI_CS3 | SPI_CS4 | SPI_CS5 | SPI_MOSI)					; drop SPI_CS2 low to enable, start with MOSI high and CLK low
		mov		[spi_state_b],	al
		mov		bx,		cmd12_bytes							; place address of cmd data in bx
		call	spi_sdcard_sendcommand

		mov		bx,		msg_sdcard_read_done
		call	print_string_to_serial
	ret

send_garbage:
	; when changing CS in SPI, a byte of (any) data should be sent just prior to and just following the CS change -- calling this a garbage byte
	; this might possibly only apply to SD Card CS  (?)
	
	mov		bp,		0x08					; send 8 bits
	.loop:
		mov		al,				[spi_state_b]	; instead of 0, need to keep CS properly set when using multiple SPI devices		
	.clock:
		; remove the following line
		and		al,				~SPI_CLK	;0b11111011	 low clock			to do: invert SPI_CLK instead of 0b... value		--use ~
		
		out		VIA1_PORTB,		al			; set MOSI (or not) first with SCK low
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		or		al,				SPI_CLK		; high clock
		out		VIA1_PORTB,		al			; raise CLK keeping MOSI the same, to send the bit
		nop
		nop
		nop
		nop
		nop
		nop
		nop

		dec		bp
		jne		.loop						; loop if there are more bits to send

		; end on low clock
		mov		al,				[spi_state_b]	
		out		VIA1_PORTB,		al			
		
	ret

spi_sdcard_sendcommand:

	call	send_garbage
	mov		al,				(SPI_CS1|			SPI_CS3 | SPI_CS4 | SPI_CS5 | SPI_MOSI)					; drop SPI_CS2 low to enable, start with MOSI high and CLK low
	mov		[spi_state_b],	al
	out		VIA1_PORTB,		al		
	call	send_garbage

	nop									; nops might not be needed... test reducing/removing
	nop
	nop
	nop
	nop
	nop
	nop
	nop

	mov		al,				ES:[bx+1]
	;call	print_char_hex
	call	spi_writebyte_port_b

	mov		al,				ES:[bx]
	;call	print_char_hex
	call	spi_writebyte_port_b
	
	mov		al,				ES:[bx+3]
	;call	print_char_hex
	call	spi_writebyte_port_b
	
	;call	lcd_line2

	mov		al,				ES:[bx+2]
	;call	print_char_hex
	call	spi_writebyte_port_b
	
	mov		al,				ES:[bx+5]
	;call	print_char_hex
	call	spi_writebyte_port_b
	
	mov		al,				ES:[bx+4]
	;call	print_char_hex
	call	spi_writebyte_port_b

	;call	delay

	call	spi_waitresult
	push	ax				; save result

	;call	delay

	call	send_garbage
	mov		al,				(SPI_CS1| SPI_CS2 | SPI_CS3 | SPI_CS4 | SPI_CS5 | SPI_MOSI)	
	mov		[spi_state_b],	al
	out		VIA1_PORTB,		al	
	call	send_garbage

	pop		ax				; retrieve result

	.out:
  ret

  spi_sdcard_sendcommand_noclose:
	; same as spi_sdcard_sendcommand, but leaves SPI_CS2 low (enabled)
	; used in cases such as READ_MULTIPLE_BLOCK, where CS should not be brought high until done reading blocks

	call	send_garbage
	mov		al,				(SPI_CS1|			SPI_CS3 | SPI_CS4 | SPI_CS5 | SPI_MOSI)					; drop SPI_CS2 low to enable, start with MOSI high and CLK low
	mov		[spi_state_b],	al
	out		VIA1_PORTB,		al		
	call	send_garbage

	nop									; nops might not be needed... test reducing/removing
	nop
	nop
	nop
	nop
	nop
	nop
	nop

	mov		al,				ES:[bx+1]
	;call	print_char_hex
	call	spi_writebyte_port_b

	mov		al,				ES:[bx]
	;call	print_char_hex
	call	spi_writebyte_port_b
	
	mov		al,				ES:[bx+3]
	;call	print_char_hex
	call	spi_writebyte_port_b
	
	;call	lcd_line2

	mov		al,				ES:[bx+2]
	;call	print_char_hex
	call	spi_writebyte_port_b
	
	mov		al,				ES:[bx+5]
	;call	print_char_hex
	call	spi_writebyte_port_b
	
	mov		al,				ES:[bx+4]
	;call	print_char_hex
	call	spi_writebyte_port_b

	;call	delay

	call	spi_waitresult
	push	ax				; save result

	;call	delay

	;call	send_garbage
	;mov		al,				(SPI_CS1| SPI_CS2 | SPI_CS3 | SPI_CS4 | SPI_CS5 | SPI_MOSI)	
	;mov		[spi_state_b],	al
	;out		VIA1_PORTB,		al	
	;call	send_garbage

	pop		ax				; retrieve result

	.out:
  ret

spi_waitresult:
	; Wait for the SD card to return something other than $ff
 
	call	spi_readbyte_port_b
	cmp		al,		0xff
	je		spi_waitresult
 
	ret

test_8char7seg:
	mov		ax,					0b00001010_00000100		; intensity = 9/32
	call	spi_send_LEDcmd
	mov		ax,					0b00000001_00000000		; digit 0 = '0'
	call	spi_send_LEDcmd
	mov		ax,					0b00000010_00000001		; digit 1 = '1'
	call	spi_send_LEDcmd
	mov		ax,					0b00000011_00000010		; digit 2 = '2'
	call	spi_send_LEDcmd
	mov		ax,					0b00000100_00000011		; digit 3 = '3'
	call	spi_send_LEDcmd
	mov		ax,					0b00000101_00000100		; digit 4 = '4'
	call	spi_send_LEDcmd
	mov		ax,					0b00000110_00000101		; digit 5 = '5'
	call	spi_send_LEDcmd
	mov		ax,					0b00000111_00000110		; digit 6 = '6'
	call	spi_send_LEDcmd
	mov		ax,					0b00001000_00000111		; digit 7 = '7'
	call	spi_send_LEDcmd
	ret

spi_8char7seg_init:

	push	ax
	mov		ax,					0b00001001_11111111		; decode mode = code B for all digits			0x09FF
	call	spi_send_LEDcmd
	mov		ax,					0b00001011_00000111		; scan limit = display all digits				
	call	spi_send_LEDcmd
	mov		ax,					0b00001010_00000000		; intensity = 1/32
	call	spi_send_LEDcmd
	mov		ax,					0b00001100_00000001		; shutdown mode = normal operation
	call	spi_send_LEDcmd
	
	mov		ax,					0b00000001_00001010		; digit 0 = '-'
	call	spi_send_LEDcmd
	mov		ax,					0b00000010_00001010		; digit 1 = '-'
	call	spi_send_LEDcmd
	mov		ax,					0b00000011_00001010		; digit 2 = '-'
	call	spi_send_LEDcmd
	mov		ax,					0b00000100_00001010		; digit 3 = '-'
	call	spi_send_LEDcmd
	mov		ax,					0b00000101_00001010		; digit 4 = '-'
	call	spi_send_LEDcmd
	mov		ax,					0b00000110_00001010		; digit 5 = '-'
	call	spi_send_LEDcmd
	mov		ax,					0b00000111_00001010		; digit 6 = '-'
	call	spi_send_LEDcmd
	mov		ax,					0b00001000_00001010		; digit 7 = '-'
	call	spi_send_LEDcmd

	mov		ax,					0b00001111_00000000		; normal operation (turn off display-test)
	call	spi_send_LEDcmd

	pop		ax
	ret

spi_init:
	; configure the port
	push	ax
	push	bx

	mov		al,				0b01111111			; disable all interrupts on VIA
	out		VIA1_IER,		al

	mov		al,				(SPI_CS1 | SPI_CS2 | SPI_CS3 | SPI_CS4 | SPI_CS5 | SPI_CLK | SPI_MOSI)	; set bits as output -- other bits will be input
	out		VIA1_DDRB,		al
	nop
	nop
	nop
	nop
	nop
	nop
	out		VIA1_DDRA,	al
	
	; set initial values on the port
	mov		al,				(SPI_CS1 | SPI_CS2 | SPI_CS3 | SPI_CS4 | SPI_CS5 | SPI_MOSI)	; start with all select lines high and clock low - mode 0
	mov		[spi_state_b],	al
	mov		[spi_state_a],	al
	out		VIA1_PORTB,		al		; set initial values - not CS's selected		;(this causes a low blip on port B lines)
	nop
	nop
	nop
	nop
	nop
	out		VIA1_PORTA,		al		; set initial values - not CS's selected
	
	mov		bx,		msg_spi_init
	call	print_string_to_serial

	pop		bx
	pop		ax
	ret

spi_writebyte_port_b:
	; Value to write in al
	; CS values and MOSI high in spi_state

	; Tick the clock 8 times with descending bits on MOSI
	; Ignoring anything returned on MISO (use spi_readbyte if MISO is needed)
  
	push	ax
	push	bx
	push	bp

	mov		bp,		0x08					; send 8 bits
	.loop:
		shl		al,				1			; shift next bit into carry
		mov		bl,				al			; save remaining bits for later
		jnc		.sendbit					; if carry clear, don't set MOSI for this bit and jump down to .sendbit
		mov		al,				[spi_state_b]	; instead of 0, need to keep CS properly set when using multiple SPI devices		
		;or		al,				SPI_MOSI	; if value in carry, set MOSI
		jmp		.clock
	.sendbit:
		mov		al,				[spi_state_b]	; instead of 0, need to keep CS properly set when using multiple SPI devices		
		and		al,				~SPI_MOSI	;0b11111101	; to do: invert SPI_MOSI instead of 0b... value
	.clock:
		; remove the following line
		and		al,				~SPI_CLK	;0b11111011	 low clock			to do: invert SPI_CLK instead of 0b... value		--use ~
		
		out		VIA1_PORTB,		al			; set MOSI (or not) first with SCK low
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		or		al,				SPI_CLK		; high clock
		out		VIA1_PORTB,		al			; raise CLK keeping MOSI the same, to send the bit
		nop
		nop
		nop
		nop
		nop
		nop
		nop

		mov		al,				bl			; restore remaining bits to send
		dec		bp
		jne		.loop						; loop if there are more bits to send

	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	
	;bring clock low
	mov		al,				[spi_state_b]			
	out		VIA1_PORTB,		al			


	pop		bp
	pop		bx
	pop		ax
	ret

spi_writebyte_port_a:
	; Value to write in al
	; CS values and MOSI high in spi_state

	; Tick the clock 8 times with descending bits on MOSI
	; Ignoring anything returned on MISO (use spi_readbyte if MISO is needed)
  
	push	ax
	push	bx
	push	bp

	mov		bp,		0x08					; send 8 bits
	.loop:
		shl		al,				1			; shift next bit into carry
		mov		bl,				al			; save remaining bits for later
		jnc		.sendbit					; if carry clear, don't set MOSI for this bit and jump down to .sendbit
		mov		al,				[spi_state_a]	; instead of 0, need to keep CS properly set when using multiple SPI devices		
		;or		al,				SPI_MOSI	; if value in carry, set MOSI
		jmp		.clock
	.sendbit:
		mov		al,				[spi_state_a]	; instead of 0, need to keep CS properly set when using multiple SPI devices		
		and		al,				~SPI_MOSI	;0b11111101	; to do: invert SPI_MOSI instead of 0b... value
	.clock:
		; remove the following line
		and		al,				~SPI_CLK	;0b11111011	 low clock			to do: invert SPI_CLK instead of 0b... value		--use ~
		
		out		VIA1_PORTA,		al			; set MOSI (or not) first with SCK low
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		or		al,				SPI_CLK		; high clock
		out		VIA1_PORTA,		al			; raise CLK keeping MOSI the same, to send the bit
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		
		mov		al,				bl			; restore remaining bits to send
		dec		bp
		jne		.loop						; loop if there are more bits to send

	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop

	;bring clock low
	mov		al,				[spi_state_a]			
	out		VIA1_PORTA,		al		

	pop		bp
	pop		bx
	pop		ax
	ret

spi_writebyte_port_a_mode_1:
	; Value to write in al
	; CS values and MOSI high in spi_state

	; Tick the clock 8 times with descending bits on MOSI
	; Ignoring anything returned on MISO (use spi_readbyte if MISO is needed)
  
	push	ax
	push	bx
	push	bp

	mov		bp,		0x08					; send 8 bits
	.loop:
		shl		al,				1			; shift next bit into carry
		mov		bl,				al			; save remaining bits for later
		jnc		.sendbit					; if carry clear, don't set MOSI for this bit and jump down to .sendbit
		mov		al,				[spi_state_a]	; instead of 0, need to keep CS properly set when using multiple SPI devices		
		jmp		.clock
	.sendbit:
		mov		al,				[spi_state_a]	; instead of 0, need to keep CS properly set when using multiple SPI devices		
		and		al,				~SPI_MOSI	;0b11111101	; to do: invert SPI_MOSI instead of 0b... value
	.clock:
		; remove the following line
		or		al,				SPI_CLK		; high clock
		
		out		VIA1_PORTA,		al			; set MOSI (or not) first with SCK low
		nop
		nop
		and		al,				~SPI_CLK	; low clock
		out		VIA1_PORTA,		al			; lower CLK keeping MOSI the same, to send the bit
		nop
		nop
		
		mov		al,				bl			; restore remaining bits to send
		dec		bp
		jne		.loop						; loop if there are more bits to send


	;bring clock low
	;mov		al,				[spi_state_a]			
	;out		VIA1_PORTA,		al		

	pop		bp
	pop		bx
	pop		ax
	ret

spi_readbyte_port_b:
	mov		bp,		0x08					; send 8 bits
	.loop:
		mov		al,				[spi_state_b]		; MOSI already high and CLK low
		out		VIA1_PORTB,		al
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		nop

		or		al,				SPI_CLK		; toggle the clock high
		out		VIA1_PORTB,		al
		in		al,				VIA1_PORTB	; read next bit
		and		al,				SPI_MISO
		clc									; default to clearing the bottom bit
		je		.readyByteBitNotSet			; unless MISO was set
		stc									; in which case get ready to set the bottom bit

		.readyByteBitNotSet:
			mov		al,				bl		; transfer partial result from bl
			rcl		al,				1		; rotate carry bit into read result
			mov		bl,				al		; save partial result back to bl
			dec		bp						; decrement counter
			jne		.loop					; loop if more bits

	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop

	push	ax		;save read value
	; end clock high
	mov		al,				[spi_state_b]		; MOSI already high and CLK low
	out		VIA1_PORTB,		al
	pop		ax		;retrieve read value

	ret

spi_readbyte_port_a:
	;push	ax
	push	bx
	push	bp

	mov		bp,		0x08					; send 8 bits
	.loop:
		
		;mov		al,				SPI_MOSI	; enable card (CS low), set MOSI (resting state), SCK low
		mov		al,				[spi_state_a]		; MOSI already high and CLK low
		out		VIA1_PORTA,		al
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		or		al,				SPI_CLK		; toggle the clock high
		out		VIA1_PORTA,		al
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		in		al,				VIA1_PORTA	; read next bit
		and		al,				SPI_MISO
		clc									; default to clearing the bottom bit
		je		.readyByteBitNotSet			; unless MISO was set
		stc									; in which case get ready to set the bottom bit

		.readyByteBitNotSet:
			mov		al,				bl		; transfer partial result from bl
			rcl		al,				1		; rotate carry bit into read result
			mov		bl,				al		; save partial result back to bl
			dec		bp						; decrement counter
			jne		.loop					; loop if more bits

	; bring clock low
	mov		al,				[spi_state_a]			
	out		VIA1_PORTA,		al	

	pop		bp
	pop		bx
	;pop		ax

	ret

spi_readbyte_port_a_mode_1:
	;push	ax
	push	bx
	push	bp

	mov		bp,		0x08					; send 8 bits
	.loop:
		
		mov		al,				[spi_state_a]		; MOSI already high and CLK low
		or		al,				SPI_CLK			; toggle the clock high
		out		VIA1_PORTA,		al
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		and		al,				~SPI_CLK		; toggle the clock low
		out		VIA1_PORTA,		al
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		nop
		in		al,				VIA1_PORTA	; read next bit
		and		al,				SPI_MISO
		clc									; default to clearing the bottom bit
		je		.readyByteBitNotSet			; unless MISO was set
		stc									; in which case get ready to set the bottom bit

		.readyByteBitNotSet:
			mov		al,				bl		; transfer partial result from bl
			rcl		al,				1		; rotate carry bit into read result
			mov		bl,				al		; save partial result back to bl
			dec		bp						; decrement counter
			jne		.loop					; loop if more bits


	; bring clock low
	push	ax
	mov		al,				[spi_state_a]			
	out		VIA1_PORTA,		al	
	pop		ax
	pop		bp
	pop		bx
	;pop		ax

	ret

spi_send_NanoSerialCmd:
	; using SPI mode 0 (cpol=0, cpha=0)
	push	bx
	push	ax

	mov		al,				(			SPI_CS2	| SPI_CS3 | SPI_CS4 | SPI_CS5 | SPI_MOSI)					; drop SPI_CS1 low to enable, start with MOSI high and CLK low
	mov		[spi_state_a],		al
	out		VIA1_PORTA,		al		

	pop		ax						; get back original ax
	push	ax						; save it again to stack

	mov		al,				ah		; digit 1
	call	spi_writebyte_port_a	; write high byte (i.e., SPI cmd)
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop

	mov		al,				(SPI_CS1 | SPI_CS2 | SPI_CS3 | SPI_CS4 | SPI_CS5 | SPI_MOSI)		; bring all SPI_CSx high, keep MOSI high, and CLK low
	out		VIA1_PORTA,		al	
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	mov		al,				[spi_state_a]
	out		VIA1_PORTA,		al	

	pop		ax						; get back original ax
	push	ax						; save it again to stack
	call	spi_writebyte_port_a	; using original al, write low byte (parameter data for previously-sent cmd above)

	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop

	mov		al,				(SPI_CS1 | SPI_CS2 | SPI_CS3 | SPI_CS4 | SPI_CS5 | SPI_MOSI)		; bring all SPI_CSx high, keep MOSI high, and CLK low
	out		VIA1_PORTA,		al	

	pop		ax
	pop		bx
	ret

rtc_getTemp:
	; addr 0x11 = temp msb
	; addr 0x12 = temp lsb

	mov		al,			0x11
	call	spi_read_RTC
	
	call	print_char_dec
	
	; decimal portion - skipping for now
	; mov		al,			0x12
	; call	spi_read_RTC

	mov		al,			' '
	call	print_char

	mov		al,			'C'
	call	print_char

	ret

rtc_setTime:
	; addr 0x82 = hours
	; addr 0x81 = minutes
	; addr 0x80 = seconds

	; ** HOURS **
	mov		ax,			0x8208		; Set to 08:00:00 for testing
	call	spi_write_RTC			; bit 4 = 10s, low nibble 1s

	ret

rtc_getTime:
	; addr 0x02 = hours
	; addr 0x01 = minutes
	; addr 0x00 = seconds

	mov		al,			' '
	call	print_char
	mov		al,			' '
	call	print_char
	mov		al,			' '
	call	print_char
	mov		al,			' '
	call	print_char

	; ** HOURS **
	mov		al,			0x02
	call	spi_read_RTC			; bit 4 = 10s, low nibble 1s
	and		al,			0b00111111
	call	print_char_hex

	; ** MINUTES **
	mov		al,			':'
	call	print_char
	mov		al,			0x01		; high nibble 10s, low nibble 1s
	call	spi_read_RTC
	call	print_char_hex
	
	; ** SECONDS **
	mov		al,			':'
	call	print_char
	mov		al,			0x00		; high nibble 10s, low nibble 1s
	call	spi_read_RTC
	call	print_char_hex
	
	ret

spi_send_LEDcmd:
	push	bx
	push	ax

	mov		al,				(		   SPI_CS2 | SPI_CS3 | SPI_CS4 | SPI_CS5 | SPI_MOSI)		; drop SPI_CS1 low to enable, start with MOSI high and CLK low
	mov		[spi_state_b],		al
	out		VIA1_PORTB,		al		

	pop		ax						; get back original ax
	push	ax						; save it again to stack

	mov		al,				ah		; digit 1
	call	spi_writebyte_port_b

	pop		ax						; get back original ax
	push	ax						; save it again to stack
	call	spi_writebyte_port_b			; using original al


	mov		al,				(		SPI_CS2 | SPI_CS3 | SPI_CS4 | SPI_CS5 | SPI_MOSI)			; CLK low
	out		VIA1_PORTB,		al	

	mov		al,				(SPI_CS1 | SPI_CS2 | SPI_CS3 | SPI_CS4 | SPI_CS5 | SPI_MOSI)		; bring all SPI_CSx high
	out		VIA1_PORTB,		al	


	pop		ax
	pop		bx
	ret

spi_write_RTC:
	; ah = address
	; al = data

	push	bx
	push	ax

	mov		al,				( SPI_CS1 |			SPI_CS3	| SPI_CS4 | SPI_CS5 | SPI_MOSI)			; drop SPI_CS3 low to enable, start with MOSI high and CLK low
	mov		[spi_state_a],		al
	out		VIA1_PORTA,		al		

	pop		ax								; get back original ax
	push	ax								; save it again to stack

	mov		al,				ah				; hi byte
	call	spi_writebyte_port_a_mode_1

	pop		ax								; get back original ax
	push	ax								; save it again to stack
	call	spi_writebyte_port_a_mode_1		; using original al = lo byte


	mov		al,				( SPI_CS1 |			SPI_CS3	| SPI_CS4 | SPI_CS5 | SPI_MOSI)			; CLK low
	out		VIA1_PORTA,		al	

	mov		al,				(SPI_CS1 | SPI_CS2 | SPI_CS3 | SPI_CS4 | SPI_CS5 | SPI_MOSI)		; bring all SPI_CSx high
	out		VIA1_PORTA,		al	

	pop		ax
	pop		bx
	ret

spi_read_RTC:
	; al = address

	push	ax

	mov		al,				( SPI_CS1 |			SPI_CS3	| SPI_CS4 | SPI_CS5 | SPI_MOSI)			; drop SPI_CS3 low to enable, start with MOSI high and CLK low
	mov		[spi_state_a],		al
	out		VIA1_PORTA,			al	

	pop		ax								; get back original ax
	;push	ax								; save it again to stack
	call	spi_writebyte_port_a_mode_1		; using original al

	nop
	nop
	nop
	nop
	nop
	nop


	call	spi_readbyte_port_a_mode_1	
	push	ax
	; call	print_char_hex

	mov		al,				( SPI_CS1 |			SPI_CS3	| SPI_CS4 | SPI_CS5 | SPI_MOSI)			; CLK low
	out		VIA1_PORTA,		al	

	mov		al,				(SPI_CS1| SPI_CS2 |	SPI_CS3 | SPI_CS4 | SPI_CS5 | SPI_MOSI)			; bring SPI_CS3 high to disable
	out		VIA1_PORTA,		al	

	pop		ax
	ret

kbd_isr:
	pusha

	; if releasing a key, don't read PPI, but reset RELEASE flag
	mov		ax,					[kb_flags]
	and		ax,					RELEASE
	je		read_key								; if equal, releasing flag is not set, so continue reading the PPI
	mov		ax,					[kb_flags]
	and		ax,					~RELEASE			; clear the RELEASE flag
	mov		word [kb_flags],	ax

	call	kbd_get_scancode						; read scancode from PPI2 into al (for the key being released)
	cmp		al,						0x12			; left shift
	je		shift_up
	cmp		al,						0x59			; right shift
	je		shift_up

	; fall into kbd_isr_done below


kbd_isr_done:
	mov		al,			0x20		; EOI byte for OCW2 (always 0x20)
	out		PICM_P0,	al			; to port for OCW2
	popa
	iret

read_key:
	call	kbd_get_scancode		; read scancode from PPI2 into al

	.release:
		cmp		al,					0xf0		; key release
		je		key_release

	.shift:
		cmp		al,					0x12		; left shift
		je		shift_down
		cmp		al,					0x59		; right shift
		je		shift_down

	.filter:									; Filter out some noise scancodes
		cmp		al,					0x7e		; Microsoft Ergo keyboard init? - not using
		je		kbd_isr_done

		cmp		al,					0xfe		; ?		to do: identify
		je		kbd_isr_done	

		cmp		al,					0x0e		; ?		to do: identify
		je		kbd_isr_done

		cmp		al,					0xaa		; ?		to do: identify
		je		kbd_isr_done	

		cmp		al,					0xf8		; ?		to do: identify
		je		kbd_isr_done

		cmp		al,					0xe0		; key up for F1, ...
		je		kbd_isr_done


	
	;.esc:
	;	cmp		al,			0x76		; ESC
	;	jne		.f1
	;	call	lcd_clear
	;	jmp		kbd_isr_done

	.f1:
		cmp		al,			0x05		; F1
		jne		.f2
		
		call	lcd_clear
		call	rtc_getTemp						; get temperature from RTC
		call	rtc_getTime						; get time from RTC
		call	lcd_line2

		jmp		kbd_isr_done

	.f2:
		cmp		al,			0x06		; F2
		jne		.ascii
		
		call	lcd_clear
		call	rtc_setTime						; get temperature from RTC
		mov		al,	's'
		call	print_char
		mov		al,	'e'
		call	print_char
		mov		al,	't'
		call	print_char
		call	lcd_line2
		call	rtc_getTime						; get time from RTC

		jmp		kbd_isr_done

	; to do - check for other non-ascii
	; http://www.philipstorr.id.au/pcbook/book3/scancode.htm

	.ascii:
		call	kbd_scancode_to_ascii			; convert scancode to ascii
		push	di
		mov		di,				[kb_wptr]
		mov		[kb_buffer+di],	ax
		pop		di
		call	keyboard_inc_wptr
		jmp		kbd_isr_done

keyboard_inc_wptr:
	push		ax
	mov			ax,				[kb_wptr]
	cmp			ax,				500
	jne			.inc
	mov word	[kb_wptr],		0
	jmp			.out

	.inc:
		add	word [kb_wptr],	2
		; fall into .out
	.out:
		pop		ax
		ret

keyboard_inc_rptr:
	push		ax
	mov			ax,				[kb_rptr]
	cmp			ax,				500
	jne			.inc
	mov word	[kb_rptr],		0
	jmp			.out

	.inc:
		add word	[kb_rptr],	2
		; fall into .out
	.out:
		pop		ax
		ret

shift_up:
	mov		ax,					[kb_flags]
	xor		ax,					SHIFT		; clear the shift flag
	mov		word [kb_flags],	ax
	jmp		kbd_isr_done

shift_down:
  	mov		ax,					[kb_flags]
	or		ax,					SHIFT		; set the shift flag
	mov		word [kb_flags],	ax
	jmp		kbd_isr_done

key_release:
	mov		ax,					[kb_flags]
	or		ax,					RELEASE		; set release flag
	mov		word [kb_flags],	ax
	jmp		kbd_isr_done

key_pressed:
	push	ax

	mov		bx,		[kb_rptr]
	;and		bx,		0x00ff

	mov		ax,		[kb_buffer + bx]
		
	cmp		al,		0x0a		; enter
	je		enter_pressed
	cmp		al,		0x1b		; escape
	je		esc_pressed

	;call	print_char
	call	print_char_vga

	jmp		key_pressed_done
esc_pressed:
	call	lcd_clear
	call	vga_init
	jmp		key_pressed_done

enter_pressed:
	call	lcd_line2

	; mov		ah,							0x01			; spi cmd 1 - print char
	; call	spi_send_NanoSerialCmd

	add		word	[cursor_pos_v],		4096
	mov		word	[cursor_pos_h],		0x00
	
	jmp		key_pressed_done

key_pressed_done:
	call	keyboard_inc_rptr
	pop		ax
	jmp		main_loop
	
pic_init:
	push	ax
											; kbd_isr is at physical address 0xC0047. The following few lines move segment C000 and offset 0047 into the IVT
	mov word [KBD_IVT_OFFSET], kbd_isr		; DS set to 0x0000 above. These MOVs are relative to DS.
											; 0x0000:0x0024 = IRQ1 offset in IVT
	mov		ax, 0xC000
	mov word [KBD_IVT_OFFSET+2], ax			; 0x0000:0x0026 = IRQ1 segment in IVT

									; ICW1: 0001 | LTIM (1=level, 0=edge) | Call address interval (1=4, 0=8) | SNGL (1=single, 0=cascade) | IC4 (1=needed, 0=not)
	mov		al,			0b00010111			;0x17		ICW1 - edge, master, ICW4
	out		PICM_P0,	al

									; ICW2: Interrupt assigned to IR0 of the 8259 (usually 0x08)
	mov		al,			0x08		; setup ICW2 - interrupt type 8 (8-F)
	out		PICM_P1,	al

									; ICW3: 1=IR input has a slave, 0=no slave			--only set if using master/slave (SNGL=0 in ICW1)
	;mov		al,			0x00		; setup ICW3 - no slaves
	;out		PICM_P1,	al

									; ICW4: 000 | SFNM (1=spec fully nested mode, 0=not) | BUF & MS (0x = nonbuffered, 10 = buffered slave, 11 = buffered master) 
									; | AEOI (1=auto EOI, 0=normal) | PM (1=x86,0=8085)
	mov		al,			0x01		; setup ICW4 - master x86 mode
	out		PICM_P1,	al

	; PIC should be ready for interrupt requests at this point

									; OCW1: For bits, 0=unmask (enable interrupt), 1=mask
	;mov		al,			0b11010000	; Unmask IR0-IR7
	;out		PICM_P1,	al

	pop		ax
	ret

print_message:
	;mov		al,		'R'
	;call	print_char
	;mov		al,		'e'
	;call	print_char
	;mov		al,		'a'
	;call	print_char
	;mov		al,		'd'
	;call	print_char
	;mov		al,		'y'
	;call	print_char
	mov		al,		'>'
	call	print_char
	ret

print_string_to_serial:
	; Assuming string is in ROM .rodata section
	; Send a NUL-terminated string;
	; In: DS:BX -> string to print
	; Return: AX = number of characters printed
	; All other registers preserved or unaffected.

	push	bx 					; Save BX 
	push	cx 					; and CX onto the sack
	mov		cx, bx 				; Save contents of BX for later use
	
	.loop:
		mov		al, ES:[bx]		; Read byte from [DS:BX]
		or		al, al 			; Did we encounter a NUL character?
		jz		.return 		; If so, return to the caller
		mov		ah,		0x01	; spi cmd 1 - print char

		call	spi_send_NanoSerialCmd

		inc		bx 				; Increment the index
		jmp		.loop 			; And loop back
	
	.return: 
		sub		bx, cx 			; Calculate our number of characters printed
		mov		ax, bx 			; And load the result into AX
		pop		cx 				; Restore CX
		pop		bx 				; and BX from the stack
		ret 					; Return to our caller

lcd_init:
	push	ax
	mov		al,		0b00111000	;0x38	; Set to 8-bit mode, 2 lines, 5x7 font
	call	lcd_command_write
	mov		al,		0b00001110	;0x0E	; LCD on, cursor on, blink off
	call	lcd_command_write
	mov		al,		0b00000001	;0x01	; clear LCD
	call	lcd_command_write
	mov		al,		0b00000110  ;0x06	; increment and shift cursor, don't shift display
	call	lcd_command_write
	pop		ax
	ret

lcd_command_write:
	call	lcd_wait
	push	dx
	push	ax
	mov		dx,		PPI1_PORTA			; Get A port address
	out		dx,		al					; Send al to port A
	mov		dx,		PPI1_PORTB			; Get B port address
	mov		al,		E					; RS=0, RW=0, E=1
	out		dx,		al					; Write to port B
	nop									; wait for high-to-low pulse to be wide enough
	nop
	mov		al,		0x0					; RS=0, RW=0, E=0
	out		dx,		al					; Write to port B

	pop		ax
	pop		dx
	ret

print_char:
	call	lcd_wait
	push	dx
	push	ax

	mov		dx,		PPI1_PORTA			; Get A port address
	out		dx,		al					; Write data (e.g. char) to port A
	mov		al,		(RS | E)			; RS=1, RW=0, E=1
	mov		dx,		PPI1_PORTB			; Get B port address
	out		dx,		al					; Write to port B - enable high
	nop									; wait for high-to-low pulse to be wide enough
	nop
	mov		al,		RS					; RS=1, RW=0, E=0
	out		dx,		al					; Write to port B - enable low

	pop		ax
	pop		dx
	ret

print_char_hex:
	push	ax

	; mov		al,		'x'
	; call	print_char
	; pop		ax
	; push	ax
	
	and		al,		0xf0		; upper nibble of lower byte
	shr		al,		4
	cmp		al,		0x0a
	sbb		al,		0x69
	das
	call	print_char

	pop		ax
	push	ax
	and		al,		0x0f		; lower nibble of lower byte
	cmp		al,		0x0a
	sbb		al,		0x69
	das
	call	print_char

	pop		ax
	ret

print_char_dec:
	; al contains the binary value that will be converted to ascii and printed to the 2-line LCD
	push	ax
	push	bx

	mov	[dec_num],				al
	mov	byte [dec_num100s],		0
	mov	byte [dec_num10s],		0
	mov	byte [dec_num1s],		0

	.hundreds_loop:
		mov	al,			[dec_num]
		cmp	al,			100				; compare to 100
		jb				.tens_loop
		mov	al,			[dec_num]
		stc								; set carry
		sbb	al,			100				; subtract 100
		mov	[dec_num],	al
		inc	byte [dec_num100s]
		jmp .hundreds_loop

	.tens_loop:
		mov	al,			[dec_num]
		cmp	al,			10				; compare to 10
		jb				.ones_loop
		mov	al,			[dec_num]
		stc								; set carry
		sub	al,			10				; subtract 10
		mov	[dec_num],	al
		inc	byte [dec_num10s]
		jmp .tens_loop
		
	.ones_loop:
		mov	al,				[dec_num]
		mov [dec_num1s],	al

	;mov	si,		[dec_num100s]						; should this work??
	;mov	al,		byte ES:[hexOutLookup,si]			;
	;call		print_char_hex

	mov		al,		[dec_num100s]
	cmp		al,		0
	je		.print_10s
	call	print_char_dec_digit
	.print_10s:
	mov		al,		[dec_num10s]
	call	print_char_dec_digit
	mov		al,		[dec_num1s]
	call	print_char_dec_digit

	pop		bx
	pop		ax

	ret

print_char_dec_digit:
	push	ax
	cmp		al,		0x0a
	sbb		al,		0x69
	das
	call	print_char
	pop		ax
	ret

kbd_get_scancode:
	; Places scancode into al

	push	dx

	mov		al,				CTL_CFG_PB_IN
	mov		dx,				PPI2_CTL
	out		dx,				al
	; mov		[ppi2_ccfg],	al					; Remember current (latest) config
	mov		dx,				PPI2_PORTB			; Get B port address
	in		al,				dx					; Read PS/2 keyboard scancode into al
	mov		ah,				0					; testing - saftey

	pop		dx
	ret

kbd_scancode_to_ascii:
	; ax is updated with the ascii value of the scancode originally in ax
	push	bx
	
	test	word [kb_flags],		SHIFT
	jne		.shifted_key			; if shift is down, jump to .shifted_key, otherwise, process as not shifted key

	.not_shifted_key:
		;and		ax,		0x00FF		; needed?
		mov		bx,		ax
		mov		ax,		ES:[ keymap + bx]			; can indexing be done with bl? "invalid effective address"
		mov		ah,		0
		;and		ax,		0x00FF		; needed?
		jmp		.out

	.shifted_key:
		;and		ax,		0x00FF		; needed?
		mov		bx,		ax
		mov		ax,		ES:[ keymap_shifted + bx]			; can indexing be done with bl? "invalid effective address"
		mov		ah,		0
		;and		ax,		0x00FF		; needed?
		; fall into .out

	.out:
		pop		bx
		ret

ToROM:
	push 	cs 					; push CS onto the stack	
	pop 	ds 					; and pop it into DS so that DS is in ROM address space
	ret

ToRAM:
	push	ax
	mov		ax,	0x0				; return DS back to 0x0
	mov		ds, ax
	pop		ax
	ret

lcd_wait:
	push	ax				
	push	dx
	mov		al,					CTL_CFG_PA_IN		; Get config value
	mov		dx,					PPI1_CTL			; Get control port address
	out		dx,					al					; Write control register on PPI
	;mov		[ppi1_ccfg],		al					; Remember current config
	.again:	
		mov		al,				(RW)				; RS=0, RW=1, E=0
		mov		dx,				PPI1_PORTB			; Get B port address
		out		dx,				al					; Write to port B
		mov		al,				(RW|E)				; RS=0, RW=1, E=1
		out		dx,				al					; Write to port B
	
		mov		dx,				PPI1_PORTA			; Get A port address

		in		al,				dx				; Read data from LCD (busy flag on D7)
		rol		al,				1				; Rotate busy flag to carry flag
		jc		.again							; If CF=1, LCD is busy
		mov		al,				CTL_CFG_PA_OUT	; Get config value
		mov		dx,				PPI1_CTL		; Get control port address
		out		dx,				al				; Write control register on PPI
		;mov		[ppi1_ccfg],	al					; Remember current config

	pop	dx
	pop	ax
	ret

delay:
	push	bp
	push	si

	mov		bp, 0xFFFF
	mov		si, 0x0001
	.delay2:
		dec		bp
		nop
		jnz		.delay2
		dec		si
		cmp		si,0    
		jnz		.delay2

	pop		si
	pop		bp
	ret

lcd_clear:
	push	ax
    mov		al,		0b00000001		; Clear display
	call	lcd_command_write
	nop
	pop		ax
	ret

lcd_line2:
	push	ax
	mov		al,		0b10101000		; Go to line 2
	call	lcd_command_write
	pop		ax
	ret

play_sound:
	push	ax
	push	dx

	mov		al,				CTL_CFG_PA_OUT				; Get config value - PA_OUT includes PB_OUT also
	mov		dx,				PPI1_CTL					; Get control port address
	out		dx,				al							; Write control register on PPI
	;mov		[ppi1_ccfg],	al							; Remember current config

	mov		bp, 0x01FF									; Number of "sine" waves (-1) - duration of sound
	.wave:
		.up:
			mov		al,		0x1
			mov		dx,		PPI1_PORTC					; Get C port address
			out		dx,		al							; Write data to port C
			mov		si,		0x0060						; Hold duration of "up"

			.uploop:
				nop
				dec		si
				cmp		si,	0
				jnz		.uploop

		.down:
			mov		al,		0x0
			mov		dx,		PPI1_PORTC					; Get C port address
			out		dx,		al							; Write data to port C
			mov		si,		0x0060						; Hold duration of "down"

			.downloop:
				nop
				dec		si
				cmp		si,	0
				jnz		.downloop

		dec		bp
		jnz		.wave

	mov		bp, 0x00FF				; Number of "sine" waves (-1) - duratin of sound
	.wave2:
		.up2:
			mov		al,		0x1
			mov		dx,		PPI1_PORTC			; Get C port address
			out		dx,		al					; Write data to port C
			mov		si,		0x0050				; Hold duration of "up"

			.uploop2:
				nop
				dec		si
				cmp		si,	0
				jnz		.uploop2

		.down2:
			mov		al,		0x0
			mov		dx,		PPI1_PORTC			; Get C port address
			out		dx,		al					; Write data to port C
			mov		si,		0x0050				; Hold duration of "down"

			.downloop2:
				nop
				dec		si
				cmp		si,	0
				jnz		.downloop2

		dec		bp
		jnz		.wave2

	.out:
		pop		dx
		pop		ax

		ret

times 0x30000-($-$$)-0x0800 db 0xff	; Fill much of ROM with FFs to allow for faster writing of flash ROMs


section .rodata start=0x30000
	; SPI SD Card commands - Each cmd has six bytes of data to be sent
		cmd0_bytes:						; GO_IDLE_STATE
			dw	0x4000
			dw	0x0000
			dw	0x0095; 
		cmd1_bytes:						; SEND_OP_COND
			dw 0x4100
			dw 0x0000
			dw 0x00f9
		cmd8_bytes:						; SEND_IF_COND
			dw 0x4800
			dw 0x0001
			dw 0xaa87
		cmd12_bytes:					; STOP_TRANSMISSION
			dw 0x4c00
			dw 0x0000
			dw 0x0061
		cmd18_bytes:					; READ_MULTIPLE_BLOCK, starting at 0x0
			dw 0x5200	
			dw 0x0000
			dw 0x00e1
		cmd41_bytes:					; SD_SEND_OP_COND
			dw 0x6940
			dw 0x0000
			dw 0x0077
		cmd55_bytes:					; APP_CMD
			dw 0x7700
			dw 0x0000
			dw 0x0065

	; strings
		string_test					db	'80286 at 8 MHz!', 0x0
		msg_spi_init				db	'SPI (and VIA) Init', 0x0a, 0x0
		msg_sdcard_init				db	'SD Card Init starting', 0x0a, 0x0
		msg_sdcard_try00			db	'SD Card Init: Sending cmd 00...', 0x0a, 0x0
		msg_sdcard_try00_done		db	'SD Card Init: cmd 00 success', 0x0a, 0x0
		msg_sdcard_init_out			db	'SD Card routine finished',0x0a, 0x0
		msg_sdcard_sendcommand		db	'SD Card Send Command: ', 0x0
		msg_sdcard_received			db	0x0a, 'Received: ', 0x0
		msg_sdcard_try08			db	'SD Card Init: Sending cmd 08...', 0x0a, 0x0
		msg_sdcard_try08_done		db	'SD Card Init: cmd 08 success', 0x0a, 0x0
		msg_garbage					db	'.', 0x0a, 0x0
		msg_sdcard_try55			db	'SD Card Init: Sending cmd 55...', 0x0a, 0x0
		msg_sdcard_try55_done		db	'SD Card Init: cmd 55 success', 0x0a, 0x0
		msg_sdcard_try41			db	'SD Card Init: Sending cmd 41...', 0x0a, 0x0
		msg_sdcard_try41_done		db	'SD Card Init: cmd 41 success.', 0x0a, '** SD Card initialization complete. Let the party begin! **', 0x0a, 0x0
		msg_sdcard_try18			db	'SD Card Init: Sending cmd 18...', 0x0a, 0x0
		msg_sdcard_try18_done		db	'SD Card Init: cmd 18 success', 0x0a, 0x0
		msg_sdcard_nodata			db	'SD Card - No data!', 0x0a, 0x0
		msg_sdcard_read_done		db  'SD Card - Finished reading data', 0x0a, 0x0

	hexOutLookup:					db	'0123456789ABCDEF'

	keymap:
		db "????????????? `?"          ; 00-0F
		db "?????q1???zsaw2?"          ; 10-1F
		db "?cxde43?? vftr5?"          ; 20-2F
		db "?nbhgy6???mju78?"          ; 30-3F
		db "?,kio09??./l;p-?"          ; 40-4F
		db "??'?[=????",$0a,"]?",$5c,"??"    ; 50-5F     orig:"??'?[=????",$0a,"]?\??"   '\' causes issue with retro assembler - swapped out with hex value 5c
		db "?????????1?47???"          ; 60-6F0
		db "0.2568",$1b,"??+3-*9??"    ; 70-7F
		db "????????????????"          ; 80-8F
		db "????????????????"          ; 90-9F
		db "????????????????"          ; A0-AF
		db "????????????????"          ; B0-BF
		db "????????????????"          ; C0-CF
		db "????????????????"          ; D0-DF
		db "????????????????"          ; E0-EF
		db "????????????????"          ; F0-FF
	keymap_shifted:
		db "????????????? ~?"          ; 00-0F
		db "?????Q!???ZSAW@?"          ; 10-1F
		db "?CXDE$#?? VFTR%?"          ; 20-2F			; had to swap # and $ on new keyboard (???)
		db "?NBHGY^???MJU&*?"          ; 30-3F
		db "?<KIO)(??>?L:P_?"          ; 40-4F
		db "??",$22,"?{+?????}?|??"          ; 50-5F      orig:"??"?{+?????}?|??"  ;nested quote - compiler doesn't like - swapped out with hex value 22
		db "?????????1?47???"          ; 60-6F
		db "0.2568???+3-*9??"          ; 70-7F
		db "????????????????"          ; 80-8F
		db "????????????????"          ; 90-9F
		db "????????????????"          ; A0-AF
		db "????????????????"          ; B0-BF
		db "????????????????"          ; C0-CF
		db "????????????????"          ; D0-DF
		db "????????????????"          ; E0-EF
		db "????????????????"          ; F0-FF

	R			dd		91.67			; 42b7570a				In ROM: 0a57b742
	
	charmap:							; ASCII 0x20 to 0x7F	Used in VGA character output
		%include "charmap.asm"



times 0x0fff0 - ($-$$) db 0xff		; fill remainder of section with FFs (faster flash ROM writes)
									; very end overlaps .bootvector

; https://www.nasm.us/xdoc/2.15.05/html/nasmdoc7.html#section-7.3
section .bootvector	start=0x3fff0
	reset:						; at 0xFFFF0			*Processor starts reading here
		jmp 0xc000:0x0			; Jump to TOP: label

; times 0x040000-($-$$) db 0xff	; Fill the rest of ROM with bytes of 0x01 (256 KB total)
times 0x10 - ($-$$) db 0xff		; 16 - length of section so far (i.e., fill the rest of the section)