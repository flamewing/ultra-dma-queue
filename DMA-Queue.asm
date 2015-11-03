; ---------------------------------------------------------------------------
; Subroutine for queueing VDP commands (seems to only queue transfers to VRAM),
; to be issued the next time ProcessDMAQueue is called.
; Can be called a maximum of 18 times before the queue needs to be cleared
; by issuing the commands (this subroutine DOES check for overflow)
; ---------------------------------------------------------------------------
; Input:
; 	d1	Source address
; 	d2	Destination address
; 	d3	Transfer length
; Output:
; 	d0,d1,d2,d3,a1	trashed
;
; With both options below set to zero, the function runs in:
; * 48(11/0) cycles if the queue was full at the start;
; * 194(33/9) cycles otherwise
; The times for the original S2 function are:
; * 52(12/0) cycles if the queue was full at the start;
; * 336(51/9) cycles if queue became full with new command;
; * 346(52/10) cycles otherwise
; The times for the original S&K function are:
; * 52(12/0) cycles if the queue was full at the start;
; * 344(53/9) cycles if queue became full with new command;
; * 354(54/10) cycles otherwise
;
; If you are on S3&K, or you have ported S3&K KosM decompressor, you definitely
; want to edit it to mask off all interrupts before calling QueueDMATransfer:
; both this function *and* the original have numerous race conditions that make
; them unsafe for use by the KosM decoder, since it sets V-Int routine before it
; executes. This can lead to broken DMAs in some rare circumstances.
;
; Like the S3&K version, but unlike the S2 version, this function is "safe" when
; the source is in RAM; this comes at no cost whatsoever, unlike what happens in
; the S3&K version. Moreover, you can gain a few more cycles if the source is in
; RAM in a few cases: whenever a call to QueueDMATransfer has this instruction:
; 	andi.l #$FFFFFF,d1
; You can simply delete it and gain 16(3/0) cycles.
; ===========================================================================
; This option breaks DMA transfers that crosses a 128kB block into two. It is
; disabled by default because you can simply align the art in ROM and avoid the
; issue altogether. It is here so that you have a high-performance routine to do
; the job in situations where you can't align it in ROM. It beats the equivalent
; functionality in the S&K disassembly with Sonic3_Complete flag set by a lot,
; especially since that version breaks up DMA transfers when they cross *32*kB
; boundaries instead of the problematic 128kB boundaries.
; This option adds 16(3/0) cycles to all DMA transfers that don't cross a 128kB
; boundary. For convenience, here are total times for all cases:
; * 48(11/0) cycles if the queue was full at the start (as always);
; * 214(37/9) cycles for DMA transfers that do not need to be split into two;
; * 252(46/9) cycles if the first piece of the DMA filled the queue;
; * 368(64/16) cycles if both pieces of the DMA were queued
; For comparison, times for the Sonic3_Complete version are:
; * If the source is in address $800000 and up (32x RAM, z80 RAM, main RAM):
; 	* 72(16/0) cycles if the queue was full
; 	* 364(57/0) cycles if queue became full with new command;
; 	* 374(58/10) cycles otherwise
; * If the source is in address $7FFFFF and down (ROM, both SCD RAMs):
; 	* If the DMA does not need to be split:
; 		* 294(53/10) cycles if the queue was full at the start;
; 		* 586(94/19) cycles if queue became full with new command;
; 		* 596(95/20) cycles otherwise
; 	* If the DMA needs to be split in two:
; 		* 436(83/30) cycles if the queue was full at the start;
; 		* 728(124/21) cycles if queue became full with the first command;
; 		* 1030(166/31) cycles if queue became full with the second command;
; 		* 1040(167/32) cycles otherwise
; Meaning you are wasting several hundreds of cycles on *each* *call*!
; What makes matters worse is that the Sonic3_Complete breaks up DMAs that it
; should not, meaning you will be wasting more cycles than can be seen by just
; comparing similar scenarios.
Use128kbSafeDMA = 0
; ===========================================================================
; Option to mask interrupts while updating the DMA queue. This fixes many race
; conditions in the DMA funcion, but it costs 46(6/1) cycles. The better way to
; handle these race conditions would be to make unsafe callers (such as S3&K's
; KosM decoder) prevent these by masking off interrupts before calling and then
; restore interrupts after.
UseVIntSafeDMA = 0
; ===========================================================================
; Option to assume that transfer length is always less than $7FFF. Only makes
; sense if Use128kbSafeDMA is 1. Moreover, setting this to 1 will cause trouble
; on a 64kB DMA, so make sure you never do one if you set it to 1!
; Enabling this saves 4(1/0) cycles on the case where a DMA is broken in two and
; both transfers are properly queued, and nothing at all otherwise.
AssumeMax7FFFXfer = 0&Use128kbSafeDMA
; ===========================================================================
; Convenience macros, for increased maintainability of the code.
    ifndef DMA
DMA = %100111
    endif
    ifndef VRAM
VRAM = %100001
    endif
    ifndef vdpCommReg_defined
; Like vdpComm, but starting from an address contained in a register
vdpCommReg_defined = 1
vdpCommReg macro reg,type,rwd,clr
	lsl.l	#2,reg							; Move high bits into (word-swapped) position, accidentally moving everything else
    if ((type&rwd)&3)<>0
	addq.w	#((type&rwd)&3),reg				; Add upper access type bits
    endif
	ror.w	#2,reg							; Put upper access type bits into place, also moving all other bits into their correct (word-swapped) places
	swap	reg								; Put all bits in proper places
    if clr <> 0
	andi.w	#3,reg							; Strip whatever junk was in upper word of reg
    endif
    if ((type&rwd)&$FC)==$20
	tas.b	reg								; Add in the DMA flag -- tas fails on memory, but works on registers
    elseif ((type&rwd)&$FC)<>0
	ori.w	#(((type&rwd)&$FC)<<2),reg		; Add in missing access type bits
    endif
    endm
    endif

    ifndef intMacros_defined
intMacros_defined = 1
enableInts macro
	move	#$2300,sr
    endm

disableInts macro
	move	#$2700,sr
    endm
    endif
; ===========================================================================

; ||||||||||||||| S U B R O U T I N E |||||||||||||||||||||||||||||||||||||||

; sub_144E: DMA_68KtoVRAM: QueueCopyToVRAM: QueueVDPCommand:
Add_To_DMA_Queue:
QueueDMATransfer:
    if UseVIntSafeDMA==1
	move.w	sr,-(sp)						; Save current interrupt mask
	disableInts								; Mask off interrupts
    endif ; UseVIntSafeDMA==1
	movea.w	(VDP_Command_Buffer_Slot).w,a1
	cmpa.w	#VDP_Command_Buffer_Slot,a1
	beq.s	.done							; return if there's no more room in the queue

	lsr.l	#1,d1							; Source address is in words for the VDP registers
    if Use128kbSafeDMA==1
	move.w  d3,d0							; d0 = length of transfer in words
	; Compute position of last transferred word. This handles 2 cases:
	; (1) zero length DMAs transfer length actually transfer $10000 words
	; (2) (source+length)&$FFFF == 0
	subq.w  #1,d0
	add.w   d1,d0							; d0 = ((src_address >> 1) & $FFFF) + ((xfer_len >> 1) - 1)
	bcs.s   .double_transfer				; Carry set = ($10000 << 1) = $20000, or new 128kB block
    endif ; Use128kbSafeDMA==1

	; Store VDP commands for specifying DMA into the queue
	swap	d1								; Want the high byte first
	move.w	#$977F,d0						; Command to specify source address & $FE0000, plus bitmask for the given byte
	and.b	d1,d0							; Mask in source address & $FE0000, stripping high bit in the process
	move.w	d0,(a1)+						; Store command
	move.w	d3,d1							; Put length together with (source address & $01FFFE) >> 1...
	movep.l	d1,1(a1)						; ... and stuff them all into RAM in their proper places (movep for the win)
	lea	8(a1),a1							; Skip past all of these commands

	vdpCommReg d2,VRAM,DMA,1				; Make DMA destination command
	move.l	d2,(a1)+						; Store command

	clr.w	(a1)							; Put a stop token at the end of the used part of the queue
	move.w	a1,(VDP_Command_Buffer_Slot).w	; Set the next free slot address, potentially undoing the above clr (this is intentional!)

.done:
    if UseVIntSafeDMA==1
	move.w	(sp)+,sr						; Restore interrupts to previous state
    endif ;UseVIntSafeDMA==1
	rts
; ---------------------------------------------------------------------------
    if Use128kbSafeDMA==1
.double_transfer:
	; Hand-coded version to break the DMA transfer into two smaller transfers
	; that do not cross a 128kB boundary. This is done much faster (at the cost
	; of space) than by the method of saving parameters and calling the normal
	; DMA function twice, as Sonic3_Complete does.
	; d0 is the number of words-1 that got over the end of the 128kB boundary
	addq.w	#1,d0							; Make d0 the number of words past the 128kB boundary
	sub.w	d0,d3							; First transfer will use only up to the end of the 128kB boundary
	; Store VDP commands for specifying DMA into the queue
	swap	d1								; Want the high byte first
	; Sadly, all registers we can spare are in use right now, so we can't use
	; no-cost RAM source safety.
	andi.w	#$7F,d1							; Strip high bit
	ori.w	#$9700,d1						; Command to specify source address & $FE0000
	move.w	d1,(a1)+						; Store command
	addq.b	#1,d1							; Advance to next 128kB boundary (**)
	move.w	d1,12(a1)						; Store it now (safe to do in all cases, as we will overwrite later if queue got filled) (**)
	move.w	d3,d1							; Put length together with (source address & $01FFFE) >> 1...
	movep.l	d1,1(a1)						; ... and stuff them all into RAM in their proper places (movep for the win)
	lea	8(a1),a1							; Skip past all of these commands

	move.w	d2,d3							; Save for later
	vdpCommReg d2,VRAM,DMA,1				; Make DMA destination command
	move.l	d2,(a1)+						; Store command

	cmpa.w	#VDP_Command_Buffer_Slot,a1		; Did this command fill the queue?
	beq.s	.skip_second_transfer			; Branch if so

	; Store VDP commands for specifying DMA into the queue
	; The source address high byte was done above already in the comments marked
	; with (**)
    if AssumeMax7FFFXfer==1
	ext.l	d0								; With maximum $7FFF transfer length, bit 15 of d0 is unset here
	movep.l	d0,3(a1)						; Stuff it all into RAM at the proper places (movep for the win)
    else
	moveq	#0,d2							; Need a zero for a 128kB block start
	move.w	d0,d2							; Copy number of words on this new block...
	movep.l	d2,3(a1)						; ... and stuff it all into RAM at the proper places (movep for the win)
    endif
	lea	10(a1),a1							; Skip past all of these commands
	; d1 contains length up to the end of the 128kB boundary
	add.w	d1,d1							; Convert it into byte length...
	add.w	d3,d1							; ... and offset destination by the correct amount
	vdpCommReg d1,VRAM,DMA,1				; Make DMA destination command
	move.l	d1,(a1)+						; Store command

	clr.w	(a1)							; Put a stop token at the end of the used part of the queue
	move.w	a1,(VDP_Command_Buffer_Slot).w	; Set the next free slot address, potentially undoing the above clr (this is intentional!)

    if UseVIntSafeDMA==1
	move.w	(sp)+,sr						; Restore interrupts to previous state
    endif ;UseVIntSafeDMA==1
	rts
; ---------------------------------------------------------------------------
.skip_second_transfer:
	move.w	a1,(a1)							; Set the next free slot address, overwriting what the second (**) instruction did

    if UseVIntSafeDMA==1
	move.w	(sp)+,sr						; Restore interrupts to previous state
    endif ;UseVIntSafeDMA==1
	rts
    endif ; Use128kbSafeDMA==1
; End of function QueueDMATransfer
; ===========================================================================

; ---------------------------------------------------------------------------
; Subroutine for issuing all VDP commands that were queued
; (by earlier calls to QueueDMATransfer)
; Resets the queue when it's done
; ---------------------------------------------------------------------------

; ||||||||||||||| S U B R O U T I N E |||||||||||||||||||||||||||||||||||||||

; sub_14AC: CopyToVRAM: IssueVDPCommands: Process_DMA:
Process_DMA_Queue:
ProcessDMAQueue:
	lea	(VDP_control_port).l,a5
	lea	(VDP_Command_Buffer).w,a1
	move.w	a1,(VDP_Command_Buffer_Slot).w

	rept (VDP_Command_Buffer_Slot-VDP_Command_Buffer)/(7*2)
	move.w	(a1)+,d0
	beq.w	.done		; branch if we reached a stop token
	; issue a set of VDP commands...
	move.w	d0,(a5)
	move.l	(a1)+,(a5)
	move.l	(a1)+,(a5)
	move.w	(a1)+,(a5)
	move.w	(a1)+,(a5)
	endm
	moveq	#0,d0

.done:
	move.w	d0,(VDP_Command_Buffer).w
	rts
; End of function ProcessDMAQueue
; ===========================================================================

; ---------------------------------------------------------------------------
; Subroutine for initializing the DMA queue.
; ---------------------------------------------------------------------------

; ||||||||||||||| S U B R O U T I N E |||||||||||||||||||||||||||||||||||||||

InitDMAQueue:
	lea	(VDP_Command_Buffer).w,a1
	move.w	#0,(a1)
	move.w	a1,(VDP_Command_Buffer_Slot).w
	move.l	#$96959493,d1
c := 0
	rept (VDP_Command_Buffer_Slot-VDP_Command_Buffer)/(7*2)
	movep.l	d1,2+c(a1)
c := c+14
	endm
	rts
; End of function ProcessDMAQueue
; ===========================================================================

