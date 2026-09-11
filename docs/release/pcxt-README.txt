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

  xtide.rom     Optional, not needed with pcxt.rom above.

Disk images (mount them from the Help menu):

  freedos.vhd   Hard disk image. Upstream ships one in games/PCXT/hd_image.zip
                (FreeDOS with CTMOUSE, LTEMM (EMS), USE!UMBS, VGATSR and the
                matching CONFIG.SYS). Extract it here as freedos.vhd.
                Any raw hard disk image with an MBR works; the core reads the
                geometry from the partition table.

  *.img         Floppy images, raw sector dumps: 160/180/320/360/720 KB work
                with the Turbo XT BIOS; 1.2 MB and 1.44 MB need a BIOS with
                high-density support.
