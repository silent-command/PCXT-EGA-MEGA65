Alternative system BIOS images for /pcxt (Sergey Kiselev's 8088 BIOS 1.0.0a)
============================================================================

All support 1.44 MB / 1.2 MB floppies. The Turbo XT BIOS the release ships
as /pcxt/pcxt.rom (upstream SW/ROMs/pcxt_pcxt31.rom) does not.

pcxt-xt.rom + xtide.rom   THE ONE TO USE. The "IBM PC/XT" build (16 KB, lands
                          at FC000) for an 8255-based XT like this core, plus
                          the XTIDE Universal BIOS build the Turbo XT BIOS
                          embeds (12 KB, already configured for this core's
                          IDE at 300h), loaded into the EC000 option-ROM slot.
                          Copy both: /pcxt/pcxt.rom and /pcxt/xtide.rom.
                          No setup memory: defaults are one 1.44 MB drive A:,
                          CGA/EGA autodetected.
pcxt-micro8088.rom        Micro 8088 build: boots DOS, but its board has a
pcxt-micro8088-xtl.rom    fixed-function keyboard port instead of an 8255, so
                          on this core the keyboard does not work and the
                          speaker is silent. Reference only.
pcxt-sergeyxt.rom         Despite the name this is the Xi 8088 build (AT-class:
                          AT keyboard controller, second PIC, mandatory RTC)
                          padded to 128 KB; it hangs on this core. Reference
                          only.

The 128 KB images have their XTIDE block reconfigured by
tools/patch_xtide_rom.py (base port 320h -> 300h, XTIDE rev 1, checksum).
Keep the Turbo XT BIOS under another name to switch back; do not combine a
128 KB image with /pcxt/xtide.rom (they contain XTIDE already).
