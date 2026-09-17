// ne1000.sv - Novell NE1000 (National Semiconductor DP8390 NIC, 8-bit ISA, 8 KB packet buffer)
// emulated on the PCXT-EGA chipset bus for the MEGA65 port, so that a stock DOS packet driver
// (Crynwr NE1000.COM, 8390.asm + ne1000.asm) and through it mTCP can use the R6's Ethernet port.
//
// Evidence the register model follows (quoted as CRYNWR file:label where it is the driver's own
// sequence, DP8390 where it is the data sheet's behaviour, BOCHS/QEMU where the two well-known
// emulators agree on a point the data sheet leaves vague):
//   CRYNWR ne1000.asm      NE_DATAPORT = base+10h (remote DMA data port), NE_RESET = base+1Fh
//                          ("Issue a read for reset"), reset_8390 = in, 1.6 ms, out; block_input /
//                          block_output = CR 22h, RBCR0/1, RSAR0/1, CR 0Ah (remote read) or 12h
//                          (remote write), N x in/out of the data port, then RDC polled in ISR after
//                          a write (block_output_1). init_card reads 16 bytes from remote address 0
//                          and keeps the first six as the station address; it only tests bit 0 of
//                          byte 0 (multicast bit), no signature test.
//   CRYNWR 8390.asm:etopen reset_board (reset port, CR 21h, 1.6 ms), DCR 48h, CR 21h, RBCR 0,
//                          RCR 20h (monitor), TCR 02h (loopback), init_card (PROM read with CR 22h,
//                          i.e. started, while in monitor + loopback), DCR 48h, PSTART 26h, BNRY 26h,
//                          PSTOP 40h, ISR FFh, IMR 3Fh, set_address (CR 60h: page 1 with STA = STP = 0,
//                          PAR0..5, CR 20h), set_hw_multi (CR 61h STOP, MAR0..7, CR 22h START),
//                          CR 61h, CURR 27h (PSTART + 1), CR 22h, TCR 00h. head.asm then calls
//                          rcv_mode_3: set_hw_multi again and RCR 04h (broadcast + own address).
//                          TPSR page 20h (SM_TSTART_PG) is the transmit buffer, 26h..3Fh the ring.
//   CRYNWR 8390.asm:send_pkt   CR read (TXP busy test), ISR read, TSR read, ISR = 0Ah, ISR = 40h, TBCR0/1,
//                          block_output to 2000h with the byte count rounded up to even, TPSR 20h,
//                          CR 26h (TXP + NODMA + START). The transmit interrupt handler (isr_tx) reads
//                          TSR and writes ISR = 0Ah.
//   CRYNWR 8390.asm:recv   IMR 00h, ISR read; on PRX/RXE: ISR = 05h, CR 62h, CURR read, CR 22h, then
//                          while next_packet != CURR: block_input of 26 bytes from next_packet<<8,
//                          status must have bit 0 (RXOK), next page must lie in [PSTART, PSTOP),
//                          the frame is "count - 4" bytes from offset 4, BNRY = next - 1 (wrapping
//                          to PSTOP - 1); finally IMR 3Fh. Overrun (OVW): CR read, CR 21h, 1.6 ms,
//                          RBCR 0, ISR read (TX completion), TCR 02h, CR 22h, CR 61h, CURR read and
//                          written back, CR 20h, packets removed as above, BNRY, ISR = 10h, TCR 00h,
//                          CR 26h if a transmit was pending.
//   DP8390                 register map pages 0/1/2, ISR bits cleared by writing ones, RST set by a
//                          reset or STOP and cleared by START, the ring buffer header {status, next
//                          page, count low, count high} with the count including the 4 FCS bytes and
//                          not the header, CURR = next page for reception, BNRY = last page the host
//                          has freed, overflow when the local DMA would enter the BNRY page (OVW,
//                          receiver halted until STOP/START), remote DMA completes with RDC when RBCR
//                          bytes have been transferred, CNTR0..2 clear on read, counters set CNT at 80h.
//   BOCHS/QEMU             the run state: STP stops, STA starts, a CR write with both clear leaves
//                          the state alone (the driver writes 20h/60h/61h with STA = 0 while running,
//                          and 61h with STP while running: set_hw_multi); CR reads back what was
//                          written with TXP cleared when the frame has gone; a reset leaves CR = 21h,
//                          ISR = 80h, IMR = 00h; the NE1000 PROM is 6 address bytes, 8 zero bytes and
//                          'B','B' (42h) at 14/15 (the NE2000 has 'W','W', 57h; Linux ne.c tells the
//                          two apart by byte doubling and looks for 57h; the 42h pair is the NE1000's
//                          documented signature). PROM at remote addresses 0000h..001Fh (mirrored),
//                          RAM at 2000h..3FFFh, anything else reads FFh.
//
// Bus timing: the chipset presents address, data and io_read_n / io_write_n for several 50 MHz
// clocks per I/O cycle (see the I/O settle guard in CHIPSET.sv). Writes and read side effects are
// taken on the trailing edge of the strobe, exactly as XT2IDE -> ide.v do (Peripherals.sv:1534-1559):
// the address, chip select and write data are registered every clock and the values of the clock
// before the strobe rose are used. Read data is a registered mux of the register file (no
// combinational path from the bus into the read data, one clock after the address changes), and the
// parent's data_bus_out register adds one more; the CPU samples many clocks later even at Max speed.
// Nothing here touches READY. The remote DMA data port reads a prefetched byte: port A of the buffer
// RAM always reads the current remote address, so the value is ready long before the next IN.
//
// Local DMA: port B of the buffer RAM is shared by the receive ring writer (priority, one byte per
// clock from the MAC's receive FIFO, which the MAC fills at one byte per four clocks) and the
// transmit reader (one byte every second clock into the MAC's transmit FIFO; the MAC starts only
// after the whole frame is queued). Address filtering happens in the ring writer after the sixth
// byte (PAR compare, broadcast, multicast hash through MAR, PRO); frames that do not match are
// discarded from then on and never reach the ring beyond those six bytes, so they cannot cause an
// overflow.
//
// Not implemented (no driver in scope uses them): the "send packet" remote DMA command (CR 1Bh),
// word-wide transfers (DCR WTS is ignored, the NE1000 is byte-wide), loopback diagnostics (a TXP in
// loopback mode completes immediately with PTX and nothing on the wire), collisions / deferral
// (full duplex link), FIFO threshold bits, page 3 (RTL8019 only).
//
// MEGA65 port done by silent-command in 2026 and licensed under GPL v3
// MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3

module ne1000 (
    input  wire        clk,             // chipset clock, 50 MHz
    input  wire        reset,           // chipset reset (active high, synchronous)
    input  wire        enable,          // card present; when 0 every read returns FFh and writes are ignored
    // XT I/O bus, decoded by the caller to base..base+1Fh (cs includes iorq and ~aen)
    input  wire        cs,
    input  wire [4:0]  address,
    input  wire        io_read_n,
    input  wire        io_write_n,
    input  wire [7:0]  data_in,
    output reg  [7:0]  data_out,        // registered
    output reg         irq,             // level: |(ISR & IMR)
    input  wire [47:0] mac_addr,        // station address PROM contents, byte 0 = [47:40]
    // MAC receive stream (eth_mac.vhd rx FIFO, sys clock side)
    input  wire        rx_empty,
    output wire        rx_rd,
    input  wire [8:0]  rx_data,         // [8] end of frame, then [7:0] = status (see eth_mac.vhd)
    // MAC transmit stream
    input  wire        tx_full,
    output reg         tx_wr,
    output reg  [8:0]  tx_data,         // [8] end of frame
    input  wire        tx_done,         // one clock per frame that left the wire
    // debug
    output wire [7:0]  dbg_isr,
    output wire        dbg_running
);

    // ------------------------------------------------------------------------------------------
    // Bus strobes (trailing edge, registered copies of the cycle)
    // ------------------------------------------------------------------------------------------
    reg        io_read_n_q = 1'b1, io_write_n_q = 1'b1, cs_q = 1'b0;
    reg  [4:0] addr_q;
    reg  [7:0] din_q;

    always_ff @(posedge clk) begin
        io_read_n_q  <= io_read_n;
        io_write_n_q <= io_write_n;
        cs_q         <= cs & enable;
        addr_q       <= address;
        din_q        <= data_in;
    end

    wire wr_strobe = cs_q & ~io_write_n_q & io_write_n;
    wire rd_strobe = cs_q & ~io_read_n_q  & io_read_n;
    wire reg_sel   = ~addr_q[4];                         // base+00h..0Fh: DP8390 registers
    wire data_sel  =  addr_q[4] & ~addr_q[3];            // base+10h..17h: remote DMA data port
    wire reset_sel =  addr_q[4] &  addr_q[3];            // base+18h..1Fh: reset port

    // ------------------------------------------------------------------------------------------
    // Register file
    // ------------------------------------------------------------------------------------------
    reg  [7:0] cr;                                       // {PS1, PS0, RD2, RD1, RD0, TXP, STA, STP}
    reg        running;                                  // STA seen after the last STP
    reg  [7:0] pstart, pstop, bnry, tpsr, curr;
    reg [15:0] tbcr, rsar, rbcr;
    reg  [7:0] isr, imr, rcr, tcr, dcr, tsr, rsr;
    reg  [7:0] par [0:5];
    reg  [7:0] mar [0:7];
    reg  [7:0] cntr0, cntr1, cntr2;
    reg [15:0] crda;                                     // current remote DMA address
    reg [15:0] rem_cnt;                                  // remote bytes left
    reg  [1:0] dma_mode;                                 // 0 idle, 1 remote read, 2 remote write
    reg        nic_reset;                                // one clock: the reset port was touched

    wire [1:0] page = cr[7:6];

    localparam int ISR_PRX = 0, ISR_PTX = 1, ISR_RXE = 2, ISR_TXE = 3, ISR_OVW = 4, ISR_CNT = 5, ISR_RDC = 6, ISR_RST = 7;
    reg  [7:0] isr_set_rx, isr_set_tx, isr_set_dma;      // one-clock set requests from the engines
    wire       rx_commit;                                // the ring writer commits CURR <= next_page in this clock
    reg  [7:0] next_page;

    wire cr_write = wr_strobe & reg_sel & (addr_q[3:0] == 4'h0);
    wire data_rd  = rd_strobe & data_sel;
    wire data_wr  = wr_strobe & data_sel;

    // ------------------------------------------------------------------------------------------
    // Station address PROM (16 bytes, remote addresses 0000h..001Fh)
    // ------------------------------------------------------------------------------------------
    function automatic [7:0] prom_byte(input [3:0] i);
        case (i)
            4'd0:  prom_byte = mac_addr[47:40];
            4'd1:  prom_byte = mac_addr[39:32];
            4'd2:  prom_byte = mac_addr[31:24];
            4'd3:  prom_byte = mac_addr[23:16];
            4'd4:  prom_byte = mac_addr[15:8];
            4'd5:  prom_byte = mac_addr[7:0];
            4'd14: prom_byte = 8'h42;                    // 'B'
            4'd15: prom_byte = 8'h42;                    // 'B'
            default: prom_byte = 8'h00;
        endcase
    endfunction

    // ------------------------------------------------------------------------------------------
    // 8 KB packet buffer: port A = remote DMA (CPU), port B = local DMA (ring writer / tx reader)
    // ------------------------------------------------------------------------------------------
    reg  [7:0]  mem [0:8191];
    reg  [7:0]  a_dout, b_dout;
    wire [12:0] a_addr   = crda[12:0];
    wire        a_in_ram = (crda[15:13] == 3'b001);
    wire        a_we     = data_wr & (dma_mode == 2'd2) & a_in_ram;
    reg  [12:0] b_addr;                                  // ring writer, registered with b_we / b_din
    reg         b_we;
    reg  [7:0]  b_din;
    reg  [12:0] tx_addr;                                 // transmit reader
    wire [12:0] b_addr_mux = b_we ? b_addr : tx_addr;

    always_ff @(posedge clk) begin
        if (a_we) mem[a_addr] <= din_q;
        a_dout <= mem[a_addr];
    end

    always_ff @(posedge clk) begin
        if (b_we) mem[b_addr_mux] <= b_din;
        b_dout <= mem[b_addr_mux];
    end

    // value the data port returns for the current remote address
    wire [7:0] dma_rd_byte = a_in_ram ? a_dout : (crda[15:5] == 11'd0) ? prom_byte(crda[3:0]) : 8'hFF;

    // ------------------------------------------------------------------------------------------
    // Remote DMA
    // ------------------------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        isr_set_dma <= 8'h00;
        if (reset | nic_reset) begin
            dma_mode <= 2'd0;
            crda     <= 16'h0000;
            rem_cnt  <= 16'h0000;
        end
        else if (cr_write) begin
            case (din_q[5:3])
                3'b001: if (rbcr != 16'h0000) begin dma_mode <= 2'd1; crda <= rsar; rem_cnt <= rbcr; end
                3'b010: if (rbcr != 16'h0000) begin dma_mode <= 2'd2; crda <= rsar; rem_cnt <= rbcr; end
                3'b011: dma_mode <= 2'd0;                            // send packet: not supported
                3'b1??: dma_mode <= 2'd0;                            // abort / complete
                default: ;
            endcase
        end
        else if ((data_rd & (dma_mode == 2'd1)) | (data_wr & (dma_mode == 2'd2))) begin
            // the remote address wraps from PSTOP to PSTART like the ring (DP8390 "remote DMA
            // wrap-around"; Bochs ne2k.cc does the same): the driver reads a wrapped packet linearly
            if (crda + 16'd1 == {pstop, 8'h00}) crda <= {pstart, 8'h00};
            else                                crda <= crda + 16'd1;
            rem_cnt <= rem_cnt - 16'd1;
            if (rem_cnt == 16'd1) begin
                dma_mode <= 2'd0;
                isr_set_dma[ISR_RDC] <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------------------------------
    // Transmit: copy TBCR bytes from TPSR<<8 into the MAC FIFO, wait for the wire, report PTX
    // ------------------------------------------------------------------------------------------
    localparam [1:0] TX_IDLE = 2'd0, TX_COPY = 2'd1, TX_EOF = 2'd2, TX_WAIT = 2'd3;
    reg  [1:0]  tx_state;
    reg [11:0]  tx_remain;
    reg         tx_rd_issued;
    reg         tx_quiet;                                // a reset hit mid-frame: finish silently
    wire        tx_loopback = (tcr[2:1] != 2'b00);
    wire        txp_start   = cr_write & din_q[2] & ~din_q[0] & (tx_state == TX_IDLE);
    // one read per two clocks, never in a clock the ring writer owns (b_we is registered, so it
    // says exactly whether port B writes in this clock)
    wire        tx_issue    = (tx_state == TX_COPY) & (tx_remain != 12'd0) & ~tx_rd_issued & ~b_we & ~tx_full;

    always_ff @(posedge clk) begin
        isr_set_tx <= 8'h00;
        tx_wr      <= 1'b0;
        tx_data    <= 9'h000;
        if (reset) begin
            tx_state     <= TX_IDLE;
            tx_rd_issued <= 1'b0;
            tx_quiet     <= 1'b0;
            tsr          <= 8'h00;
        end
        else begin
            if (nic_reset) begin
                tx_quiet <= (tx_state != TX_IDLE);
                tsr      <= 8'h00;
            end
            case (tx_state)
                TX_IDLE: begin
                    tx_rd_issued <= 1'b0;
                    if (txp_start) begin
                        if (tx_loopback) begin                       // nothing on the wire, complete at once
                            tsr <= 8'h01;
                            isr_set_tx[ISR_PTX] <= 1'b1;
                        end
                        else begin
                            tx_state  <= TX_COPY;
                            tx_addr   <= {tpsr[4:0], 8'h00};
                            tx_remain <= (tbcr > 16'd2040) ? 12'd2040 : tbcr[11:0];
                            tx_quiet  <= 1'b0;
                        end
                    end
                end
                TX_COPY: begin
                    if (tx_rd_issued) begin                          // b_dout holds mem[tx_addr - 1]
                        tx_wr        <= 1'b1;
                        tx_data      <= {1'b0, b_dout};
                        tx_rd_issued <= 1'b0;
                    end
                    else if (tx_issue) begin
                        tx_rd_issued <= 1'b1;
                        tx_addr      <= tx_addr + 13'd1;
                        tx_remain    <= tx_remain - 12'd1;
                    end
                    else if (tx_remain == 12'd0) begin
                        tx_state <= TX_EOF;
                    end
                end
                TX_EOF: begin
                    if (~tx_full) begin
                        tx_wr    <= 1'b1;
                        tx_data  <= 9'h100;
                        tx_state <= TX_WAIT;
                    end
                end
                default: begin                                       // TX_WAIT
                    if (tx_done) begin
                        tx_state <= TX_IDLE;
                        if (~tx_quiet) begin
                            tsr <= 8'h01;                            // PTX, no collisions, no deferral
                            isr_set_tx[ISR_PTX] <= 1'b1;
                        end
                    end
                end
            endcase
        end
    end

    // ------------------------------------------------------------------------------------------
    // Receive ring writer
    // ------------------------------------------------------------------------------------------
    localparam [1:0] RXW_IDLE = 2'd0, RXW_DATA = 2'd1, RXW_DISCARD = 2'd2, RXW_HDR = 2'd3;
    reg  [1:0]  rxw_state;
    reg [15:0]  wr_addr;                                 // next byte goes here (page, offset)
    reg  [7:0]  start_page;                              // CURR at the start of this frame
    reg  [7:0]  cur_page;                                // page of the last byte written
    reg [11:0]  byte_cnt;
    reg  [1:0]  hdr_idx;
    reg  [7:0]  hdr_status;
    reg [31:0]  dst_crc;                                 // reflected CRC-32 over the destination address
    reg         dst_is_bcast, dst_is_mcast, dst_match;
    reg         rx_halted;                               // overflow: receiver stopped until START

    wire        rx_eof    = rx_data[8];
    wire [7:0]  rx_st     = rx_data[7:0];
    wire        st_fcs_ok = rx_st[0], st_runt = rx_st[1], st_long = rx_st[2], st_fae = rx_st[3],
                st_rxer   = rx_st[4], st_ovr  = rx_st[5];
    wire        rcr_sep = rcr[0], rcr_ar = rcr[1], rcr_ab = rcr[2], rcr_am = rcr[3], rcr_pro = rcr[4], rcr_mon = rcr[5];

    // byte-serial reflected CRC-32 (same polynomial and form as the MAC's dibit engine)
    function automatic [31:0] crc32_byte(input [31:0] c, input [7:0] d);
        reg [31:0] r;
        begin
            r = c ^ {24'h0, d};
            for (int i = 0; i < 8; i++) r = r[0] ? ((r >> 1) ^ 32'hEDB88320) : (r >> 1);
            crc32_byte = r;
        end
    endfunction

    // multicast hash: the DP8390 takes the six most significant bits of the (non-reflected) CRC over
    // the destination address as {MAR index[2:0], bit[2:0]}; in the reflected register those are bits
    // 0..5 reversed (Linux 8390.c make_mc_bits: bits[crc >> 29] |= 1 << ((crc >> 26) & 7)).
    wire [31:0] dst_crc_next  = crc32_byte(dst_crc, rx_st);
    wire [5:0]  hash_now      = {dst_crc_next[0], dst_crc_next[1], dst_crc_next[2],
                                 dst_crc_next[3], dst_crc_next[4], dst_crc_next[5]};
    wire        mar_bit_now   = mar[hash_now[5:3]][hash_now[2:0]];
    wire        dst_match_now = dst_match & (rx_st == par[byte_cnt[2:0]]);
    wire        dst_bcast_now = dst_is_bcast & (rx_st == 8'hFF);
    // decided when the sixth byte arrives (byte_cnt == 5)
    wire        addr_ok_now   = dst_bcast_now ? rcr_ab :
                                dst_is_mcast  ? (rcr_am & mar_bit_now) :
                                                (rcr_pro | dst_match_now);

    // ring arithmetic
    wire [7:0]  page_inc      = (wr_addr[15:8] + 8'd1 == pstop) ? pstart : wr_addr[15:8] + 8'd1;
    wire [15:0] wr_addr_next  = (wr_addr[7:0] == 8'hFF) ? {page_inc, 8'h00} : wr_addr + 16'd1;
    wire        entering_page = (wr_addr[7:0] == 8'h00);
    wire [7:0]  cur_page_next = (cur_page + 8'd1 == pstop) ? pstart : cur_page + 8'd1;

    wire        pop = ~rx_empty & (rxw_state != RXW_HDR);
    assign      rx_rd = pop;

    // frame status byte written to the ring / RSR
    wire        st_crc_err = ~st_fcs_ok | st_ovr | st_long | st_rxer;
    wire        st_prx     = ~st_crc_err & ~st_fae;
    wire [7:0]  status_now = {1'b0, 1'b0, (dst_is_bcast | dst_is_mcast), 1'b0, 1'b0, st_fae, st_crc_err, st_prx};
    wire        accept_now = ~rcr_mon & (st_prx | rcr_sep) & (~st_runt | rcr_ar);

    always_ff @(posedge clk) begin
        isr_set_rx <= 8'h00;
        b_we       <= 1'b0;
        if (reset) begin
            rxw_state <= RXW_IDLE;
            rx_halted <= 1'b0;
            rsr       <= 8'h00;
            cntr0     <= 8'h00;
            cntr1     <= 8'h00;
            cntr2     <= 8'h00;
        end
        else begin
            // counters clear on read (page 0, 0Dh..0Fh)
            if (rd_strobe & reg_sel & (page == 2'd0) & (addr_q[3:0] == 4'hD)) cntr0 <= 8'h00;
            if (rd_strobe & reg_sel & (page == 2'd0) & (addr_q[3:0] == 4'hE)) cntr1 <= 8'h00;
            if (rd_strobe & reg_sel & (page == 2'd0) & (addr_q[3:0] == 4'hF)) cntr2 <= 8'h00;
            if (cr_write & din_q[1] & ~din_q[0]) rx_halted <= 1'b0;   // START restarts the receiver

            case (rxw_state)
                RXW_IDLE: begin
                    if (pop & ~rx_eof) begin                         // first byte of a frame
                        dst_crc      <= crc32_byte(32'hFFFFFFFF, rx_st);
                        dst_is_bcast <= (rx_st == 8'hFF);
                        dst_is_mcast <= rx_st[0];
                        dst_match    <= (rx_st == par[0]);
                        byte_cnt     <= 12'd1;
                        if (~running) begin
                            rxw_state <= RXW_DISCARD;
                        end
                        else if (rx_halted | (curr == bnry)) begin  // ring full: missed packet
                            rxw_state <= RXW_DISCARD;
                            rx_halted <= 1'b1;
                            isr_set_rx[ISR_OVW] <= 1'b1;
                            rsr       <= 8'h10;                      // MPA
                            cntr2     <= cntr2 + 8'd1;
                            if (cntr2 == 8'h7F) isr_set_rx[ISR_CNT] <= 1'b1;
                        end
                        else begin
                            rxw_state  <= RXW_DATA;
                            start_page <= curr;
                            cur_page   <= curr;
                            wr_addr    <= {curr, 8'h05};
                            b_addr     <= {curr[4:0], 8'h04};
                            b_din      <= rx_st;
                            b_we       <= 1'b1;
                        end
                    end
                end

                RXW_DATA: begin
                    if (pop) begin
                        if (rx_eof) begin
                            rsr <= status_now;
                            if (~st_prx & ~st_runt) begin
                                if (st_fae) begin
                                    cntr0 <= cntr0 + 8'd1;
                                    if (cntr0 == 8'h7F) isr_set_rx[ISR_CNT] <= 1'b1;
                                end
                                else begin
                                    cntr1 <= cntr1 + 8'd1;
                                    if (cntr1 == 8'h7F) isr_set_rx[ISR_CNT] <= 1'b1;
                                end
                            end
                            if (accept_now) begin
                                rxw_state  <= RXW_HDR;
                                hdr_idx    <= 2'd0;
                                hdr_status <= status_now;
                                next_page  <= cur_page_next;
                                b_addr     <= {start_page[4:0], 8'h00};
                                b_din      <= status_now;
                                b_we       <= 1'b1;
                            end
                            else begin
                                rxw_state <= RXW_IDLE;
                            end
                        end
                        else if (entering_page & (wr_addr[15:8] == bnry)) begin
                            // the next page is the one the host has not freed yet: overflow
                            rxw_state <= RXW_DISCARD;
                            rx_halted <= 1'b1;
                            isr_set_rx[ISR_OVW] <= 1'b1;
                            rsr       <= 8'h10;
                            cntr2     <= cntr2 + 8'd1;
                            if (cntr2 == 8'h7F) isr_set_rx[ISR_CNT] <= 1'b1;
                        end
                        else begin
                            b_addr   <= wr_addr[12:0];
                            b_din    <= rx_st;
                            b_we     <= 1'b1;
                            cur_page <= wr_addr[15:8];
                            wr_addr  <= wr_addr_next;
                            if (byte_cnt != 12'hFFF) byte_cnt <= byte_cnt + 12'd1;
                            if (byte_cnt <= 12'd5) begin
                                dst_crc      <= dst_crc_next;
                                dst_is_bcast <= dst_bcast_now;
                                dst_match    <= dst_match_now;
                                if (byte_cnt == 12'd5 && ~addr_ok_now) rxw_state <= RXW_DISCARD;
                            end
                        end
                    end
                end

                RXW_DISCARD: begin
                    if (pop & rx_eof) rxw_state <= RXW_IDLE;
                end

                default: begin                                       // RXW_HDR: bytes 1..3, then commit
                    hdr_idx <= hdr_idx + 2'd1;
                    case (hdr_idx)
                        2'd0: begin b_we <= 1'b1; b_addr <= {start_page[4:0], 8'h01}; b_din <= next_page;          end
                        2'd1: begin b_we <= 1'b1; b_addr <= {start_page[4:0], 8'h02}; b_din <= byte_cnt[7:0];      end
                        2'd2: begin b_we <= 1'b1; b_addr <= {start_page[4:0], 8'h03}; b_din <= {4'h0, byte_cnt[11:8]}; end
                        default: begin                               // rx_commit is high in this clock
                            rxw_state <= RXW_IDLE;
                            if (hdr_status[0]) isr_set_rx[ISR_PRX] <= 1'b1;
                            else               isr_set_rx[ISR_RXE] <= 1'b1;
                        end
                    endcase
                end
            endcase

            if (nic_reset) begin                                     // hardware reset: drop the frame in flight
                rx_halted <= 1'b0;
                rsr       <= 8'h00;
                cntr0     <= 8'h00;
                cntr1     <= 8'h00;
                cntr2     <= 8'h00;
                b_we      <= 1'b0;
                if (rxw_state == RXW_DATA || (rxw_state == RXW_IDLE && pop && ~rx_eof)) rxw_state <= RXW_DISCARD;
                else if (rxw_state == RXW_HDR) rxw_state <= RXW_IDLE;
            end
        end
    end

    // ------------------------------------------------------------------------------------------
    // Register writes, ISR, CR, reset port
    // ------------------------------------------------------------------------------------------
    wire [7:0] isr_set_all = isr_set_rx | isr_set_tx | isr_set_dma;
    // CURR moves at the same edge as the writer goes idle, so a frame whose first byte is already
    // queued starts behind the header just written, never on top of it
    assign rx_commit = (rxw_state == RXW_HDR) && (hdr_idx == 2'd3) && ~nic_reset;

    always_ff @(posedge clk) begin
        nic_reset <= 1'b0;
        if (reset | nic_reset) begin
            cr      <= 8'h21;
            running <= 1'b0;
            isr     <= 8'h80;
            imr     <= 8'h00;
            rcr     <= 8'h00;
            tcr     <= 8'h00;
            dcr     <= 8'h00;
            if (reset) begin
                pstart <= 8'h00; pstop <= 8'h00; bnry <= 8'h00; tpsr <= 8'h00; curr <= 8'h00;
                tbcr <= 16'h0000; rsar <= 16'h0000; rbcr <= 16'h0000;
                for (int i = 0; i < 6; i++) par[i] <= 8'h00;
                for (int i = 0; i < 8; i++) mar[i] <= 8'h00;
            end
        end
        else begin
            // the engines set bits, the host clears them by writing ones (RST only through START)
            if (wr_strobe & reg_sel & (page == 2'd0) & (addr_q[3:0] == 4'h7))
                isr[6:0] <= (isr[6:0] & ~din_q[6:0]) | isr_set_all[6:0];
            else
                isr[6:0] <= isr[6:0] | isr_set_all[6:0];

            // TXP reads back until the frame has left the wire
            if (tx_state == TX_WAIT && tx_done) cr[2] <= 1'b0;

            if ((rd_strobe | wr_strobe) & reset_sel) nic_reset <= 1'b1;

            if (rx_commit) curr <= next_page;

            if (wr_strobe & reg_sel) begin
                if (addr_q[3:0] == 4'h0) begin
                    cr[7:3] <= din_q[7:3];
                    cr[1:0] <= din_q[1:0];
                    if (txp_start & ~tx_loopback) cr[2] <= 1'b1;
                    if (din_q[0]) begin
                        running <= 1'b0;
                        isr[7]  <= 1'b1;
                    end
                    else if (din_q[1]) begin
                        running <= 1'b1;
                        isr[7]  <= 1'b0;
                    end
                end
                else if (page == 2'd0) begin
                    case (addr_q[3:0])
                        4'h1: pstart     <= din_q;
                        4'h2: pstop      <= din_q;
                        4'h3: bnry       <= din_q;
                        4'h4: tpsr       <= din_q;
                        4'h5: tbcr[7:0]  <= din_q;
                        4'h6: tbcr[15:8] <= din_q;
                        4'h8: rsar[7:0]  <= din_q;
                        4'h9: rsar[15:8] <= din_q;
                        4'hA: rbcr[7:0]  <= din_q;
                        4'hB: rbcr[15:8] <= din_q;
                        4'hC: rcr        <= din_q;
                        4'hD: tcr        <= din_q;
                        4'hE: dcr        <= din_q;
                        4'hF: imr        <= din_q;
                        default: ;
                    endcase
                end
                else if (page == 2'd1) begin
                    case (addr_q[3:0])
                        4'h1, 4'h2, 4'h3, 4'h4, 4'h5, 4'h6: par[addr_q[3:0] - 4'd1] <= din_q;
                        4'h7: curr <= din_q;
                        default: mar[addr_q[2:0]] <= din_q;          // 8h..Fh
                    endcase
                end
            end
        end
    end

    // ------------------------------------------------------------------------------------------
    // Read data (registered mux) and the interrupt
    // ------------------------------------------------------------------------------------------
    reg [7:0] rd_mux;
    always_comb begin
        rd_mux = 8'hFF;
        if (~address[4]) begin
            if (address[3:0] == 4'h0) rd_mux = cr;
            else case (page)
                2'd0: case (address[3:0])
                    4'h1: rd_mux = wr_addr[7:0];                     // CLDA0
                    4'h2: rd_mux = wr_addr[15:8];                    // CLDA1
                    4'h3: rd_mux = bnry;
                    4'h4: rd_mux = tsr;
                    4'h5: rd_mux = 8'h00;                            // NCR
                    4'h6: rd_mux = 8'h00;                            // FIFO
                    4'h7: rd_mux = isr;
                    4'h8: rd_mux = crda[7:0];
                    4'h9: rd_mux = crda[15:8];
                    4'hA: rd_mux = 8'h00;                            // reserved
                    4'hB: rd_mux = 8'h00;
                    4'hC: rd_mux = rsr;
                    4'hD: rd_mux = cntr0;
                    4'hE: rd_mux = cntr1;
                    default: rd_mux = cntr2;
                endcase
                2'd1: case (address[3:0])
                    4'h1, 4'h2, 4'h3, 4'h4, 4'h5, 4'h6: rd_mux = par[address[3:0] - 4'd1];
                    4'h7: rd_mux = curr;
                    default: rd_mux = mar[address[2:0]];
                endcase
                2'd2: case (address[3:0])
                    4'h1: rd_mux = pstart;
                    4'h2: rd_mux = pstop;
                    4'h4: rd_mux = tpsr;
                    4'hC: rd_mux = rcr;
                    4'hD: rd_mux = tcr;
                    4'hE: rd_mux = dcr;
                    4'hF: rd_mux = imr;
                    default: rd_mux = 8'h00;                         // next packet / address counters
                endcase
                default: rd_mux = 8'h00;                             // page 3: RTL8019 only
            endcase
        end
        else if (~address[3]) rd_mux = dma_rd_byte;                  // data port
        else                  rd_mux = 8'hFF;                        // reset port
    end

    always_ff @(posedge clk) begin
        data_out <= enable ? rd_mux : 8'hFF;
        irq      <= enable & |(isr[6:0] & imr[6:0]);
    end

    assign dbg_isr     = isr;
    assign dbg_running = running;

endmodule
