---------------------------------------------------------------------------------------------------------
-- PCXT-EGA on MiSTer2MEGA65: MEGA65 keyboard -> PS/2 set-2 scancodes
--
-- The framework scans the 80 MEGA65 keys at 1 kHz (key_num_i cycles 0..79,
-- key_pressed_n_i is the debounced state). This module detects presses and
-- releases, translates them with a layout table into PS/2 set-2 make/break
-- sequences and queues the bytes into ps2_tx, which drives the chipset's PS/2
-- input. It also emits the MiSTer-style ps2_key event word the core's splash
-- logic watches for F12.
--
-- Layout: the MEGA65 keycaps are mapped to what they say, on a US PC layout.
-- Where a legend needs a different shift state on a PC than on the MEGA65
-- (":" is shift+";" on a PC, "@" is shift+2, the shifted digit row differs),
-- the translator forces the PC shift state around that key and restores the
-- physical shift state when it is released. The PC's view of its two shift
-- keys is modelled in pc_lshift / pc_rshift, updated at the one place where a
-- shift make or break is queued, whatever its origin (physical key or forced
-- fix), so the model cannot drift from the byte stream. (An earlier version
-- kept a single flag that only shift makes refreshed; a physical shift
-- release left it stale and the next forced-shift key lost its shift, which
-- is how ":" typed after Shift+letter came out as ";".) Keys the MEGA65 lacks:
--
--   ` ~      <- arrow-left, shift+arrow-left          [ ]  <- shift+:  shift+;
--   ^ |      <- arrow-up,   shift+arrow-up            { }  <- shift+@  shift+*
--   # \      <- pound,      shift+pound               F2..F12 <- shift+F1..F11
--   F12      <- Shift+F11 (HELP stays with the framework)   Esc  <- ESC and RUN/STOP
--   Insert   <- shift+INS/DEL   Delete <- MEGA+INS/DEL   Home <- CLR/HOME
--   Alt      <- MEGA            AltGr  <- ALT   ScrollLock <- NO SCROLL
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
---------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity keyboard is
   port (
      clk_main_i           : in  std_logic;               -- core clock (chipset, 50 MHz)
      rst_i                : in  std_logic;

      -- Interface to the MEGA65 keyboard
      key_num_i            : in  integer range 0 to 79;   -- cycles through all MEGA65 keys
      key_pressed_n_i      : in  std_logic;               -- low active: debounced feedback: is kb_key_num_i pressed right now?

      -- host -> device PS/2 lines from the chipset (clock-low = inhibit)
      ps2_host_clk_i       : in  std_logic;
      ps2_host_data_i      : in  std_logic;

      -- device -> host PS/2 lines into the chipset
      ps2_clk_o            : out std_logic;
      ps2_data_o           : out std_logic;

      -- MiSTer ps2_key event word: {toggle, pressed, extended, code}
      ps2_key_o            : out std_logic_vector(10 downto 0)
   );
end keyboard;

architecture beh of keyboard is

   -- MEGA65 key numbers (framework numbering)
   constant m65_ins_del       : integer := 0;
   constant m65_return        : integer := 1;
   constant m65_horz_crsr     : integer := 2;   -- cursor right
   constant m65_f7            : integer := 3;
   constant m65_f1            : integer := 4;
   constant m65_f3            : integer := 5;
   constant m65_f5            : integer := 6;
   constant m65_vert_crsr     : integer := 7;   -- cursor down
   constant m65_3             : integer := 8;
   constant m65_w             : integer := 9;
   constant m65_a             : integer := 10;
   constant m65_4             : integer := 11;
   constant m65_z             : integer := 12;
   constant m65_s             : integer := 13;
   constant m65_e             : integer := 14;
   constant m65_left_shift    : integer := 15;
   constant m65_5             : integer := 16;
   constant m65_r             : integer := 17;
   constant m65_d             : integer := 18;
   constant m65_6             : integer := 19;
   constant m65_c             : integer := 20;
   constant m65_f             : integer := 21;
   constant m65_t             : integer := 22;
   constant m65_x             : integer := 23;
   constant m65_7             : integer := 24;
   constant m65_y             : integer := 25;
   constant m65_g             : integer := 26;
   constant m65_8             : integer := 27;
   constant m65_b             : integer := 28;
   constant m65_h             : integer := 29;
   constant m65_u             : integer := 30;
   constant m65_v             : integer := 31;
   constant m65_9             : integer := 32;
   constant m65_i             : integer := 33;
   constant m65_j             : integer := 34;
   constant m65_0             : integer := 35;
   constant m65_m             : integer := 36;
   constant m65_k             : integer := 37;
   constant m65_o             : integer := 38;
   constant m65_n             : integer := 39;
   constant m65_plus          : integer := 40;
   constant m65_p             : integer := 41;
   constant m65_l             : integer := 42;
   constant m65_minus         : integer := 43;
   constant m65_dot           : integer := 44;
   constant m65_colon         : integer := 45;
   constant m65_at            : integer := 46;
   constant m65_comma         : integer := 47;
   constant m65_gbp           : integer := 48;
   constant m65_asterisk      : integer := 49;
   constant m65_semicolon     : integer := 50;
   constant m65_clr_home      : integer := 51;
   constant m65_right_shift   : integer := 52;
   constant m65_equal         : integer := 53;
   constant m65_arrow_up      : integer := 54;
   constant m65_slash         : integer := 55;
   constant m65_1             : integer := 56;
   constant m65_arrow_left    : integer := 57;
   constant m65_ctrl          : integer := 58;
   constant m65_2             : integer := 59;
   constant m65_space         : integer := 60;
   constant m65_mega          : integer := 61;
   constant m65_q             : integer := 62;
   constant m65_run_stop      : integer := 63;
   constant m65_no_scrl       : integer := 64;
   constant m65_tab           : integer := 65;
   constant m65_alt           : integer := 66;
   constant m65_help          : integer := 67;
   constant m65_f9            : integer := 68;
   constant m65_f11           : integer := 69;
   constant m65_f13           : integer := 70;
   constant m65_esc           : integer := 71;
   constant m65_capslock      : integer := 72;
   constant m65_up_crsr       : integer := 73;
   constant m65_left_crsr     : integer := 74;
   constant m65_restore       : integer := 75;

   -- One table entry: PS/2 set-2 code, extended (E0) flag, and the shift the
   -- PC needs for this legend: KEEP the physical shift, force ON, force OFF.
   type shift_t is (KEEP, S_ON, S_OFF);
   type entry_t is record
      code  : std_logic_vector(7 downto 0);
      ext   : boolean;
      shift : shift_t;
   end record;
   constant NONE : entry_t := (x"00", false, KEEP);

   function E(c : std_logic_vector(7 downto 0)) return entry_t is
   begin return (c, false, KEEP); end;
   function X(c : std_logic_vector(7 downto 0)) return entry_t is
   begin return (c, true, KEEP); end;
   function SH_ON(c : std_logic_vector(7 downto 0)) return entry_t is
   begin return (c, false, S_ON); end;
   function SH_OFF(c : std_logic_vector(7 downto 0)) return entry_t is
   begin return (c, false, S_OFF); end;
   function SH_XOFF(c : std_logic_vector(7 downto 0)) return entry_t is
   begin return (c, true, S_OFF); end;

   -- PS/2 set-2 codes
   constant K_A : std_logic_vector(7 downto 0) := x"1C";  constant K_B : std_logic_vector(7 downto 0) := x"32";
   constant K_C : std_logic_vector(7 downto 0) := x"21";  constant K_D : std_logic_vector(7 downto 0) := x"23";
   constant K_E : std_logic_vector(7 downto 0) := x"24";  constant K_F : std_logic_vector(7 downto 0) := x"2B";
   constant K_G : std_logic_vector(7 downto 0) := x"34";  constant K_H : std_logic_vector(7 downto 0) := x"33";
   constant K_I : std_logic_vector(7 downto 0) := x"43";  constant K_J : std_logic_vector(7 downto 0) := x"3B";
   constant K_K : std_logic_vector(7 downto 0) := x"42";  constant K_L : std_logic_vector(7 downto 0) := x"4B";
   constant K_M : std_logic_vector(7 downto 0) := x"3A";  constant K_N : std_logic_vector(7 downto 0) := x"31";
   constant K_O : std_logic_vector(7 downto 0) := x"44";  constant K_P : std_logic_vector(7 downto 0) := x"4D";
   constant K_Q : std_logic_vector(7 downto 0) := x"15";  constant K_R : std_logic_vector(7 downto 0) := x"2D";
   constant K_S : std_logic_vector(7 downto 0) := x"1B";  constant K_T : std_logic_vector(7 downto 0) := x"2C";
   constant K_U : std_logic_vector(7 downto 0) := x"3C";  constant K_V : std_logic_vector(7 downto 0) := x"2A";
   constant K_W : std_logic_vector(7 downto 0) := x"1D";  constant K_X : std_logic_vector(7 downto 0) := x"22";
   constant K_Y : std_logic_vector(7 downto 0) := x"35";  constant K_Z : std_logic_vector(7 downto 0) := x"1A";
   constant K_1 : std_logic_vector(7 downto 0) := x"16";  constant K_2 : std_logic_vector(7 downto 0) := x"1E";
   constant K_3 : std_logic_vector(7 downto 0) := x"26";  constant K_4 : std_logic_vector(7 downto 0) := x"25";
   constant K_5 : std_logic_vector(7 downto 0) := x"2E";  constant K_6 : std_logic_vector(7 downto 0) := x"36";
   constant K_7 : std_logic_vector(7 downto 0) := x"3D";  constant K_8 : std_logic_vector(7 downto 0) := x"3E";
   constant K_9 : std_logic_vector(7 downto 0) := x"46";  constant K_0 : std_logic_vector(7 downto 0) := x"45";
   constant K_SPACE  : std_logic_vector(7 downto 0) := x"29";  constant K_ENTER  : std_logic_vector(7 downto 0) := x"5A";
   constant K_BKSP   : std_logic_vector(7 downto 0) := x"66";  constant K_ESC    : std_logic_vector(7 downto 0) := x"76";
   constant K_TAB    : std_logic_vector(7 downto 0) := x"0D";  constant K_LCTRL  : std_logic_vector(7 downto 0) := x"14";
   constant K_LSHIFT : std_logic_vector(7 downto 0) := x"12";  constant K_RSHIFT : std_logic_vector(7 downto 0) := x"59";
   constant K_LALT   : std_logic_vector(7 downto 0) := x"11";  constant K_CAPS   : std_logic_vector(7 downto 0) := x"58";
   constant K_SCRL   : std_logic_vector(7 downto 0) := x"7E";
   constant K_F1  : std_logic_vector(7 downto 0) := x"05";  constant K_F2  : std_logic_vector(7 downto 0) := x"06";
   constant K_F3  : std_logic_vector(7 downto 0) := x"04";  constant K_F4  : std_logic_vector(7 downto 0) := x"0C";
   constant K_F5  : std_logic_vector(7 downto 0) := x"03";  constant K_F6  : std_logic_vector(7 downto 0) := x"0B";
   constant K_F7  : std_logic_vector(7 downto 0) := x"83";  constant K_F8  : std_logic_vector(7 downto 0) := x"0A";
   constant K_F9  : std_logic_vector(7 downto 0) := x"01";  constant K_F10 : std_logic_vector(7 downto 0) := x"09";
   constant K_F11 : std_logic_vector(7 downto 0) := x"78";  constant K_F12 : std_logic_vector(7 downto 0) := x"07";
   constant K_COMMA  : std_logic_vector(7 downto 0) := x"41";  constant K_DOT    : std_logic_vector(7 downto 0) := x"49";
   constant K_SLASH  : std_logic_vector(7 downto 0) := x"4A";  constant K_SEMI   : std_logic_vector(7 downto 0) := x"4C";
   constant K_MINUS  : std_logic_vector(7 downto 0) := x"4E";  constant K_EQUAL  : std_logic_vector(7 downto 0) := x"55";
   constant K_QUOTE  : std_logic_vector(7 downto 0) := x"52";  constant K_LBRK   : std_logic_vector(7 downto 0) := x"54";
   constant K_RBRK   : std_logic_vector(7 downto 0) := x"5B";  constant K_BSLASH : std_logic_vector(7 downto 0) := x"5D";
   constant K_GRAVE  : std_logic_vector(7 downto 0) := x"0E";
   -- extended (E0-prefixed)
   constant K_UP    : std_logic_vector(7 downto 0) := x"75";  constant K_DOWN  : std_logic_vector(7 downto 0) := x"72";
   constant K_LEFT  : std_logic_vector(7 downto 0) := x"6B";  constant K_RIGHT : std_logic_vector(7 downto 0) := x"74";
   constant K_HOME  : std_logic_vector(7 downto 0) := x"6C";  constant K_INS   : std_logic_vector(7 downto 0) := x"70";
   constant K_DEL   : std_logic_vector(7 downto 0) := x"71";  constant K_RALT  : std_logic_vector(7 downto 0) := x"11";

   -- layout: entry for (key, physical shift state)
   function translate(key : integer; shift : boolean; mega : boolean) return entry_t is
   begin
      case key is
         when m65_a => return E(K_A); when m65_b => return E(K_B); when m65_c => return E(K_C);
         when m65_d => return E(K_D); when m65_e => return E(K_E); when m65_f => return E(K_F);
         when m65_g => return E(K_G); when m65_h => return E(K_H); when m65_i => return E(K_I);
         when m65_j => return E(K_J); when m65_k => return E(K_K); when m65_l => return E(K_L);
         when m65_m => return E(K_M); when m65_n => return E(K_N); when m65_o => return E(K_O);
         when m65_p => return E(K_P); when m65_q => return E(K_Q); when m65_r => return E(K_R);
         when m65_s => return E(K_S); when m65_t => return E(K_T); when m65_u => return E(K_U);
         when m65_v => return E(K_V); when m65_w => return E(K_W); when m65_x => return E(K_X);
         when m65_y => return E(K_Y); when m65_z => return E(K_Z);

         -- digit row: MEGA65 shifted legends ! " # $ % & ' ( ) differ from a US PC
         when m65_1 => return E(K_1);
         when m65_2 => if shift then return SH_ON(K_QUOTE); else return E(K_2); end if;
         when m65_3 => return E(K_3);
         when m65_4 => return E(K_4);
         when m65_5 => return E(K_5);
         when m65_6 => if shift then return SH_ON(K_7);     else return E(K_6); end if;   -- &
         when m65_7 => if shift then return SH_OFF(K_QUOTE); else return E(K_7); end if;  -- '
         when m65_8 => if shift then return SH_ON(K_9);     else return E(K_8); end if;   -- (
         when m65_9 => if shift then return SH_ON(K_0);     else return E(K_9); end if;   -- )
         when m65_0 => return E(K_0);

         when m65_space      => return E(K_SPACE);
         when m65_return     => return E(K_ENTER);
         when m65_tab        => return E(K_TAB);
         when m65_esc        => return E(K_ESC);
         when m65_run_stop   => return E(K_ESC);
         when m65_left_shift => return E(K_LSHIFT);
         when m65_right_shift=> return E(K_RSHIFT);
         when m65_ctrl       => return E(K_LCTRL);
         when m65_mega       => return E(K_LALT);
         when m65_alt        => return X(K_RALT);
         when m65_capslock   => return E(K_CAPS);
         when m65_no_scrl    => return E(K_SCRL);
         -- HELP belongs to the framework (options menu). It must not reach the
         -- core: the chipset toggles its F12 pause on the break code, which halts
         -- the CPU and swallows every key. F12 is Shift+F11.
         when m65_help       => return NONE;

         when m65_ins_del    => if mega then return SH_XOFF(K_DEL); elsif shift then return SH_XOFF(K_INS); else return E(K_BKSP); end if;
         when m65_clr_home   => return X(K_HOME);
         when m65_up_crsr    => return X(K_UP);
         when m65_vert_crsr  => return X(K_DOWN);
         when m65_left_crsr  => return X(K_LEFT);
         when m65_horz_crsr  => return X(K_RIGHT);

         when m65_f1  => if shift then return SH_OFF(K_F2);  else return E(K_F1);  end if;
         when m65_f3  => if shift then return SH_OFF(K_F4);  else return E(K_F3);  end if;
         when m65_f5  => if shift then return SH_OFF(K_F6);  else return E(K_F5);  end if;
         when m65_f7  => if shift then return SH_OFF(K_F8);  else return E(K_F7);  end if;
         when m65_f9  => if shift then return SH_OFF(K_F10); else return E(K_F9);  end if;
         when m65_f11 => if shift then return SH_OFF(K_F12); else return E(K_F11); end if;

         when m65_comma     => return E(K_COMMA);
         when m65_dot       => return E(K_DOT);
         when m65_slash     => return E(K_SLASH);
         when m65_minus     => return E(K_MINUS);
         when m65_equal     => return E(K_EQUAL);                                            -- shift gives +
         when m65_plus      => return SH_ON(K_EQUAL);
         when m65_colon     => if shift then return SH_OFF(K_LBRK);   else return SH_ON(K_SEMI);  end if;
         when m65_semicolon => if shift then return SH_OFF(K_RBRK);   else return SH_OFF(K_SEMI); end if;
         when m65_at        => if shift then return SH_ON(K_LBRK);    else return SH_ON(K_2);     end if;
         when m65_asterisk  => if shift then return SH_ON(K_RBRK);    else return SH_ON(K_8);     end if;
         when m65_gbp       => if shift then return SH_OFF(K_BSLASH); else return SH_ON(K_3);     end if;
         when m65_arrow_left=> if shift then return SH_ON(K_GRAVE);   else return SH_OFF(K_GRAVE); end if;
         when m65_arrow_up  => if shift then return SH_ON(K_BSLASH);  else return SH_ON(K_6);     end if;

         when others => return NONE;
      end case;
   end function;

   -- scan state
   signal pressed        : std_logic_vector(79 downto 0) := (others => '0');
   signal key_num_q      : integer range 0 to 79 := 0;
   signal key_pressed_q  : std_logic := '0';

   -- event being processed
   --   SHIFT_FIX  make of a key with a forced shift state: bring the PC's shift
   --              to the wanted state (one make, or one break per PC shift key)
   --   FIX/FIX2   queue one shift make (code) or break (F0 code), then go on
   --              to fix_next
   --   RESTORE    after the release of the key that forced the shift state:
   --              bring the PC's shift keys back to the physical ones
   type ev_state_t is (IDLE, LOOKUP, SHIFT_FIX, FIX, FIX2, PREFIX, CODE, DONE, RESTORE);
   signal ev_state       : ev_state_t := IDLE;
   signal ev_key         : integer range 0 to 79 := 0;
   signal ev_make        : std_logic := '0';
   signal ev_entry       : entry_t := NONE;
   signal ev_want_shift  : boolean := false;
   signal ev_release_sub : natural range 0 to 2 := 0;
   signal fix_code       : std_logic_vector(7 downto 0) := K_LSHIFT;
   signal fix_make       : boolean := false;
   signal fix_next       : ev_state_t := IDLE;

   -- per-key remembered translation, so a release sends the break of what
   -- the press sent even if the modifiers changed meanwhile
   type entry_arr_t is array (0 to 79) of entry_t;
   signal sent_entry     : entry_arr_t := (others => NONE);

   signal phys_shift     : boolean;
   -- the PC's view of its shift keys, and the shift state it derives from them
   signal pc_lshift      : boolean := false;
   signal pc_rshift      : boolean := false;
   signal emitted_shift  : boolean;
   -- the key (if any) whose forced shift state is in effect
   signal override_key   : integer range 0 to 79 := 0;
   signal override_on    : boolean := false;

   -- transmitter queue
   signal tx_data        : std_logic_vector(7 downto 0);
   signal tx_we          : std_logic := '0';
   signal tx_full        : std_logic;

   signal key_toggle     : std_logic := '0';
   signal key_word       : std_logic_vector(10 downto 0) := (others => '0');

begin

   phys_shift    <= pressed(m65_left_shift) = '1' or pressed(m65_right_shift) = '1';
   emitted_shift <= pc_lshift or pc_rshift;

   ---------------------------------------------------------------------------
   -- Scan: sample the framework's 1 kHz scan and raise one event per edge.
   -- Events are consumed faster than the scan produces them (one key per ms,
   -- a few bytes per event at 12.5 kHz), so a one-deep pending slot is enough.
   ---------------------------------------------------------------------------
   p_scan_and_translate : process (clk_main_i)
      variable now_pressed : std_logic;
      variable ent         : entry_t;
   begin
      if rising_edge(clk_main_i) then
         tx_we <= '0';
         key_num_q     <= key_num_i;
         key_pressed_q <= not key_pressed_n_i;

         case ev_state is
            when IDLE =>
               now_pressed := key_pressed_q;
               if now_pressed /= pressed(key_num_q) then
                  pressed(key_num_q) <= now_pressed;
                  ev_key   <= key_num_q;
                  ev_make  <= now_pressed;
                  ev_state <= LOOKUP;
               end if;

            when LOOKUP =>
               if ev_make = '1' then
                  ent := translate(ev_key, phys_shift, pressed(m65_mega) = '1');
                  sent_entry(ev_key) <= ent;
               else
                  ent := sent_entry(ev_key);
               end if;
               ev_entry <= ent;
               if ent = NONE then
                  ev_state <= DONE;
               elsif ev_make = '1' and ent.shift /= KEEP then
                  -- this key needs a definite PC shift state: force it, and
                  -- undo that when the key is released
                  ev_want_shift <= ent.shift = S_ON;
                  override_on   <= true;
                  override_key  <= ev_key;
                  ev_state      <= SHIFT_FIX;
               else
                  -- everything else, the physical shift keys included, passes
                  -- straight through (CODE keeps the PC model in step with a
                  -- shift key's make and break alike)
                  ev_state <= PREFIX;
               end if;

            when SHIFT_FIX =>
               if ev_want_shift and not emitted_shift then
                  fix_code <= K_LSHIFT; fix_make <= true;  fix_next <= PREFIX;    ev_state <= FIX;
               elsif not ev_want_shift and pc_lshift then
                  fix_code <= K_LSHIFT; fix_make <= false; fix_next <= SHIFT_FIX; ev_state <= FIX;
               elsif not ev_want_shift and pc_rshift then
                  fix_code <= K_RSHIFT; fix_make <= false; fix_next <= SHIFT_FIX; ev_state <= FIX;
               else
                  ev_state <= PREFIX;
               end if;

            when FIX =>
               -- a shift make, or the first byte of a shift break
               if tx_full = '0' then
                  if fix_make then
                     tx_data <= fix_code; tx_we <= '1';
                     if fix_code = K_LSHIFT then pc_lshift <= true; else pc_rshift <= true; end if;
                     ev_state <= fix_next;
                  else
                     tx_data <= x"F0"; tx_we <= '1';
                     ev_state <= FIX2;
                  end if;
               end if;

            when FIX2 =>
               -- second byte of a shift break
               if tx_full = '0' then
                  tx_data <= fix_code; tx_we <= '1';
                  if fix_code = K_LSHIFT then pc_lshift <= false; else pc_rshift <= false; end if;
                  ev_state <= fix_next;
               end if;

            when PREFIX =>
               if tx_full = '0' then
                  if ev_entry.ext then
                     tx_data <= x"E0"; tx_we <= '1';          -- E0 [F0] code
                     if ev_make = '0' then ev_release_sub <= 2; else ev_release_sub <= 0; end if;
                  elsif ev_make = '0' then
                     tx_data <= x"F0"; tx_we <= '1';          -- F0 code
                     ev_release_sub <= 0;
                  else
                     ev_release_sub <= 0;
                  end if;
                  ev_state <= CODE;
               end if;

            when CODE =>
               if tx_full = '0' then
                  if ev_release_sub = 2 then
                     tx_data <= x"F0"; tx_we <= '1';          -- the F0 of E0 F0 code
                     ev_release_sub <= 0;
                  else
                     tx_data <= ev_entry.code; tx_we <= '1';
                     -- a physical shift key: the PC's view follows the byte
                     if not ev_entry.ext then
                        if ev_entry.code = K_LSHIFT then pc_lshift <= ev_make = '1'; end if;
                        if ev_entry.code = K_RSHIFT then pc_rshift <= ev_make = '1'; end if;
                     end if;
                     ev_state <= DONE;
                  end if;
               end if;

            when DONE =>
               -- MiSTer ps2_key event word for the splash/F12 logic
               if ev_entry /= NONE then
                  key_toggle <= not key_toggle;
                  if ev_entry.ext then
                     key_word <= (not key_toggle) & ev_make & '1' & ev_entry.code;
                  else
                     key_word <= (not key_toggle) & ev_make & '0' & ev_entry.code;
                  end if;
               end if;
               -- a release of the key that forced a shift state: put the PC's
               -- shift keys back to the physical ones
               if ev_make = '0' and override_on and ev_key = override_key then
                  override_on <= false;
                  ev_state    <= RESTORE;
               else
                  ev_state <= IDLE;
               end if;

            when RESTORE =>
               if (pressed(m65_left_shift) = '1') /= pc_lshift then
                  fix_code <= K_LSHIFT; fix_make <= pressed(m65_left_shift) = '1';  fix_next <= RESTORE; ev_state <= FIX;
               elsif (pressed(m65_right_shift) = '1') /= pc_rshift then
                  fix_code <= K_RSHIFT; fix_make <= pressed(m65_right_shift) = '1'; fix_next <= RESTORE; ev_state <= FIX;
               else
                  ev_state <= IDLE;
               end if;
         end case;

         if rst_i = '1' then
            pressed       <= (others => '0');
            ev_state      <= IDLE;
            pc_lshift     <= false;
            pc_rshift     <= false;
            override_on   <= false;
            tx_we         <= '0';
            key_toggle    <= '0';
            key_word      <= (others => '0');
         end if;
      end if;
   end process;

   i_ps2_tx : entity work.ps2_tx
      port map (
         clk_i       => clk_main_i,
         rst_i       => rst_i,
         data_i      => tx_data,
         we_i        => tx_we,
         full_o      => tx_full,
         empty_o     => open,
         host_clk_i  => ps2_host_clk_i,
         host_data_i => ps2_host_data_i,
         ps2_clk_o   => ps2_clk_o,
         ps2_data_o  => ps2_data_o
      );

   ps2_key_o <= key_word;

end architecture beh;
