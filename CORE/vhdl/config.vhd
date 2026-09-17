----------------------------------------------------------------------------------
-- MiSTer2MEGA65 Framework
--
-- Configuration data for the Shell
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2023 and licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity config is
port (
   clk_i       : in std_logic;

   -- bits 27 .. 12:    select configuration data block; called "Selector" hereafter
   -- bits 11 downto 0: address the up to 4k the configuration data
   address_i   : in std_logic_vector(27 downto 0);

   -- config data
   data_o      : out std_logic_vector(15 downto 0)
);
end entity config;

architecture beh of config is

--------------------------------------------------------------------------------------------------------------------
-- String and character constants (specific for the Anikki-16x16 font)
--------------------------------------------------------------------------------------------------------------------

-- !!! DO NOT TOUCH !!!
constant CHR_LINE_1  : character := character'val(196);
constant CHR_LINE_5  : string := CHR_LINE_1 & CHR_LINE_1 & CHR_LINE_1 & CHR_LINE_1 & CHR_LINE_1;
constant CHR_LINE_10 : string := CHR_LINE_5 & CHR_LINE_5;
constant CHR_LINE_50 : string := CHR_LINE_10 & CHR_LINE_10 & CHR_LINE_10 & CHR_LINE_10 & CHR_LINE_10;

--------------------------------------------------------------------------------------------------------------------
-- Welcome and Help Screens (Selectors 0x1000 .. 0x1FFF)
--------------------------------------------------------------------------------------------------------------------

-- define the amount of WHS array elements: between 1 and 16
constant WHS_RECORDS   : natural := 2;

-- define the maximum amount of pages per WHS array element: between 1 and 256
-- (this is necessary because Vivado does not support unconstrained arrays in a record)
constant WHS_MAX_PAGES : natural := 3;

 -- !!! DO NOT TOUCH !!!
constant SEL_WHS           : std_logic_vector(15 downto 0) := x"1000";
type WHS_INDEX_TYPE is array (0 to WHS_MAX_PAGES - 1) of natural;
type WHS_RECORD_TYPE is record
   page_count  : natural;
   page_start  : WHS_INDEX_TYPE;
   page_length : WHS_INDEX_TYPE;
end record;
type WHS_RECORD_ARRAY_TYPE is array (0 to WHS_RECORDS - 1) of WHS_RECORD_TYPE;

-- START YOUR CONFIGURATION BELOW THIS LINE

-- Define all your screens as string constants. They will be synthesized as ROMs.
-- You can name these string constants as you want to, as long as you make them part of the WHS array (see below).
--
-- WHS array position 0 is defined as the "Welcome Screen" as controled by WELCOME_ACTIVE and WELCOME_AT_RESET.
-- If you are not using a Welcome Screen but only Help menu items, then you need to leave WHS array pos. 0 empty.
--
-- WHS array position 1 and onwards is for all the Option Menu items tagged as "Help": The first one in the
-- Options menu is WHS array pos. 1, the second one in the menu is WHS array pos. 2 and so on.
--
-- Maximum 16 WHS array positions: The selector's bits 11 downto 8 select the WHS array position; 0=Welcome Screen
-- That means a maximum of 15 menu items in the Options menu can be tagged as "Help"
-- The selector's bits 7 downto 0 are selecting the page within the WHS array, so maximum 256 pages per Welcome Screen or Help menu item
--
-- Within a selector's address range, address 0 is the beginning of the string itself, while address 0xFFF of the 4k
-- window contains the amount of pages, so each zero-terminated string can be up to 4095 bytes = 4094 characters long.

constant SCR_WELCOME : string :=

   "PCXT-EGA for MEGA65 (work in progress)\n" &
   "IBM PC/XT with EGA, ported from MiSTer\n\n" &

   -- We are not insisting. But it would be nice if you gave us credit for MiSTer2MEGA65 by leaving these lines in
   "Powered by MiSTer2MEGA65,\n" &
   "done by sy2002 and MJoergen\n\n" &

   "MEGA65 key           PC key\n" &
   CHR_LINE_10 & CHR_LINE_10 & CHR_LINE_10 & CHR_LINE_10 & "\n" &
   "MEGA                 Alt         ALT: AltGr\n" &
   "RUN/STOP, ESC        Esc\n" &
   "INS/DEL              Backspace\n" &
   "Shift+INS/DEL        Insert      MEGA+: Delete\n" &
   "CLR/HOME             Home\n" &
   "NO SCROLL            Scroll Lock\n" &
   "HELP                 Options menu\n" &
   "Shift+F1..F11        F2..F12\n" &
   "Shift+: and Shift+;  [ and ]\n" &
   "Shift+@ and Shift+*  { and }\n" &
   "Pound, Shift+Pound   # and backslash\n" &
   "Arrow left/up        ` and ^   shifted: ~ |\n\n" &

   "Help key: Options menu\n\n" &
   "    Press Space to continue.\n";

constant HELP_1 : string :=

   "\n PCXT-EGA for MEGA65\n\n" &

   " IBM PC/XT (8088 or 8086) with an EGA card,\n" &
   " ported from MiSTer-devel/PCXT-EGA_MiSTer.\n" &
   " MEGA65 port by silent-command, 2026.\n" &
   " Powered by MiSTer2MEGA65.\n\n" &

   " 640 KB, upper memory and 2 MB EMS live in\n" &
   " HyperRAM. Mount a hard disk image under\n" &
   " Hard Disk, close the menu and press\n" &
   " Ctrl+Alt+Del (CTRL + MEGA + INS/DEL) to\n" &
   " boot it. Floppy images mount under Drive\n" &
   " A and B at any time. Settings are saved\n" &
   " when the menu closes if /m2m/m2mcfg\n" &
   " exists on the SD card.\n\n" &

   " Cursor right to learn more.       (1 of 3)\n" &
   " Press Space to close the help screen.";

constant HELP_2 : string :=

   "\n Keyboard\n\n" &

   " The MEGA65 keys type what they say, on\n" &
   " a US PC layout. Keys the MEGA65 lacks:\n\n" &

   "  [ ]   Shift+:  Shift+;\n" &
   "  { }   Shift+@  Shift+*\n" &
   "  # \   Pound    Shift+Pound\n" &
   "  ` ~   Arrow-left, shifted\n" &
   "  ^ |   Arrow-up, shifted\n" &
   "  F2..F12    Shift+F1..F11\n" &
   "  Insert     Shift+INS/DEL\n" &
   "  Delete     MEGA+INS/DEL\n" &
   "  Alt        MEGA     AltGr: ALT\n" &
   "  Esc        RUN/STOP or ESC\n\n" &

   " Crsr left: Prev  Crsr right: Next (2 of 3)\n" &
   " Press Space to close the help screen.";

constant HELP_3 : string :=

   "\n Menu and SD card\n\n" &

   " CPU: speed, 8086, 286 speedup.\n" &
   " Sound: Adlib / SB FM, Tandy, SB IRQ 7,\n" &
   "   speaker volume, boost.\n" &
   " Display: EGA/CGA/mono monitor, tint.\n" &
   " Input: joysticks (ports 1 and 2), swap,\n" &
   "   write-protect A: and B:.\n\n" &

   " /pcxt/pcxt.rom      PC/XT BIOS with XTIDE\n" &
   " /pcxt/ega_bios.rom  EGA BIOS (required)\n" &
   " /pcxt/*.vhd *.img   disk images\n" &
   " /m2m/m2mcfg         saved settings\n\n" &

   " Cursor left to go back.           (3 of 3)\n" &
   " Press Space to close the help screen.";

-- Concatenate all your Welcome and Help screens into one large string, so that during synthesis one large string ROM can be build.
constant WHS_DATA : string := SCR_WELCOME & HELP_1 & HELP_2 & HELP_3;

-- The WHS array needs the start address of each page. As a best practice: Just define some constants, that you can name for example
-- just like you named the string constants and then add _START. Use the 'length attribute of VHDL to add up all previous strings
-- so that the Synthesis tool can calculate the start addresses: Your first string starts at zero, your next one at the address which
-- is equal to the length of the first one, your next one at the address which is equal to the sum of the previous ones, and so on.
constant SCR_WELCOME_START : natural := 0;
constant HELP_1_START      : natural := SCR_WELCOME'length;
constant HELP_2_START      : natural := HELP_1_START + HELP_1'length;
constant HELP_3_START      : natural := HELP_2_START + HELP_2'length;

-- Fill the WHS array with page start addresses and the length of each page.
-- Make sure that array element 0 is always your Welcome page. If you don't use a welcome page, fill everything with zeros.
constant WHS : WHS_RECORD_ARRAY_TYPE := (
   --- Welcome Screen
   (page_count    => 1,
    page_start    => (SCR_WELCOME_START,  0, 0),
    page_length   => (SCR_WELCOME'length, 0, 0)),

   --- Help pages
   (page_count    => 3,
    page_start    => (HELP_1_START,  HELP_2_START,  HELP_3_START),
    page_length   => (HELP_1'length, HELP_2'length, HELP_3'length))
);

--------------------------------------------------------------------------------------------------------------------
-- Set start folder for file browser and specify config file for menu persistence (Selectors 0x0100 and 0x0101)
--------------------------------------------------------------------------------------------------------------------

-- !!! DO NOT TOUCH !!!
constant SEL_DIR_START     : std_logic_vector(15 downto 0) := x"0100";
constant SEL_CFG_FILE      : std_logic_vector(15 downto 0) := x"0101";

-- START YOUR CONFIGURATION BELOW THIS LINE

constant DIR_START         : string := "/pcxt";
constant CFG_FILE          : string := "/m2m/m2mcfg";

--------------------------------------------------------------------------------------------------------------------
-- General configuration settings: Reset, Pause, OSD behavior, Ascal, etc. (Selector 0x0110)
--------------------------------------------------------------------------------------------------------------------

constant SEL_GENERAL       : std_logic_vector(15 downto 0) := x"0110";  -- !!! DO NOT TOUCH !!!

-- START YOUR CONFIGURATION BELOW THIS LINE

-- at a minimum, keep the reset line active for this amount of "QNICE loops" (see gencfg.asm).
-- "0" means: deactivate this feature
constant RESET_COUNTER     : natural := 100;

-- put the core in PAUSE state if any OSD opens
constant OPTM_PAUSE        : boolean := false;

-- show the welcome screen in general
constant WELCOME_ACTIVE    : boolean := true;

-- shall the welcome screen also be shown after the core is reset?
-- (only relevant if WELCOME_ACTIVE is true)
constant WELCOME_AT_RESET  : boolean := true;

-- keyboard and joystick connection during reset and OSD
constant KEYBOARD_AT_RESET : boolean := false;
constant JOY_1_AT_RESET    : boolean := false;
constant JOY_2_AT_RESET    : boolean := false;

constant KEYBOARD_AT_OSD   : boolean := false;
constant JOY_1_AT_OSD      : boolean := false;
constant JOY_2_AT_OSD      : boolean := false;

-- Avalon Scaler settings (see ascal.vhd, used for HDMI output only)
-- 0=set ascal mode (via QNICE's ascal_mode_o) to the value of the config.vhd constant ASCAL_MODE
-- 1=do nothing, leave ascal mode alone, custom QNICE assembly code can still change it via M2M$ASCAL_MODE
--               and QNICE's CSR will be set to not automatically sync ascal_mode_i
-- 2=keep ascal mode in sync with the QNICE input register ascal_mode_i:
--   use this if you want to control the ascal mode for example via the Options menu
--   where you would wire the output of certain options menu bits with ascal_mode_i
constant ASCAL_USAGE       : natural := 2;
constant ASCAL_MODE        : natural := 0;   -- see ascal.vhd for the meaning of this value

-- Save on-screen-display settings if the file specified by CFG_FILE exists and if it has
-- the length of OPTM_SIZE bytes. If the first byte of the file has the value 0xFF then it
-- is considered as "default", i.e. the menu items specified by OPTM_G_STDSEL are selected.
-- If the file does not exists, then settings are not saved and OPTM_G_STDSEL always denotes the standard settings.
constant SAVE_SETTINGS     : boolean := true;

-- Delay in ms between the last write request to a virtual drive from the core and the start of the
-- cache flushing (i.e. writing to the SD card). Since every new write from the core invalidates the cache,
-- and therefore leads to a completely new writing of the cache (flushing), this constant prevents thrashing.
-- The default is 2 seconds (2000 ms). Should be reasonable for many systems, but if you have a very fast
-- or very slow system, you might need to change this constant.
--
-- Constraint (@TODO): Currently we have only one constant for all virtual drives, i.e. the delay is
-- the same for all virtual drives. This might be absolutely OK; future will tell. If we need to have
-- more flexibility: vdrives.vhd already supports one delay per virtual drive. All what would need
-- to be done in such a case is: Enhance config.vhd to have more constants plus enhance the initialization
-- routine VD_INIT in vdrives.asm (tagged by @TODO) to store different values in the appropriate registers.
constant VD_ANTI_THRASHING_DELAY : natural := 2000;

-- Amount of bytes saved in one iteration of the background saving (buffer flushing) process
-- Constraint (@TODO): Similar constraint as in VD_ANTI_THRASHING_DELAY: Only one value for all drives.
-- shell.asm and shell_vars.asm already supports distinct values per drive; config.vhd and VD_INIT would
-- needs to be updated in case we would need this feature in future
constant VD_ITERATION_SIZE       : natural := 100;

--------------------------------------------------------------------------------------------------------------------
-- Name and version of the core  (Selector 0x0200)
--------------------------------------------------------------------------------------------------------------------

-- !!! DO NOT TOUCH !!!
constant SEL_CORENAME      : std_logic_vector(15 downto 0) := x"0200";

-- START YOUR CONFIGURATION BELOW THIS LINE

-- Currently this is only used in the debug console. Use the welcome screen and the
-- help system to display the name and version of your core to the end user
constant CORENAME          : string := "PCXT-EGA V0.7.3";

--------------------------------------------------------------------------------------------------------------------
-- "Help" menu / Options menu  (Selectors 0x0300 .. 0x0312): DO NOT TOUCH
--------------------------------------------------------------------------------------------------------------------

-- !!! DO NOT TOUCH !!! Selectors for accessing the menu configuration data
constant SEL_OPTM_ITEMS       : std_logic_vector(15 downto 0) := x"0300";
constant SEL_OPTM_GROUPS      : std_logic_vector(15 downto 0) := x"0301";
constant SEL_OPTM_STDSEL      : std_logic_vector(15 downto 0) := x"0302";
constant SEL_OPTM_LINES       : std_logic_vector(15 downto 0) := x"0303";
constant SEL_OPTM_START       : std_logic_vector(15 downto 0) := x"0304";
constant SEL_OPTM_ICOUNT      : std_logic_vector(15 downto 0) := x"0305";
constant SEL_OPTM_MOUNT_DRV   : std_logic_vector(15 downto 0) := x"0306";
constant SEL_OPTM_SINGLESEL   : std_logic_vector(15 downto 0) := x"0307";
constant SEL_OPTM_MOUNT_STR   : std_logic_vector(15 downto 0) := x"0308";
constant SEL_OPTM_DIMENSIONS  : std_logic_vector(15 downto 0) := x"0309";
constant SEL_OPTM_SAVING_STR  : std_logic_vector(15 downto 0) := x"030A";
constant SEL_OPTM_HELP        : std_logic_vector(15 downto 0) := x"0310";
constant SEL_OPTM_CRTROM      : std_logic_vector(15 downto 0) := x"0311";
constant SEL_OPTM_CRTROM_STR  : std_logic_vector(15 downto 0) := x"0312";

-- !!! DO NOT TOUCH !!! Configuration constants for OPTM_GROUPS (shell.asm and menu.asm expect them to be like this)
constant OPTM_G_TEXT       : integer := 16#00000#;         -- text that cannot be selected
constant OPTM_G_CLOSE      : integer := 16#000FF#;        -- menu items that closes menu
constant OPTM_G_STDSEL     : integer := 16#00100#;        -- item within a group that is selected by default
constant OPTM_G_LINE       : integer := 16#00200#;        -- draw a line at this position
constant OPTM_G_START      : integer := 16#00400#;        -- selector / cursor position after startup (only use once!)
                                                          -- 16#00800# is used in OPTM_G_MOUNT_DRV (OPTM_G_SINGLESEL)
constant OPTM_G_HEADLINE   : integer := 16#01000#;        -- like OPTM_G_TEXT but will be shown in a brigher color
                                                          -- 16#02000# is used in OPTM_G_HELP (plus OPTM_G_SINGLESEL)
                                                          -- 16#04000# is used in OPTM_G_SUBMENU
constant OPTM_G_SINGLESEL  : integer := 16#08000#;        -- single select item
constant OPTM_G_MOUNT_DRV  : integer := 16#08800#;        -- line item means: mount drive; first occurance = drive 0, second = drive 1, ...
constant OPTM_G_HELP       : integer := 16#0A000#;        -- line item means: help screen; first occurance = WHS(1), second = WHS(2), ...
constant OPTM_G_SUBMENU    : integer := 16#0C000#;        -- starts/ends a section that is treated as submenu
constant OPTM_G_LOAD_ROM   : integer := 16#18000#;        -- line item means: load ROM; first occurance = rom 0, second = rom 1, ...

constant OPTM_GTC          : natural := 17;                -- Amount of significant bits in OPTM_G_* constants

-- @TODO/REMINDER: If we added in future more configuration constants that are not meant to be saved in the
-- configuration file, such as OPTM_G_MOUNT_DRV and OPTM_G_LOAD_ROM, then we need to make sure that we
-- also extend _ROSMS_4A and _ROSMC_NEXTBIT in options.asm accordingly.
-- Also: Right now OPTM_G_SUBMENU cannot have a "selected" state (and therefore cannot be saved in the config file)
-- and therefore _ROSMS_4A and _ROSMC_NEXTBIT are not yet handling the situation. If we decided to change that in future,
-- we would need to define the right semantics everywhere.

--------------------------------------------------------------------------------------------------------------------
-- "Help" menu / Options menu: START YOUR CONFIGURATION BELOW THIS LINE
--------------------------------------------------------------------------------------------------------------------

-- Strings with which %s will be replaced in case the menu item is of type OPTM_G_MOUNT_DRV
constant OPTM_S_MOUNT      : string := "<Mount Drive>";     -- no disk image mounted, yet
constant OPTM_S_CRTROM     : string := "<Load>";            -- no ROM loaded, yet
constant OPTM_S_SAVING     : string := "<Saving>";          -- the internal write cache is dirty and not yet written back to the SD card

-- Size of menu and menu items
-- CAUTION: 1. End each line (also the last one) with a \n and make sure empty lines / separator lines are only consisting of a "\n"
--             Do use a lower case \n. If you forget one of them or if you use upper case, you will run into undefined behavior.
--          2. Start each line that contains an actual menu item (multi- or single-select) with a Space character,
--             otherwise you will experience visual glitches.
constant OPTM_SIZE         : natural := 90;  -- amount of items including empty lines:
                                             -- needs to be equal to the number of lines in OPTM_ITEMS and amount of items in OPTM_GROUPS
                                             -- IMPORTANT: If SAVE_SETTINGS is true and OPTM_SIZE changes: Make sure to re-generate and
                                             -- and re-distribute the config file. You can make a new one using M2M/tools/make_config.sh

-- Net size of the Options menu on the screen in characters (excluding the frame, which is hardcoded to two characters)
-- Without submenus: Use OPTM_SIZE as height, otherwise count how large the actually visible main menu is.
constant OPTM_DX           : natural := 23;
constant OPTM_DY           : natural := 19;

-- Line numbers of this menu are the bit numbers in qnice_osm_control_i / main_osm_control_i.
-- main.vhd decodes the core options, mega65.vhd the framework ones (C_MENU_*):
--   2 Drive A   3 Drive B   4 Hard Disk
--   9..12 CPU speed 4.77 / 7.16 / 9.54 / Max   14 8086 CPU   15 286 speedup
--  21..27 HDMI modes
--  33..35 FM synth Adlib / SB FM / none   37 Tandy sound   38 SB IRQ 7
--  40..43 speaker volume   45..47 audio boost
--  53..55 monitor 5154 / 5153 / 5151   57..60 tint full / green / amber / b&w
--  62..64 VGA 31 kHz / 15 kHz / 15 kHz + csync
--  70 joystick 1   71 joystick 2   72 swap   74 write-protect A   75 write-protect B
--  77..79 mouse off / C1351 / Amiga (port 1)
--  83 CRT emulation   84 zoom   85 audio improvements
constant OPTM_ITEMS        : string :=

   " PCXT-EGA\n"            &    --    0
   "\n"                     &    --    1
   " Drive A:%s\n"          &    --    2
   " Drive B:%s\n"          &    --    3
   " Hard Disk:%s\n"        &    --    4
   "\n"                     &    --    5

   " CPU: %s\n"             &    --    6  CPU submenu
   " CPU Settings\n"        &    --    7
   "\n"                     &    --    8
   " 4.77 MHz\n"            &    --    9
   " 7.16 MHz\n"            &    -- 10
   " 9.54 MHz\n"            &    -- 11
   " Max\n"                 &    -- 12
   "\n"                     &    -- 13
   " 8086 CPU (reset)\n"    &    -- 14
   " 286 speedup\n"         &    -- 15
   "\n"                     &    -- 16
   " Back to main menu\n"   &    -- 17

   " HDMI: %s\n"            &    -- 18  HDMI submenu
   " HDMI Settings\n"       &    -- 19
   "\n"                     &    -- 20
   " 720p 50 Hz 16:9\n"     &    -- 21
   " 720p 60 Hz 16:9\n"     &    -- 22
   " 576p 50 Hz 4:3\n"      &    -- 23
   " 576p 50 Hz 5:4\n"      &    -- 24
   " 640x480 60 Hz\n"       &    -- 25
   " 720x480 59.94 Hz\n"    &    -- 26
   " 800x600 60 Hz\n"       &    -- 27
   "\n"                     &    -- 28
   " Back to main menu\n"   &    -- 29

   " Sound: %s\n"           &    -- 30  Sound submenu
   " Sound Settings\n"      &    -- 31
   "\n"                     &    -- 32
   " Adlib\n"               &    -- 33
   " Sound Blaster FM\n"    &    -- 34
   " No FM synth\n"         &    -- 35
   "\n"                     &    -- 36
   " Tandy sound\n"         &    -- 37
   " Sound Blaster IRQ 7\n" &    -- 38
   "\n"                     &    -- 39
   " Speaker: Low\n"        &    -- 40
   " Speaker: Medium\n"     &    -- 41
   " Speaker: High\n"       &    -- 42
   " Speaker: Max\n"        &    -- 43
   "\n"                     &    -- 44
   " Boost: None\n"         &    -- 45
   " Boost: 2x\n"           &    -- 46
   " Boost: 4x\n"           &    -- 47
   "\n"                     &    -- 48
   " Back to main menu\n"   &    -- 49

   " Display: %s\n"         &    -- 50  Display submenu
   " Display Settings\n"    &    -- 51
   "\n"                     &    -- 52
   " EGA monitor 5154\n"    &    -- 53
   " CGA monitor 5153\n"    &    -- 54
   " Mono monitor 5151\n"   &    -- 55
   "\n"                     &    -- 56
   " Full color\n"          &    -- 57
   " Green\n"               &    -- 58
   " Amber\n"               &    -- 59
   " Black and white\n"     &    -- 60
   "\n"                     &    -- 61
   " VGA: 31 kHz\n"         &    -- 62  scandoubled for VGA monitors (off in mode 13h)
   " VGA: 15 kHz\n"         &    -- 63  native raster for CRTs / SCART
   " VGA: 15 kHz + CSync\n" &    -- 64  composite sync on the HS pin
   "\n"                     &    -- 65
   " Back to main menu\n"   &    -- 66

   " Input Settings\n"      &    -- 67  Input submenu
   " Input Settings\n"      &    -- 68
   "\n"                     &    -- 69
   " Joystick 1\n"          &    -- 70
   " Joystick 2\n"          &    -- 71
   " Swap joysticks\n"      &    -- 72
   "\n"                     &    -- 73
   " Write-protect A:\n"    &    -- 74
   " Write-protect B:\n"    &    -- 75
   "\n"                     &    -- 76
   " Mouse: Off\n"          &    -- 77  port 1
   " Mouse: C1351\n"        &    -- 78  Commodore 1351 (proportional mode)
   " Mouse: Amiga\n"        &    -- 79  Amiga / Atari ST mouse
   "\n"                     &    -- 80
   " Back to main menu\n"   &    -- 81

   "\n"                     &    -- 82
   " HDMI: CRT emulation\n" &    -- 83
   " HDMI: Zoom-in\n"       &    -- 84
   " Audio improvements\n"  &    -- 85
   "\n"                     &    -- 86
   " Help\n"                &    -- 87
   "\n"                     &    -- 88
   " Close Menu\n";              -- 89

-- define your own constants here and choose meaningful names
-- make sure that your first group uses the value 1 (0 means "no menu item", such as text and line),
-- and be aware that you can only have a maximum of 254 groups (255 means "Close Menu");
-- also make sure that your group numbers are monotonic increasing (e.g. 1, 2, 3, 4, ...)
-- single-select items and therefore also drive mount items need to have unique identifiers
constant OPTM_G_DRIVE_A    : integer := 1;
constant OPTM_G_DRIVE_B    : integer := 2;
constant OPTM_G_HDD        : integer := 3;
constant OPTM_G_CPU_SPEED  : integer := 4;
constant OPTM_G_CPU_8086   : integer := 5;
constant OPTM_G_FAKE286    : integer := 6;
constant OPTM_G_HDMI       : integer := 7;
constant OPTM_G_OPL        : integer := 8;
constant OPTM_G_TANDY      : integer := 9;
constant OPTM_G_SB_IRQ7    : integer := 10;
constant OPTM_G_SPEAKER    : integer := 11;
constant OPTM_G_BOOST      : integer := 12;
constant OPTM_G_MONITOR    : integer := 13;
constant OPTM_G_TINT       : integer := 14;
constant OPTM_G_VGA        : integer := 15;
constant OPTM_G_JOY1       : integer := 16;
constant OPTM_G_JOY2       : integer := 17;
constant OPTM_G_JOY_SWAP   : integer := 18;
constant OPTM_G_WP_A       : integer := 19;
constant OPTM_G_WP_B       : integer := 20;
constant OPTM_G_MOUSE      : integer := 21;
constant OPTM_G_CRT        : integer := 22;
constant OPTM_G_Zoom       : integer := 23;
constant OPTM_G_Audio      : integer := 24;
constant OPTM_G_HELP_ITEM  : integer := 25;

-- !!! DO NOT TOUCH !!!
type OPTM_GTYPE is array (0 to OPTM_SIZE - 1) of integer range 0 to 2**OPTM_GTC- 1;

-- define your menu groups: which menu items are belonging together to form a group?
-- where are separator lines? which items should be selected by default?
-- make sure that you have exactly the same amount of entries here than in OPTM_ITEMS and defined by OPTM_SIZE
constant OPTM_GROUPS       : OPTM_GTYPE := ( OPTM_G_TEXT + OPTM_G_HEADLINE,            --    0 Headline "PCXT-EGA"
                                             OPTM_G_LINE,                              --    1
                                             OPTM_G_DRIVE_A + OPTM_G_MOUNT_DRV + OPTM_G_START, --    2 Drive A, cursor start
                                             OPTM_G_DRIVE_B + OPTM_G_MOUNT_DRV,        --    3 Drive B
                                             OPTM_G_HDD     + OPTM_G_MOUNT_DRV,        --    4 Hard Disk
                                             OPTM_G_LINE,                              --    5

                                             OPTM_G_SUBMENU,                           --    6 CPU submenu: START "CPU: %s"
                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            --    7 Headline "CPU Settings"
                                             OPTM_G_LINE,                              --    8
                                             OPTM_G_CPU_SPEED + OPTM_G_STDSEL,         --    9 4.77 MHz (default)
                                             OPTM_G_CPU_SPEED,                         -- 10 7.16 MHz
                                             OPTM_G_CPU_SPEED,                         -- 11 9.54 MHz
                                             OPTM_G_CPU_SPEED,                         -- 12 Max
                                             OPTM_G_LINE,                              -- 13
                                             OPTM_G_CPU_8086 + OPTM_G_SINGLESEL,       -- 14 8086 CPU toggle (applied at reset)
                                             OPTM_G_FAKE286  + OPTM_G_SINGLESEL,       -- 15 286 speedup toggle
                                             OPTM_G_LINE,                              -- 16
                                             OPTM_G_CLOSE + OPTM_G_SUBMENU,            -- 17 Back; CPU submenu: END

                                             OPTM_G_SUBMENU,                           -- 18 HDMI submenu: START "HDMI: %s"
                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            -- 19 Headline "HDMI Settings"
                                             OPTM_G_LINE,                              -- 20
                                             OPTM_G_HDMI + OPTM_G_STDSEL,              -- 21 720p 50 Hz 16:9 (default)
                                             OPTM_G_HDMI,                              -- 22 720p 60 Hz 16:9
                                             OPTM_G_HDMI,                              -- 23 576p 50 Hz 4:3
                                             OPTM_G_HDMI,                              -- 24 576p 50 Hz 5:4
                                             OPTM_G_HDMI,                              -- 25 640x480 60 Hz
                                             OPTM_G_HDMI,                              -- 26 720x480 59.94 Hz
                                             OPTM_G_HDMI,                              -- 27 800x600 60 Hz
                                             OPTM_G_LINE,                              -- 28
                                             OPTM_G_CLOSE + OPTM_G_SUBMENU,            -- 29 Back; HDMI submenu: END

                                             OPTM_G_SUBMENU,                           -- 30 Sound submenu: START "Sound: %s"
                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            -- 31 Headline "Sound Settings"
                                             OPTM_G_LINE,                              -- 32
                                             OPTM_G_OPL + OPTM_G_STDSEL,               -- 33 Adlib (default)
                                             OPTM_G_OPL,                               -- 34 Sound Blaster FM
                                             OPTM_G_OPL,                               -- 35 No FM synth
                                             OPTM_G_LINE,                              -- 36
                                             OPTM_G_TANDY   + OPTM_G_SINGLESEL,        -- 37 Tandy sound toggle
                                             OPTM_G_SB_IRQ7 + OPTM_G_SINGLESEL,        -- 38 SB IRQ 7 toggle (off = IRQ 5)
                                             OPTM_G_LINE,                              -- 39
                                             OPTM_G_SPEAKER + OPTM_G_STDSEL,           -- 40 Speaker: Low (default)
                                             OPTM_G_SPEAKER,                           -- 41 Speaker: Medium
                                             OPTM_G_SPEAKER,                           -- 42 Speaker: High
                                             OPTM_G_SPEAKER,                           -- 43 Speaker: Max
                                             OPTM_G_LINE,                              -- 44
                                             OPTM_G_BOOST + OPTM_G_STDSEL,             -- 45 Boost: None (default)
                                             OPTM_G_BOOST,                             -- 46 Boost: 2x
                                             OPTM_G_BOOST,                             -- 47 Boost: 4x
                                             OPTM_G_LINE,                              -- 48
                                             OPTM_G_CLOSE + OPTM_G_SUBMENU,            -- 49 Back; Sound submenu: END

                                             OPTM_G_SUBMENU,                           -- 50 Display submenu: START "Display: %s"
                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            -- 51 Headline "Display Settings"
                                             OPTM_G_LINE,                              -- 52
                                             OPTM_G_MONITOR + OPTM_G_STDSEL,           -- 53 EGA monitor 5154 (default)
                                             OPTM_G_MONITOR,                           -- 54 CGA monitor 5153
                                             OPTM_G_MONITOR,                           -- 55 Mono monitor 5151
                                             OPTM_G_LINE,                              -- 56
                                             OPTM_G_TINT + OPTM_G_STDSEL,              -- 57 Full color (default)
                                             OPTM_G_TINT,                              -- 58 Green
                                             OPTM_G_TINT,                              -- 59 Amber
                                             OPTM_G_TINT,                              -- 60 Black and white
                                             OPTM_G_LINE,                              -- 61
                                             OPTM_G_VGA + OPTM_G_STDSEL,               -- 62 VGA: 31 kHz (default)
                                             OPTM_G_VGA,                               -- 63 VGA: 15 kHz
                                             OPTM_G_VGA,                               -- 64 VGA: 15 kHz + CSync
                                             OPTM_G_LINE,                              -- 65
                                             OPTM_G_CLOSE + OPTM_G_SUBMENU,            -- 66 Back; Display submenu: END

                                             OPTM_G_SUBMENU,                           -- 67 Input submenu: START "Input Settings"
                                             OPTM_G_TEXT + OPTM_G_HEADLINE,            -- 68 Headline "Input Settings"
                                             OPTM_G_LINE,                              -- 69
                                             OPTM_G_JOY1 + OPTM_G_SINGLESEL + OPTM_G_STDSEL, -- 70 Joystick 1 toggle (default on)
                                             OPTM_G_JOY2 + OPTM_G_SINGLESEL + OPTM_G_STDSEL, -- 71 Joystick 2 toggle (default on)
                                             OPTM_G_JOY_SWAP + OPTM_G_SINGLESEL,       -- 72 Swap joysticks toggle
                                             OPTM_G_LINE,                              -- 73
                                             OPTM_G_WP_A + OPTM_G_SINGLESEL,           -- 74 Write-protect A: toggle
                                             OPTM_G_WP_B + OPTM_G_SINGLESEL,           -- 75 Write-protect B: toggle
                                             OPTM_G_LINE,                              -- 76
                                             OPTM_G_MOUSE + OPTM_G_STDSEL,             -- 77 Mouse: Off (default)
                                             OPTM_G_MOUSE,                             -- 78 Mouse: C1351
                                             OPTM_G_MOUSE,                             -- 79 Mouse: Amiga
                                             OPTM_G_LINE,                              -- 80
                                             OPTM_G_CLOSE + OPTM_G_SUBMENU,            -- 81 Back; Input submenu: END

                                             OPTM_G_LINE,                              -- 82
                                             OPTM_G_CRT     + OPTM_G_SINGLESEL,        -- 83 On/Off toggle
                                             OPTM_G_Zoom    + OPTM_G_SINGLESEL,        -- 84 On/Off toggle
                                             OPTM_G_Audio   + OPTM_G_SINGLESEL,        -- 85 On/Off toggle
                                             OPTM_G_LINE,                              -- 86
                                             OPTM_G_HELP_ITEM + OPTM_G_HELP,           -- 87 Help screens (WHS 1)
                                             OPTM_G_LINE,                              -- 88
                                             OPTM_G_CLOSE                              -- 89 Close Menu
                                           );

--------------------------------------------------------------------------------------------------------------------
-- !!! CAUTION: M2M FRAMEWORK CODE !!! DO NOT TOUCH ANYTHING BELOW THIS LINE !!!
--------------------------------------------------------------------------------------------------------------------

--------------------------------------------------------------------------------------------------------------------
-- Address Decoding
--------------------------------------------------------------------------------------------------------------------

begin

addr_decode : process(clk_i)
   -- return ASCII value of given string at the position defined by index (zero-based)
   pure function str2data(str : string; index : integer) return std_logic_vector is
   variable strpos : integer;
   begin
      strpos := index + 1;
      if strpos <= str'length then
         return std_logic_vector(to_unsigned(character'pos(str(strpos)), 16));
      else
         return X"0000"; -- zero terminated strings
      end if;
   end function str2data;

   -- return the dimensions of the Options menu
   pure function getDXDY(dx, dy, index: natural) return std_logic_vector is
   begin
      case index is
         when 0 => return std_logic_vector(to_unsigned(dx + 2, 16));
         when 1 => return std_logic_vector(to_unsigned(dy + 2, 16));
         when others => return X"0000";
      end case;
   end function getDXDY;

   -- convert bool to std_logic_vector
   pure function bool2slv(b: boolean) return std_logic_vector is
   begin
      if b then
         return x"0001";
      else
         return x"0000";
      end if;
   end function bool2slv;

   -- return the General Configuration settings
   function getGenConf(index: natural) return std_logic_vector is
   begin
      case index is
         when 1      => return std_logic_vector(to_unsigned(RESET_COUNTER, 16));
         when 2      => return bool2slv(OPTM_PAUSE);
         when 3      => return bool2slv(WELCOME_ACTIVE);
         when 4      => return bool2slv(WELCOME_AT_RESET);
         when 5      => return bool2slv(KEYBOARD_AT_RESET);
         when 6      => return bool2slv(JOY_1_AT_RESET);
         when 7      => return bool2slv(JOY_2_AT_RESET);
         when 8      => return bool2slv(KEYBOARD_AT_OSD);
         when 9      => return bool2slv(JOY_1_AT_OSD);
         when 10     => return bool2slv(JOY_2_AT_OSD);
         when 11     => return std_logic_vector(to_unsigned(ASCAL_USAGE, 16));
         when 12     => return std_logic_vector(to_unsigned(ASCAL_MODE, 16));
         when 13     => return std_logic_vector(to_unsigned(VD_ANTI_THRASHING_DELAY, 16));
         when 14     => return std_logic_vector(to_unsigned(VD_ITERATION_SIZE, 16));
         when 15     => return bool2slv(SAVE_SETTINGS);
         when others => return x"0000";
      end case;
   end function getGenConf;

   variable index           : integer;
   variable whs_page_index  : integer;
   variable whs_array_index : integer;

begin

   if falling_edge(clk_i) then

      index := to_integer(unsigned(address_i(11 downto 0)));
      whs_page_index  := to_integer(unsigned(address_i(19 downto 12)));
      whs_array_index := to_integer(unsigned(address_i(23 downto 20)));

      data_o <= x"EEEE";

      -----------------------------------------------------------------------------------
      -- Welcome & Help System: upper 4 bits of address equal SEL_WHS' upper 4 bits
      -----------------------------------------------------------------------------------

      if address_i(27 downto 24) = SEL_WHS(15 downto 12) then

         if  whs_array_index < WHS_RECORDS then
            if index = 4095 then
               data_o <= std_logic_vector(to_unsigned(WHS(whs_array_index).page_count, 16));
            else
               if index < WHS(whs_array_index).page_length(whs_page_index) then
                  data_o <= str2data(WHS_DATA, WHS(whs_array_index).page_start(whs_page_index) + index);
               else
                  data_o <= (others => '0'); -- zero-terminated strings
               end if;
            end if;
         end if;

      -----------------------------------------------------------------------------------
      -- All other selectors, which are 16-bit values
      -----------------------------------------------------------------------------------

      else

         case address_i(27 downto 12) is
            when SEL_GENERAL           => data_o <= getGenConf(index);
            when SEL_DIR_START         => data_o <= str2data(DIR_START, index);
            when SEL_CFG_FILE          => data_o <= str2data(CFG_FILE, index);
            when SEL_CORENAME          => data_o <= str2data(CORENAME, index);
            when SEL_OPTM_ITEMS        => data_o <= str2data(OPTM_ITEMS, index);
            when SEL_OPTM_MOUNT_STR    => data_o <= str2data(OPTM_S_MOUNT, index);
            when SEL_OPTM_CRTROM_STR   => data_o <= str2data(OPTM_S_CRTROM, index);
            when SEL_OPTM_SAVING_STR   => data_o <= str2data(OPTM_S_SAVING, index);
            when SEL_OPTM_GROUPS       => data_o <= std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(15)) &
                                                    std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(14)) & "0" &
                                                    std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(12)) & "0000" &
                                                    std_logic_vector(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(7 downto 0));
            when SEL_OPTM_STDSEL       => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(8));
            when SEL_OPTM_LINES        => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(9));
            when SEL_OPTM_START        => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(10));
            when SEL_OPTM_MOUNT_DRV    => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(11));
            when SEL_OPTM_HELP         => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(13));
            when SEL_OPTM_SINGLESEL    => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(15));
            when SEL_OPTM_CRTROM       => data_o <= x"000" & "000" & std_logic(to_unsigned(OPTM_GROUPS(index), OPTM_GTC)(16));
            when SEL_OPTM_ICOUNT       => data_o <= x"00" & std_logic_vector(to_unsigned(OPTM_SIZE, 8));
            when SEL_OPTM_DIMENSIONS   => data_o <= getDXDY(OPTM_DX, OPTM_DY, index);

            when others                => null;
         end case;
      end if;
   end if;
end process;

end architecture beh;

