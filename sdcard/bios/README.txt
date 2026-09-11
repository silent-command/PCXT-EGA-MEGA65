Alternative system BIOS images for /pcxt/pcxt.rom
=================================================

pcxt-micro8088.rom      Sergey Kiselev's Micro 8088 BIOS 1.0.0a with XTIDE
                        Universal BIOS r625 (128 KB flash image from the
                        upstream tree, SW/8088_bios/binaries/bios-micro8088-
                        xtide.rom). Three bytes patched so XTIDE drives this
                        core's IDE controller: base port 320h -> 300h (offset
                        0x4E), device type XT-CF -> XTIDE rev 1 (0x52), option
                        ROM checksum (0x1FFF). Supports 1.44 MB / 1.2 MB
                        floppies (default setup: one 1.44 MB drive A:).
                        Limits on this core: setup settings cannot be saved
                        (no flash), the PC speaker is silent with this BIOS.
pcxt-micro8088-xtl.rom  Same, but with the 12 KB ide_xtl.rom XTIDE build used
                        by the Turbo XT BIOS instead of r625.

To use one: copy it to the SD card as /pcxt/pcxt.rom (keep a copy of the
Turbo XT BIOS, upstream SW/ROMs/pcxt_pcxt31.rom, to switch back). Do not
also provide /pcxt/xtide.rom with these images.
