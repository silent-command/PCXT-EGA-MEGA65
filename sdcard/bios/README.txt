Alternative system BIOS images for /pcxt/pcxt.rom
=================================================

All three are 128 KB flash images from the upstream tree
(SW/8088_bios/binaries, Sergey Kiselev's 8088 BIOS 1.0.0a with XTIDE
Universal BIOS r625), with the XTIDE block reconfigured by
tools/patch_xtide_rom.py so it drives this core's IDE controller: base port
320h -> 300h, device type XT-CF -> XTIDE rev 1, option-ROM checksum fixed.
All support 1.44 MB / 1.2 MB floppies (default setup: one 1.44 MB drive A:).
Setup settings cannot be saved on this core (no flash), so defaults apply at
every boot.

pcxt-sergeyxt.rom       "Sergey's XT" build: for a board with a real 8255
                        like this core's chipset. USE THIS ONE.
pcxt-micro8088.rom      Micro 8088 build: boots DOS, but its board has a
                        fixed-function keyboard port instead of an 8255, so
                        on this core the KEYBOARD DOES NOT WORK and the PC
                        speaker is silent. Kept for reference.
pcxt-micro8088-xtl.rom  Micro 8088 build with the ide_xtl.rom XTIDE instead
                        of r625. Same keyboard limitation.

To use one: copy it to the SD card as /pcxt/pcxt.rom (keep the Turbo XT
BIOS, upstream SW/ROMs/pcxt_pcxt31.rom, under another name to switch back).
Do not also provide /pcxt/xtide.rom with these images: they contain XTIDE.
