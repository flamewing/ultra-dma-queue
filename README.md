# Super fast DMA queue for the Sega Genesis
This is an extremelly optimized DMA queue function for the Sega Genesis, written in Motorolla 68000 assembly. It was made originally for Sonic hacks, but can be used with hacks of other games, or with homebrew games.

## How much faster is it?
In this section, I will compare it against the 3 DMA functions that were used by the Sonic hacking community before the release of this code:

* The stock S2 DMA queue function;
* the stock S&K DMA queue function;
* the Sonic3\_Complete DMA queue function that is used when you assemble the Git disassembly with Sonic3\_Complete=1.

The stock S2 function is the fastest of the 3:

* 52(12/0) cycles if the queue was full;
* 336(51/9) cycles if the new transfer filled the queue;
* 346(52/10) cycles otherwise.

The stock S&K function is 8(2/0) cycles slower than the S2 version, but it can be safely used when the source is in RAM (the S2 version requires some extra care, but I won't go into details). So its times are:

* 52(12/0) cycles if the queue was full;
* 344(53/9) cycles if the new transfer filled the queue;
* 354(54/10) cycles otherwise.

The Sonic3\_Complete version is based on the S&K stock version; it thus also safe with RAM sources. However, it breaks up DMA transfers that cross 32kB boundaries into two DMA transfers(\*). The way it does this adds an enormous overhead on all DMA transfers. Its times are:

* If the source is in address $800000 and up (32x RAM, z80 RAM, main RAM):
    * 72(16/0) cycles if the queue was full;
    * 364(57/0) cycles if queue became full with new command;
    * 374(58/10) cycles otherwise;
* If the source is in address $7FFFFF and down (ROM, both SCD RAMs):
    * If the DMA does not need to be split:
        * 294(53/10) cycles if the queue was full at the start;
        * 586(94/19) cycles if queue became full with new command;
        * 596(95/20) cycles otherwise;
    * If the DMA needs to be split in two:
        * 436(83/30) cycles if the queue was full at the start;
        * 728(124/21) cycles if queue became full with the first command;
        * 1030(166/31) cycles if queue became full with the second command;
        * 1040(167/32) cycles otherwise.

As can be seen, you are wasting *hundreds of cycles* by using the Sonic3\_Complete version... but even more than you think when you note the (\*) above: the VDP has issues with DMAs that cross a 128kB boundary in ROM; the Sonic3\_Complete tries to handle this, but is overzealous — it breaks up transfers that cross a **32**kB boundary instead. Thus, loads of DMAs are broken into two that should not be broken at all... leading to several hundreds of wasted cycles. The function is bad enough that manually breaking up the transfers would be much faster — potentially 2/3 of the time.

So, how does my optimized function compare with this?

There are two basic versions you can select with a flag during assembly: the "competitor" to stock S2/stock S&K versions, which does not care whether or not transfers cross a 128kB boundary; and the "competitor" to Sonic3\_Complete version, which is 128kB safe. Both of them are safe for RAM sources, and done so in an optimized way that has zero cost -- the functions would not be faster without this added protection. The times for the non-128kB-safe version are:

* 48(11/0) cycles if the queue was full at the start;
* 194(33/9) cycles otherwise.

The times for the 128kB-safe version are:

* 48(11/0) cycles if the queue was full at the start (as always);
* 214(37/9) cycles for DMA transfers that do not need to be split into two;
* 252(46/9) cycles if the first piece of the DMA filled the queue;
* 368(64/16) cycles if both pieces of the DMA were queued.

I will leave comparisons to whoever want to make them; however, I *will* mention that if you use SonMapEd-generated DPLCs and you are using the Sonic3\_Complete function, you are easily wasting thousands of cycles every frame.

## How to use it
I am assuming here that you start of from a Sonic 2 or Sonic & Knuckles hack. Using the new function requires that you do two things:

1. going through your assembly files and changing the way the queue is cleared;
2. calling the initialization function for the new DMA function.

In the end, you will have gained two bytes in RAM, and a DMA queue that runs much faster. So lets start with:

### Git S2 version
Find every instance of this code:
```68k
	move.l	#VDP_Command_Buffer,(VDP_Command_Buffer_Slot).w
```
and change it to this:
```68k
	move.w	#VDP_Command_Buffer,(VDP_Command_Buffer_Slot).w
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
Add these lines after the above block:
```68k
	clr.w	(VDP_Command_Buffer).w
	move.w	#VDP_Command_Buffer,(VDP_Command_Buffer_Slot).w
```
Then scan further down until you find this:
```68k
	clearRAM PNT_Buffer,$C04	; PNT buffer
```
and change it to this:
```68k
	clearRAM PNT_Buffer,$C00	; PNT buffer
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
		move.w	#0,(DMA_queue).w
		move.l	#DMA_queue,(DMA_queue_slot).w
```
and change them to
```68k
		move.w	#0,(DMA_queue).w
		move.w	#DMA_queue,(DMA_queue_slot).w
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

### Transfers of 64kB or larger
If you have enabled the version that breaks DMAs into two if they go over a 128kB boundary, this is relevant for you; but if you don't care about modified Sega Genesis consoles with 128kB of VRAM, you can simply skip this.

There is an option that saves 4(1/0) cycles on the case where a DMA transfer is broken in two pieces and both pieces are correctly queued (that is, the first transfer did not fill the queue). This option assumes that you never perform a transfer with length of 64kB or higher; note that transfers of exactly 64kB are included here! Under these conditions, a small optimization exists that leads to the small savings mentioned. This is disabled by default to avoid this edge case. If you need transfers larger than 64kB (meaning you are assuming a modified Sega Genesis with 128kB of VRAM), you will want to set AssumeMax7FFFXfer to 0 to disable this optimization.

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
