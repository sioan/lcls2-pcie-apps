-------------------------------------------------------------------------------
-- File       : TDetSemi.vhd
-- Company    : SLAC National Accelerator Laboratory
-- Created    : 2017-10-26
-- Last update: 2018-09-05
-------------------------------------------------------------------------------
-- Description: TDetSemi File
-------------------------------------------------------------------------------
-- This file is part of 'axi-pcie-core'.
-- It is subject to the license terms in the LICENSE.txt file found in the 
-- top-level directory of this distribution and at: 
--    https://confluence.slac.stanford.edu/display/ppareg/LICENSE.html. 
-- No part of 'axi-pcie-core', including this file, 
-- may be copied, modified, propagated, or distributed except according to 
-- the terms contained in the LICENSE.txt file.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

use work.StdRtlPkg.all;

use work.AxiPkg.all;
use work.AxiLitePkg.all;
use work.AxiStreamPkg.all;
use work.SsiPkg.all;
use work.Pgp3Pkg.all;
use work.EventPkg.all;
use work.TDetPkg.all;

library unisim;
use unisim.vcomponents.all;

entity TDetSemi is
  generic (
    TPD_G            : time             := 1 ns;
    DEBUG_G          : boolean          := false );
  port (
    ------------------------      
    --  Top Level Interfaces
    ------------------------    
    -- AXI-Lite Interface
    axilClk         : in  sl;
    axilRst         : in  sl;
    axilReadMaster  : in  AxiLiteReadMasterType;
    axilReadSlave   : out AxiLiteReadSlaveType;
    axilWriteMaster : in  AxiLiteWriteMasterType;
    axilWriteSlave  : out AxiLiteWriteSlaveType;
    -- DMA Interface
    dmaClks         : out slv                 (3 downto 0);
    dmaRsts         : out slv                 (3 downto 0);
    dmaObMasters    : in  AxiStreamMasterArray(3 downto 0);
    dmaObSlaves     : out AxiStreamSlaveArray (3 downto 0);
    dmaIbMasters    : out AxiStreamMasterArray(3 downto 0);
    dmaIbSlaves     : in  AxiStreamSlaveArray (3 downto 0);
    dmaIbAlmostFull : in  slv                 (3 downto 0);
    dmaIbFull       : in  slv                 (3 downto 0);
    axiCtrl         : in  AxiCtrlType := AXI_CTRL_UNUSED_C;
    ---------------------
    --  TDetSemi Ports
    ---------------------
    tdetClk         : in  sl;
    tdetClkRst      : in  sl;
    tdetTiming      : out TDetTimingArray(3 downto 0);
    tdetEvent       : in  TDetEventArray (3 downto 0);
    tdetStatus      : in  TDetStatusArray(3 downto 0);
    modPrsL         : in  sl );
end TDetSemi;

architecture mapping of TDetSemi is

  constant NUM_LANES_C       : natural := 4;

  signal intObMasters     : AxiStreamMasterArray(NUM_LANES_C-1 downto 0);
  signal intObSlaves      : AxiStreamSlaveArray (NUM_LANES_C-1 downto 0);
  signal dmaObAlmostFull  : slv                 (NUM_LANES_C-1 downto 0) := (others=>'0');

  signal txOpCodeEn       : slv                 (NUM_LANES_C-1 downto 0);
  signal txOpCode         : Slv8Array           (NUM_LANES_C-1 downto 0);
  signal rxOpCodeEn       : slv                 (NUM_LANES_C-1 downto 0);
  signal rxOpCode         : Slv8Array           (NUM_LANES_C-1 downto 0);

  signal idmaClks         : slv                 (NUM_LANES_C-1 downto 0);
  signal idmaRsts         : slv                 (NUM_LANES_C-1 downto 0);

  signal sAxisCtrl : AxiStreamCtrlArray(NUM_LANES_C-1 downto 0) := (others=>AXI_STREAM_CTRL_UNUSED_C);

  type AxiRegType is record
    id        : slv(31 downto 0);
    partition : slv( 2 downto 0);
    enable    : sl;
    clear     : sl;
    length    : slv(23 downto 0);
    axilWriteSlave  : AxiLiteWriteSlaveType;
    axilReadSlave   : AxiLiteReadSlaveType;
  end record;
  constant AXI_REG_INIT_C : AxiRegType := (
    id        => (others=>'0'),
    partition => (others=>'0'),
    enable    => '0',
    clear     => '0',
    length    => (others=>'0'),
    axilWriteSlave => AXI_LITE_WRITE_SLAVE_INIT_C,
    axilReadSlave  => AXI_LITE_READ_SLAVE_INIT_C );

  signal a    : AxiRegType := AXI_REG_INIT_C;
  signal ain  : AxiRegType;
  signal as   : AxiRegType;
  
  signal statusv, vstatus : Slv117Array    (NUM_LANES_C-1 downto 0);
  signal status           : TDetStatusArray(NUM_LANES_C-1 downto 0);

  type StateType is (IDLE_S,
                     WAIT_S,
                     HDR1_S,
                     HDR2_S,
                     HDR3_S,
                     SEND_S);
  type StateArray is array(natural range<>) of StateType;
  
  type RegType is record
    state    : StateType;
    length   : slv(23 downto 0);
    count    : slv(31 downto 0);
    inc      : sl;
    ack      : sl;
    txMaster : AxiStreamMasterType;
  end record;

  constant REG_INIT_C : RegType := (
    state       => IDLE_S,
    length      => (others=>'0'),
    count       => (others=>'0'),
    inc         => '0',
    ack         => '0',
    txMaster    => AXI_STREAM_MASTER_INIT_C );

  type RegArray is array(natural range<>) of RegType;

  signal r   : RegArray(NUM_LANES_C-1 downto 0) := (others=>REG_INIT_C);
  signal rin : RegArray(NUM_LANES_C-1 downto 0);

  constant DEBUG_C : boolean := DEBUG_G;

  component ila_0
    port ( clk     : in sl;
           probe0  : in slv(255 downto 0) );
  end component;

  signal r0_state : slv(3 downto 0);
  
begin

  dmaClks <= idmaClks;
  dmaRsts <= idmaRsts;

  GEN_DEBUG : if DEBUG_C generate

    r0_state <= x"0" when r(0).state = WAIT_S else
                x"1" when r(0).state = IDLE_S else
                x"2" when r(0).state = HDR1_S else
                x"3" when r(0).state = HDR2_S else
                x"4" when r(0).state = HDR3_S else
                x"5" when r(0).state = SEND_S else
                x"6";
    
    U_ILA : ila_0
      port map ( clk                  => tdetClk,
                 probe0(           0) => tdetClkRst,
                 probe0(           1) => tdetEvent(0).valid,
                 probe0(           2) => tdetEvent(0).isEvent,
                 probe0(18 downto  3) => tdetEvent(0).header.pulseId(15 downto 0),
                 probe0(26 downto 19) => tdetEvent(0).header.count  ( 7 downto 0),
                 probe0(42 downto 27) => tdetEvent(0).header.l1t,
                 probe0(50 downto 43) => tdetEvent(0).header.payload,
                 probe0(54 downto 51) => r0_state,
                 probe0(          55) => dmaIbSlaves(0).tReady,
                 probe0(          56) => dmaIbAlmostFull(0),
                 probe0(          57) => r(0).ack,
                 probe0(          58) => as.enable,
                 probe0(61 downto 59) => as.partition,
                 probe0(69 downto 62) => as.id(7 downto 0),
                 probe0(77 downto 70) => r(0).count(7 downto 0),
                 probe0(255 downto 78) => (others=>'0') );
  end generate;

  GEN_LANE : for i in 0 to NUM_LANES_C-1 generate
    idmaClks(i)     <= tdetClk;
    idmaRsts(i)     <= tdetClkRst;
    dmaIbMasters(i) <= r(i).txMaster;
    ----------------------------------------
    -- Emulate PGP Read of TDET Registers --
    ----------------------------------------
    --if v.txMaster.tValid = '0' then
    --  v.txMaster := saxisMasters(i);
    --  saxisSlaves  (i).tReady <= '1';
    --end if;
    dmaObSlaves (i) <= AXI_STREAM_SLAVE_FORCE_C;
    
    statusv(i) <= toSlv(tdetStatus(i));
    
    U_StatusV : entity work.SynchronizerVector
      generic map ( WIDTH_G => statusv(i)'length )
      port map ( clk     => axilClk,
                 dataIn  => statusv(i),
                 dataOut => vstatus(i) );

    status(i) <= toTDetStatus(vstatus(i));

    U_AFullS : entity work.Synchronizer
      port map ( clk => tdetClk, dataIn => dmaIbAlmostFull(i), dataOut => tdetTiming(i).aFull );

  end generate;
  
  acomb : process ( a, axilRst, axilReadMaster, axilWriteMaster, modPrsL, status ) is
    variable v : AxiRegType;
    variable ep : AxiLiteEndpointType;
  begin
    v := a;

    axiSlaveWaitTxn ( ep, axilWriteMaster, axilReadMaster, v.axilWriteSlave, v.axilReadSlave );
    axiSlaveRegister( ep, x"00", 0, v.partition );
    axiSlaveRegister( ep, x"00", 3, v.clear );
    axiSlaveRegister( ep, x"00", 4, v.length );
    axiSlaveRegister( ep, x"00",31, v.enable );
    
    axiSlaveRegister( ep, x"04", 0, v.id );

    axiSlaveRegisterR( ep, x"08", 0, status(0).partitionAddr );
    axiSlaveRegisterR( ep, x"0c", 0, modPrsL);

    for i in 0 to NUM_LANES_C-1 loop
      axiSlaveRegisterR( ep, toSlv(16*i+16,8), 0, status(i).cntL0 );
      axiSlaveRegisterR( ep, toSlv(16*i+16,8),24, status(i).cntOflow );
      axiSlaveRegisterR( ep, toSlv(16*i+20,8), 0, status(i).cntL1A );
      axiSlaveRegisterR( ep, toSlv(16*i+24,8), 0, status(i).cntL1R );
      axiSlaveRegisterR( ep, toSlv(16*i+28,8), 0, status(i).cntWrFifo );
      axiSlaveRegisterR( ep, toSlv(16*i+28,8), 8, status(i).cntRdFifo );
      axiSlaveRegisterR( ep, toSlv(16*i+28,8),16, status(i).msgDelay );
    end loop;
    
    axiSlaveDefault ( ep, v.axilWriteSlave, v.axilReadSlave );

    if axilRst = '1' then
      v := AXI_REG_INIT_C;
    end if;

    ain <= v;

    axilReadSlave  <= a.axilReadSlave;
    axilWriteSlave <= a.axilWriteSlave;
  end process acomb;

  aseq : process ( axilClk ) is
  begin
    if rising_edge(axilClk) then
      a <= ain;
    end if;
  end process aseq;

  U_IdS : entity work.SynchronizerVector
    generic map ( WIDTH_G => 32 )
    port map ( clk => tdetClk, dataIn => a.id, dataOut => as.id );
  U_PartitionS : entity work.SynchronizerVector
    generic map ( WIDTH_G => 3 )
    port map ( clk => tdetClk, dataIn => a.partition, dataOut => as.partition );
  U_EnableS : entity work.Synchronizer
    port map ( clk => tdetClk, dataIn => a.enable, dataOut => as.enable );
  U_ClearS : entity work.Synchronizer
    port map ( clk => tdetClk, dataIn => a.clear, dataOut => as.clear );
  U_LengthS : entity work.SynchronizerVector
    generic map ( WIDTH_G => a.length'length )
    port map ( clk => tdetClk, dataIn => a.length, dataOut => as.length );

  comb : process ( r, tdetClkRst, tdetEvent, as, dmaIbSlaves ) is
    variable v : RegType;
    variable i,j : integer;
  begin
    for i in 0 to NUM_LANES_C-1 loop
      v := r(i);

      v.ack := '0';
      
      if dmaIbSlaves(i).tReady = '1' then
        v.txMaster.tValid := '0';
      end if;

      case r(i).state is
        when WAIT_S =>
          v.state := IDLE_S;
        when IDLE_S =>
          if as.enable = '1' and tdetEvent(i).valid = '1' then
            v.state           := HDR1_S;
            ssiSetUserSof(PGP3_AXIS_CONFIG_C, v.txMaster, '1');
            v.txMaster.tValid := '1';
            v.txMaster.tLast  := '0';
            v.txMaster.tData(63 downto 0) := toSlv(tdetEvent(i).header)(63 downto 0);
            v.txMaster.tKeep  := genTKeep(PGP3_AXIS_CONFIG_C);
          end if;
        when HDR1_S =>
          if v.txMaster.tValid = '0' then
            v.state           := HDR2_S;
            ssiSetUserSof(PGP3_AXIS_CONFIG_C, v.txMaster, '0');
            v.txMaster.tValid := '1';
            v.txMaster.tLast  := '0';
            v.txMaster.tData(63 downto 0) := toSlv(tdetEvent(i).header)(127 downto 64); 
            v.txMaster.tKeep  := genTKeep(PGP3_AXIS_CONFIG_C);
          end if;
        when HDR2_S =>
          if v.txMaster.tValid = '0' then
            v.state           := HDR3_S;
            v.txMaster.tValid := '1';
            v.txMaster.tLast  := '0';
            v.txMaster.tData(63 downto 0) := toSlv(tdetEvent(i).header)(191 downto 128);
            v.txMaster.tKeep  := genTKeep(PGP3_AXIS_CONFIG_C);
          end if;
        when HDR3_S =>
          if v.txMaster.tValid = '0' then
            v.txMaster.tValid := '1';
            v.txMaster.tLast  := '1';
            v.txMaster.tData(63 downto 0) := toSlv(0,64);
            v.txMaster.tKeep  := genTKeep(PGP3_AXIS_CONFIG_C);
            v.state := WAIT_S;
            v.ack   := '1';
            if tdetEvent(i).isEvent = '1' then
              v.txMaster.tLast  := '0';
              v.state   := SEND_S;
              v.length  := as.length;
              v.inc     := '1';
            end if;
          end if;
        when SEND_S =>
          if v.txMaster.tValid = '0' then
            for j in 0 to PGP3_AXIS_CONFIG_C.TDATA_BYTES_C/4-1 loop
              v.txMaster.tData(32*j+31 downto 32*j)  :=  resize(r(i).length - j, 32);
            end loop;
            v.txMaster.tValid := '1';
            v.txMaster.tLast  := '1';
            v.length          := toSlv(0,as.length'length);
            v.state           := IDLE_S;
            j := conv_integer(r(i).length);
            if j <= PGP3_AXIS_CONFIG_C.TDATA_BYTES_C/4 then
              v.txMaster.tKeep := (others=>'0');
              v.txMaster.tKeep(4*j-1 downto 0) := (others=>'1');
            else
              v.txMaster.tKeep := (others=>'0');
              v.txMaster.tKeep(PGP3_AXIS_CONFIG_C.TDATA_BYTES_C-1 downto 0) := (others=>'1');
              v.txMaster.tLast := '0';
              v.length         := r(i).length - PGP3_AXIS_CONFIG_C.TDATA_BYTES_C/4;
              v.state          := SEND_S;
            end if;
            if r(i).inc = '1' then
              v.inc      := '0';
              v.count    := r(i).count + 1;
              v.txMaster.tData(31 downto 0) := resize(r(i).count,32);
            end if;
          end if;
        when others => null;
      end case;

      if tdetClkRst = '1' or as.clear = '1' then
        v := REG_INIT_C;
      end if;

      rin(i) <= v;

      tdetTiming  (i).id        <= as.id;
      tdetTiming  (i).partition <= as.partition;
      tdetTiming  (i).enable    <= as.enable;
      tdetTiming  (i).ack       <= v.ack;
    end loop;
    
  end process;

  process (tdetClk) is
  begin
    if rising_edge(tdetClk) then
      for i in 0 to NUM_LANES_C-1 loop
        r(i) <= rin(i);
      end loop;
    end if;
  end process;

end mapping;
