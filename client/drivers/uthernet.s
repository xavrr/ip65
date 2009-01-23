; uthernet driver
; for the moment, always assume slot 3


	.export cs_init

	.export cs_packet_page
	.export cs_packet_data
	.export cs_rxtx_data
	.export cs_tx_cmd
	.export cs_tx_len
  .export cs_driver_name
  
cs_rxtx_data	= $c0b0
cs_tx_cmd	= $c0b4
cs_tx_len	= $c0b6
cs_packet_page	= $c0ba
cs_packet_data	= $c0bc
 

	.code

cs_init:
	
	rts

.rodata
cs_driver_name:
	.byte "UTHERNET",0