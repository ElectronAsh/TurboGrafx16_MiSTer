module pcecd_top(
	input            RESET,
	input            CLOCK,
	
	// cpu register interface
	input            CS_N,
	input            RD_N,
	input            WR_N,
	input  [20:0]    ADDR,
	
	input      [7:0] DIN,
	output reg [7:0] DOUT,
	
	output           IRQ2_ASSERT,
	
	input img_mounted,
	input img_readonly,
	input [63:0] img_size,
	
	output reg [31:0] sd_lba,
	output reg    sd_rd,       // only single sd_rd can be active at any given time
	//output reg    sd_wr,       // only single sd_wr can be active at any given time
	input         sd_ack,

	//input   [7:0] sd_buff_addr,	// 256 WORDS! (NOT USING THIS NOW! Checking sd_ack to know when all 2048 bytes have trasnferred from the HPS).
	
	input  [15:0] sd_buff_din,	// 16-bit wide. Because the HPS uses that for ROM loading and save game stuff.
	input         sd_buff_wr,
	
	output reg  [15:0]  sd_req_type,
	
	output [15:0] cd_audio_l,
	output [15:0] cd_audio_r,
	
	output reg bram_locked
);

// CD Data buffer...
reg [16:0] data_buffer_pos;	// 128KB for both of these, but the BRAM can only fit 32KB for the buffer itself atm.
reg [16:0] data_buffer_size;	// (data will wrap, corrupt, but it might help us boot games further during debugging.)

wire [15:0] data_buffer_addr = data_buffer_pos;
wire [7:0] data_buffer_din = (!data_buffer_addr[0]) ? sd_buff_din[7:0] : sd_buff_din[15:8];

wire data_buffer_wr = (sd_buff_wr && data_buffer_wr_ena) | data_buffer_wr_force;
reg data_buffer_wr_ena;
reg data_buffer_wr_force;

wire [7:0] data_buffer_dout;

cd_data_buffer	cd_data_buffer_inst (
	.clock ( CLOCK ),

	.address ( data_buffer_addr ),	// 32KB.
	.data ( data_buffer_din ),
	.wren ( data_buffer_wr ),
	
	.q ( data_buffer_dout )
);



// CD Audio FIFO...
reg cdda_play = 0;
reg left_chan = 0;

reg [15:0] temp_l;

reg [15:0] samp_l;
reg [15:0] samp_r;

reg [9:0] audio_clk_div = 0;

reg sd_ack_1;

always @(posedge CLOCK) begin
	sd_ack_1 <= sd_ack;
	
	// Set left channel on rising edge of sd_ack.
	// This should override the above assign!
	if (sd_ack && !sd_ack_1) left_chan <= 1'b1;

	if (audio_clk_div>0) audio_clk_div <= audio_clk_div - 1;	
	else begin
		left_chan <= !left_chan;
		audio_clk_div <= 486;
		if (left_chan) temp_l <= audio_fifo_dout;
		else begin
			// Make sure both the left and right samples get output at the same time.
			// Just a minor thing, but Ace will notice. :p
			samp_l <= temp_l;
			samp_r <= audio_fifo_dout;
		end
	end
end

wire audio_clk_en = (audio_clk_div==0);


//wire audio_fifo_reset = RESET | !cdda_play;
wire audio_fifo_reset = RESET;

wire audio_fifo_full;
wire audio_fifo_wr = !audio_fifo_full && sd_ack && sd_buff_wr && cdda_play;

wire [11:0] audio_fifo_usedw;

wire audio_fifo_empty;
wire audio_fifo_rd = !audio_fifo_empty && audio_clk_en && cdda_play;

wire [15:0] audio_fifo_dout;

cd_audio_fifo	cd_audio_fifo_inst (
	.aclr ( audio_fifo_reset ),

	.wrclk ( CLOCK ),
	.wrreq ( audio_fifo_wr ),
	.wrfull ( audio_fifo_full ),
	.wrusedw ( audio_fifo_usedw ),
	.data ( sd_buff_din ),
	
	.rdclk ( CLOCK ),
	.rdreq ( audio_fifo_rd ),
	.rdempty ( audio_fifo_empty ),
	.q ( audio_fifo_dout )
);

// The CD Audio FIFO should be getting cleared now when cdda_play==0.
//
// But this mux is needed anyway, to prevent possible DC offset on the output.
// (the state of the FIFO output can be undefined when aclr is High.)
//
assign cd_audio_l = (cdda_play) ? samp_l : 16'h0000;
assign cd_audio_r = (cdda_play) ? samp_r : 16'h0000;



//TODO: add hps "channel" to read/write from save ram

reg [7:0] cmd_buff [0:9]/*synthesis noprune*/;
reg [3:0] cmd_buff_pos = 0;


reg [1:0] stat_counter;	// Kludge.


// ADPCM stuff...
reg adpcm_reset;

reg adpcm_playing;
reg adpcm_reading;	// "ADPCM RAM to something" flag. Direct reads??
reg adpcm_writing;	// "CD to ADPCM RAM, DMA running" flag. Probably.
wire [7:0] adpcm_status = {adpcm_reading, 3'b000, adpcm_playing, adpcm_writing, 1'b0, !adpcm_playing};	// 0x180C.

reg adpcm_repeat;

reg [15:0] adpcm_read_addr;
reg [15:0] adpcm_write_addr;
reg [15:0] adpcm_length;

reg [15:0] adpcm_start_addr;
reg [15:0] adpcm_half_addr;
reg [15:0] adpcm_end_addr;

wire ADPCM_HALF_FLAG = adpcm_read_addr == (adpcm_start_addr + (adpcm_length >> 1));
wire ADPCM_FULL_FLAG = adpcm_read_addr == adpcm_end_addr;


//wire adpcm_address_control = {adpcm_reset, 1'b0, adpcm_repeat, 
wire [7:0] adpcm_address_control = {adpcm_reset, 1'b0, 1'b0, 5'b00000};


// Crusty BCD to DEC conversion, but it works.
wire [7:0] m_dec = (cmd_buff[2][7:4]*10) + cmd_buff[2][3:0];
wire [7:0] s_dec = (cmd_buff[3][7:4]*10) + cmd_buff[3][3:0];
wire [7:0] f_dec = (cmd_buff[4][7:4]*10) + cmd_buff[4][3:0];


//TODO: check if registers are needed (things are probably bound to some logic with the cd drive), placeholders for now
//wire [7:0] cdc_status = {SCSI_BSY, SCSI_REQ, SCSI_MSG, SCSI_CD, SCSI_IO, SCSI_BIT2, SCSI_BIT1, SCSI_BIT0};             // $1800 - CDC status
wire [7:0] cdc_status = {SCSI_BSY, SCSI_REQ, SCSI_MSG, SCSI_CD, SCSI_IO, 3'b001};             // $1800 - CDC status

always_comb begin
	case (ADDR[7:0])
		// Super System Card registers $18Cx range
		8'hC1: DOUT <= 8'haa;
		8'hC2: DOUT <= 8'h55;
		8'hC3: DOUT <= 8'h00;
		8'hC5: DOUT <= 8'haa;	// Japan System 3 card / BIOS!
		8'hC6: DOUT <= 8'h55;	//
		8'hC7: DOUT <= 8'h03;
		
		//8'hC1: DOUT <= 8'haa;
		//8'hC2: DOUT <= 8'h55;
		//8'hC3: DOUT <= 8'h00;
		//8'hC5: DOUT <= 8'h55;	// US System 3 card / BIOS!
		//8'hC6: DOUT <= 8'haa;	//
		//8'hC7: DOUT <= 8'h03;

		8'h00: DOUT <= cdc_status;
		8'h01: DOUT <= cdc_databus;
		8'h02: DOUT <= int_mask;		// Or INT_MASK.
		8'h03: DOUT <= {bram_locked, READY_FLAG, DONE_FLAG, bram_lock[4], ADPCM_FULL_FLAG, ADPCM_HALF_FLAG, left_chan, bram_lock[0]};
		8'h04: DOUT <= cd_reset;
		8'h05: DOUT <= convert_pcm;
		8'h06: DOUT <= pcm_data;
		8'h07: DOUT <= bram_unlock;
		
		8'h08: DOUT <= adpcm_address_low;		// CD Sector data actually gets read from this reg!
															// (with a delay as well, because data_buffer_dout gets put into adpcm_address_low AFTER reg 0x08 gets read!)
		//8'h08: DOUT <= data_buffer_dout;
		
		8'h09: DOUT <= adpcm_address_high;
		8'h0A: DOUT <= adpcm_ram_data;
		8'h0B: DOUT <= adpcm_dma_control;
		8'h0C: DOUT <= adpcm_status;
		8'h0D: DOUT <= adpcm_address_control;
		8'h0E: DOUT <= adpcm_playback_rate;
		8'h0F: DOUT <= adpcm_fade_timer;
		default: DOUT <= 8'hFF;
	endcase
end


// CD Interface Register 0x00 - CDC status
	// x--- ---- busy signal
	// -x-- ---- request signal
	// --x- ---- msg bit
	// ---x ---- cd signal
	// ---- x--- i/o signal

// Signals under our (the "target") control.
/*
wire SCSI_BSY = cdc_status[7];
wire SCSI_REQ = cdc_status[6];
wire SCSI_MSG = cdc_status[5];
wire SCSI_CD = cdc_status[4];
wire SCSI_IO = cdc_status[3];
*/

// Signals under the control of the initiator (not us!)
/*
wire RST_signal = SCSI_RST;
wire ACK_signal = SCSI_ACK;
wire SEL_signal = SCSI_SEL;
*/

localparam BUSY_BIT = 8'h80;
localparam REQ_BIT  = 8'h40;
localparam MSG_BIT  = 8'h20;
localparam CD_BIT   = 8'h10;
localparam IO_BIT   = 8'h08;

localparam PHASE_BUS_FREE    = 8'b00000001;
localparam PHASE_COMMAND     = 8'b00000010;
localparam PHASE_DATA_IN     = 8'b00000100;
localparam PHASE_DATA_OUT    = 8'b00001000;
localparam PHASE_STATUS      = 8'b00010000;
localparam PHASE_MESSAGE_IN  = 8'b00100000;
localparam PHASE_MESSAGE_OUT = 8'b01000000;

reg [7:0] cdc_databus;            // $1801 - CDC command / status / data //TODO: this will probably change to a wire connected to the pcecd_drive module
reg [7:0] int_mask;          		 // $1802 - ADPCM / CD control
reg [7:0] bram_lock;              // $1803 - BRAM lock / CD status
reg [7:0] cd_reset;               // $1804 - CD reset
reg [7:0] convert_pcm;            // $1805 - Convert PCM data / PCM data
reg [7:0] pcm_data;               // $1806 - PCM data
reg [7:0] bram_unlock;            // $1807 - BRAM unlock / CD status
reg [7:0] adpcm_address_low;      // $1808 - ADPCM address (LSB) / CD data
reg [7:0] adpcm_address_high;     // $1809 - ADPCM address (MSB)
reg [7:0] adpcm_ram_data;         // $180A - ADPCM RAM data port
reg [7:0] adpcm_dma_control;      // $180B - ADPCM DMA control
//reg [7:0] adpcm_status;           // $180C - ADPCM status
//reg [7:0] adpcm_address_control;  // $180D - ADPCM address control
reg [7:0] adpcm_playback_rate;    // $180E - ADPCM playback rate
reg [7:0] adpcm_fade_timer;       // $180F - ADPCM and CD audio fade timer

//reg bram_locked;
reg motor_on;

// Phase handling
reg [7:0] phase;
reg [7:0] old_phase;

// Status sending
reg cd_status_sent = 0;
reg cd_message_sent = 0;


reg [2:0] read_state;

reg [2:0] dir_state;

reg [1:0] cdda_state;

reg [1:0] cdda_req_type = 0;
reg [7:0] min;
reg [7:0] sec;
reg [7:0] fra;

// Ack handling
//reg clear_ack = 0;

reg READY_FLAG = 0;
reg DONE_FLAG = 0;

// SCSI Command Handling
reg SCSI_RST = 1;
reg SCSI_ACK = 0;
reg SCSI_SEL = 0;


reg SCSI_BSY;
reg SCSI_REQ;
reg SCSI_MSG;
reg SCSI_CD;
reg SCSI_IO;
reg SCSI_BIT2;
reg SCSI_BIT1;
reg SCSI_BIT0;
// ^ Bits [2:0] are probably drive SCSI ID bits.
// The PCE often writes 0x81 (b10000001) to both CDC_STAT and CDC_CMD.
//
// I think it's quite possible that whenever CDC_STAT gets written, that IS the whole SCSI ID
// (of both the PCE (7) and CD drive (0).
//
// (from Io_cd13.PDF)...
//
// "Selection: In this state, the initiator selects a target unit and gets the target to carry out a given function,
// such as reading or writing data. The initator outputs the OR-value of its SCSI-ID and the target's SCSI-ID onto the DATA bus
// (for example, if the initiator is 2 (0000 0100) and the target is 5 (0010 0000) then the OR-ed ID on the bus wil be 0010 0100.)
// The target then determines that it's ID is on the data bus, and sets the BUSY line active."
// 
//
// In short, we can ignore that, and assume that one CD drive is on the bus.
// It looks like the PCE maybe writes the the value 0x81 to both CDC_STAT and CDC_CMD as a kind of double-check.
// And the CD drive ignores that "Command" anyway, since it's not in SELection at that point.
//
// Which is why MAME, bizhawk, and other emulators don't need to have the 0x81 in command parsing table.
// Those emulators just set the SCSI_SEL bit whenever CDC_STAT gets written to (and they also clear the CD transfer IRQ flags).
//
// ElectronAsh.

reg [3:0] packet_bytecount;	// Should probably be a wire [3:0]?

always_ff begin
	case (cmd_buff[0])
		8'h00: packet_bytecount <= 6;		// Command = 0x00 TEST_UNIT_READY (6)
		8'h08: packet_bytecount <= 6;		// Command = 0x08 READ (6)
		8'hD8: packet_bytecount <= 10;	// Command = 0xD8 NEC_SET_AUDIO_START_POS (10)
		8'hD9: packet_bytecount <= 10;	// Command = 0xD9 NEC_SET_AUDIO_STOP_POS (10)
		8'hDA: packet_bytecount <= 10;	// Command = 0xDA NEC_PAUSE (10)
		8'hDD: packet_bytecount <= 10;	// Command = 0xDD NEC_GET_SUBQ (10)
		8'hDE: packet_bytecount <= 10;	// Command = 0xDE NEC_GET_DIR_INFO (10)
		8'hFF: packet_bytecount <= 1;		// Command = 0xFF END_OF_LIST (1)
		8'h81: packet_bytecount <= 1;		// Command = 0x81 RESET CMD BUFFER (1), maybe?
	endcase
end


reg [3:0] status_state;
reg [3:0] message_state;
reg [3:0] command_state;
reg [3:0] data_state;

reg old_ack;

reg [31:0] sd_sector_count;


// READ command parsing stuff... ;)
reg [20:0] frame/*synthesis noprune*/;
reg [7:0] frame_count/*synthesis noprune*/;

reg [7:0] byte_count/*synthesis noprune*/;	// Byte count for TOC stuff / misc.


// For CD Audio playback...
reg [1:0] cdda_status;
reg [7:0] cdda_play_mode;
reg [20:0] start_frame;
reg [20:0] current_frame;
reg [20:0] end_frame;
reg [2:0] cdda_mode;
reg cdda_repeat;
reg end_mark;


localparam IRQ_TRANSFER_READY     = 8'h40;
localparam IRQ_TRANSFER_DONE      = 8'h20;
localparam IRQ_BRAM               = 8'h10; // ???
localparam IRQ_SAMPLE_FULL_PLAY   = 8'h08;
localparam IRQ_SAMPLE_HALF_PLAY   = 8'h04;

// Assert IRQ if any of the bits are high, and unmasked.
assign IRQ2_ASSERT = (int_mask & bram_lock & 8'h7C);


// CDC_STAT <= 8'h00;			// 0x1800. [7]=BUSY. [6]=REQ. [5]=MSG. [4]=CD. [3]=IO. [2:0]=Seems to be the SCSI ID of the drive, where b001==SCSI ID 0.

// CDC_CMD <= 8'h00;				// 0x1801. Seems to be write-only. Doesn't seem to get handled by MAME pce_cd_device::intf_r?

// INT_MASK <= 8'h00;			// 0x1802. [7]=ACK_FLAG!    [6]=READY_MASK. [5]=DONE_MASK. [4]=BRAM_MASK. [3]=ADPCM_FULL_MASK. [2]=ADPCM_HALF_MASK. [1]=CDDA_LR_MASK.
// BRAM_LOCK <= 8'h00;			// 0x1803. [7]=BRAM_LOCKED. [6]=READY_FLAG. [5]=DONE_FLAG. [4]=BRAM_FLAG. [3]=ADPCM_FULL_FLAG. [2]=ADPCM_HALF_FLAG. [1]=CDDA_LR_FLAG.

// CD_RESET <= 8'h00;			// 0x1804. [1]=Reset the CD drive. (some docs say bit "2" is reset, but it's bit 1, according to MAME (value & 2)! ElectronAsh.
// CONV_PCM <= 8'h00;			// 0x1805. CDDA PCM sample value LSB byte.
// PCM_DATA <= 8'h00;			// 0x1806. CDDA PCM sample value MSB byte.
// BRAM_UNLOCK <= 8'h00;		// 0x1807. [7]=Unlocks BRAM when SET.
// ADPCM_A_LO <= 8'h00;			// 0x1808. ADPCM Addr LSB. CD DATA gets read by the PCE from this address!!
// ADPCM_A_HI <= 8'h00;			// 0x1809. ADPCM Addr MSB.
// ADPCM_RAM_DATA <= 8'h00;	// 0x180A. ADPCM Data port.
// ADPCM_DMA_CONT <= 8'h00;	// 0x180B. 
// ADPCM_STAT <= 8'h00;			// 0x180C. [7]=ADPCM is reading data. [3]=ADPCM Playing. [2]=Pending ADPCM write. [0]=ADPCM Stopped.
// ADPCM_ADDR_CONT <= 8'h00;	// 0x180D. [7]=ADPCM Reset. [6]=ADPCM Play. [5]=ADPCM Repeat. [4]=ADPCM Set Length. [3]=ADPCM Read Addr. [1:0]=ADPCM Write Addr.
// ADPCM_RATE <= 8'h00;			// 0x180E. ADPCM playback rate.
// ADPCM_FADE <= 8'h00;			// 0x180F. ADPCM Fade in / out register.

reg RD_N_1;
reg RD_N_2;

reg WR_N_1;
reg WR_N_2;

(*keep*)wire CDR_RD_N_FALLING = (!RD_N_1 && RD_N_2);
(*keep*)wire CDR_RD_N_RISING = (RD_N_1 && !RD_N_2);

(*keep*)wire CDR_WR_N_FALLING = (!WR_N_1 && WR_N_2);
(*keep*)wire CDR_WR_N_RISING = (WR_N_1 && !WR_N_2);

//TODO: a pcecd_drive module should be probably added
always_ff @(posedge CLOCK) begin
	if (RESET) begin
		// Start off with the "drive" in reset.
		SCSI_RST <= 1;	// The PCE (core) should deassert this on start-up of the SS3 CD BIOS.
		
		old_phase <= ~phase;	// ElectronAsh. (force a phase update after reset).
	end else begin
		old_phase <= phase;
		
		RD_N_1 <= RD_N;
		RD_N_2 <= RD_N_1;

		WR_N_1 <= WR_N;
		WR_N_2 <= WR_N_1;
		
		//sd_rd <= 1'b0;
		//sd_wr <= 1'b0;
		
		old_ack <= sd_ack;

		if (phase==PHASE_DATA_IN && !CS_N & CDR_RD_N_RISING && ADDR[7:0]==8'h08) begin
			if (data_buffer_pos < data_buffer_size-1) begin
				data_buffer_pos <= data_buffer_pos + 1;
			end
			else begin
				data_buffer_pos <= 0;
				READY_FLAG <=1'b0;	// Clear IRQ_TRANSFER_READY flag! (MAME does this. Sort of).
				DONE_FLAG <= 1'b1;	// Set IRQ_TRANSFER_DONE flag!
				phase <= PHASE_STATUS;
			end
		end
			
		begin
			if (!CS_N & CDR_RD_N_FALLING) begin
				case (ADDR[7:0])
					// Super System Card registers $18Cx range
					//8'hC1: DOUT <= 8'haa;
					//8'hC2: DOUT <= 8'h55;
					//8'hC3: DOUT <= 8'h00;
					//8'hC5: DOUT <= 8'haa;
					//8'hC6: DOUT <= 8'h55;
					//8'hC7: DOUT <= 8'h03;

					8'h00: begin	// 0x1800 CDC_STAT
						//DOUT <= cdc_status;
						$display("Read 0x0. dout = 0x%h", cdc_status);
					end
					8'h01: begin	// 0x1801 CDC_CMD
						//DOUT <= cdc_databus;
					end
					8'h02: begin	// 0x1802 INT_MASK
						$display("Read 0x2. dout = 0x%h", int_mask);
						//DOUT <= int_mask;
					end
					8'h03: begin	// 0x1803 BRAM_LOCK
						$display("Read 0x3. dout = 0x%h", bram_lock);
						$display("bram_locked = 0x%h", 1'b1);
						//DOUT <= bram_lock;
						bram_locked <= 1;					// A read from this reg LOCKs BRAM access!
						//bram_lock <= (bram_lock & 8'h6E) | bram_locked<<7 | motor_on<<4 | !bram_lock[1]<<1;
						//bram_lock[7] <= bram_locked;	// [7]=BRAM Locked.
						//READY_FLAG <=bram_lock[6];	// [6]=READY_INT_SIG.
						//DONE_FLAG <= bram_lock[5];	// [5]=DONE_INT_SIG.
						//DONE_FLAG <= 1'b1;	// [5]=DONE_INT_SIG. TESTING !!!!! PCE needs to see this set after a CDDA Play command (and probably others). ElectronAsh.
						//bram_lock[4] <= motor_on;		// [4]=BRAM_INT_SIG.
						//bram_lock[3] <= bram_lock[3];	// [3]=ADPCM_FULL_INT_SIG.
						//bram_lock[2] <= bram_lock[2];	// [2]=ADPCM_HALF_INT_SIG.
						//bram_lock[1] <= !bram_lock[1];	// [1]=CDDA L/R speaker select. (hacky toggling thing from MAME).
					end
					8'h04: begin	// 0x1804 CD_RESET
						$display("Read 0x4. dout = 0x%h", cd_reset);
						//DOUT <= cd_reset;
					end
					8'h05: begin	// 0x1805 CONVERT PCM DATA / PCM DATA
						//DOUT <= convert_pcm;
						convert_pcm <= ~convert_pcm;	// Ugly hack. Make the PCE think some CD audio is playing / toggling the levels.
					end
					8'h06: begin	// 0x1806 PCM DATA
						//DOUT <= pcm_data;
						pcm_data <= ~pcm_data;	// Ugly hack. Make the PCE think some CD audio is playing / toggling the levels.
					end
					8'h07: begin	// 0x1807 BRAM_UNLOCK
						//DOUT <= (bram_locked) ? 8'h7F : 8'h8F;
						//DOUT <= bram_unlock;
						//bram_unlock <= (bram_locked) ? (bram_lock & 8'h7F) : (bram_lock | 8'h80);
						bram_unlock[7]   <= !bram_locked;	// MAME clears the MSB of bram_unlock if bram_locked is SET?? Check.
																		// Bits [6:0] of bram_unlock should stay the same?
					end
					8'h08: begin	// 0x1808
						//DOUT <= adpcm_address_low;
						adpcm_address_low <= data_buffer_dout;		// Looks like it does actually need this delay, so it sees the next CD sector byte on the NEXT read of 0x08!
					end
					8'h09: begin	// 0x1809
						//DOUT <= adpcm_address_high;
					end
					8'h0A: begin	// 0x180A
						//DOUT <= adpcm_ram_data;
					end
					8'h0B: begin	// 0x180B
						//DOUT <= adpcm_dma_control;
					end
					8'h0C: begin	// 0x180C
						//DOUT <= adpcm_status;
					end
					8'h0D: begin	// 0x180D
						//DOUT <= adpcm_address_control;
					end
					8'h0E: begin	// 0x180E
						//DOUT <= adpcm_playback_rate;
					end
					8'h0F: begin	// 0x180F
						//DOUT <= adpcm_fade_timer;
					end
					default:; //DOUT <= 8'hFF;
				endcase
			end
			
			if (!CS_N & CDR_WR_N_FALLING) begin
				case (ADDR[7:0])
					8'h00: begin	// 0x1800 CDC_STAT
						//cdc_status <= DIN;
						//SCSI_BSY  <= DIN[7];	// Bits 7:3 of CDC_STAT seem to be READ ONLY! ElectronAsh.
						//SCSI_REQ  <= DIN[6];
						//SCSI_MSG  <= DIN[5];
						//SCSI_CD   <= DIN[4];
						//SCSI_IO   <= DIN[3];

						// Clear IRQ bits [7:5].
						//bram_lock[7] <= 1'b0;	//	 Clear [7]=bram_locked, but not?
						READY_FLAG <=1'b0;	//	 Clear [6]=READY_INT_SIG.
						DONE_FLAG <= 1'b0;	//	 Clear [5]=DONE_INT_SIG.
						
						// The MAME code normally assumes there is only ONE drive on the bus.
						// So no real point checking to see if the ID matches before setting SCSI_SEL.
						// But we could add a check for seeing 0x81 written to CDC_STAT (or CDC_CMD?) later on.
						
						if (DIN==8'h81) begin		// Selection "command", AFAIK. (bitwise OR of the PCE and drive SCSI IDs).
							SCSI_BIT2 <= DIN[2];		// Lower three bits are probably the drive's SCSI ID.
							SCSI_BIT1 <= DIN[1];		// Which will normally be set to 0b00000001 (bit 0 set == SCSI ID 0).
							SCSI_BIT0 <= DIN[0];
							SCSI_SEL <= 1;				// Select!
							status_state <= 0;
							message_state <= 0;
							command_state <= 0;
							data_state <= 0;
							cmd_buff_pos <= 0;
							phase <= PHASE_COMMAND;	// ElectronAsh.
						end
					end
					8'h01: begin	// 0x1801 CDC_CMD
						//$display("Write to 0x1. 0x%h", DIN);
						cdc_databus <= DIN;
						
						if (DIN==8'h81) begin			// Deselect "command", AFAIK. (bitwise OR of the PCE and drive SCSI IDs).
							SCSI_BIT2 <= 0;
							SCSI_BIT1 <= 0;
							SCSI_BIT0 <= 0;
							SCSI_SEL <= 0;					// Deselect!
							DONE_FLAG <= 1'b0;		// Clear the IRQ_TRANSFER_DONE flag!
							phase <= PHASE_BUS_FREE;	// ElectronAsh.
						end
					end
					8'h02: begin	// 0x1802 INT_MASK
						int_mask <= DIN;
						// Set ACK signal to contents of the interrupt registers 7th bit? A full command will have this bit high
						SCSI_ACK <= DIN[7];
						//IRQ2_ASSERT <= (DIN & bram_lock & 8'h7C) != 0; // RefreshIRQ2(); ... using din here
						//$display("Write to 0x2. IRQ2_ASSERT will be: 0x%h", (int_mask & bram_lock & 8'h7C) != 0);
					end
					8'h03: begin	// 0x1803 BRAM_LOCK
						//bram_lock <= DIN;	// Does not seem to allow direct writes to this in MAME.
					end
					8'h04: begin	// 0x1804 CD_RESET
						cd_reset <= DIN;
						SCSI_RST <= DIN[1];	// Bit 1 (0x02) of DIN sets (or clears) SCSI_RST.
					end
					8'h05: begin	// 0x1805
						//convert_pcm <= DIN;
					end
					8'h06: begin	// 0x1806
						//pcm_data <= DIN;
					end
					8'h07: begin	// 0x1807
						bram_unlock <= DIN;
						if (DIN[7]) bram_locked <= 0;	// If the MSB bit of the write data is SET, it should UNLOCK bram.
					end
					8'h08: begin	// 0x1808
						adpcm_address_low <= DIN;
					end
					8'h09: begin	// 0x1809
						adpcm_address_high <= DIN;
					end
					8'h0A: begin	// 0x180A
						adpcm_ram_data <= DIN;
					end
					8'h0B: begin	// 0x180B
						adpcm_dma_control <= DIN;

						if (DIN & 8'h03) begin
							adpcm_writing <= 1'b1;		// adpcm_status, bit [2] (0x04).
						end
					end
					8'h0C: begin	// 0x180C
						//adpcm_status <= DIN;
					end
					8'h0D: begin	// 0x180D
						//adpcm_address_control <= DIN;
						
						if (DIN[7]) adpcm_reset <= 1'b1;
						
						if (DIN[6]) begin
							adpcm_start_addr <= adpcm_read_addr;
							adpcm_half_addr <= adpcm_read_addr + (adpcm_length >> 1);
							adpcm_end_addr <= adpcm_read_addr + adpcm_length;
							//bram_lock[3:2] <= 2'b00;	// Clear [3]=ADPCM_FULL_INT_SIG and [2]=ADPCM_HALF_INT_SIG at the start of playing. No longer need this. using ADPCM_HALF_FLAG assign etc.
							adpcm_playing <= 1'b1;
						end
						else adpcm_playing <= 1'b0;	// TODO: Check if this is a direct bit set / clear, vs a transitional thing. ElectronAsh.
						
						if (DIN[5]) adpcm_repeat <= 1'b1; else adpcm_repeat <= 1'b0;
						if (DIN[4]) adpcm_length <= {adpcm_address_high, adpcm_address_low};
						if (DIN[3]) adpcm_read_addr <= {adpcm_address_high, adpcm_address_low};
						if (DIN[1]) adpcm_write_addr <= {adpcm_address_high, adpcm_address_low};
					end
					8'h0E: begin	// 0x180E
						adpcm_playback_rate <= DIN;
					end
					8'h0F: begin	// 0x180F
						adpcm_fade_timer <= DIN;
					end
				endcase
			end // end wr


			if (SCSI_RST) begin
				$display("Performing reset");
				//cdc_status <= 0;
				SCSI_BSY  <= 1'b0;
				SCSI_REQ  <= 1'b0;
				SCSI_MSG  <= 1'b0;
				SCSI_CD   <= 1'b0;
				SCSI_IO   <= 1'b0;
				SCSI_BIT2 <= 1'b0;
				SCSI_BIT1 <= 1'b0;
				SCSI_BIT0 <= 1'b0;
				
				SCSI_ACK <= 1'b0;
				SCSI_SEL <= 0;					// Deselect.
				
				READY_FLAG <= 0;
				DONE_FLAG <= 0;
				
				cdc_databus           <= 8'b0;
				int_mask         		 <= 8'b0;
				bram_lock             <= 8'b0;
				cd_reset              <= 8'b0;
				convert_pcm           <= 8'b0;
				pcm_data              <= 8'b0;
				bram_unlock           <= 8'b0;
				adpcm_address_low     <= 8'b0;
				adpcm_address_high    <= 8'b0;
				adpcm_ram_data        <= 8'b0;
				adpcm_dma_control     <= 8'b0;
				//adpcm_address_control <= 8'b0;
				adpcm_playback_rate   <= 8'b0;
				adpcm_fade_timer      <= 8'b0;
				
				status_state <= 0;
				message_state <= 0;
				command_state <= 0;
				dir_state <= 0;
				data_state <= 0;
				data_buffer_size <= 14'd0;
				data_buffer_pos <= 0;
				read_state <= 0;
				int_mask         <= 8'h00;
				bram_lock        <= 8'h00;
				motor_on <= 0;
				cmd_buff_pos <= 4'd0;
				data_buffer_wr_ena <= 0;
				data_buffer_wr_force = 0;
				
				cdda_play <= 1'b0;
				cdda_repeat <= 1'b0;
				cdda_state <= 2'd0;
				cdda_status <= 2'd0;	// 0==CDDA Stopped. 1==CDDA Playing. 2==CDDA Paused.
				
				cdda_req_type = 0;
				
				adpcm_reset <= 1'b1;
				
				bram_lock <= 8'h00;	// TESTING!
				
				bram_locked <= 1;	// BRAM starts locked, according to MAME.
				motor_on <= 0;

				// Clear the command buffer				
				cmd_buff[0] <= 8'h00;
				cmd_buff[1] <= 8'h00;
				cmd_buff[2] <= 8'h00;
				cmd_buff[3] <= 8'h00;
				cmd_buff[4] <= 8'h00;
				cmd_buff[5] <= 8'h00;
				cmd_buff[6] <= 8'h00;
				cmd_buff[7] <= 8'h00;
				cmd_buff[8] <= 8'h00;
				cmd_buff[9] <= 8'h00;
				
				data_buffer_size <= 14'd0;
				data_buffer_pos <= 0;
				data_buffer_wr_ena <= 0;
				data_buffer_wr_force = 0;
				
				read_state <= 0;
				dir_state <= 0;
					
				sd_rd <= 1'b0;
				//sd_wr <= 1'b0;
		

				// Stop all reads
				// Stop all audio
				phase <= PHASE_BUS_FREE;
				
				old_phase <= ~phase;	// ElectronAsh. (force a phase update after reset).
			end
			else begin	// SCSI_RST is Low (run)...
			
				if (adpcm_reset) begin
					adpcm_reset <= 1'b0;
					
					adpcm_read_addr <= 16'h0000;
					adpcm_write_addr <= 16'h0000;
					adpcm_length <= 16'h0000;
					
					adpcm_start_addr <= 16'h0000;
					adpcm_half_addr <= 16'h0000;
					adpcm_end_addr <= 16'h0000;
					
					adpcm_reading <= 1'b0;
					adpcm_playing <= 1'b0;
					adpcm_writing <= 1'b0;
				end
		
				// Spoofing the ADPCM DMA transfer for now.
				// This would normally transfer data directly from the CD into the 64KB ADPCM RAM.
				if (adpcm_writing && cmd_buff[0]==8'h08 && phase==PHASE_DATA_IN) begin
					adpcm_writing <= 1'b0;	// Clear adpcm_status, bit [2] (0x04). DMA done!
					DONE_FLAG <= 1'b1;	// Set IRQ_TRANSFER_DONE flag!
					phase <= PHASE_STATUS;
				end
				
				if (adpcm_playing) begin
					if (audio_clk_en && adpcm_read_addr < adpcm_end_addr) begin
						adpcm_read_addr <= adpcm_read_addr + 1'b1;
						//if (adpcm_read_addr == adpcm_half_addr) bram_lock[2] <= 1'b1;	// Set [3]=ADPCM_HALF_INT_SIG at the halfway point. No longer needed.
					end
					else begin
						//bram_lock[3] <= 1'b1;	// Set [3]=ADPCM_FULL_INT_SIG. No longer needed.
						
						if (adpcm_repeat) begin
							// adpcm_start_addr is a BACKUP of the original adpcm_read_addr, so the assignment is swapped here
							// (as opposed to the write to reg 0xD, which used adpcm_read_addr to assign to these)...
							adpcm_read_addr <= adpcm_start_addr;
							//adpcm_half_addr <= adpcm_start_addr + (adpcm_length >> 1);	// Shouldn't need to rewrite these values for a repeat? ElectronAsh.
							//adpcm_end_addr <= adpcm_start_addr + adpcm_length;
							
							//bram_lock[3:2] <= 2'b00;	// Clear [3]=ADPCM_FULL_INT_SIG and [2]=ADPCM_HALF_INT_SIG at the start (or repeat) of playing. No longer needed.
							adpcm_playing <= 1'b1;
						end
						else begin
							adpcm_repeat <= 1'b0;
							adpcm_playing <= 1'b0;
						end
					end				
				end
				
				
				case (cdda_state)
				0: if (cdda_play) begin
					cdda_status <= 2'd1;			// 0==CDDA Stopped. 1==CDDA Playing. 2==CDDA Paused.
					
					case (cdda_req_type)
						0: sd_req_type <= 16'h5200;	// Request 2352-byte (CD Audio) sector type. LBA.
						1: sd_req_type <= 16'h5201;	// Request 2352-byte (CD Audio) sector type. MSF.
						2: sd_req_type <= 16'h5202;	// Request 2352-byte (CD Audio) sector type. TRACK.
					endcase

					sd_lba <= current_frame;
					sd_rd <= 1'b1;					// Go!
					cdda_state <= cdda_state + 1;
				end
				1: begin
					if (sd_ack) begin
						sd_rd <= 1'b0;
						cdda_state <= cdda_state + 1;
					end
				end
				2: begin
					// "sd_ack" low denotes a sector has just transferred.
					
					if (cmd_buff[0]==8'h08) begin	// STOP CDDA playback as soon as a READ command is seen! TESTING !!!
						cdda_play <= 1'b0;
						cdda_state <= 0;
					end
					else if (!sd_ack && audio_fifo_usedw<1700) begin
						if (current_frame < end_frame && cdda_play) begin	// Check if we've reached end_frame yet (and cdda_play is still set).
							current_frame <= current_frame + 1;
							sd_lba <= sd_lba + 1;
							sd_rd <= 1'b1;
							cdda_state <= 1;			// ..No, Loop back, to fetch another sector!
						end
						else begin
							case (cdda_mode)
							1: begin			// Repeat.
								current_frame <= start_frame;	// Set back to the start frame.
								//cdda_play <= 1'b1;	// Keep playing (don't really need to set this again).
								cdda_state <= 0;
							end
							2: begin			// IRQ when finished.
								cdda_status <= 2'd0;	// 0==CDDA Stopped. 1==CDDA Playing. 2==CDDA Paused.
								cdda_play <= 1'b0;
								DONE_FLAG <= 1'b1;	// This mode sets the IRQ_TRANSFER_DONE flag at the end of CDDA playback. (MAME).
							end
							3: begin			// Play without repeat (STOP).
								cdda_status <= 2'd0;	// 0==CDDA Stopped. 1==CDDA Playing. 2==CDDA Paused.
								cdda_play <= 1'b0;
								cdda_state <= 0;		// Back to idle state. (won't restart unless cdda_play is set again.)
							end
							endcase
						end
					end
				end
				default:;
				endcase
				
				
				if (phase!=old_phase) begin
					case (phase)
						PHASE_BUS_FREE: begin
							$display ("PHASE_BUS_FREE");
							SCSI_BSY <= 0;		// Clear BUSY_BIT.
							SCSI_REQ <= 0;		// Clear REQ_BIT.
							SCSI_MSG <= 0;		// Clear MSG_BIT.
							SCSI_CD  <= 0;		// Clear CD_BIT.
							SCSI_IO  <= 0;		// Clear IO_BIT.
							SCSI_BIT2 <= 0;	// Deselection seems to clear the lower bits (SCSI ID?) as well. ElectronAsh.
							SCSI_BIT1 <= 0;
							SCSI_BIT0 <= 0;
							DONE_FLAG <= 1'b0;	// Clear the IRQ_TRANSFER_DONE flag!
							cmd_buff_pos <= 0;
						end
						PHASE_COMMAND: begin	
							$display ("PHASE_COMMAND");
							SCSI_BSY <= 1;	// Set BUSY_BIT.
							SCSI_REQ <= 1;	// Set REQ_BIT.
							SCSI_MSG <= 0;	// Clear MSG_BIT.
							SCSI_CD  <= 1;	// Set CD_BIT.
							SCSI_IO  <= 0;	// Clear IO_BIT.
						end
						PHASE_STATUS: begin
							$display ("PHASE_STATUS");
							SCSI_BSY <= 1;	// Set BUSY_BIT.
							SCSI_REQ <= 1;	// Set REQ_BIT.
							SCSI_MSG <= 0;	// Clear MSG_BIT.
							SCSI_CD  <= 1;	// Set CD_BIT.
							SCSI_IO  <= 1;	// Set IO_BIT.
						end
						PHASE_DATA_IN: begin
							$display ("PHASE_DATA_IN");
							SCSI_BSY <= 1;	// Set BUSY_BIT.
							SCSI_REQ <= 1;	// Set REQ_BIT.
							SCSI_MSG <= 0;	// Clear MSG_BIT.
							SCSI_CD <= 0;	// Clear CD_BIT.
							SCSI_IO <= 1;	// Set IO_BIT.
						end
						PHASE_MESSAGE_IN: begin
							$display ("PHASE_MESSAGE_IN");
							SCSI_BSY <= 1;	// Set BUSY_BIT. [7]
							SCSI_REQ <= 1;	// Set REQ_BIT. [6]
							SCSI_MSG <= 1;	// Set MSG_BIT. [5]
							SCSI_CD <= 1;	// Set CD_BIT.  [4]
							SCSI_IO <= 1;	// Set IO_BIT.  [3]
						end
					endcase
				end
			end

			if (SCSI_SEL && phase==PHASE_COMMAND) begin
				case (command_state)
				0: if (SCSI_ACK) begin		// The PCE should already have written to CDC_CMD (cdc_databus) before it raises ACK!
					cmd_buff[cmd_buff_pos] <= cdc_databus;	// Grab the packet byte!
					cmd_buff_pos <= cmd_buff_pos + 1;
					SCSI_REQ <= 1'b0;					// Clear the REQ.
					command_state <= command_state + 1;
				end
				
				1: if (!SCSI_ACK) begin
					if (cmd_buff_pos < packet_bytecount) begin	// More bytes left to grab...
						SCSI_REQ <= 1;
						command_state <= 0;
					end
					else begin						// Else...
						SCSI_REQ <= 0;				// Stop REQuesting bytes!
						cmd_buff_pos <= 0;
						read_state <= 0;
						dir_state <= 0;
						stat_counter <= 3;
						cdda_state <= 0;
						command_state <= command_state + 1;
					end
				end
				
				// command_state 2 (parse the command packet itself)...
				2: begin			
					case (cmd_buff[0])
					8'h00: begin	// TEST_UNIT_READY (6).
						phase <= PHASE_STATUS;
					end
					
					8'h08: begin	// READ (6).
						case (read_state)
						0: begin
							cdda_status <= 2'd0;	// 0==CDDA Stopped. 1==CDDA Playing. 2==CDDA Paused.
							cdda_play <= 1'b0;	// STOP CDDA Playback immediately!
						
							frame <= {cmd_buff[1][4:0], cmd_buff[2], cmd_buff[3]};
							frame_count <= cmd_buff[4];

							sd_req_type <= 16'h4800;	// Request 2048-byte CD sectors from the HPS.
							sd_lba <= {cmd_buff[1][4:0], cmd_buff[2], cmd_buff[3]};
							
							sd_sector_count <= 0;
							
							sd_rd <= 1'b1;
							data_buffer_pos <= 0;
							data_buffer_wr_ena <= 1;
							read_state <= read_state + 1;
						end
						
						1: if (sd_ack) begin					// sd_ack should stay high during the whole sector transfer.
							sd_rd <= 1'b0;						// Need to clear sd_rd as soon as sd_ack goes high, apparently.
							read_state <= read_state + 1;
						end
						
						// This is a bit of a kludge atm, due to the HPS using a 16-bit bus for cart ROM / VHD loading... ElectronAsh.
						2: begin						
							if (sd_buff_wr) begin
								data_buffer_pos <= data_buffer_pos + 1;
								data_buffer_wr_force = 1;			// Force another write to the (8-bit) data buffer on the NEXT clock, for the upper data byte (16-bit HPS bus).
								read_state <= read_state + 1;		// (the lower data byte will get written directly by the HPS via sd_wr.)
							end
							
							if (!sd_ack) begin						// Have all 1024 WORDS (2048 bytes) of the CD sector data been written to the data buffer?...
								sd_lba <= sd_lba + 1;
								sd_sector_count <= sd_sector_count + 1;
								read_state <= 4;
							end
						end
						
						3: begin
							data_buffer_wr_force = 0;
							data_buffer_pos <= data_buffer_pos + 1;
							read_state <= read_state - 1;		// Loop back, to transfer the rest of the bytes for the current SD sector.
						end
						
						4: begin
							if (sd_sector_count < frame_count) begin	// Not done yet...
								if (!sd_ack) begin		// Wait for sd_ack to go Low before asserting sd_rd again!
									sd_rd <= 1;										// Request another SD sector.
									read_state <= 1;								// Loop back!
								end
							end
							else begin												// Else, done!
								data_buffer_size <= frame_count*2048;
								data_buffer_wr_ena <= 0;
								motor_on <= 1;
								//sd_rd <= 1'b0;				// Sanity check!
								//sd_lba <= 0;					// Sanity check.
								//sd_req_type <= 16'h0000;	// Set back to 0, in case other commands need RAW SD / VHD sectors (or TOC info).
								data_buffer_pos <= 0;
								READY_FLAG <=1'b1;	// Set IRQ_TRANSFER_READY flag!
								phase <= PHASE_DATA_IN;
							end
						end
						default:;
						endcase
					end
					
					8'hD8: begin	// NEC_SET_AUDIO_START_POS (10).
						case (cmd_buff[9][7:6])
						2'b00: begin	// 0x00. LBA.
							start_frame <= {cmd_buff[3][4:0], cmd_buff[4], cmd_buff[5]};
							current_frame <= {cmd_buff[3][4:0], cmd_buff[4], cmd_buff[5]};
							cdda_req_type = 0;
						end
						2'b01: begin	// 0x40. MSF. (BCD). m=buff[2]. s=buff[3]. f=buff[4].
							//current_frame <= {cmd_buff[2], cmd_buff[3], cmd_buff[4]};
							//current_frame <= bcd2dec(cmd_buff[4]) + (75 * (bcd2dec(cmd_buff[3]) + bcd2dec(cmd_buff[2]) * 60));
							//cdda_req_type = 1;	// MSF.
							start_frame <= (((m_dec*60) + s_dec) * 75)  + f_dec;
							current_frame <= (((m_dec*60) + s_dec) * 75)  + f_dec;
							cdda_req_type = 0;	// Frame.
						end
						2'b10: begin	// 0x80. Track number in (BCD??) cmd_buff[2].
							//start_frame <= cmd_buff[2];
							current_frame <= cmd_buff[2];
							cdda_req_type = 2;
						end
						default:;
						endcase
						
						if (cmd_buff[1] & 8'h03) begin	// According to MAME, this mode plays until the end of the DISK.
							cdda_status <= 2'd1;		// 0==CDDA Stopped. 1==CDDA Playing. 2==CDDA Paused.
							cdda_state <= 0;
							cdda_mode <= (cmd_buff[1] & 8'h02) ? 2 : 3;	// Mode 2 sets IRQ at the end. (MAME).
							cdda_play <= 1'b1;
						end
						else begin										// And this mode plays until the end of the current TRACK.
							cdda_status <= 2'd1;		// 0==CDDA Stopped. 1==CDDA Playing. 2==CDDA Paused.
							cdda_state <= 0;
							cdda_mode <= 2'd3;
							cdda_play <= 1'b1;
						end

						data_buffer_pos <= 0;
						DONE_FLAG <= 1'b1;	// Set IRQ_TRANSFER_DONE flag!
						phase <= PHASE_STATUS;
					end
					
					8'hD9: begin	// NEC_SET_AUDIO_STOP_POS (10).
						case (cmd_buff[9][7:6])
						2'b00: begin	// 0x00. LBA.
							end_frame <= {cmd_buff[3][4:0], cmd_buff[4], cmd_buff[5]};
							cdda_req_type = 0;
						end
						2'b01: begin	// 0x40. MSF. (BCD). m=buff[2]. s=buff[3]. f=buff[4].
							//end_frame <= bcd2dec(cmd_buff[4]) + (75 * (bcd2dec(cmd_buff[3]) + bcd2dec(cmd_buff[2]) * 60));
							//cdda_req_type = 1;	// MSF.
							end_frame <= (((m_dec*60) + s_dec) * 75)  + f_dec;
							cdda_req_type = 0;	// Frame.
						end
						2'b10: begin	// 0x80. Track number (BCD??) in cmd_buff[2].
							end_frame <= cmd_buff[2];
							cdda_req_type = 2;
						end
						endcase
						
						cdda_mode <= cmd_buff[1][1:0];
						
						if (cmd_buff[1] & 8'h03) begin						
							if (cdda_status==2'd2) begin // Is CDDA PAUSED?...
								cdda_status <= 2'd2;	// 0==CDDA Stopped. 1==CDDA Playing. 2==CDDA Paused.
								cdda_play <= 1'b0;	// PAUSE audio!
								cdda_state <= 0;
							end
							else begin
								cdda_status <= 2'd1;	// 0==CDDA Stopped. 1==CDDA Playing. 2==CDDA Paused.
								//cdda_play <= 1'b1;
								cdda_state <= 0;
							end
						end
						else begin
							//end_frame <= last_frame;	// TODO.
							cdda_status <= 2'd0;		// 0==CDDA Stopped. 1==CDDA Playing. 2==CDDA Paused.
							cdda_play <= 1'b0;
							cdda_state <= 0;
						end
					
						data_buffer_pos <= 0;
						DONE_FLAG <= 1'b1;	// Set IRQ_TRANSFER_DONE flag!
						phase <= PHASE_STATUS;
					end
					
					8'hDA: begin	// NEC_PAUSE (10).
						cdda_status <= 2'd2;		// 0==CDDA Stopped. 1==CDDA Playing. 2==CDDA Paused.
						cdda_play <= 1'b0;
						data_buffer_pos <= 0;
						DONE_FLAG <= 1'b1;	// Set IRQ_TRANSFER_DONE flag!
						phase <= PHASE_STATUS;	// TESTING! ElectronAsh.
					end
					
					8'hDD: begin	// NEC_GET_SUBQ (10).
						data_buffer_pos <= 0;
						DONE_FLAG <= 1'b1;	// Set IRQ_TRANSFER_DONE flag!
						phase <= PHASE_STATUS;	// TESTING! ElectronAsh.
					end
					
					8'hDE: begin	// NEC_GET_DIR_INFO (10).
						case (dir_state)
						0: begin
							sd_req_type <= {4'hD, cmd_buff[1][3:0], cmd_buff[2]};	// Request TOC from HPS.
																													// Upper byte of "sd_req_type" will be 0xD0,0xD1,or 0xD2.
																													// Lower byte of "sd_req_type" will be cmd_buff[2]. ElectronAsh.
							sd_lba <= 0;
							sd_rd <= 1'b1;
							
							data_buffer_pos <= 0;
							data_buffer_wr_ena <= 1;
							dir_state <= dir_state + 1;
						end
						1: begin
							// Wait for sd_ack to go HIGH before continuing.
							// (because it doesn't happen immediately, and we need to check for sd_ack low in state 2).
							if (sd_ack) begin
								sd_rd <= 1'b0;				// Need to clear sd_rd as soon as sd_ack goes high, apparently.
								dir_state <= dir_state + 1;
							end
						end
						
						// This is a bit of a kludge atm, due to the HPS using a 16-bit bus for cart ROM / VHD loading... ElectronAsh.
						2: begin											// sd_ack should stay high for the whole 4-byte (TOC) transfer.
							if (sd_buff_wr) begin
								data_buffer_pos <= data_buffer_pos + 1;
								data_buffer_wr_force = 1;			// Force another write to the (8-bit) data buffer on the NEXT clock, for the upper data byte (16-bit HPS bus).
								dir_state <= dir_state + 1;		// (the lower data byte will get written directly by the HPS via sd_wr.)
							end
							
							if (!sd_ack) begin						// Have 2 WORDS (4 bytes) of TOC data been written to the data buffer yet?...
								//sd_lba <= sd_lba + 1;				// We always transfer 4 bytes from the HPS (with padding), because of the HPS 16-bit bus.
								//sd_sector_count <= sd_sector_count + 1;
								dir_state <= 4;
							end
						end
						
						3: begin
							data_buffer_wr_force = 0;
							data_buffer_pos <= data_buffer_pos + 1;
							dir_state <= dir_state - 1;		// Loop back, to transfer the rest of the bytes for the current TOC.
						end
						
						4: begin
							/*if (data_buffer_pos < 4) begin	// Not done yet...
								if (!sd_ack) begin				// Wait for sd_ack to go Low before asserting sd_rd again!
									sd_rd <= 1;						// Request another WORD from the HPS.
									dir_state <= 1;				// Loop back!
								end
							end
							else*/ begin											// Else, done!
								//sd_rd <= 1'b0;										// Sanity check!
								if (cmd_buff[1]==8'd0) data_buffer_size <= 2;	// TOC0 returns 2 bytes to the PCE.
								if (cmd_buff[1]==8'd1) data_buffer_size <= 3;	// TOC1 returns 3 bytes to the PCE.
								if (cmd_buff[1]==8'd2) data_buffer_size <= 4;	// TOC2 returns 4 bytes to the PCE.
								data_buffer_wr_ena <= 0;
								motor_on <= 1;
								sd_req_type <= 16'h0000;	// Set back to 0, in case other commands need RAW SD / VHD sectors (or TOC info).
								data_buffer_pos <= 0;
								READY_FLAG <=1'b1;		// Set IRQ_TRANSFER_READY flag!
								phase <= PHASE_DATA_IN;
							end
						end
						
						default:;
						endcase

					end	// end NEC_GET_DIR_INFO (10).
					
					8'hFF: begin	// END_OF_LIST (1) command.
							phase <= PHASE_STATUS;
					end
					default:;	// Unknown command.
					endcase
				end	// end begin
				default:;
				endcase	// endcase command_state.
			end	// end  if (SCSI_SEL && phase==PHASE_COMMAND/
			
			
			if (SCSI_SEL && phase==PHASE_DATA_IN) begin
				cdc_databus <= data_buffer_dout;		// Continually output new data from the buffer.
				case (data_state)
				0: if (SCSI_ACK) begin
					SCSI_REQ <= 1'b0;					// Clear the REQ.
					data_buffer_pos <= data_buffer_pos + 1;
					data_state <= data_state + 1;
				end
				1: if (!SCSI_ACK) begin
					if (data_buffer_pos < data_buffer_size) begin
						SCSI_REQ <= 1'b1;	// More bytes left to SEND to PCE.
						data_state <= 0;
					end
					else begin						// Else, done!
						data_buffer_pos <= 0;
						READY_FLAG <=1'b0;	// Clear IRQ_TRANSFER_READY flag! (MAME does this. Sort of).
						DONE_FLAG <= 1'b1;	// Set IRQ_TRANSFER_DONE flag!
						phase <= PHASE_STATUS;
					end
				end
				default:;
				endcase
			end

			
			if (SCSI_SEL && phase==PHASE_STATUS) begin
				cdc_databus <= 8'h00;	// Returning 0x00 for the "status" byte atm.
				case (status_state)
				0: if (SCSI_ACK) begin
					SCSI_REQ <= 1'b0;					// Clear the REQ.
					status_state <= status_state + 1;
				end
				1: if (!SCSI_ACK) begin
					phase <= PHASE_MESSAGE_IN;
				end
				default:;
				endcase
			end
			
			
			if (SCSI_SEL && phase==PHASE_MESSAGE_IN) begin
				cdc_databus <= 8'h00;		// Returning 0x00 for the "message" byte atm. (MAME does this anyway.)
				case (message_state)
				0: if (SCSI_ACK) begin
					SCSI_REQ <= 1'b0;					// Clear the REQ.
					message_state <= message_state + 1;
				end
				1: if (!SCSI_ACK) begin
					phase <= PHASE_BUS_FREE;
				end
				default:;
				endcase
			end

		end // end if sel - and our main logic
	end // end else main
end // end always



function  bcd2dec;
input [7:0] bcd;
begin
	bcd2dec = (bcd[7:4]*10) + bcd[3:0];
end
endfunction


endmodule
