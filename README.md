# Super fast DMA queue for the Sega Genesis
This is an extremelly optimized DMA queue function for the Sega Genesis, written in Motorolla 68000 assembly. It was made originally for Sonic hacks, but can be used with hacks of other games, or with homebrew games.

## License
This uses a bsd 0-Clause License (0BSD). The TL;DR version is [here](https://tldrlegal.com/license/bsd-0-clause-license).

Basically, you can use however you want, and you don't have to add credits, licenses, or anything to your hack.

I only ask for the courtesy of giving some credit if you use it, but you are not forced to do it.

## How much faster is it?
In this section, I will compare it against the 3 DMA functions that were used by the Sonic hacking community before the release of this code:

* The stock S2 DMA queue function;
* the stock S&K DMA queue function;
* the Sonic3\_Complete DMA queue function that is used when you assemble the Git disassembly with Sonic3\_Complete=1.

The stock S2 function is the fastest of the 3:

* 52(12/0) cycles if the queue was full (DMA discarded);
* 336(51/9) cycles if the new transfer filled the queue (DMA queued);
* 346(52/10) cycles otherwise (DMA queued).

The stock S&K function is 8(2/0) cycles slower than the S2 version, but it can be safely used when the source is in RAM (the S2 version requires some extra care, but I won't go into details). So its times are:

* 52(12/0) cycles if the queue was full (DMA discarded);
* 344(53/9) cycles if the new transfer filled the queue (DMA queued);
* 354(54/10) cycles otherwise (DMA queued).

**TODO:** Fix numbers for Sonic3\_Complete, given Clownacy's recent changes.

The Sonic3\_Complete version is based on the S&K stock version; it thus also safe with RAM sources. However, it breaks up DMA transfers that cross 32 kB boundaries into two DMA transfers(\*). The way it does this adds an enormous overhead on all DMA transfers. Its times are:

* If the source is in address $800000 and up (32x RAM, z80 RAM, main RAM):
    * 72(16/0) cycles if the queue was full (DMA discarded);
    * 364(57/0) cycles if queue became full with new command (DMA queued);
    * 374(58/10) cycles otherwise (DMA queued);
* If the source is in address $7FFFFF and down (ROM, both SCD RAMs):
    * If the DMA does not need to be split:
        * 294(53/10) cycles if the queue was full at the start (DMA discarded);
        * 586(94/19) cycles if queue became full with new command (DMA queued);
        * 596(95/20) cycles otherwise (DMA queued);
    * If the DMA needs to be split in two:
        * 436(83/30) cycles if the queue was full at the start (DMA discarded);
        * 728(124/21) cycles if queue became full with the first command (second piece is discarded);
        * 1030(166/31) cycles if queue became full with the second command (both pieces queued);
        * 1040(167/32) cycles otherwise (both pieces queued).

As can be seen, you are wasting *hundreds of cycles* by using the Sonic3\_Complete version... but even more than you think when you note the (\*) above: the VDP has issues with DMAs that cross a 128 kB boundary in ROM; the Sonic3\_Complete tries to handle this, but is overzealous — it breaks up transfers that cross a **32** kB boundary instead. Thus, loads of DMAs are broken into two that should not be broken at all... leading to several hundreds of wasted cycles. The function is bad enough that manually breaking up the transfers would be much faster — potentially 2/3 of the time.

So, how does my optimized function compare with this?

There are three basic versions you can select with flags during assembly:

* the "competitor" to stock S2 version: does not care whether the transfer crosses a 128 kB boundary, and is not safe for use with RAM sources. This version runs in:
    * 48(11/0) cycles if the queue was full (DMA discarded);
    * 170(27/9) cycles otherwise (DMA queued).
* the "competitor" to stock S&K version: also does not care whether the transfer crosses a 128 kB boundary, but it *is* safe for use with RAM sources. This version (the default) runs in:
    * 48(11/0) cycles if the queue was full (DMA discarded);
    * 184(29/9) cycles otherwise (DMA queued).
* the "competitor" to Sonic3\_Complete version, which is 128 kB safe *and* is safe for use with RAM sources. This version runs in:
    * 48(11/0) cycles if the queue was full (DMA discarded, no increase compared to other versions);
    * 200(32/9) cycles if the DMA does not cross a 128kB boundary  (DMA queued);
    * 226(38/9) cycles if the DMA crosses a 128kB boundary, and the first piece fills the queue (second piece is discarded);
    * 338(56/17) cycles if the DMA crosses a 128kB boundary, and the queue has space for both pieces (both pieces queued).

I will leave comparisons to whoever want to make them; however, I *will* mention that if you use SonMapEd-generated DPLCs and you are using the Sonic3\_Complete function, you are easily wasting thousands of cycles every frame.

## How to use it
I am assuming here that you start of from a Sonic 2 or Sonic & Knuckles hack. Using the new function requires that you do two things:

1. going through your assembly files and changing the way the queue is cleared;
2. calling the initialization function for the new DMA function.

In the end, you will have gained two bytes in RAM, and a DMA queue that runs much faster. So lets start with:

### Git S2 version
Find every instance of this code:
```68k
	clr.w	(VDP_Command_Buffer).w
	move.l	#VDP_Command_Buffer,(VDP_Command_Buffer_Slot).w
```
and change it to this:
```68k
	ResetDMAQueue
```
Now find this:
```68k
	bsr.w	VDPSetupGame
```
and change it to this:
```68k
	jsr	(InitDMAQueue).l
	bsr.w	VDPSetupGame
```
Now find the "SpecialStage" label and scan down to this:
```68k
	move	#$2700,sr		; Mask all interrupts
	lea	(VDP_control_port).l,a6
	move.w	#$8B03,(a6)		; EXT-INT disabled, V scroll by screen, H scroll by line
	move.w	#$8004,(a6)		; H-INT disabled
	move.w	#$8ADF,(Hint_counter_reserve).w	; H-INT every 224th scanline
	move.w	#$8230,(a6)		; PNT A base: $C000
	move.w	#$8405,(a6)		; PNT B base: $A000
	move.w	#$8C08,(a6)		; H res 32 cells, no interlace, S/H enabled
	move.w	#$9003,(a6)		; Scroll table size: 128x32
	move.w	#$8700,(a6)		; Background palette/color: 0/0
	move.w	#$8D3F,(a6)		; H scroll table base: $FC00
	move.w	#$857C,(a6)		; Sprite attribute table base: $F800
	move.w	(VDP_Reg1_val).w,d0
	andi.b	#$BF,d0
	move.w	d0,(VDP_control_port).l
```
Add this line after the above block:
```68k
	ResetDMAQueue
```
Then scan further down until you find this:
```68k
	clearRAM SS_Misc_Variables,SS_Misc_Variables_End+4
```
and change it to this:
```68k
	clearRAM SS_Misc_Variables,SS_Misc_Variables_End
```
And finally find this:
```68k
; ---------------------------------------------------------------------------
; Subroutine for queueing VDP commands (seems to only queue transfers to VRAM),
; to be issued the next time ProcessDMAQueue is called.
; Can be called a maximum of 18 times before the buffer needs to be cleared
; by issuing the commands (this subroutine DOES check for overflow)
; ---------------------------------------------------------------------------

; ||||||||||||||| S U B R O U T I N E |||||||||||||||||||||||||||||||||||||||

; sub_144E: DMA_68KtoVRAM: QueueCopyToVRAM: QueueVDPCommand: Add_To_DMA_Queue:
QueueDMATransfer:
```
and delete everything from this up until (and including) this:
```68k
; loc_14CE:
ProcessDMAQueue_Done:
	move.w	#0,(VDP_Command_Buffer).w
	move.l	#VDP_Command_Buffer,(VDP_Command_Buffer_Slot).w
	rts
; End of function ProcessDMAQueue
```
In its place, include the "DMA-Queue.asm" file. You can also edit s2.constants.asm to reflect the fact that VDP_Command_Buffer_Slot is now a word instead of a longword.

### Git S&K version
Add the following equates somewhere:
```68k
VDP_Command_Buffer := DMA_queue
VDP_Command_Buffer_Slot := DMA_queue_slot
```
Then find all cases of
```68k
		clr.w	(DMA_queue).w
		move.l	#DMA_queue,(DMA_queue_slot).w
```
and all cases of
```68k
		move.w	#0,(DMA_queue).w
		move.l	#DMA_queue,(DMA_queue_slot).w
```
and change them to
```68k
		ResetDMAQueue
```
Now find all cases of
```68k
		bsr.w	Init_VDP
```
and change them to
```68k
		jsr	(InitDMAQueue).l
		bsr.w	Init_VDP
```
Finally, find this:
```68k
; ---------------------------------------------------------------------------
; Adds art to the DMA queue
; Inputs:
; d1 = source address
; d2 = destination VRAM address
; d3 = number of words to transfer
; ---------------------------------------------------------------------------

; =============== S U B R O U T I N E =======================================


Add_To_DMA_Queue:
```
and delete everything from this up until (and including) this:
```68k
$$stop:
		move.w	#0,(DMA_queue).w
		move.l	#DMA_queue,(DMA_queue_slot).w
		rts
; End of function Process_DMA_Queue
```
In its place, include the "DMA-Queue.asm" file. You can also edit sonic3k.constants.asm to reflect the fact that VDP_Command_Buffer_Slot is now a word instead of a long.

## Additional Care
There are some additional points that are worth paying attention to.

### 128kB boundaries and you
For both S2 or S&K (or anywhere you want to use this), the version that does not check for 128kB boundaries is the default. The reason is this: you can (and should) always align the problematic art in such a way that the DMA never needs to be split in two. So enabling this option by default carries a penalty with little real benefit. In any case, you can toggle this by setting the Use128kbSafeDMA option to 1.

### RAM sources and you
Sources in RAM typically have the top byte of the source address equal to $FF. This causes a problem when shifting down, because a 1 comes down to bit 23 of the source address as it is sent to the VP, which is actually the DMA flag (needs to be 0). For this reason, the DMA queue function defaults to RAM safety at the cost of 14(2/0) cycles. If you never transfer from RAM, you can set AssumeSourceAddressIsRAMSafe to 1 and gain these cycles back. If you may transfer from RAM, you can still benefit from this by editing all caller sites and doing a bitwise-and of the source address with $FFFFFF. You may have to hunt down the source of the addresses and do it there.

### Source adresses in words
By default, source addresses are in bytes, while the DMA length is in words. Moreover, the source address is converted to words to send to the VDP. You can use this to save 10(1/0) cycles if you pre-divide all source addresses by 2, then set AssumeSourceAddressInBytes to 0. Like with the above option, you will need to hunt down the ultimate sources of the addresses.

### RAM sources *and* addresses in words
You can combine both of the above in one step: you can use the supplied dmaSource function to convert all source addresses to satisfy the requirements of both and save 24(3/0) cycles.

### Macros, space vs time
If you are doing a static DMA (see below for an example), you can use the supplied QueueStaticDMA to inline the code and save even more cycles. This macro does not try to split DMAs for crossing 128 kB boundaries, and just errors out (during assembly) instead. A static DMA is of the form:
```68k
	move.l	#(Chunk_Table+$7C00) & $FFFFFF,d1
	move.w	#tiles_to_bytes(ArtTile_ArtUnc_HTZClouds),d2
	move.w	#tiles_to_bytes(8)/2,d3
	jsr	(QueueDMATransfer).w
```
Including the QueueDMATransfer routine (with default options), this code runs in:

* 94(20/2) cycles if the queue was full (DMA discarded);
* 230(38/11) otherwise (DMA queued).

This block can be replaced by the macro as follows:

```68k
	QueueStaticDMA Chunk_Table+$7C00,tiles_to_bytes(8),tiles_to_bytes(ArtTile_ArtUnc_HTZClouds)
```
(note that the length is no longer divided by 2). This dumps am optimized version of the DMA queuing function in-place, so there is no register assignments, no function call and no return. This code runs in:
* 32(7/0) cycles if queue is full (DMA discarded);
* 122(21/8) cycles otherwise (DMA queued).

So it is clear that using the macro represents enormous savings when possible, especially when compared to the stock versions of the DMA queue function. It does come at a cost: the macro is 20 words long, versus 9 words for the original code.

If the caller uses a `jmp` instead of a `jsr`, the savings are smaller: `jmp` is 8(1/0) cycles faster than `jsr`, and you need to add an `rts` after the QueueStaticDMA macro (an additional 16(4/0) cycles).

This macro is not interrupt-safe (see below), but can be made safe with UseVIntSafeDMA flag, as described below.

### Interrupt Safety
The original functions have several race conditions that makes them unsafe regarding interrupts. My version removes one of them, but adds another. For the vast majority of cases, this is irrelevant — the QueueDMATransfer function is generally called only when Vint\_routine is zero, meaning that the DMA queue will not be processed, and all is well.

There is one exception, though: the S3&K KosM decoder. Since the KosM decoder sets Vint\_routine to a nonzero value, you can potentially run into an interrupt in the middle of a QueueDMATransfer call. Effects range from lost DMA transfers, to garbage DMA transfers, to one garbage DMA and a lost DMA (if the transfer was split), or, in the best possible outcome, no ill effects at all. To guarantee that the last case is always the case, you can toggle interrupt safety by setting the UseVIntSafeDMA flag to 1. This does, however, add overhead to all safe callers; a better option would be to modify the unsafe callers so that they mask interrupts while the DMA transfer is being queued.

### ASM68k
If you use this crap, all you need to do to use the code above is:

* replace the dotted labels (composed symbols) by @ labels (local symbols);
* replace the last two instances of "endm" by "endr";
* edit the vdpCommReg macro to use asm68k-style parameters.

And before you complain that asm68k is not crap, I invite you to assemble the following and check the output:
```68k
	move.w	(d0),d1
	move.w	d0 ,d1
	dc.b	1 , 2
	moveq	#$80,d0
```
