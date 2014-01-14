library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;
use Std.TextIO.all;

entity uart_monitor is
  port (
    reset : in std_logic;
    clock : in std_logic;
    tx : out std_logic;
    rx : in  std_logic;
    activity : out std_logic;

    monitor_mem_address : out std_logic_vector(27 downto 0);
    monitor_mem_rdata : in unsigned(7 downto 0);
    monitor_mem_wdata : out unsigned(7 downto 0);
    monitor_mem_register : in unsigned(15 downto 0);
    monitor_mem_read : out std_logic := '0';
    monitor_mem_write : out std_logic := '0';
    monitor_mem_ready_toggle : in std_logic
    );
end uart_monitor;

architecture behavioural of uart_monitor is
  component UART_TX_CTRL is
    Port ( SEND : in  STD_LOGIC;
           DATA : in  STD_LOGIC_VECTOR (7 downto 0);
           CLK : in  STD_LOGIC;
           READY : out  STD_LOGIC;
           UART_TX : out  STD_LOGIC);
  end component;

  component uart_rx is
    Port ( clk : in  STD_LOGIC;
           UART_RX : in  STD_LOGIC;
           data : out  STD_LOGIC_VECTOR (7 downto 0);
           data_ready : out std_logic;
           data_acknowledge : in std_logic
           );
  end component;

-- raise for one cycle when we have a byte ready to send.
-- should only be asserted when tx_ready='1'.
  signal tx_trigger : std_logic := '0';
-- the byte to send.
  signal tx_data : std_logic_vector(7 downto 0);
-- indicates that uart is ready to TX the next byte.
  signal tx_ready : std_logic;

  signal rx_data : std_logic_vector(7 downto 0);
  signal rx_ready : std_logic;
  signal rx_acknowledge : std_logic := '0';

-- Counter for slow clock derivation (for testing at least)
  signal counter : unsigned(31 downto 0) := (others => '0');
  signal tx_counter : std_logic;

  signal blink : std_logic := '1';

-- Buffer to hold entered command
  signal cmdbuffer : String(1 to 64);
  signal cmdlen : integer := 0;
  signal redraw_position : integer;

  constant crlf : string := cr & lf;
  constant bannerMessage : String :=
    crlf &
    crlf &
    "--------------------------------" & crlf &
    "65GS Serial Monitor" & crlf &
    "---------------------------------" & crlf &
    "Type ? for help." & crlf;
  signal banner_position : integer := 1;
  constant helpMessage : String :=
    "?                       - Display this help" & crlf &
    "r                       - Print processor state." & crlf &
    "s <address> <value>     - Set memory." & crlf &
    "m <address>             - Display contents of memory" & crlf;

  constant errorMessage : string := crlf & "? SYNTAX  ERROR" & crlf;
  
  type monitor_state is (Reseting,
                         PrintBanner,PrintHelp,PrintError,PrintError2,
                         NextCommand,NextCommand2,PrintPrompt,
                         AcceptingInput,
                         RedrawInputBuffer,RedrawInputBuffer2,RedrawInputBuffer3,
                         EnterPressed,EnterPressed2,EnterPressed3,
                         EraseInputBuffer,EraseInputBuffer2,
                         SyntaxError,
                         ParseHex,
                         PrintHex,
                         SetMemory1,SetMemory2,SetMemory3,SetMemory4,SetMemory5,
                         SetMemory6,SetMemory7,SetMemory8,SetMemory9,
                         ShowMemory1,ShowMemory2,ShowMemory3,ShowMemory4,
                         ShowMemory5,ShowMemory6,ShowMemory7
                         );
  signal state : monitor_state := Reseting;

  -- For parsing commands
  signal parse_position : integer;
  signal hex_value : unsigned(31 downto 0);
  signal target_address : unsigned(27 downto 0);
  signal target_value : unsigned(7 downto 0);
  signal hex_digits_read : integer;
  signal hex_digits_output : integer;
  signal success_state : monitor_state;

  type sixteenbytes is array (0 to 15) of unsigned(7 downto 0);
  signal membuf : sixteenbytes;
  signal byte_number : integer;
  
begin

  uart_tx0: uart_tx_ctrl
    port map (
      send    => tx_trigger,
      clk     => clock,
      data    => tx_data,
      ready   => tx_ready,
      uart_tx => tx);

  uart_rx0: uart_rx 
    Port map ( clk => clock,
               UART_RX => rx,
               data => rx_data,
               data_ready => rx_ready,
               data_acknowledge => rx_acknowledge);

  -- purpose: test uart output
  testclock: process (clock)
    -- purpose: turn character into std_logic_vector(7 downto 0)
    function to_std_logic_vector (
      c : character)
      return std_logic_vector is
      variable i : integer := character'pos(c);
      variable u : unsigned(7 downto 0) := to_unsigned(i,8);
    begin  -- to_std_logic_vector
      return std_logic_vector(u);
    end to_std_logic_vector;

    -- purpose: convert ascii value in a std_logic_vector to a VHDL character
    function to_character (
      v : std_logic_vector(7 downto 0))
      return character is
    begin  -- to_character
      return character'val(to_integer(unsigned(v)));   
    end to_character;
    
    -- purpose: Process a character typed by the user.
    procedure character_received (char : in character) is
    begin  -- character_received
      if (char >= ' ' and char < del) or char > c159 then
        if cmdlen<63 then
          -- Echo character back to user
          tx_data <= to_std_logic_vector(char);
          tx_trigger <= '1';
          -- Append to input buffer
          cmdbuffer(cmdlen) <= char;
          cmdlen <= cmdlen + 1;
        else
          -- Input buffer full, so ring bell.
          tx_data <= to_std_logic_vector(bel);
          tx_trigger <= '1';
        end if;
      else
        -- Non-printable character, for now print ?
        case char is
          when dc2 =>
            -- Redraw line
            redraw_position <= 1;
            state <= RedrawInputBuffer;
          when nak =>
            -- Erase line
            state <= EraseInputBuffer;            
          when bs =>
            if cmdlen>1 then
              -- Delete character from end of line
              tx_data <= to_std_logic_vector(del);
              tx_trigger <= '1';                    
              cmdlen <= cmdlen - 1;
            end if;
          when del =>
            if cmdlen>1 then
              -- Delete character from end of line
              tx_data <= to_std_logic_vector(del);
              tx_trigger <= '1';                    
              cmdlen <= cmdlen - 1;
            end if;
          when cr => state <= EnterPressed;
          when lf => state <= EnterPressed;
          when others =>
            tx_data <= to_std_logic_vector(bel);
            tx_trigger <= '1';                    
        end case;
      end if;
    end character_received;

    -- purpose: If we can write a character, do so and advance the state
    procedure try_output_char (
      char       : in character;
      next_state : in monitor_state) is
    begin  -- try_output_char
      if tx_ready='1' then
        tx_data <= to_std_logic_vector(char);
        tx_trigger <= '1';
        state <= next_state;
      end if;
    end try_output_char;

    -- purpose: output a hex string
    procedure print_hex (
      value      : in unsigned(31 downto 0);
      digits     : in integer;
      next_state : in monitor_state) is
    begin  -- print_hex
      hex_value <= value;
      hex_digits_read <= digits;
      hex_digits_output <= 0;
      success_state <= next_state;
      state <= PrintHex;
    end print_hex;
    procedure print_hex_addr (
      value      : in unsigned(27 downto 0);
      next_state : in monitor_state) is
    begin  -- print_hex
      print_hex(value & x"0",7,next_state);
    end print_hex_addr;
    procedure print_hex_byte (
      value      : in unsigned(7 downto 0);
      next_state : in monitor_state) is
    begin  -- print_hex
      print_hex(value & x"000000",2,next_state);
    end print_hex_byte;
    
    -- purpose: accept one hex digit
    procedure got_hex_digit (
      digit : in unsigned(3 downto 0)) is
    begin  -- got_hex_digit
      if hex_digits_read=8 then
        state <= SyntaxError;
      end if;
      hex_value <= hex_value(27 downto 0) & digit;
      hex_digits_read <= hex_digits_read + 1;
    end got_hex_digit;
    -- purpose: parse a hex digit
    procedure parse_hex_digit is
    begin  -- parse_hex_digit
      if parse_position>=cmdlen then
        if hex_digits_read = 0 then
          -- If we reach end of command and have parsed no digit, it's an error
          state <= SyntaxError;
        end if;
      else
        case cmdbuffer(cmdlen) is
          when '0' => got_hex_digit(x"0"); when '1' => got_hex_digit(x"1");
          when '2' => got_hex_digit(x"2"); when '3' => got_hex_digit(x"3");
          when '4' => got_hex_digit(x"4"); when '5' => got_hex_digit(x"5");
          when '6' => got_hex_digit(x"6"); when '7' => got_hex_digit(x"7");
          when '8' => got_hex_digit(x"8"); when '9' => got_hex_digit(x"9");
          when 'a' => got_hex_digit(x"a"); when 'A' => got_hex_digit(x"a");
          when 'b' => got_hex_digit(x"b"); when 'B' => got_hex_digit(x"b");
          when 'c' => got_hex_digit(x"c"); when 'C' => got_hex_digit(x"c");
          when 'd' => got_hex_digit(x"d"); when 'D' => got_hex_digit(x"d");
          when 'e' => got_hex_digit(x"e"); when 'E' => got_hex_digit(x"e");
          when 'f' => got_hex_digit(x"f"); when 'F' => got_hex_digit(x"f");
          when others =>
            if hex_digits_read = 0 then
              state <= SyntaxError;
            else
              state <= success_state;
            end if;
        end case;
      end if;
    end parse_hex_digit;

    function hex_char (
      nybl : unsigned(3 downto 0))
      return character is
    begin
      case nybl is
        when x"0" => return '0'; when x"1" => return '1';
        when x"2" => return '2'; when x"3" => return '3';
        when x"4" => return '4'; when x"5" => return '5';
        when x"6" => return '6'; when x"7" => return '7';
        when x"8" => return '8'; when x"9" => return '9';
        when x"a" => return 'A'; when x"b" => return 'B';
        when x"c" => return 'C'; when x"d" => return 'D';
        when x"e" => return 'E'; when x"f" => return 'F';
        when others => return '?';
      end case;
    end hex_char;
    
    -- purpose: parse a hex string from the command buffer
    procedure parse_hex (
      next_state : in monitor_state) is
    begin  -- parse_hex
      success_state <= next_state;
      state <= ParseHex;
      hex_value <= (others => '0');
      hex_digits_read <= 0;
      parse_hex_digit;
    end parse_hex;

    -- purpose: skip one space in command buffer
    procedure skip_space (
      next_state : monitor_state) is
    begin  -- skip_space
      if parse_position<cmdlen and cmdbuffer(parse_position)=' ' then
        parse_position <= parse_position + 1;
        state <= next_state;
      else
        state <= SyntaxError;
      end if;
    end skip_space;

    -- purpose: succeed if at end of command
    procedure end_of_command (
      next_state : monitor_state) is
    begin
      if parse_position>=cmdlen then
        state <= next_state;
      else
        state <= SyntaxError;
      end if;
    end end_of_command;

  begin  -- process testclock
    if reset='0' then
      state <= Reseting;      
    elsif rising_edge(clock) then
      -- Update counter and clear outputs
      counter <= counter + 1;
      tx_counter <= std_logic(counter(27));
      rx_acknowledge <= '0';
      tx_trigger<='0';

      -- 1 cycle delay after sending characters
      if tx_trigger/='1' then      
        -- General state machine
        case state is
          when Reseting =>
            banner_position <= 1;
            state <= PrintBanner;
          when PrintHelp =>
            if tx_ready='1' then
              tx_data <= to_std_logic_vector(helpMessage(banner_position));
              tx_trigger <= '1';
              if banner_position<helpMessage'length then
                banner_position <= banner_position + 1;
              else
                state <= PrintPrompt;
                cmdlen <= 1;
              end if;
            end if;
          when PrintBanner =>
            if tx_ready='1' then
              tx_data <= to_std_logic_vector(bannerMessage(banner_position));
              tx_trigger <= '1';
              if banner_position<bannerMessage'length then
                banner_position <= banner_position + 1;
              else
                state <= PrintPrompt;
                cmdlen <= 1;
              end if;
            end if;
          when PrintError =>
            if tx_ready='1' then
              tx_data <= to_std_logic_vector(errorMessage(banner_position));
              tx_trigger <= '1';
              if banner_position<errorMessage'length then
                banner_position <= banner_position + 1;
              else
                state <= PrintError2;
              end if;
            end if;
          when PrintError2 =>
            if parse_position<cmdlen then
              if tx_ready='1' then
                try_output_char(cmdbuffer(parse_position),PrintError2);
              end if;
            else
              state <= NextCommand;
            end if;
          when NextCommand => cmdlen <= 1; try_output_char(cr,NextCommand2);
          when NextCommand2 => try_output_char(lf,PrintPrompt);
          when PrintPrompt => try_output_char('.',AcceptingInput);
          when AcceptingInput =>
            -- If there is a character waiting
            if rx_ready = '1' and rx_acknowledge='0' then
              blink <= not blink;
              activity <= blink;
              rx_acknowledge<='1';
              character_received(to_character(rx_data));
            end if;
          when RedrawInputBuffer => try_output_char(cr,RedrawInputBuffer2);
          when RedrawInputBuffer2 => try_output_char('.',RedrawInputBuffer3);
          when RedrawInputBuffer3 =>
            if redraw_position<cmdlen then
              try_output_char(cmdbuffer(redraw_position),RedrawInputBuffer3);
              redraw_position <= redraw_position + 1;
            else
              state <= AcceptingInput;
            end if;
          when EraseInputBuffer => redraw_position<=1; try_output_char(cr,EraseInputBuffer2);
          when EraseInputBuffer2 =>
            if redraw_position<cmdlen then
              try_output_char(' ',EraseInputBuffer2);
              redraw_position <= redraw_position + 1;
            else
              cmdlen <= 1;
              try_output_char(cr,PrintPrompt);
            end if;
          when EnterPressed => try_output_char(cr,EnterPressed2);
          when EnterPressed2 => try_output_char(lf,EnterPressed3);
          when EnterPressed3 =>
            if cmdlen>1 then
              if (cmdbuffer(1) = 'h' or cmdbuffer(1) = 'H' or cmdbuffer(1) = '?') then
                banner_position <= 1;
                state <= PrintHelp;
              elsif cmdbuffer(1) = 's' or cmdbuffer(1) = 'S' then
                parse_position <= 2;
                parse_hex(SetMemory1);
              elsif cmdbuffer(1) = 'm' or cmdbuffer(1) = 'M' then
                parse_position <= 2;
                parse_hex(ShowMemory1);
              else
                state <= SyntaxError;
              end if;
            else
              cmdlen <= 1;
              state <= PrintPrompt;
            end if;
          when SetMemory1 => target_address <= hex_value(27 downto 0);
                             skip_space(SetMemory2);
          when SetMemory2 => parse_hex(SetMemory3);
          when SetMemory3 => target_value <= hex_value(7 downto 0);
                             end_of_command(SetMemory4);
          when SetMemory4 =>
            -- Set contents of memory location <target_address> to <target_value>
            -- XXX Not implemented
            try_output_char('=',SetMemory5);
          when SetMemory5 => print_hex_addr(target_address,SetMemory5);
          when SetMemory6 => try_output_char(' ',SetMemory7);
          when SetMemory7 => print_hex_byte(target_value,NextCommand);            
          when ParseHex => parse_hex_digit;
          when PrintHex =>
            if hex_digits_output<hex_digits_read then
              if tx_ready='1' then
                try_output_char(hex_char(hex_value(31 downto 28)),PrintHex);
                hex_digits_output <= hex_digits_output + 1;
                hex_value <= hex_value(27 downto 0) & x"0";
              end if;
            else
              state <= success_state;
            end if;
          when ShowMemory1 =>
            -- XXX Need to actually read memory from the CPU
            target_address <= hex_value(27 downto 0);
            end_of_command(ShowMemory2);
          when ShowMemory2 => print_hex_addr(target_address,ShowMemory3);
          when ShowMemory3 => try_output_char(' ',ShowMemory4);
          when ShowMemory4 => try_output_char(':',ShowMemory5); byte_number <= 0;
          when ShowMemory5 => print_hex_addr(target_address,ShowMemory6);
          when ShowMemory6 =>
            if byte_number = 16 then
              state<=NextCommand;
            else
              try_output_char(' ',ShowMemory7);
            end if;
          when ShowMemory7 =>
            byte_number <= byte_number + 1;
            print_hex_byte(membuf(byte_number),ShowMemory6);
          when SyntaxError =>
            banner_position <= 1; state <= PrintError;
          when others => null;
        end case;
      end if;
    end if;
  end process testclock;
  
end behavioural;
