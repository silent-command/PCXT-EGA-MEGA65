/pcxt folder of the SD card - PCXT-EGA for MEGA65
==================================================

Everything here is ready to use except ega_bios.rom, which you have to supply.

Files the core loads from here at startup:

  pcxt.rom      System BIOS, 16 KB. INCLUDED and already in place. It is
                Sergey Kiselev's 8088 BIOS, XT build (GPL v3,
                https://github.com/skiselev/8088_bios). It reads 1.2 MB and
                1.44 MB floppies, which the MEGA65's internal drive needs, and
                works with xtide.rom below for large hard disks.
                roms/ holds this and the alternatives; see roms/README.txt to
                change it. You do not need to.

  xtide.rom     XTIDE Universal BIOS, 12 KB. INCLUDED and already in place
                (GPL v2, https://www.xtideuniversalbios.org/, reconfigured for
                this core's IDE at port 300h). Hard disk support for the BIOS
                above. Not needed if you switch to the Turbo XT BIOS, which
                has XTIDE built in.

  ega_bios.rom  EGA card BIOS, 16 KB. REQUIRED, NOT INCLUDED: it is a dump
                of the IBM EGA card's ROM (U44, 27128), part 6277356, still
                under copyright, so no core can ship it. Make it yourself:
                1. Download the raw dump (16,384 bytes) in a browser:
                   https://minuszerodegrees.net/rom/bin/ibm_6277356_ega_card_u44_27128.bin
                   (listed at https://minuszerodegrees.net/rom/rom.htm as
                   IBM / EGA / U44).
                2. Reverse its byte order - the dump is stored back to front.
                   python3 -c "open('ega_bios.rom','wb').write(open('ibm_6277356_ega_card_u44_27128.bin','rb').read()[::-1])"
                   or the upstream script SW/ROMs/EGA/make_ega_bios_rom.py
                   from https://github.com/MiSTer-devel/PCXT-EGA_MiSTer,
                   which downloads and reverses in one step.
                3. The result begins with bytes 55 AA 20 and has MD5
                   528455ed0b701722c166c6536ba4ff46. Put it here.
                Without it the core stops at the boot splash and says so.

  roms/         Every system BIOS option, with its own README. Nothing here is
                loaded directly; the files above are what the core reads.

Disk images (mount them from the Help menu):

  freedos.vhd   Bootable FreeDOS hard disk, INCLUDED. FreeDOS
                (https://www.freedos.org/) with the drivers this machine
                wants: CTMOUSE for the mouse, LTEMM for the 2 MB of EMS,
                USE!UMBS, and the core's own VGATSR.COM and XTEGACTL.COM.
                Mount it under "Hard Disk", close the menu and press
                Ctrl+Alt+Del.

                FDAUTO.BAT runs FASTFREE.COM at boot: it counts the free
                clusters in under a second so the first DIR does not stall
                while FreeDOS does that one cluster at a time (about 40 s on
                this image at 4.77 MHz). Harmless to copy to your own images.

                The MiSTer release ships a similar image in
                games/PCXT/hd_image.zip that also carries a DEMOS folder of PC
                demoscene productions (8088 MPH, Area 5150, 8088 Feet and
                others). Those are separate copyrighted works by their
                authors, so they are not in this one. They are worth seeking
                out - this machine runs them as real hardware does - and the
                usual scene archives, pouet.net and scene.org, have them under
                their own names.

                Any raw hard disk image with an MBR works here; the core reads
                the geometry from the partition table.

  netdisk.img   Networking kit for the emulated NE1000: the Crynwr packet
                driver and mTCP (DHCP, ping, FTP, telnet and more), both GPL.
                See the Network section of the main README.

  joytest.img   Game port test, and SETJOY for BIOSes that leave the equipment
                bit clear. See the joystick note in the main README.

  *.img         Floppy images, raw sector dumps: 160/180/320/360/720 KB always
                work; 1.2 MB and 1.44 MB need the default BIOS above.
