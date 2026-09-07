--------------------------------------------------------------------------------
-- MEGA65 overlay for PCXT-EGA_MiSTer/rtl/common/bram.vhd
--
-- The upstream file wraps Altera altsyncram. This file keeps the same five
-- entity names, generics and ports, but describes the memories behaviourally
-- so Vivado infers block RAM. Semantics kept from the original:
--   * synchronous read, unregistered output (data appears one clock after
--     the address);
--   * read-during-write on the same port returns the new data
--     (NEW_DATA_NO_NBE_READ, i.e. write-first);
--   * the q output is forced to all ones while cs is low;
--   * enable_x is a clock enable for the whole port.
-- mem_init_file is accepted but ignored: nothing in the core initialises
-- these RAMs from a file (ide.v is the only user, with dpram #(12,16)).
-- dpram_dif and dpram_difclk require equal widths on both ports; no user in
-- the core needs the mixed-width form.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity spram_sz is
    generic (
        addr_width    : integer := 8;
        data_width    : integer := 8;
        numwords      : integer := 2**8;
        mem_init_file : string  := " ";
        mem_name      : string  := "MEM"
    );
    port (
        clock   : in  std_logic;
        address : in  std_logic_vector(addr_width-1 downto 0);
        data    : in  std_logic_vector(data_width-1 downto 0) := (others => '0');
        enable  : in  std_logic := '1';
        wren    : in  std_logic := '0';
        q       : out std_logic_vector(data_width-1 downto 0);
        cs      : in  std_logic := '1'
    );
end entity;

architecture rtl of spram_sz is
    type mem_t is array (0 to numwords-1) of std_logic_vector(data_width-1 downto 0);
    signal mem : mem_t;
    signal q0  : std_logic_vector(data_width-1 downto 0);
begin
    process (clock)
    begin
        if rising_edge(clock) then
            if enable = '1' then
                if (wren and cs) = '1' then
                    mem(to_integer(unsigned(address))) <= data;
                    q0 <= data;
                else
                    q0 <= mem(to_integer(unsigned(address)));
                end if;
            end if;
        end if;
    end process;
    q <= q0 when cs = '1' else (others => '1');
end architecture;


library ieee;
use ieee.std_logic_1164.all;

entity spram is
    generic (
        addr_width    : integer := 8;
        data_width    : integer := 8;
        mem_init_file : string  := " ";
        mem_name      : string  := "MEM"
    );
    port (
        clock   : in  std_logic;
        address : in  std_logic_vector(addr_width-1 downto 0);
        data    : in  std_logic_vector(data_width-1 downto 0) := (others => '0');
        enable  : in  std_logic := '1';
        wren    : in  std_logic := '0';
        q       : out std_logic_vector(data_width-1 downto 0);
        cs      : in  std_logic := '1'
    );
end entity;

architecture rtl of spram is
begin
    u : entity work.spram_sz
        generic map (addr_width, data_width, 2**addr_width, mem_init_file, mem_name)
        port map (clock, address, data, enable, wren, q, cs);
end architecture;


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dpram_difclk is
    generic (
        addr_width_a  : integer := 8;
        data_width_a  : integer := 8;
        addr_width_b  : integer := 8;
        data_width_b  : integer := 8;
        mem_init_file : string  := " "
    );
    port (
        clk_a     : in  std_logic;
        clk_b     : in  std_logic;
        address_a : in  std_logic_vector(addr_width_a-1 downto 0);
        data_a    : in  std_logic_vector(data_width_a-1 downto 0) := (others => '0');
        enable_a  : in  std_logic := '1';
        wren_a    : in  std_logic := '0';
        q_a       : out std_logic_vector(data_width_a-1 downto 0);
        cs_a      : in  std_logic := '1';
        address_b : in  std_logic_vector(addr_width_b-1 downto 0) := (others => '0');
        data_b    : in  std_logic_vector(data_width_b-1 downto 0) := (others => '0');
        enable_b  : in  std_logic := '1';
        wren_b    : in  std_logic := '0';
        q_b       : out std_logic_vector(data_width_b-1 downto 0);
        cs_b      : in  std_logic := '1'
    );
end entity;

architecture rtl of dpram_difclk is
    type mem_t is array (0 to 2**addr_width_a-1) of std_logic_vector(data_width_a-1 downto 0);
    shared variable mem : mem_t;
    signal q0 : std_logic_vector(data_width_a-1 downto 0);
    signal q1 : std_logic_vector(data_width_b-1 downto 0);
begin
    assert addr_width_a = addr_width_b and data_width_a = data_width_b
        report "dpram_difclk overlay: ports must have equal widths" severity failure;

    port_a : process (clk_a)
    begin
        if rising_edge(clk_a) then
            if enable_a = '1' then
                if (wren_a and cs_a) = '1' then
                    mem(to_integer(unsigned(address_a))) := data_a;
                    q0 <= data_a;
                else
                    q0 <= mem(to_integer(unsigned(address_a)));
                end if;
            end if;
        end if;
    end process;

    port_b : process (clk_b)
    begin
        if rising_edge(clk_b) then
            if enable_b = '1' then
                if (wren_b and cs_b) = '1' then
                    mem(to_integer(unsigned(address_b))) := data_b;
                    q1 <= data_b;
                else
                    q1 <= mem(to_integer(unsigned(address_b)));
                end if;
            end if;
        end if;
    end process;

    q_a <= q0 when cs_a = '1' else (others => '1');
    q_b <= q1 when cs_b = '1' else (others => '1');
end architecture;


library ieee;
use ieee.std_logic_1164.all;

entity dpram_dif is
    generic (
        addr_width_a  : integer := 8;
        data_width_a  : integer := 8;
        addr_width_b  : integer := 8;
        data_width_b  : integer := 8;
        mem_init_file : string  := " "
    );
    port (
        clock     : in  std_logic;
        address_a : in  std_logic_vector(addr_width_a-1 downto 0);
        data_a    : in  std_logic_vector(data_width_a-1 downto 0) := (others => '0');
        enable_a  : in  std_logic := '1';
        wren_a    : in  std_logic := '0';
        q_a       : out std_logic_vector(data_width_a-1 downto 0);
        cs_a      : in  std_logic := '1';
        address_b : in  std_logic_vector(addr_width_b-1 downto 0) := (others => '0');
        data_b    : in  std_logic_vector(data_width_b-1 downto 0) := (others => '0');
        enable_b  : in  std_logic := '1';
        wren_b    : in  std_logic := '0';
        q_b       : out std_logic_vector(data_width_b-1 downto 0);
        cs_b      : in  std_logic := '1'
    );
end entity;

architecture rtl of dpram_dif is
begin
    u : entity work.dpram_difclk
        generic map (addr_width_a, data_width_a, addr_width_b, data_width_b, mem_init_file)
        port map (clock, clock, address_a, data_a, enable_a, wren_a, q_a, cs_a,
                  address_b, data_b, enable_b, wren_b, q_b, cs_b);
end architecture;


library ieee;
use ieee.std_logic_1164.all;

entity dpram is
    generic (
        addr_width    : integer := 8;
        data_width    : integer := 8;
        mem_init_file : string  := " "
    );
    port (
        clock     : in  std_logic;
        address_a : in  std_logic_vector(addr_width-1 downto 0);
        data_a    : in  std_logic_vector(data_width-1 downto 0) := (others => '0');
        enable_a  : in  std_logic := '1';
        wren_a    : in  std_logic := '0';
        q_a       : out std_logic_vector(data_width-1 downto 0);
        cs_a      : in  std_logic := '1';
        address_b : in  std_logic_vector(addr_width-1 downto 0) := (others => '0');
        data_b    : in  std_logic_vector(data_width-1 downto 0) := (others => '0');
        enable_b  : in  std_logic := '1';
        wren_b    : in  std_logic := '0';
        q_b       : out std_logic_vector(data_width-1 downto 0);
        cs_b      : in  std_logic := '1'
    );
end entity;

architecture rtl of dpram is
begin
    u : entity work.dpram_dif
        generic map (addr_width, data_width, addr_width, data_width, mem_init_file)
        port map (clock, address_a, data_a, enable_a, wren_a, q_a, cs_a,
                  address_b, data_b, enable_b, wren_b, q_b, cs_b);
end architecture;
