;
; Pently audio engine
; Visualizer
;
; Copyright 2018 Damian Yerrick
; 
; This software is provided 'as-is', without any express or implied
; warranty.  In no event will the authors be held liable for any damages
; arising from the use of this software.
; 
; Permission is granted to anyone to use this software for any purpose,
; including commercial applications, and to alter it and redistribute it
; freely, subject to the following restrictions:
; 
; 1. The origin of this software must not be misrepresented; you must not
;    claim that you wrote the original software. If you use this software
;    in a product, an acknowledgment in the product documentation would be
;    appreciated but is not required.
; 2. Altered source versions must be plainly marked as such, and must not be
;    misrepresented as being the original software.
; 3. This notice may not be removed or altered from any source distribution.
;

.include "pentlyconfig.inc"
.include "pently.inc"
.include "nes.inc"
.include "shell.inc"

ARROW_SPRITE_TILE = $15

; This screen covers visualization, rehearsal mark seeking,
; slowdown/step playback, and track muting.
;
; Local TODO for https://github.com/pinobatch/pently/issues/27
; 1. Tempo scaling
; 2. Playback stepping a row at a time
; 3. Check issue
; 4. What is causing a higher than expected Peak on song start?

DIRTY_MUTE = $01

.zeropage
vis_to_clear: .res 1
vis_dirty: .res 1
vis_section_load_row: .res 1
vis_A_gesture_time: .res 1
vis_cursor_x: .res 1

.if PENTLY_USE_REHEARSAL
  vis_cur_song_section: .res 1
  vis_num_sections: .res 1
  vis_section_src: .res 2
  vis_start_held: .res 1
.endif

; Injection palette
.if PENTLY_USE_VIS
  vis_pulse1_color: .res 1
  vis_pulse2_color: .res 1
  vis_tri_color: .res 1
  vis_noise_color: .res 1
  vis_mute: .res 1
.endif

CH_TRI = $08
CH_NOISE = $0C
CH_END = $10
.if PENTLY_USE_ATTACK_TRACK
  LAST_TRACK = $10
.else
  LAST_TRACK = $0C
.endif

copydst_lo = $0180
copydst_hi = $0181
copybuf = $0100
LF = $0A

songrow = 35
caporow = 36
muterow = 56

.code
.proc vis
  .if ::PENTLY_USE_REHEARSAL
    lda #caporow
    sta vis_section_load_row
    lda #2
    sta vis_to_clear
  .else
    lda #$FF
    sta vis_section_load_row
    lda #0
    sta vis_to_clear
  .endif

  jsr load_song_title

  lda #0
  .if ::PENTLY_USE_REHEARSAL
    sta vis_start_held
  .endif
  sta vis_A_gesture_time
  sta vis_cursor_x
  lda #DIRTY_MUTE
  sta vis_dirty
  ldx #4
  stx oam_used
vis_loop:
  ldx oam_used
  jsr ppu_clear_oam

  ; Wait for vblank
  lda nmis
  :
    cmp nmis
    beq :-

  lda vis_to_clear
  beq vis_cleared
    jsr vis_clear_part
    lda #VBLANK_NMI|OBJ_1000|BG_0000|0
    bne have_which_nt
  vis_cleared:
    lda #>OAM
    sta OAM_DMA
    .if ::PENTLY_USE_VIS
      ; Update palette
      lda #$3F
      sta PPUADDR
      lda #$11
      sta PPUADDR
      lda vis_pulse1_color
      ldx vis_noise_color
      sta PPUDATA
      stx PPUDATA
      bit PPUDATA
      bit PPUDATA
      lda vis_pulse2_color
      sta PPUDATA
      bit PPUDATA
      bit PPUDATA
      bit PPUDATA
      lda vis_tri_color
      sta PPUDATA
    .endif
    
    lda copydst_hi
    bmi nocopy
      sta PPUADDR
      lda copydst_lo
      sta PPUADDR
      ldx #0
      :
        lda copybuf,x
        sta PPUDATA
        inx
        cpx #32
        bcc :-
    
    nocopy:
    lda #VBLANK_NMI|OBJ_1000|BG_0000|1
    sta copydst_hi
  have_which_nt:

  ldx #0
  ldy #0
  sec
  jsr ppu_screen_on
  jsr pently_update
  jsr read_pads
  ldx #4
  stx oam_used
  jsr vis_prepare_vram_row
  .if ::PENTLY_USE_VIS
    jsr vis_update_obj
  .endif
  .if ::PENTLY_USE_VARMIX
    jsr vis_draw_mute_cursor
  .endif

  lda vis_A_gesture_time
  beq :+
    dec vis_A_gesture_time
  :
  
  .if ::PENTLY_USE_REHEARSAL
    jsr find_current_row

    lda vis_cursor_x
    bne notRehearsalKeys
      jsr vis_draw_section_arrow
      jsr vis_handle_rehearsal_keys
    notRehearsalKeys:
    jsr vis_handle_tempo_keys
  .endif
  
  .if ::PENTLY_USE_VARMIX
    jsr vis_handle_varmix_keys
  .endif

  lda new_keys
  and #KEY_B
  bne vis_done
  jmp vis_loop
vis_done:
  rts
.endproc

; Song name and section names ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

.proc clear_copybuf
  sec
  ror a
  sta copydst_hi
  lda #0
  ror a
  lsr copydst_hi
  ror a
  lsr copydst_hi
  ror a
  sta copydst_lo
  ldx #31
  lda #' '
  :
    sta copybuf,x
    dex
    bpl :-
  bail:
  rts
.endproc

.proc load_song_title
bail = clear_copybuf::bail
src = $00
newlines_left = $03
  lda #songrow
  jsr clear_copybuf
  lda #>tracknames_txt
  ldy #<tracknames_txt
  sta src+1

  lda cur_song
  beq found
  sta newlines_left
  lda #0
  sta src+0
  searchloop:
    lda (src),y
    beq bail
    iny
    bne :+
      inc src+1
    :
    cmp #LF
    bne searchloop
    dec newlines_left
    bne searchloop
  found:
  sty src+0
  ldx #2
.endproc
.proc print_to_copybuf
src = $00
  ldy #0
  copyloop:
    lda (src),y
    beq not_found
    cmp #LF
    beq not_found
    sta copybuf,x
    iny
    inx
    cpx #32
    bcc copyloop
  not_found:
  rts
.endproc

.proc vis_clear_part
  ; Clearing nametable must be FAST
  clc
  adc #$23
  sta PPUADDR
  lda #$80
  sta PPUADDR
  lda #' '
  ldx #64
  :
    sta PPUDATA
    sta PPUDATA
    sta PPUDATA
    sta PPUDATA
    dex
    bne :-
  dec vis_to_clear
bail:
  rts
.endproc

.proc vis_prepare_vram_row
no_room = vis_clear_part::bail

  ; Ensure there's room in the VRAM copy buffer to load something
  lda copydst_hi
  bpl no_room

  ; Now look for things to load
  .if ::PENTLY_USE_REHEARSAL
    ; Are the section names drawn yet?
    lda vis_section_load_row
    bmi not_section_name
      jmp vis_draw_section_name
    not_section_name:
  .endif

  .if ::PENTLY_USE_VARMIX
    lda vis_dirty
    and #DIRTY_MUTE
    beq not_dirty0
      jmp vis_draw_mute
    not_dirty0:
  .endif

  rts
.endproc

.if PENTLY_USE_REHEARSAL
.proc vis_draw_section_name
src = $00

  lda vis_section_load_row
  jsr clear_copybuf
  lda vis_section_load_row
  sec
  sbc #caporow + 1
  bcs past_caporow
    ; 'Capo' row: Load the word "capo"
    lda #'c'
    sta copybuf+3
    lda #'a'
    sta copybuf+4
    lda #'p'
    sta copybuf+5
    lda #'o'
    sta copybuf+6

    ; With that out of the way, we can find the rehearsal marks
    lda cur_song
    asl a
    tax
    lda pently_rehearsal_marks,x
    sta vis_section_src+0
    lda pently_rehearsal_marks+1,x
    sta vis_section_src+1
    ldy #0
    lda (vis_section_src),y
    sta $5555
    sta vis_num_sections
    beq no_marks_left

    ; Skip past the row counts to the mark names
    asl a
    adc #2
    adc vis_section_src
    sta vis_section_src
    bcc :+
      inc vis_section_src+1
    :
    inc vis_section_load_row
    rts
  past_caporow:
    lda vis_section_src
    sta src
    lda vis_section_src+1
    sta src+1
    ldx #3
    jsr print_to_copybuf
    
    ; If at NUL terminator, stop
    cmp #0
    beq no_marks_left

    ; Move to next piece
    sec
    tya
    adc vis_section_src
    sta vis_section_src
    bcc :+
      inc vis_section_src+1
    :
    inc vis_section_load_row
    rts
no_marks_left:

  lda #$FF
  sta vis_section_load_row
  rts
.endproc

;;
; Sets vis_cur_song_section to the lowest section number whose ending
; row number is greater than the current row number.
.proc find_current_row
src = $00
nleft = $02

  ; If rows not printed yet, assume section 0
  lda vis_section_load_row
  cmp #caporow+16
  lda #0
  bcc have_section

  lda cur_song
  asl a
  tax
  lda pently_rehearsal_marks,x
  sta src+0
  lda pently_rehearsal_marks+1,x
  sta src+1
  ldy #0
  lda (src),y
  beq have_section
  sta nleft
  iny
  iny
  sectloop:
    lda pently_rowslo
    cmp (src),y
    iny
    lda pently_rowshi
    sbc (src),y
    bcc have_y
    iny
    dec nleft
    bne sectloop
  have_y:
  tya
  lsr a
  sec
  sbc #1
have_section:
  sta vis_cur_song_section
  rts
.endproc

.proc vis_draw_section_arrow
  ldy oam_used
  tya
  clc
  adc #4
  sta oam_used
  lda vis_cur_song_section
  asl a
  asl a
  asl a
  adc #(caporow - 32) * 8 - 1
  sta OAM,y
  lda #RIGHT_ARROW_SPRITE_TILE
  sta OAM+1,y
  lda #0
  sta OAM+2,y
  lda #16
  sta OAM+3,y
bail:
  rts
.endproc

.proc seek_to_section
src = $00
  asl a
  beq vis_draw_section_arrow::bail
  tay
  lda cur_song
  asl a
  tax
  lda pently_rehearsal_marks,x
  sta src+0
  lda pently_rehearsal_marks+1,x
  sta src+1
  iny
  lda (src),y
  tax
  dey
  lda (src),y
  jmp pently_skip_to_row
.endproc

.proc vis_handle_rehearsal_keys
  lda cur_keys
  and #KEY_START
  bne startHeld

  ; Down: Go to start of next section
  lda new_keys
  and #KEY_DOWN
  beq notDown
  lda vis_cur_song_section
  cmp vis_num_sections
  bcs notDown
    lda #1
    adc vis_cur_song_section
    jsr seek_to_section
  notDown:

  ; Up: Rewind, then go to start of previous section
  lda new_keys
  and #KEY_UP
  beq notUp
  lda vis_cur_song_section
  beq notUp
    lda pently_tempo_scale
    pha
    lda cur_song
    jsr pently_start_music
    .if ::PENTLY_USE_VARMIX
      jsr vis_set_mute
    .endif
    pla
    sta pently_tempo_scale
    lda vis_cur_song_section
    sec
    sbc #1
    bcc notUp
    jsr seek_to_section
  notUp:

startHeld:
  rts
.endproc

.proc vis_handle_tempo_keys
  lda new_keys
  and #KEY_START
  ora vis_start_held
  sta vis_start_held
  lda cur_keys
  eor #$FF
  and vis_start_held
  beq not_start_release
  lda #$80
  eor pently_tempo_scale
  sta pently_tempo_scale
  jmp consume_start_held

not_start_release:
  ; Test for Start+Up and Start+Down
  lda cur_keys
  and #KEY_START
  beq nope

  lda pently_tempo_scale
  and #$03
  tax

  lda new_keys
  and #KEY_UP
  beq not_start_up
    cpx #0
    beq :+
      dec pently_tempo_scale
    :
    jmp consume_start_held
  not_start_up:
  
  lda new_keys
  and #KEY_DOWN
  beq nope
    cpx #3
    beq :+
      inc pently_tempo_scale
    :

consume_start_held:
  lda #0
  sta vis_start_held
nope:

  ; Check for A while paused = step once
  
  lda pently_tempo_scale
  and new_keys
  bpl not_paused_A
  lda vis_cursor_x
  bne not_paused_A
    clc
    ldx pently_rowshi
    lda pently_rowslo
    adc #1
    bcc :+
      inx
    :
    jsr pently_skip_to_row
  not_paused_A:

  rts
.endproc

.endif

; Visualizer ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

VIS_PITCH_Y = 183
TARGET_NOTE_DOT_TILE = $13

.if PENTLY_USE_VIS

.proc vis_update_obj
semitonenum = $08
overtone_x = $09
effective_vol = $0A
semitone_xlo = $0C
semitone_xhi = $0D

  ldy #4

  ; Y: OAM index; X: channel
  ldx #0
  chloop:
    ; Draw pitch/volume marks
    lda pently_vis_dutyvol,x
    and #$0F
    beq pitchvol_mark_done  ; Draw no such mark for silent channels
      jmp draw_pitchvol_mark
    pitchvol_mark_done:

    ; Draw target note marks for pulse 1, pulse 2 and triangle
    cpx #CH_NOISE
    bcs target_note_mark_done
      jmp draw_target_note_mark
    target_note_mark_done:
    inx
    inx
    inx
    inx
    cpx #CH_END
    bcc chloop
  sty oam_used

  ; Calculate palette based on attack injection
.if ::PENTLY_USE_ATTACK_TRACK
  ldx #$20
  lda pently_vis_arpphase+0
  bmi pulse1_injected
.endif
    ldx #$26
  pulse1_injected:
  stx vis_pulse1_color

.if ::PENTLY_USE_ATTACK_TRACK
  ldx #$20
  lda pently_vis_arpphase+4
  bmi pulse2_injected
.endif
    ldx #$2A
  pulse2_injected:
  stx vis_pulse2_color

.if ::PENTLY_USE_ATTACK_TRACK
  ldx #$20
  lda pently_vis_arpphase+CH_TRI
  bmi tri_injected
.endif
    ldx #$12
  tri_injected:
  stx vis_tri_color

  ; Calculate noise palette based on color
  ldx #$10
  lda pently_vis_pitchhi+CH_NOISE
  bpl noise_is_hiss
    ldx #$28
  noise_is_hiss:
  stx vis_noise_color
  rts
    
draw_pitchvol_mark:
  lsr a
  cpx #CH_TRI
  bne :+
    lda #0
  :
  sta effective_vol

  lda pently_vis_pitchhi,x
  cpx #CH_NOISE
  bne st_not_noise
    stx semitone_xlo
    and #$0F
    tax
    lda noise_to_sprite_x,x
    ldx semitone_xlo
    jmp have_semitone_xhi
  st_not_noise:

  ; Triangle draws the lowest octave as hollow and the other
  ; octaves as solid, except offset an octave to the left because
  ; it sounds an octave below pulse.
  cpx #CH_TRI
  bne have_semitonenum
    sta semitonenum
    cmp #12  ; C=0 for hollow (lowest) octave, 1 for solid octaves
    lda #3 * 12 * 5
    bcs :+
      lda #3 * 12 * 4
      inc effective_vol
    :
    sta overtone_x
    lda semitonenum
    bcc :+
      sbc #12
    :
  have_semitonenum:
  sta semitonenum
  sta semitone_xhi
  lda pently_vis_pitchlo,x
  asl a
  rol semitone_xhi
  sta semitone_xlo
  clc
  adc pently_vis_pitchlo,x
  bpl :+
    inc semitone_xhi
  :
  lda semitonenum
  adc semitone_xhi
  clc
  adc #16
have_semitone_xhi:
  sta semitone_xhi

  lda #VIS_PITCH_Y  ; Y position
  sta OAM+0,y
  lda effective_vol
  ora vis_ch_vol_tiles,x
  sta OAM+1,y
  lda vis_ch_attribute,x
  sta OAM+2,y
  lda semitone_xhi
  sta OAM+3,y
  iny
  iny
  iny
  iny

  cpx #CH_TRI
  bne no_overtone_mark
  clc
  adc overtone_x
  bcs no_overtone_mark
    sta OAM+3,y
    lda #VIS_PITCH_Y
    sta OAM+0,y
    lda #$12  ; triangle overtone mark
    sta OAM+1,y
    lda #$02  ; triangle attribute
    sta OAM+2,y
    iny
    iny
    iny
    iny
  no_overtone_mark:
  jmp pitchvol_mark_done

draw_target_note_mark:
  ; First, is this a black key or a white key?
  lda pently_vis_note,x
  cmp #96
  bcc :+
    sbc #96
  :
  cmp #48
  bcc :+
    sbc #48
  :
  cmp #24
  bcc :+
    sbc #24
  :
  cmp #12
  bcc :+
    sbc #12
  :
  
  stx semitone_xlo
  tax
  lda whitekey_pos,x
  lsr a
  ldx semitone_xlo
  sta semitone_xhi
  
  lda vis_ch_whitekey_y,x
  bcc :+
    lda vis_ch_blackkey_y,x
  :
  sta OAM+0,y
  lda #TARGET_NOTE_DOT_TILE
  sta OAM+1,y
  lda vis_ch_attribute,x
  sta OAM+2,y
  
  ; Find the X position of the mark
  lda pently_vis_note,x
  cpx #CH_TRI
  bne target_not_trioctave
  cmp #12
  bcc target_not_trioctave
    sbc #12
  target_not_trioctave:
  sta semitonenum
  asl a
  clc
  adc semitonenum
  clc
  adc semitone_xhi
  sta OAM+3,y
  iny
  iny
  iny
  iny
  jmp target_note_mark_done
.endproc

.rodata

vis_ch_whitekey_y:
  ; 0. Y base for white keys
  ; 1. Y position for black keys
  ; 2. Tile base (for volume)
  ; 3. attribute
  .byte 170, 157, $00, 0
  .byte 172, 161, $00, 1
  .byte 174, 165, $10, 2
  .byte 255, 255, $08, 0
vis_ch_blackkey_y = vis_ch_whitekey_y + 1
vis_ch_vol_tiles = vis_ch_whitekey_y + 2
vis_ch_attribute = vis_ch_whitekey_y + 3

; Approximate X positions of noise pitches, assuming 93-step
; waveform.
noise_to_sprite_x:
  .byte 248, 212, 176, 140, 104, 83, 68, 57, 45, 33, 12
  ; The following are not to scale with the rest of the keyboard.
  ; If they were, they'd lie to the left of the keyboard's left edge.
  .byte 10, 8, 6, 3, 0

whitekey_pos:
  .byte 16*2+0
  .byte       16*2+1
  .byte 15*2+0
  .byte 17*2+0
  .byte       16*2+1
  .byte 16*2+0
  .byte       16*2+1
  .byte 15*2+0
  .byte 17*2+0
  .byte       16*2+1
  .byte 16*2+0
  .byte       16*2+1

.endif  ; PENTLY_USE_VIS

; Track muting ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
.code
.if PENTLY_USE_VARMIX
.proc vis_set_initial_mute
  lda #pently_resume_mute
  sta vis_mute
.endproc
.proc vis_set_mute
mutebit = $08
  lda vis_mute
  ldx #0
  loop:
    lsr a
    ror pently_mute_track,x
    inx
    inx
    inx
    inx
    cpx #LAST_TRACK+4
    bcc loop
  rts
.endproc

MUTE_X = 15
.proc vis_draw_mute
  lda #<~DIRTY_MUTE
  sta vis_dirty
  lda #muterow
  jsr clear_copybuf
  
  ldx #31
  :
    lda chmute_status_bar,x
    sta copybuf,x
    dex
    bpl :-

  ldx #15
  lda vis_mute
  chloop:
    lsr a
    bcc :+
      tay
      lda #$FE
      sta copybuf,x
      tya
    :
    cpx #(LAST_TRACK / 4) * 3 + MUTE_X
    inx
    inx
    inx
    bcc chloop
  rts
.endproc

.proc vis_handle_varmix_keys
MUTE_ALL = (1 << (LAST_TRACK / 4 + 1)) - 1
  lda vis_cursor_x
  beq notLeft
  lda new_keys
  and #KEY_LEFT
  beq notLeft
    dec vis_cursor_x
    jmp cancel_A_gesture
  notLeft:

  lda vis_cursor_x
  cmp #(LAST_TRACK / 4) + 1
  bcs notRight
  lda new_keys
  and #KEY_RIGHT
  beq notRight
    inc vis_cursor_x
  cancel_A_gesture:
    lda #0
    sta vis_A_gesture_time
  notA:
    rts
  notRight:

  ldx vis_cursor_x
  beq notA
  lda new_keys
  bpl notA
  lda vis_A_gesture_time
  bne is_double_click
    ; Single click: Toggle this channel
    lda #15
    sta vis_A_gesture_time
    lda one_shl_x-1,x
    eor vis_mute
    jmp have_vis_mute
    
is_double_click:
  ; Double-click with at least one other channel not muted puts this
  ; channel on solo
  lda vis_mute
  eor #MUTE_ALL  ; A: channels NOT muted
  and not_1_shl_x-1,x  ; A: channels other than this not muted
  beq unmute_all
    lda not_1_shl_x-1,x
    and #MUTE_ALL
    jmp have_vis_mute
  unmute_all:
    lda #0
  have_vis_mute:

  sta vis_mute
  lda #DIRTY_MUTE
  ora vis_dirty
  sta vis_dirty
  jmp vis_set_mute
.endproc

.proc vis_draw_mute_cursor
  lda vis_cursor_x
  beq no_cursor
    ldy oam_used
    tya
    clc
    adc #4
    sta oam_used
    
    lda #(muterow - 32) * 8 + 4
    sta OAM+0,y
    lda #ARROW_SPRITE_TILE
    sta OAM+1,y
    lda #1
    sta OAM+2,y
    lda vis_cursor_x
    asl a
    adc vis_cursor_x
    asl a
    asl a
    asl a
    adc #(MUTE_X - 3) * 8 + 4
    sta OAM+3,y
  no_cursor:
  rts
.endproc

.rodata
chmute_status_bar:
  .byte $02,$02,$08,$09,$0A,$0B,$0C,$0D,$0E,$0F,$02,$02,$02,$02,$02,$FF
  .byte $EA,$EB,$FF,$FA,$FB,$FF,$EC,$ED,$FF,$FC,$FD,$FF,$EE,$EF,$02,$02
one_shl_x:
  .repeat 8, I
    .byte 1 << I
  .endrepeat
not_1_shl_x:
  .repeat 8, I
    .byte $FF ^ (1 << I)
  .endrepeat

.endif
