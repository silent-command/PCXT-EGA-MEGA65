/pcxt folder of the SD card - PCXT-EGA for MEGA65
==================================================

Files the core loads from here at startup:

  pcxt.rom      System BIOS, 64 KB. INCLUDED. It is upstream's
                SW/ROMs/pcxt_pcxt31.rom: the Super PC/Turbo XT BIOS v3.1
                with the XTIDE Universal BIOS embedded at F000h.

  ega_bios.rom  EGA card BIOS, 16 KB. REQUIRED, NOT INCLUDED: it is a dump
                of the IBM EGA card's ROM (U44, 27128) and cannot be
                redistributed. Build it from your own dump with the upstream
                script CORE/PCXT-EGA_MiSTer/SW/ROMs/EGA/make_ega_bios_rom.py
                (the dump is stored byte-reversed; the script handles that).
                See the "EGA BIOS" section of the upstream README:
                https://github.com/MiSTer-devel/PCXT-EGA_MiSTer
                Without it the core shows a blank screen.

  xtide.rom     Optional, not needed with pcxt.rom above. Required with the
                alternative BIOS below.

  bios-hd-floppy/  Alternative system BIOS with 1.2 MB / 1.44 MB floppy
                support: pcxt-xt.rom is Sergey Kiselev's 8088 BIOS 1.0.0a,
                XT build (16 KB, GPLv3, https://github.com/skiselev/8088_bios)
                and xtide.rom is the XTIDE Universal BIOS 2.0.0b3+ (12 KB,
                GPLv2, reconfigured for this core's IDE at port 300h). To use
                them copy pcxt-xt.rom to /pcxt/pcxt.rom and xtide.rom to
                /pcxt/xtide.rom. Tested with DOS 3.30 and FreeDOS.

Disk images (mount them from the Help menu):

  freedos.vhd   Hard disk image. Upstream ships one in games/PCXT/hd_image.zip
                (FreeDOS with CTMOUSE, LTEMM (EMS), USE!UMBS, VGATSR and the
                matching CONFIG.SYS). Extract it here as freedos.vhd.
                Any raw hard disk image with an MBR works; the core reads the
                geometry from the partition table.

  *.img         Floppy images, raw sector dumps: 160/180/320/360/720 KB work
                with the Turbo XT BIOS; 1.2 MB and 1.44 MB need the
                alternative BIOS in bios-hd-floppy/ (see above).
