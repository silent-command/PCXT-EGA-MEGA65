# Memory backend (Phase 6): HyperRAM behind the byte bus

`CORE/vhdl/mem_backend.vhd` is the slave of the byte-wide Avalon bus that the
`KFSDRAM.sv` overlay drives on the chipset's SDRAM pins.

| XT address        | What                    | Backing                     |
|-------------------|-------------------------|-----------------------------|
| 00000-9FFFF       | 640 KB conventional RAM | HyperRAM                    |
| C0000-C3FFF       | EGA BIOS (16 KB)        | block RAM, written by rom_loader |
| C4000-CFFFF       | UMB (48 KB)             | HyperRAM (core UMB option on) |
| D0000-DFFFF       | EMS page frame          | never presented: the chipset maps it to the pages |
| E0000-FFFFF       | system BIOS window (128 KB, `pcxt.rom`) | block RAM, written by rom_loader, read-only on the bus |
| EC000-EFFFF       | XT-IDE BIOS (16 KB, `xtide.rom`) | block RAM, written by rom_loader; only decoded once an xtide.rom has been loaded, then it wins over pcxt.rom there |
| 200000-3FFFFF     | 2 MB EMS pages (128 x 16 KB) | HyperRAM (core EMS option on) |
| anything else     | empty bus               | reads FF, writes ignored    |

## pcxt.rom placement (32 / 64 / 96 / 128 KB)

`pcxt.rom` is stored by file offset in a 128 KB block RAM (32 RAMB36) and
placed so that its last byte is at FFFFF: 64 KB at F0000, 32 KB at F8000,
96 KB at E8000, 128 KB at E0000. Bytes of the window below the image read
FF. The firmware streams the file without telling the device its size
(`CRTROM_AUTOLOAD` never writes the CSR window), so the backend takes the
highest word offset written since the last word 0 as the size; word 0 starts
a new image. Files longer than 128 KB are cut to their first 128 KB.

One exception matches what MiSTer does with the 128 KB flash images built by
skiselev/8088_bios (`bios-micro8088-xtide.rom`: XTIDE at file offset 0, BIOS
body at A000-FFFF, entry at FFF0, upper 64 KB all FF - the chip is twice the
mapped size): a 128 KB image whose upper half contains only FFFF words is
treated as the 64 KB image in its lower half, i.e. file byte 0 lands at
F0000 and E0000-EFFFF read FF. Images that use the upper half (e.g.
`bios-sergey-xt-xtide.rom`, 64 KB of FF followed by the image) are placed
normally.

The BIOS window ignores Avalon writes. The chipset's `RAM.sv` write-protect
(`osm_bios_writable_i` is "00") never lets CPU writes through anyway, but the
core's own loader FSM writes each downloaded word a second time at
F0000 + file offset, which is the wrong place for anything but a 64 KB
image. The EGA and XT-IDE windows accept Avalon writes as before. The EGA
and XT-IDE windows take the first 16 KB of their files; longer files no
longer wrap.

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
configurations in one simulation). Test T1a covers the pcxt.rom placement:
32 / 96 / 128 KB images, the blank-upper-half rule, xtide.rom precedence at
EC000 and dropped Avalon writes. `run_rom_loader_tb.ps1` streams word
addresses up to 1FFFE and checks that M2M CSR-window writes yield no data.
