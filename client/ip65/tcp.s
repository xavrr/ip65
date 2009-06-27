;TCP (transmission control protocol) functions

MAX_TCP_PACKETS_SENT=8     ;timeout after sending 8 messages will be about 7 seconds (1+2+3+4+5+6+7+8)/4

.include "../inc/common.i"
.ifndef NB65_API_VERSION_NUMBER
  .define EQU     =
  .include "../inc/nb65_constants.i"
.endif

.import ip65_error

.export tcp_init
.export tcp_process
.export tcp_listen
.export tcp_connect
.export tcp_callback
.export tcp_connect_ip
.export tcp_send_data_len
.export tcp_send

.import ip_calc_cksum
.import ip_send
.import ip_create_packet
.import ip_inp
.import ip_outp
.import ip65_process

.import check_for_abort_key
.import timer_read

.importzp acc32
.importzp op32
.importzp acc16

.import add_32_32
.import add_16_32
.import cmp_32_32
.import cmp_16_16



.importzp ip_cksum_ptr
.importzp ip_header_cksum
.importzp ip_src
.importzp ip_dest
.importzp ip_data
.importzp ip_proto
.importzp ip_proto_tcp
.importzp ip_id
.importzp ip_len

.import copymem
.importzp copy_src
.importzp copy_dest

.import cfg_ip


.segment "TCP_VARS"

tcp_cxn_state_closed      = 0 
tcp_cxn_state_listening   = 1  ;(waiting for an inbound SYN)
tcp_cxn_state_syn_sent    = 2  ;(waiting for an inbound SYN/ACK)
tcp_cxn_state_established = 3  ;  

; tcp packet offsets
tcp_inp		= ip_inp + ip_data  ;pointer to tcp packet inside inbound ethernet frame
tcp_outp	= ip_outp + ip_data ;pointer to tcp packet inside outbound ethernet frame
tcp_src_port	= 0 ;offset of source port field in tcp packet
tcp_dest_port	= 2 ;offset of destination port field in tcp packet
tcp_seq		= 4 ;offset of sequence number field in tcp packet
tcp_ack	= 8 ;offset of acknowledgement field in tcp packet
tcp_header_length	= 12 ;offset of header length field in tcp packet
tcp_flags_field	= 13 ;offset of flags field in tcp packet
tcp_window_size = 14 ; offset of window size field in tcp packet
tcp_checksum = 16 ; offset of checksum field in tcp packet
tcp_urgent_pointer = 18 ; offset of urgent pointer field in tcp packet
tcp_data=20   ;offset of data in tcp packet 

; virtual header
tcp_vh		= tcp_outp - 12
tcp_vh_src	= 0
tcp_vh_dest	= 4
tcp_vh_zero	= 8
tcp_vh_proto	= 9
tcp_vh_len	= 10

;
tcp_flag_FIN  =1
tcp_flag_SYN  =2
tcp_flag_RST  =4
tcp_flag_PSH  =8
tcp_flag_ACK  =16
tcp_flag_URG  =32




.segment "TCP_VARS"
tcp_state:  .res 1
tcp_local_port: .res 2
tcp_remote_port: .res 2
tcp_remote_ip: .res 4
tcp_sequence_number: .res 4
tcp_ack_number: .res 4
tcp_data_ptr: .res 2
tcp_data_len: .res 2
tcp_send_data_ptr: .res 2
tcp_send_data_len: .res 2
tcp_callback: .res 2
tcp_flags: .res 1

tcp_connect_sequence_number: .res 4
tcp_connect_expected_sequence_number: .res 4
tcp_connect_ack_number: .res 4

tcp_connect_last_ack: .res 4

tcp_connect_local_port: .res 2
tcp_connect_remote_port: .res 2
tcp_connect_ip: .res 4


tcp_timer:  .res 1
tcp_loop_count: .res 1
tcp_packet_sent_count: .res 1
.data
tcp_client_port: .word $0400  

.code

tcp_init:
  
  rts

;make outbound tcp connection
;inputs:
; tcp_connect_ip:  destination ip address (4 bytes)
; AX: destination port (2 bytes)
; tcp_callback: vector to call when data arrives on this connection
;outputs:
;   carry flag is set if an error occured, clear otherwise
tcp_connect:
  stax  tcp_connect_remote_port
  inc   tcp_client_port
  ldax  tcp_client_port
  stax  tcp_connect_local_port
  lda #tcp_cxn_state_syn_sent
  sta tcp_state
  lda #0  ;reset the "packet sent" counter
  sta tcp_packet_sent_count
  
  
@tcp_polling_loop:

  ;create a SYN packet
  lda #tcp_flag_SYN
  sta tcp_flags
  lda  #0
  sta  tcp_data_len
  sta  tcp_data_len+1
  
	ldx #3				; 
:	lda tcp_connect_ip,x
	sta tcp_remote_ip,x
	dex
	bpl :-
  ldax  tcp_connect_local_port
  stax  tcp_local_port  
  ldax  tcp_connect_remote_port
  stax  tcp_remote_port
  
  jsr tcp_send_packet
  lda tcp_packet_sent_count
  adc #1
  sta tcp_loop_count       ;we wait a bit longer between each resend  
@outer_delay_loop: 
  jsr timer_read
  stx tcp_timer            ;we only care about the high byte  
@inner_delay_loop:  
  jsr ip65_process
  jsr check_for_abort_key
  bcc @no_abort
  lda #NB65_ERROR_ABORTED_BY_USER
  sta ip65_error
  rts
@no_abort:  
  lda tcp_state  
  cmp #tcp_cxn_state_syn_sent
  bne @got_a_response

  jsr timer_read
  cpx tcp_timer            ;this will tick over after about 1/4 of a second
  beq @inner_delay_loop
  
  dec tcp_loop_count
  bne @outer_delay_loop  

@break_polling_loop:
  
	inc tcp_packet_sent_count
  lda tcp_packet_sent_count
  cmp #MAX_TCP_PACKETS_SENT-1
  bpl @too_many_messages_sent
  jmp @tcp_polling_loop

@too_many_messages_sent:
@failed:
  lda #tcp_cxn_state_closed
  sta tcp_state
  lda #NB65_ERROR_TIMEOUT_ON_RECEIVE
  sta ip65_error  
  sec             ;signal an error
  rts
@got_a_response:
  clc
  rts

;send tcp data
;inputs:
;   tcp connection should already be opened
;   tcp_send_data_len: length of data to send (exclusive of any headers)
;   AX: pointer to buffer containing data to be sent
;outputs:
;   carry flag is set if an error occured, clear otherwise
tcp_send:
	stax tcp_send_data_ptr
	lda tcp_state
  cmp #tcp_cxn_state_established
  beq @connection_established
  lda #NB65_ERROR_CONNECTION_CLOSED
  sta ip65_error
  sec
  rts

@connection_established:
  ldax #tcp_connect_expected_sequence_number
  stax acc32
  ldax tcp_send_data_len
  jsr add_16_32
  

@tcp_polling_loop:

  ;create a data packet
  lda #tcp_flag_ACK+tcp_flag_PSH
  sta tcp_flags
  ldax tcp_send_data_len
  stax tcp_data_len
  
  ldax tcp_send_data_ptr
  stax tcp_data_ptr
  
	ldx #3				; 
:	lda tcp_connect_ip,x
	sta tcp_remote_ip,x
	dex
	bpl :-
  ldax  tcp_connect_local_port
  stax  tcp_local_port  
  ldax  tcp_connect_remote_port
  stax  tcp_remote_port
  
  
  jsr tcp_send_packet
  
  lda tcp_packet_sent_count
  adc #1
  sta tcp_loop_count       ;we wait a bit longer between each resend  
@outer_delay_loop: 
  jsr timer_read
  stx tcp_timer            ;we only care about the high byte  
@inner_delay_loop:  
  jsr ip65_process
  jsr check_for_abort_key
  bcc @no_abort
  lda #NB65_ERROR_ABORTED_BY_USER
  sta ip65_error
  rts
@no_abort:  
  ldax #tcp_connect_last_ack
  stax acc32
  ldax #tcp_connect_expected_sequence_number
  jsr cmp_32_32
  beq @got_ack

  jsr timer_read
  cpx tcp_timer            ;this will tick over after about 1/4 of a second
  beq @inner_delay_loop
  
  dec tcp_loop_count
  bne @outer_delay_loop  

@break_polling_loop:
  
	inc tcp_packet_sent_count
  lda tcp_packet_sent_count
  cmp #MAX_TCP_PACKETS_SENT-1
  bpl @too_many_messages_sent
  jmp @tcp_polling_loop

@too_many_messages_sent:
@failed:
  lda #tcp_cxn_state_closed
  sta tcp_state
  lda #NB65_ERROR_TIMEOUT_ON_RECEIVE
  sta ip65_error  
  sec             ;signal an error
  rts
@got_ack:
  clc
  rts


;send a single tcp packet 
;inputs:
; tcp_remote_ip: IP address of destination server
; tcp_remote_port: destination tcp port 
; tcp_local_port: source tcp port
; tcp_flags: 6 bit flags
; tcp_data_ptr: pointer to data to include in this packet
; tcp_data_len: length of data pointed at by tcp_data_ptr
;outputs:
;   carry flag is set if an error occured, clear otherwise
tcp_send_packet:
  ldax  tcp_data_ptr
  stax copy_src			; copy data to output buffer
	ldax #tcp_outp + tcp_data
	stax copy_dest
	ldax tcp_data_len
	jsr copymem

	ldx #3				; copy virtual header addresses
:	lda tcp_remote_ip,x
	sta tcp_vh + tcp_vh_dest,x	; set virtual header destination
	lda cfg_ip,x
	sta tcp_vh + tcp_vh_src,x	; set virtual header source
	dex
	bpl :-

	lda tcp_local_port		; copy source port
	sta tcp_outp + tcp_src_port + 1
	lda tcp_local_port + 1
	sta tcp_outp + tcp_src_port

	lda tcp_remote_port		; copy destination port
	sta tcp_outp + tcp_dest_port + 1
	lda tcp_remote_port + 1
	sta tcp_outp + tcp_dest_port

  ldx #3				; copy sequence and ack (if ACK flag set) numbers (in reverse order)
  ldy #0
:	lda tcp_sequence_number,x
	sta tcp_outp + tcp_seq,y
  lda #tcp_flag_ACK
  bit tcp_flags
  bne @ack_set 
  lda #0
  beq @sta_ack
  @ack_set:
	lda tcp_ack_number,x
  @sta_ack:
	sta tcp_outp + tcp_ack,y
  iny
	dex
	bpl :-

  lda #$50    ;4 bit header length in 32bit words + 4 bits of zero
  sta tcp_outp+tcp_header_length
  lda tcp_flags
  sta tcp_outp+tcp_flags_field
  
	lda #ip_proto_tcp
	sta tcp_vh + tcp_vh_proto

  ldax  #$0010  ;$1000 in network byte order
  stax  tcp_outp+tcp_window_size

	lda #0				; clear checksum
	sta tcp_outp + tcp_checksum
	sta tcp_outp + tcp_checksum + 1
	sta tcp_vh + tcp_vh_zero	; clear virtual header zero byte

	ldax #tcp_vh			; checksum pointer to virtual header
	stax ip_cksum_ptr

	lda tcp_data_len		; copy length + 20
	clc
	adc #20
	sta tcp_vh + tcp_vh_len + 1	; lsb for virtual header
	tay
	lda tcp_data_len + 1
	adc #0
	sta tcp_vh + tcp_vh_len		; msb for virtual header

	tax				; length to A/X
	tya

	clc				; add 12 bytes for virtual header
	adc #12
	bcc :+
	inx
:
	jsr ip_calc_cksum		; calculate checksum
	stax tcp_outp + tcp_checksum

	ldx #3				; copy addresses
:	lda tcp_remote_ip,x
	sta ip_outp + ip_dest,x		; set ip destination address
	dex
	bpl :-

	jsr ip_create_packet		; create ip packet template

	lda tcp_data_len 	; ip len = tcp data length +20 byte ip header + 20 byte tcp header
	ldx tcp_data_len +1
	clc
	adc #40 
	bcc :+
	inx
:	sta ip_outp + ip_len + 1	; set length
	stx ip_outp + ip_len

	ldax #$1234    			; set ID
	stax ip_outp + ip_id

	lda #ip_proto_tcp		; set protocol
	sta ip_outp + ip_proto

	jmp ip_send			; send packet, sec on error


;listen on the tcp port specified
; tcp_callback: vector to call when data arrives on specified port
; AX: set to tcp port to listen on
tcp_listen:
  rts

check_current_connection:
;see if the ip packet we just got is for a valid (non-closed) tcp connection
;inputs:
; eth_inp: should contain an ethernet frame encapsulating an inbound tcp packet
;outputs:
; carry flag clear if inbound tcp packet part of existing connection
  ldax  #ip_inp+ip_src
  stax  acc32
  ldax  #tcp_connect_ip
  stax  op32
  jsr   cmp_32_32
  beq @remote_ip_matches
  
  sec
  rts
@remote_ip_matches:
  ldax  tcp_inp+tcp_src_port
  stax  acc16
  lda   tcp_connect_remote_port+1 ;this value in reverse byte order to how it is presented in the TCP header
  ldx   tcp_connect_remote_port 
  jsr   cmp_16_16
  beq @remote_port_matches
  sec
  rts
@remote_port_matches:
  ldax  tcp_inp+tcp_dest_port
  stax  acc16
  lda   tcp_connect_local_port+1 ;this value in reverse byte order to how it is presented in the TCP header
  ldx   tcp_connect_local_port 
  jsr   cmp_16_16
  beq   @local_port_matches
  sec
  rts
@local_port_matches:
  clc
  rts
  
tcp_process:
;process incoming tcp packet
;inputs:
; eth_inp: should contain an ethernet frame encapsulating an inbound tcp packet
;outputs:
; none but if connection was found, an outbound message may be created, overwriting eth_outp
; also tcp_state and other tcp variables may be modified

  lda #tcp_flag_RST
  bit tcp_inp+tcp_flags_field
  beq @not_reset
  jsr check_current_connection
  bcs @not_current_connection_on_rst
  ;connection has been reset so mark it as closed  
  lda #tcp_cxn_state_closed
  sta tcp_state
  lda #NB65_ERROR_CONNECTION_RESET_BY_PEER
  sta ip65_error
@not_current_connection_on_rst:
  ;if we get a reset for a closed or nonexistent connection, then ignore it
  rts
@not_reset:
  lda tcp_inp+tcp_flags_field
  cmp #tcp_flag_SYN+tcp_flag_ACK
  bne @not_syn_ack
  jsr check_current_connection
  bcs @not_current_connection_on_syn_ack
  lda tcp_state
  cmp #tcp_cxn_state_syn_sent
  bne @not_expecting_syn_ack
  ;this IS the syn/ack we are waiting for :-)
  ldx #3				; copy sequence number to ack (in reverse order)
  ldy #0
:	lda tcp_inp + tcp_seq,y
	sta tcp_connect_ack_number,x
  iny
	dex
	bpl :-

  ldax #tcp_connect_ack_number
  stax acc32
  ldax  #$0001  ;
  jsr add_16_32 ;increment the ACK counter by 1, for the SYN we just received


  lda #tcp_cxn_state_established
  sta tcp_state
@not_expecting_syn_ack: 
  jmp @send_ack
  
@not_current_connection_on_syn_ack:
@not_syn_ack:  

  lda tcp_inp+tcp_flags_field
  cmp #tcp_flag_ACK
  bne @not_ack
  
  rts
@not_ack:  
  lda tcp_inp+tcp_flags_field
  cmp #tcp_flag_SYN
  bne @not_syn
;for the moment, inbound connections not accepted. so send a RST
;create a RST packet
  ldx #3				; copy sequence number to ack (in reverse order)
  ldy #0
:	lda tcp_inp + tcp_seq,y
	sta tcp_ack_number,x
  iny
	dex
	bpl :-

  ldax #tcp_ack_number 
  stax acc32
  ldax  #$0001  ;
  jsr add_16_32 ;increment the ACK counter by 1, for the SYN we just received
  
@send_rst:
  
  lda #tcp_flag_RST+tcp_flag_ACK
  sta tcp_flags
  ldax  #0
  stax  tcp_data_len
	ldx #3				; 
:	lda ip_inp+ip_src,x
	sta tcp_remote_ip,x
	dex
	bpl :-
  
  ;copy src/dest ports in inverted byte order
  lda tcp_inp+tcp_src_port
	sta tcp_remote_port+1
  lda tcp_inp+tcp_src_port+1
	sta tcp_remote_port
  
  lda tcp_inp+tcp_dest_port
	sta tcp_local_port+1
  lda tcp_inp+tcp_dest_port+1
	sta tcp_local_port
  
  jsr tcp_send_packet
  rts

@not_syn:
  rts
@send_ack:
;create an ACK packet
  lda #tcp_flag_ACK
  sta tcp_flags
  ldax  #0
  stax  tcp_data_len
	ldx #3				; 
:	lda tcp_connect_ip,x
	sta tcp_remote_ip,x
  lda tcp_connect_ack_number,x
  sta tcp_ack_number,x
  lda tcp_connect_sequence_number,x
  sta tcp_sequence_number,x
	dex
	bpl :-
  ldax  tcp_connect_local_port
  stax  tcp_local_port  
  ldax  tcp_connect_remote_port
  stax  tcp_remote_port
  
  
  jsr tcp_send_packet
  rts