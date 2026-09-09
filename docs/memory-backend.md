# Memory backend (Phase 6): HyperRAM behind the byte bus

`CORE/vhdl/mem_backend.vhd` is the slave of the byte-wide Avalon bus that the
`KFSDRAM.sv` overlay drives on the chipset's SDRAM pins.

| XT address        | What                    | Backing                     |
|-------------------|-------------------------|-----------------------------|
| 00000-9FFFF       | 640 KB conventional RAM | HyperRAM                    |
| C0000-C3FFF       | EGA BIOS (16 KB)        | block RAM, written by rom_loader |
| C4000-CFFFF       | UMB (48 KB)             | HyperRAM (core UMB option on) |
| D0000-DFFFF       | EMS page frame          | never presented: the chipset maps it to the pages |
| EC000-EFFFF       | XT-IDE BIOS (16 KB)     | block RAM, written by rom_loader |
| F0000-FFFFF       | PC/XT BIOS (64 KB)      | block RAM, written by rom_loader |
| 200000-3FFFFF     | 2 MB EMS pages (128 x 16 KB) | HyperRAM (core EMS option on) |
| anything else     | empty bus               | reads FF, writes ignored    |

HyperRAM is 4 M x 16-bit words. The framework's scaler owns words 0 to
0xFFFFF (2 MB for 720x576). The PC lives at word `G_HR_BASE` = 0x200000:
word = base + byte/2, byte writes use byteenable, reads take the byte out of
the word. The path is chipset clock -> `M2M/vhdl/memory/avm_fifo.vhd` (xpm
async FIFO) -> `avm_cache.vhd` (one line of 8 words) -> framework arbiter ->
HyperRAM, all in `hr_clk` (100 MHz). `CORE.xdc` declares hr_clk asynchronous
to the chipset/CPU clocks.

Ordering: block-RAM reads answer one clock after acceptance, HyperRAM reads
much later, so a block-RAM or unmapped access is held with waitrequest while
any HyperRAM read is outstanding. The overlay issues at most two reads back
to back; the backend tracks up to eight.

Latency (bench, HyperRAM modelled with 10 clocks): a cache hit still costs
12 byte-bus clocks (240 ns) because of the two FIFO crossings, a miss 17.
The 8088 at 4.77 MHz has an 840 ns bus cycle, so this adds about one wait
state; faster CPU settings pay more.

Framework caveat: `avm_cache.vhd` answers two back-to-back reads of the same
word with a single readdatavalid (its read-hit clause fires while the miss
is being answered). The backend feeds the cache one read at a time
(`c_pending`), which costs one hr clock on such pairs and nothing on
sequential fetch. A framework fix would be to add `and rd_burstcount = X"00"`
to that waitrequest clause.

Bench: `CORE/rtl/tb/mem_backend_tb.vhd`, run with
`powershell -File CORE/rtl/tb/run_mem_backend_tb.ps1` (xsim; both cache
configurations in one simulation, 5425 checks).
