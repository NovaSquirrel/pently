;
; Pently sound effect player and "mixer"
; Copyright 2009-2015 Damian Yerrick
;
; Copying and distribution of this file, with or without
; modification, are permitted in any medium without royalty provided
; the copyright notice and this notice are preserved in all source
; code copies.  This file is offered as-is, without any warranty.
;

.include "pently.inc"
.import pently_update_music, pently_update_music_ch, pently_music_playing, pently_sfx_table
.import periodTableLo, periodTableHi
.export pently_zp_state, pentlyBSS

SNDCHN = $4015

; Ordinarily, the effect engine will move a pulse sound effect from
; $4000 to $4004 if $4004 is idle and $4000 is not, or if $4004 has
; less sfx data left to play than $4000.  Turn this off to force all
; pulse sfx to be played on $4000.
SQUARE_POOLING = 1

; As of 2011-03-10, a sound effect interrupts a musical instrument on
; the same channel only if the volume of the sfx is greater than that
; of the instrument.  Turn this off to force sound fx to interrupt
; the music whenever sfx data remains on that channel, even if the
; music is louder.
KEEP_MUSIC_IF_LOUDER = 1

.segment "ZEROPAGE"
pently_zp_state: .res 36
.segment "BSS"
pentlyBSS: .res 88

sfx_datalo = pently_zp_state + 0
sfx_datahi = pently_zp_state + 1
sfx_rate = pentlyBSS + 0
sfx_ratecd = pentlyBSS + 1
ch_lastfreqhi = pentlyBSS + 2
sfx_remainlen = pentlyBSS + 3

.ifndef SOUND_NTSC_ONLY
SOUND_NTSC_ONLY = 0
.endif
.if (!SOUND_NTSC_ONLY)
.importzp tvSystem
.endif

.segment "CODE"

;;
; Initializes all sound channels.
; Call this at the start of a program or as a "panic button" before
; entering a long stretch of code where you don't call update_sound.
;
.proc pently_init
  lda #$0F
  sta SNDCHN
  lda #$30
  sta $4000
  sta $4004
  sta $400C
  sta ch_lastfreqhi+0
  sta ch_lastfreqhi+8
  sta ch_lastfreqhi+4
  lda #$80
  sta $4008
  lda #8
  sta $4001
  sta $4005
  lda #0
  sta $4003
  sta $4007
  sta $400F
  sta sfx_remainlen+0
  sta sfx_remainlen+4
  sta sfx_remainlen+8
  sta sfx_remainlen+12
  sta sfx_ratecd+0
  sta sfx_ratecd+4
  sta sfx_ratecd+8
  sta sfx_ratecd+12
  sta pently_music_playing
  lda #64
  sta $4011
  rts
.endproc

;;
; Starts a sound effect.
; (Trashes pently_zptemp+0 through +4 and X.)
;
; @param A sound effect number (0-63)
;
.proc pently_start_sound
snddatalo = pently_zptemp + 0
snddatahi = pently_zptemp + 1
sndchno   = pently_zptemp + 2
sndlen    = pently_zptemp + 3
sndrate   = pently_zptemp + 4

  asl a
  asl a
  tax
  lda pently_sfx_table,x
  sta snddatalo
  lda pently_sfx_table+1,x
  sta snddatahi
  lda pently_sfx_table+2,x
  and #$0C
  sta sndchno
  lda pently_sfx_table+2,x
  lsr a
  lsr a
  lsr a
  lsr a
  sta sndrate
  lda pently_sfx_table+3,x
  sta sndlen

  ; Split up square wave sounds between pulse 1 ($4000) and
  ; pulse 2 ($4004) depending on which has less data left to play
  .if ::SQUARE_POOLING
    lda sndchno
    bne not_ch0to4  ; if not ch 0, don't try moving it
      lda sfx_remainlen+4
      cmp sfx_remainlen
      bcs not_ch0to4
      lda #4
      sta sndchno
    not_ch0to4:
  .endif 

  ; Play only if this sound effect is no shorter than the existing
  ; effect on the same channel
  ldx sndchno
  lda sndlen
  cmp sfx_remainlen,x
  bcc ch_full

  ; Replace the current sound effect if any
  sta sfx_remainlen,x
  lda snddatalo
  sta sfx_datalo,x
  lda snddatahi
  sta sfx_datahi,x
  lda sndrate
  sta sfx_rate,x
  lda #0
  sta sfx_ratecd,x
ch_full:
  rts
.endproc


;;
; Updates sound effect channels.
;
.proc pently_update
  jsr pently_update_music
  ldx #12
loop:
  jsr pently_update_music_ch
  jsr pently_update_one_ch
  dex
  dex
  dex
  dex
  bpl loop
  rts
.endproc

.proc pently_update_one_ch
srclo  = pently_zptemp + 0
srchi  = pently_zptemp + 1
tvol   = pently_zptemp + 2
tpitch = pently_zptemp + 3
t4     = pently_zptemp + 4


  ; At this point, the music engine should have left duty and volume
  ; in 2 and pitch in 3.
  lda sfx_remainlen,x
  ora sfx_ratecd,x
  bne ch_not_done
  lda tvol
  bne update_channel_hw

  ; Turn off the channel and force a reinit of the length counter.
  cpx #8
  beq not_triangle_kill
    lda #$30
  not_triangle_kill:
  sta $4000,x
  lda #$FF
  sta ch_lastfreqhi,x
  rts
ch_not_done:

  ; playback rate divider
  dec sfx_ratecd,x
  bpl rate_divider_cancel
  lda sfx_rate,x
  sta sfx_ratecd,x

  ; fetch the instruction
  lda sfx_datalo+1,x
  sta srchi
  lda sfx_datalo,x
  sta srclo
  clc
  adc #2
  sta sfx_datalo,x
  bcc :+
    inc sfx_datahi,x
  :
  ldy #0
  .if ::KEEP_MUSIC_IF_LOUDER
    lda tvol
    and #$0F
    sta t4
    lda (srclo),y
    and #$0F
    
    ; At this point: A = sfx volume; 4 = musc volume
    cmp t4
    bcc music_was_louder
  .endif
  lda (srclo),y
  sta tvol
  iny
  lda (srclo),y
  sta tpitch
music_was_louder:
  dec sfx_remainlen,x

update_channel_hw:
  lda tvol
  ora #$30
  cpx #12
  bne notnoise
  sta $400C
  lda tpitch
  sta $400E
rate_divider_cancel:
  rts

notnoise:
  sta $4000,x
  ldy tpitch
.if ::SOUND_NTSC_ONLY = 0
  lda tvSystem
  lsr a
  bcc :+
  iny
:
.endif
  lda periodTableLo,y
  sta $4002,x
  lda periodTableHi,y
  cmp ch_lastfreqhi,x
  beq no_change_to_hi_period
  sta ch_lastfreqhi,x
  sta $4003,x
no_change_to_hi_period:

  rts
.endproc
