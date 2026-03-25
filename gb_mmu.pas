unit gb_mmu;
{ 单元定义: Game Boy 内存管理单元（MMU）与总线路由层。 }
{ 负责内容: 地址映射、卡带/VRAM/WRAM/OAM/IO 访问、DMA/HDMA、CGB 双速与外设桥接（PPU/APU/Timer/Joypad）。 }



{
  注释规范（与 gb_cpu.pas 一致）:
  - 说明“为什么要这样映射/时序推进”，而不仅是“做了什么”。
  - 涉及寄存器行为时尽量写明硬件位语义与兼容取舍。
  - 涉及 DMA/HDMA/OAM bug/双速时写明与测试 ROM 的关系。
  - 参考:
    Pan Docs: https://gbdev.io/pandocs/
    Memory Map / I/O Ports / OAM DMA Transfer / VRAM DMA Transfers / CGB Registers。
}

{ Game Boy MMU: memory map, echo RAM, IO. Read8/Write8 with case on high byte. }

interface

uses
  gb_cart, gb_timer, gb_ppu, gb_cpu, gb_joypad, gb_apu;

type
  TSerialByteProc = procedure(AByte: Byte) of object;
  TDebugWriteProc = procedure(Addr: Word; Value: Byte) of object;

  TGBMMU = class
  private
    FCart: TCartridge;
    FTimer: TGBTimer;
    FPPU: TGBPPU;
    FCpu: TCpu;
    FWRAM: array[0..32767] of Byte; { CGB: WRAM bank0 + bank1..7 (8 * 4KB) }
    FVRAM: array[0..16383] of Byte; { CGB: 2 banks * 8KB }
    FVRAMDisplay: array[0..16383] of Byte;
    FOAM: array[0..159] of Byte;
    FHRAM: array[0..126] of Byte;
    FIF: Byte;
    FIE: Byte;
    FJoypad: TGBJoypad;
    FAPU: TGBAPU;
    FSerial: array[0..1] of Byte;
    FSerialActive: Boolean;
    FSerialCycles: Cardinal;
    FIORegs: array[0..$7F] of Byte; { Generic FF00-FF7F fallback registers }
    FCGBMode: Boolean;
    FForceCGBMode: Boolean;
    FDoubleSpeed: Boolean;
    FSpeedTickRemainder: Cardinal;
    FKEY1: Byte; { FF4D: bit7=current speed, bit0=prepare switch }
    FVBK: Byte; { FF4F: VRAM bank select bit0 }
    FSVBK: Byte; { FF70: WRAM bank select (1..7, 0 treated as 1) }
    FBGPI: Byte; { FF68 }
    FOBPI: Byte; { FF6A }
    FBGPaletteRAM: array[0..63] of Byte; { FF69 data, 8 palettes * 4 colors * 2 bytes }
    FOBPaletteRAM: array[0..63] of Byte; { FF6B data }
    FKey1Writes: Cardinal;
    FStopSwitches: Cardinal;
    FBGP: Byte;
    FOBP0: Byte;
    FOBP1: Byte;
    FDMA: Byte;
    FDMAActive: Boolean;
    FDMACycles: Cardinal;
    FHDMA1: Byte;
    FHDMA2: Byte;
    FHDMA3: Byte;
    FHDMA4: Byte;
    FHDMA5: Byte;
    FHDMASource: Word;
    FHDMADest: Word;
    FHDMABlocksRemaining: Byte;
    FHDMAActive: Boolean;
    FHDMAHBlank: Boolean;
    FVRAMWriteCount: Cardinal;
    FVRAMMaxByte: Byte;
    FOnSerialByte: TSerialByteProc;
    FOnDebugWrite: TDebugWriteProc;
    FPendingBusOAMValid: Boolean;
    FPendingBusOAMRead: Boolean;
    FPendingBusTicks: UInt64;
    procedure CorruptOAMRead(Row: Integer);
    procedure CorruptOAMWrite(Row: Integer);
    procedure CorruptOAMReadWrite(Row: Integer);
    procedure TriggerOAMBug(Kind: Byte; Addr: Word);
    procedure ApplyOAMCorruptionKind(AKind: Byte);
    procedure FlushPendingBusOAM(const CurrentTicks: UInt64);
    procedure RequestIrq(IrqBit: Byte);
    procedure CopyVRAMToDisplay;
    procedure UpdateSerial(Cycles: Cardinal);
    procedure ExecuteHDMABlock;
    procedure MaybeStepHBlankHDMA(OldMode, NewMode: Byte; OldLY: Byte; Cycles: Cardinal);
    function Read8ForDisplay(Addr: Word): Byte;
    function Read8ForPPU(Addr: Word): Byte;
    function ReadVRAMBankedForDisplay(Addr: Word; Bank: Byte): Byte;
    function ReadVRAMBankedForPPU(Addr: Word; Bank: Byte): Byte;
    function WRAMBank1To7: Byte;
    function VRAMBank0or1: Byte;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Reset;
    procedure Update(Cycles: Cardinal);
    procedure RunCpuAndTimer(Cycles: Cardinal);
    function Read8(Addr: Word): Byte;
    procedure Write8(Addr: Word; Value: Byte);
    function Read16(Addr: Word): Word;
    procedure Write16(Addr: Word; Value: Word);
    property Cart: TCartridge read FCart write FCart;
    property Timer: TGBTimer read FTimer write FTimer;
    property PPU: TGBPPU read FPPU write FPPU;
    property APU: TGBAPU read FAPU;
    property Cpu: TCpu read FCpu write FCpu;
    property OnSerialByte: TSerialByteProc read FOnSerialByte write FOnSerialByte;
    property OnDebugWrite: TDebugWriteProc read FOnDebugWrite write FOnDebugWrite;
    procedure SetJoypadState(AButtons, ADirections: Byte);
    procedure CpuTick(Cycles: Cardinal);
    procedure CpuTickTimerOnly(Cycles: Cardinal);
    function HandleStop: Boolean;
    procedure OnCpuBusAccess(Addr: Word; IsWrite: Boolean);
    procedure OnCpuIDUOp(Addr: Word; Kind: Byte);
    property BGP: Byte read FBGP;
    property OBP0: Byte read FOBP0;
    property OBP1: Byte read FOBP1;
    property VRAMWriteCount: Cardinal read FVRAMWriteCount;
    property VRAMMaxByte: Byte read FVRAMMaxByte;
    property Key1Writes: Cardinal read FKey1Writes;
    property StopSwitches: Cardinal read FStopSwitches;
    property IsCGBMode: Boolean read FCGBMode;
    property IsDoubleSpeed: Boolean read FDoubleSpeed;
    property ForceCGBMode: Boolean read FForceCGBMode write FForceCGBMode;
    function ReadCGBPaletteColor(IsOBJ: Boolean; PaletteIndex, ColorIndex: Byte): Word;
  end;

implementation

function TGBMMU.WRAMBank1To7: Byte;
begin
  { FF70(SVBK):
    - CGB only.
    - value 0 maps to bank 1 (hardware behavior), never to bank 0 in $D000-$DFFF. }
  if not FCGBMode then
    Exit(1);
  Result := FSVBK and 7;
  if Result = 0 then
    Result := 1;
end;

function TGBMMU.VRAMBank0or1: Byte;
begin
  { FF4F(VBK): CGB VRAM bank selector (0/1). DMG always uses bank 0. }
  if not FCGBMode then
    Exit(0);
  Result := FVBK and 1;
end;

constructor TGBMMU.Create;
begin
  inherited Create;
  { MMU owns and wires all core peripherals. CPU callbacks are connected by gb_core. }
  FJoypad := TGBJoypad.Create;
  FJoypad.OnRequestIrq := RequestIrq;
  FAPU := TGBAPU.Create;
  FTimer := TGBTimer.Create;
  FPPU := TGBPPU.Create;
  FTimer.OnRequestIrq := RequestIrq;
  FPPU.OnRequestIrq := RequestIrq;
  FPPU.OnRead8 := Read8ForPPU;
  FPPU.OnRead8ForDisplay := Read8ForDisplay;
  FPPU.OnReadVRAMBanked := ReadVRAMBankedForPPU;
  FPPU.OnReadVRAMBankedForDisplay := ReadVRAMBankedForDisplay;
  FPPU.OnFrameStart := CopyVRAMToDisplay;
  FCart := nil;
  Reset;
end;

destructor TGBMMU.Destroy;
begin
  FPPU.Free;
  FTimer.Free;
  FAPU.Free;
  FJoypad.Free;
  inherited;
end;

procedure TGBMMU.CorruptOAMRead(Row: Integer);
var
  Base, PrevBase: Integer;
  A0, B0, C0: Word;
  I: Integer;
begin
  { DMG OAM bug（mode 2）中的“读导致损坏”模式。
    这里按 mealybug test 所需模式对当前/前一行 8-byte entry 做组合。 }
  if (Row <= 0) or (Row > 19) then
    Exit;
  Base := Row * 8;
  PrevBase := (Row - 1) * 8;
  A0 := Word(FOAM[Base]) or (Word(FOAM[Base + 1]) shl 8);
  B0 := Word(FOAM[PrevBase]) or (Word(FOAM[PrevBase + 1]) shl 8);
  C0 := Word(FOAM[PrevBase + 4]) or (Word(FOAM[PrevBase + 5]) shl 8);
  A0 := B0 or (A0 and C0);
  FOAM[Base] := Byte(A0 and $FF);
  FOAM[Base + 1] := Byte(A0 shr 8);
  for I := 2 to 7 do
    FOAM[Base + I] := FOAM[PrevBase + I];
end;

procedure TGBMMU.CorruptOAMWrite(Row: Integer);
var
  Base, PrevBase: Integer;
  A0, B0, C0: Word;
  I: Integer;
begin
  { DMG OAM bug（mode 2）中的“写导致损坏”模式。 }
  if (Row <= 0) or (Row > 19) then
    Exit;
  Base := Row * 8;
  PrevBase := (Row - 1) * 8;
  A0 := Word(FOAM[Base]) or (Word(FOAM[Base + 1]) shl 8);
  B0 := Word(FOAM[PrevBase]) or (Word(FOAM[PrevBase + 1]) shl 8);
  C0 := Word(FOAM[PrevBase + 4]) or (Word(FOAM[PrevBase + 5]) shl 8);
  A0 := ((A0 xor C0) and (B0 xor C0)) xor C0;
  FOAM[Base] := Byte(A0 and $FF);
  FOAM[Base + 1] := Byte(A0 shr 8);
  for I := 2 to 7 do
    FOAM[Base + I] := FOAM[PrevBase + I];
end;

procedure TGBMMU.CorruptOAMReadWrite(Row: Integer);
var
  B2, B1, B0: Integer;
  A, B, C, D: Word;
  I: Integer;
begin
  { DMG OAM bug 中“同 M-cycle 读+写叠加”模式。
    该模式与单纯读/写不同，是 oam_bug 7/8 通过的关键之一。 }
  if (Row >= 4) and (Row <= 18) then
  begin
    B2 := (Row - 2) * 8;
    B1 := (Row - 1) * 8;
    B0 := Row * 8;
    A := Word(FOAM[B2]) or (Word(FOAM[B2 + 1]) shl 8);
    B := Word(FOAM[B1]) or (Word(FOAM[B1 + 1]) shl 8);
    C := Word(FOAM[B0]) or (Word(FOAM[B0 + 1]) shl 8);
    D := Word(FOAM[B1 + 4]) or (Word(FOAM[B1 + 5]) shl 8);
    B := (B and (A or C or D)) or (A and C and D);
    FOAM[B1] := Byte(B and $FF);
    FOAM[B1 + 1] := Byte(B shr 8);
    for I := 0 to 7 do
      FOAM[B0 + I] := FOAM[B1 + I];
    for I := 0 to 7 do
      FOAM[B2 + I] := FOAM[B1 + I];
  end;
  CorruptOAMRead(Row);
end;

procedure TGBMMU.TriggerOAMBug(Kind: Byte; Addr: Word);
var
  Row: Integer;
begin
  { 仅在 OAM 区 + mode2 扫描阶段触发。
    CGB 硬件不存在 DMG 同款 OAM corruption，因此外层会在 CGB 禁用。 }
  if (Addr < $FE00) or (Addr > $FEFF) then
    Exit;
  if not Assigned(FPPU) then
    Exit;
  if not FPPU.InMode2 then
    Exit;
  Row := FPPU.CurrentOAMRow;
  if Row < 0 then
    Exit;
  case Kind of
    0: CorruptOAMRead(Row);
    1: CorruptOAMWrite(Row);
    2: CorruptOAMReadWrite(Row);
  end;
end;

procedure TGBMMU.ApplyOAMCorruptionKind(AKind: Byte);
var
  Row: Integer;
begin
  { 以“当前扫描到的 OAM 行”为目标应用损坏模型。 }
  if not Assigned(FPPU) or (not FPPU.InMode2) then
    Exit;
  Row := FPPU.CurrentOAMRow;
  if Row < 0 then
    Exit;
  case AKind of
    0: CorruptOAMRead(Row);
    1: CorruptOAMWrite(Row);
    2: CorruptOAMReadWrite(Row);
  end;
end;

procedure TGBMMU.FlushPendingBusOAM(const CurrentTicks: UInt64);
begin
  { 将上一回调里缓存的总线访问在“跨 M-cycle 边界”时真正落地，
    以便和同 M-cycle 的 IDU 操作组合（匹配 mealybug OAM 时序）。 }
  if FCGBMode then
  begin
    FPendingBusOAMValid := False;
    Exit;
  end;

  if not FPendingBusOAMValid then
    Exit;
  if FPendingBusTicks <> CurrentTicks then
  begin
    if FPendingBusOAMRead then
      ApplyOAMCorruptionKind(0)
    else
      ApplyOAMCorruptionKind(1);
    FPendingBusOAMValid := False;
  end;
end;

procedure TGBMMU.RequestIrq(IrqBit: Byte);
begin
  FIF := FIF or (1 shl IrqBit);
end;

procedure TGBMMU.SetJoypadState(AButtons, ADirections: Byte);
begin
  FJoypad.SetState(AButtons, ADirections);
end;

procedure TGBMMU.Reset;
var
  I: Integer;
begin
  { Reset 选择“无 boot ROM 直入”的常见初值风格，兼顾测试 ROM 可运行性。 }
  for I := 0 to 32767 do
  begin
    FWRAM[I] := 0;
    if I < 16384 then
      FVRAM[I] := 0;
  end;
  for I := 0 to 159 do
    FOAM[I] := 0;
  for I := 0 to 126 do
    FHRAM[I] := 0;
  FIF := 1; { DMG post-boot IF low bits typically start with VBlank request set }
  FIE := 0;
  FJoypad.Reset;
  FSerial[0] := 0;
  FSerial[1] := 0;
  FSerialActive := False;
  FSerialCycles := 0;
  for I := 0 to $7F do
    FIORegs[I] := $FF;
  FBGP := $FC;
  FOBP0 := $FF;
  FOBP1 := $FF;
  FDMA := 0;
  FDMAActive := False;
  FDMACycles := 0;
  FHDMA1 := 0;
  FHDMA2 := 0;
  FHDMA3 := 0;
  FHDMA4 := 0;
  FHDMA5 := $FF;
  FHDMASource := 0;
  FHDMADest := $8000;
  FHDMABlocksRemaining := 0;
  FHDMAActive := False;
  FHDMAHBlank := False;
  FVRAMWriteCount := 0;
  FVRAMMaxByte := 0;
  FPendingBusOAMValid := False;
  FPendingBusOAMRead := False;
  FPendingBusTicks := 0;
  { Default model selection:
    - CGB-only carts ($C0) always run in CGB mode
    - CGB-capable carts ($80) run in DMG mode unless ForceCGBMode is set
      (for example when loading .gbc files in UI runners). }
  FCGBMode := Assigned(FCart) and (FCart.RequiresCGB or (FForceCGBMode and FCart.SupportsCGB));
  FDoubleSpeed := False;
  FSpeedTickRemainder := 0;
  FKEY1 := 0;
  FVBK := 0;
  FSVBK := 1;
  FBGPI := 0;
  FOBPI := 0;
  for I := 0 to 63 do
  begin
    FBGPaletteRAM[I] := 0;
    FOBPaletteRAM[I] := 0;
  end;
  FKey1Writes := 0;
  FStopSwitches := 0;
  if Assigned(FTimer) then
  begin
    FTimer.IsCGB := FCGBMode;
    FTimer.Reset;
  end;
  if Assigned(FAPU) then
    FAPU.Reset;
  if Assigned(FPPU) then
  begin
    FPPU.CGBMode := FCGBMode;
    FPPU.Reset;
  end;
  CopyVRAMToDisplay;
end;

procedure TGBMMU.CopyVRAMToDisplay;
var
  I: Integer;
begin
  { 帧开始时做 VRAM 快照，渲染阶段读取快照，降低“写入中撕裂”差异。 }
  for I := 0 to 16383 do
    FVRAMDisplay[I] := FVRAM[I];
end;

procedure TGBMMU.UpdateSerial(Cycles: Cardinal);
var
  ByteCycles: Cardinal;
begin
  { 串口内部时钟:
    - DMG 常规 4096 cycles/byte
    - CGB 可切到高速（SC bit1）128 cycles/byte
    - 双速下再减半。完成后请求 Serial IRQ(bit3)。 }
  if not FSerialActive then
    Exit;

  if FCGBMode and ((FSerial[1] and $02) <> 0) then
    ByteCycles := 128
  else
    ByteCycles := 4096;
  if FDoubleSpeed and (ByteCycles > 1) then
    ByteCycles := ByteCycles shr 1;

  Inc(FSerialCycles, Cycles);
  while FSerialActive and (FSerialCycles >= ByteCycles) do
  begin
    Dec(FSerialCycles, ByteCycles);
    FSerialActive := False;
    FSerial[1] := FSerial[1] and $7F;
    if Assigned(FOnSerialByte) then
      FOnSerialByte(FSerial[0]);
    RequestIrq(3);
  end;
end;

procedure TGBMMU.ExecuteHDMABlock;
var
  I: Integer;
  Src: Word;
  Dst: Word;
  Off: Word;
  Bank: Byte;
begin
  { CGB VRAM DMA 一次传 16 字节（Pan Docs: VRAM DMA Transfers）。
    General DMA: 一次传完整长度；HBlank DMA: 每次 HBlank 传一个 block。 }
  if not FCGBMode then
    Exit;
  if FHDMABlocksRemaining = 0 then
    Exit;

  Src := FHDMASource;
  Dst := FHDMADest;
  Bank := VRAMBank0or1;

  for I := 0 to 15 do
  begin
    Off := (Dst - $8000) and $1FFF;
    FVRAM[Off + Word(Bank) * $2000] := Read8(Src);
    Inc(Src);
    Inc(Dst);
  end;

  FHDMASource := Src;
  FHDMADest := $8000 or ((Dst - $8000) and $1FF0);
  Dec(FHDMABlocksRemaining);

  FHDMA1 := Byte(FHDMASource shr 8);
  FHDMA2 := Byte(FHDMASource and $F0);
  FHDMA3 := Byte((FHDMADest - $8000) shr 8) and $1F;
  FHDMA4 := Byte(FHDMADest and $F0);

  if FHDMABlocksRemaining = 0 then
  begin
    FHDMAActive := False;
    FHDMAHBlank := False;
    FHDMA5 := $FF;
  end
  else if FHDMAActive and FHDMAHBlank then
    FHDMA5 := (FHDMABlocksRemaining - 1) and $7F
  else
    FHDMA5 := $80 or ((FHDMABlocksRemaining - 1) and $7F);
end;

procedure TGBMMU.MaybeStepHBlankHDMA(OldMode, NewMode: Byte; OldLY: Byte; Cycles: Cardinal);
begin
  if not (FCGBMode and FHDMAActive and FHDMAHBlank) then
    Exit;

  { 精细路径: 可见线进入 mode0(HBlank) 时传输一个 16-byte block。 }
  if (OldMode <> 0) and (NewMode = 0) and Assigned(FPPU) and (FPPU.LY < 144) then
  begin
    ExecuteHDMABlock;
    Exit;
  end;

  { 粗粒度兜底: 一次推进 >= 456 cycles 可能跨过模式边沿，补执行一次。 }
  if (Cycles >= 456) and (OldLY < 144) then
    ExecuteHDMABlock;
end;

function TGBMMU.Read8ForDisplay(Addr: Word): Byte;
var
  Off: Word;
begin
  { 给 PPU 渲染线程/路径读取“帧起始快照”的 VRAM。 }
  Addr := Addr and $FFFF;
  if (Addr >= $8000) and (Addr <= $9FFF) then
  begin
    Off := Addr - $8000;
    Result := FVRAMDisplay[Off]; { display path remains bank0 for now }
  end
  else
    Result := $FF;
end;

function TGBMMU.ReadVRAMBankedForDisplay(Addr: Word; Bank: Byte): Byte;
var
  Off: Word;
begin
  { CGB 显示路径按 bank 读取快照。 }
  Addr := Addr and $FFFF;
  if (Addr >= $8000) and (Addr <= $9FFF) then
  begin
    Off := Addr - $8000;
    Result := FVRAMDisplay[Off + Word(Bank and 1) * $2000];
  end
  else
    Result := $FF;
end;

procedure TGBMMU.Update(Cycles: Cardinal);
var
  OldMode, NewMode: Byte;
  OldLY: Byte;
begin
  { 供“非 CPU tick 驱动”路径使用：统一推进 serial/APU/timer/PPU。 }
  UpdateSerial(Cycles);
  if Assigned(FAPU) then
    FAPU.Update(Cycles);
  if Assigned(FTimer) then
    FTimer.Update(Cycles);
  if Assigned(FPPU) then
  begin
    OldMode := FPPU.Mode;
    OldLY := FPPU.LY;
    FPPU.Update(Cycles);
    NewMode := FPPU.Mode;
    MaybeStepHBlankHDMA(OldMode, NewMode, OldLY, Cycles);
  end;
  if FDMAActive then
  begin
    FDMACycles := FDMACycles + Cycles;
    if FDMACycles >= 160 * 4 then
      FDMAActive := False;
  end;
end;

procedure TGBMMU.RunCpuAndTimer(Cycles: Cardinal);
var
  Total: Cardinal;
begin
  { 扫描线调度模式下，按预算 cycles 运行 CPU；
    若 CPU.OnTick=nil，则由本函数兜底推进 timer。 }
  Total := 0;
  while (Total < Cycles) and Assigned(FCpu) do
  begin
    FCpu.Step;
    if FCpu.Stopped then
      Break;
    Inc(Total, FCpu.Cycles);
    if (not Assigned(FCpu.OnTick)) and Assigned(FTimer) then
      FTimer.Update(FCpu.Cycles);
  end;
end;

function TGBMMU.Read8ForPPU(Addr: Word): Byte;
var
  Off: Word;
begin
  { PPU 取数入口:
    - VRAM/OAM 走本地数组，避免再次触发 CPU 侧副作用
    - 其他地址回退 MMU.Read8。 }
  Addr := Addr and $FFFF;
  if (Addr >= $8000) and (Addr <= $9FFF) then
  begin
    Off := Addr - $8000;
    Result := FVRAM[Off]; { PPU path currently bank0; CGB attribute rendering comes later }
  end
  else if (Addr >= $FE00) and (Addr <= $FE9F) then
    Result := FOAM[Addr - $FE00]
  else
    Result := Read8(Addr);
end;

function TGBMMU.ReadVRAMBankedForPPU(Addr: Word; Bank: Byte): Byte;
var
  Off: Word;
begin
  { CGB 渲染读取指定 VRAM bank（tile attr 的 bank 位会走这里）。 }
  Addr := Addr and $FFFF;
  if (Addr >= $8000) and (Addr <= $9FFF) then
  begin
    Off := Addr - $8000;
    Result := FVRAM[Off + Word(Bank and 1) * $2000];
  end
  else
    Result := $FF;
end;

function TGBMMU.ReadCGBPaletteColor(IsOBJ: Boolean; PaletteIndex, ColorIndex: Byte): Word;
var
  Base: Integer;
  Lo, Hi: Byte;
begin
  { CGB 调色板 RAM:
    8 palettes * 4 colors * 2 bytes(15-bit BGR), 共 64 字节每组。 }
  Base := ((PaletteIndex and 7) * 8) + ((ColorIndex and 3) * 2);
  if IsOBJ then
  begin
    Lo := FOBPaletteRAM[Base];
    Hi := FOBPaletteRAM[Base + 1];
  end
  else
  begin
    Lo := FBGPaletteRAM[Base];
    Hi := FBGPaletteRAM[Base + 1];
  end;
  Result := Word(Lo) or (Word(Hi) shl 8);
end;

function TGBMMU.Read8(Addr: Word): Byte;
var
  A: Word;
  Off: Word;
  WBank: Byte;
begin
  { Pan Docs memory map:
    0000-7FFF ROM, 8000-9FFF VRAM, A000-BFFF cart RAM,
    C000-DFFF WRAM, E000-FDFF echo, FE00-FE9F OAM, FF00-FF7F I/O, FF80-FFFE HRAM. }
  Addr := Addr and $FFFF;
  case Addr shr 8 of
    $00..$3F, $40..$7F:
      { ROM read（含 MBC bank 选择） }
      if Assigned(FCart) then
        Result := FCart.ReadROM(Addr)
      else
        Result := $FF;
    $80..$9F:
      begin
        { VRAM read: DMG 固定 bank0，CGB 由 VBK 选择。 }
        Off := Addr - $8000;
        Result := FVRAM[Off + Word(VRAMBank0or1) * $2000];
      end;
    $A0..$BF:
      { External RAM read（需由卡带控制器判定 enable/bank）。 }
      if Assigned(FCart) then
        Result := FCart.ReadRAM(Addr)
      else
        Result := $FF;
    $C0..$DF:
      begin
        { WRAM: C000-CFFF 固定 bank0，D000-DFFF 在 CGB 下可切换 1..7。 }
        if Addr < $D000 then
          Result := FWRAM[Addr - $C000] { bank 0 }
        else
        begin
          WBank := WRAMBank1To7;
          Result := FWRAM[$1000 * WBank + (Addr - $D000)];
        end;
      end;
    $E0..$FD:
      begin
        { Echo RAM: E000-FDFF 镜像 C000-DDFF。 }
        A := Addr - $2000;
        if A < $D000 then
          Result := FWRAM[A - $C000]
        else
        begin
          WBank := WRAMBank1To7;
          Result := FWRAM[$1000 * WBank + (A - $D000)];
        end;
      end;
    $FE:
      if Addr < $FEA0 then
      begin
        { OAM 在 mode2/mode3 不可由 CPU 读取（返回 $FF）。 }
        if Assigned(FPPU) and ((FPPU.LCDC and $80) <> 0) and (FPPU.Mode in [2, 3]) then
          Result := $FF
        else
          Result := FOAM[Addr - $FE00];
      end
      else
        { FEA0-FEFF 为不可用区（Not Usable）。 }
        Result := $FF;
    $FF:
      case Addr of
        $FF00:
          Result := FJoypad.ReadP1;
        $FF01: Result := FSerial[0];
        $FF02: Result := FSerial[1] or $7E;
        $FF04..$FF07: if Assigned(FTimer) then Result := FTimer.Read(Addr) else Result := $FF;
        $FF0F: Result := FIF or $E0;
        $FF10..$FF3F: if Assigned(FAPU) then Result := FAPU.Read(Addr) else Result := $FF;
        $FF40..$FF46, $FF4A..$FF4B: if Assigned(FPPU) then Result := FPPU.Read(Addr) else Result := $FF;
        $FF47: Result := FBGP;
        $FF48: Result := FOBP0;
        $FF49: Result := FOBP1;
        $FF4F:
          if FCGBMode then
            Result := (FVBK and 1) or $FE
          else
            Result := $FF;
        $FF4D:
          if FCGBMode then
            Result := (FKEY1 and $81) or $7E
          else
            Result := $FF;
        $FF51:
          if FCGBMode then
            Result := FHDMA1
          else
            Result := $FF;
        $FF52:
          if FCGBMode then
            Result := FHDMA2
          else
            Result := $FF;
        $FF53:
          if FCGBMode then
            Result := FHDMA3 or $E0
          else
            Result := $FF;
        $FF54:
          if FCGBMode then
            Result := FHDMA4
          else
            Result := $FF;
        $FF55:
          if FCGBMode then
            Result := FHDMA5
          else
            Result := $FF;
        $FF68:
          if FCGBMode then
            Result := FBGPI
          else
            Result := $FF;
        $FF69:
          if FCGBMode then
            Result := FBGPaletteRAM[FBGPI and $3F]
          else
            Result := $FF;
        $FF6A:
          if FCGBMode then
            Result := FOBPI
          else
            Result := $FF;
        $FF6B:
          if FCGBMode then
            Result := FOBPaletteRAM[FOBPI and $3F]
          else
            Result := $FF;
        $FF70:
          if FCGBMode then
            Result := (FSVBK and 7) or $F8
          else
            Result := $FF;
        $FF80..$FFFE: Result := FHRAM[Addr - $FF80];
        $FFFF: Result := FIE or $E0;
      else
        if Addr <= $FF7F then
          Result := FIORegs[Addr - $FF00]
        else
          Result := $FF;
      end;
  else
    Result := $FF;
  end;
end;

procedure TGBMMU.Write8(Addr: Word; Value: Byte);
var
  A, Off: Word;
  I: Integer;
  Src: Word;
  WBank: Byte;
  Idx: Byte;
begin
  { Write 路径保持与 Read 路径对称，并在 I/O 地址应用副作用。 }
  Addr := Addr and $FFFF;
  case Addr shr 8 of
    $00..$3F, $40..$7F:
      { 写 ROM 地址实际上是在写 MBC 控制寄存器。 }
      if Assigned(FCart) then
        FCart.WriteROM(Addr, Value);
    $80..$9F:
      begin
        { VRAM 写入；用于调试统计 VRAM 活跃度。 }
        Off := Addr - $8000;
        FVRAM[Off + Word(VRAMBank0or1) * $2000] := Value;
        Inc(FVRAMWriteCount);
        if Value > FVRAMMaxByte then
          FVRAMMaxByte := Value;
      end;
    $A0..$BF:
      if Assigned(FCart) then
        FCart.WriteRAM(Addr, Value);
    $C0..$DF:
      begin
        if Addr < $D000 then
          FWRAM[Addr - $C000] := Value
        else
        begin
          WBank := WRAMBank1To7;
          FWRAM[$1000 * WBank + (Addr - $D000)] := Value;
        end;
      end;
    $E0..$FD:
      begin
        { Echo RAM 镜像写。 }
        A := Addr - $2000;
        if A < $D000 then
          FWRAM[A - $C000] := Value
        else
        begin
          WBank := WRAMBank1To7;
          FWRAM[$1000 * WBank + (A - $D000)] := Value;
        end;
      end;
    $FE:
      if Addr < $FEA0 then
      begin
        { OAM 在 DMA 活跃或 PPU mode2/3 时屏蔽 CPU 写。 }
        if (not FDMAActive) and not (Assigned(FPPU) and ((FPPU.LCDC and $80) <> 0) and (FPPU.Mode in [2, 3])) then
          FOAM[Addr - $FE00] := Value;
      end;
    $FF:
      case Addr of
        $FF00:
          FJoypad.WriteP1(Value);
        $FF01: FSerial[0] := Value;
        $FF02: begin
                 FSerial[1] := Value;
                 { SC bit7=start 且 bit0=internal clock 时启动传输。 }
                 if ((Value and $81) = $81) then
                 begin
                   FSerialActive := True;
                   FSerialCycles := 0;
                 end;
               end;
        $FF04..$FF07: if Assigned(FTimer) then FTimer.Write(Addr, Value);
        $FF0F: FIF := Value and $1F;
        $FF10..$FF3F: if Assigned(FAPU) then FAPU.Write(Addr, Value);
        $FF40..$FF45, $FF4A..$FF4B: if Assigned(FPPU) then FPPU.Write(Addr, Value);
        $FF47: FBGP := Value;
        $FF48: FOBP0 := Value;
        $FF49: FOBP1 := Value;
        $FF4F:
          if FCGBMode then
            FVBK := Value and 1;
        $FF4D:
          if FCGBMode then
          begin
            { KEY1: 仅 bit0 可写（prepare speed switch），bit7 只读当前速度。 }
            FKEY1 := (FKEY1 and $80) or (Value and 1);
            Inc(FKey1Writes);
          end;
        $FF51:
          if FCGBMode then
            FHDMA1 := Value;
        $FF52:
          if FCGBMode then
            FHDMA2 := Value and $F0;
        $FF53:
          if FCGBMode then
            FHDMA3 := Value and $1F;
        $FF54:
          if FCGBMode then
            FHDMA4 := Value and $F0;
        $FF55:
          if FCGBMode then
          begin
            { HDMA5:
              - bit7=1: HBlank DMA（分块）
              - bit7=0: General DMA（立即全部传完）
              - HBlank 活跃时写 bit7=0 可中止。 }
            if FHDMAActive and FHDMAHBlank and ((Value and $80) = 0) then
            begin
              FHDMAActive := False;
              FHDMAHBlank := False;
              FHDMA5 := $80 or ((FHDMABlocksRemaining - 1) and $7F);
            end
            else
            begin
              FHDMASource := (Word(FHDMA1) shl 8) or (Word(FHDMA2) and $F0);
              FHDMADest := $8000 or ((Word(FHDMA3 and $1F) shl 8) or (Word(FHDMA4) and $F0));
              FHDMABlocksRemaining := (Value and $7F) + 1;
              if (Value and $80) <> 0 then
              begin
                FHDMAActive := True;
                FHDMAHBlank := True;
                FHDMA5 := (FHDMABlocksRemaining - 1) and $7F; { bit7=0 while active }
              end
              else
              begin
                FHDMAActive := False;
                FHDMAHBlank := False;
                while FHDMABlocksRemaining > 0 do
                  ExecuteHDMABlock;
                FHDMA5 := $FF;
              end;
            end;
          end;
        $FF68:
          if FCGBMode then
            FBGPI := Value;
        $FF69:
          if FCGBMode then
          begin
            { BG palette data: BGPI bit7=1 时写后自动递增索引。 }
            Idx := FBGPI and $3F;
            FBGPaletteRAM[Idx] := Value;
            if (FBGPI and $80) <> 0 then
              FBGPI := (FBGPI and $80) or ((Idx + 1) and $3F);
          end;
        $FF6A:
          if FCGBMode then
            FOBPI := Value;
        $FF6B:
          if FCGBMode then
          begin
            { OBJ palette data: OBPI bit7=1 时写后自动递增索引。 }
            Idx := FOBPI and $3F;
            FOBPaletteRAM[Idx] := Value;
            if (FOBPI and $80) <> 0 then
              FOBPI := (FOBPI and $80) or ((Idx + 1) and $3F);
          end;
        $FF70:
          if FCGBMode then
            FSVBK := Value and 7;
        $FF46:
          begin
            { OAM DMA: 从 XX00-XX9F 复制 160 字节到 FE00-FE9F。
              这里一次性拷贝数据，另用 FDMACycles 维持“DMA 活跃窗口”时序屏蔽。 }
            FDMA := Value;
            FDMAActive := True;
            FDMACycles := 0;
            Src := Word(Value) shl 8;
            for I := 0 to 159 do
              FOAM[I] := Read8(Src + I);
          end;
        $FF80..$FFFE: FHRAM[Addr - $FF80] := Value;
        $FFFF: FIE := Value and $1F;
      else
        if Addr <= $FF7F then
          FIORegs[Addr - $FF00] := Value;
      end;
  end;
  if Assigned(FOnDebugWrite) then
    FOnDebugWrite(Addr, Value);
end;

procedure TGBMMU.CpuTick(Cycles: Cardinal);
var
  EffectivePPU: Cardinal;
  TimerCycles: Cardinal;
  OldMode, NewMode: Byte;
  OldLY: Byte;
begin
  { CPU 每条指令结束后回调:
    - timer/APU/serial 跟随 CPU 速度（双速时更快）
    - PPU 固定“正常速率”，双速时相当于每 2 CPU cycles 才走 1 PPU cycle。 }
  if FDoubleSpeed then
  begin
    { In CGB double-speed mode, CPU/timer run faster, while PPU timing stays at normal speed. }
    TimerCycles := Cycles;
    FSpeedTickRemainder := FSpeedTickRemainder + Cycles;
    EffectivePPU := FSpeedTickRemainder shr 1;
    FSpeedTickRemainder := FSpeedTickRemainder and 1;
  end
  else
  begin
    TimerCycles := Cycles;
    EffectivePPU := Cycles;
  end;

  if (TimerCycles > 0) and Assigned(FTimer) then
    FTimer.Update(TimerCycles);
  if (TimerCycles > 0) and Assigned(FAPU) then
    FAPU.Update(TimerCycles);
  if TimerCycles > 0 then
    UpdateSerial(TimerCycles);
  if (EffectivePPU > 0) and Assigned(FPPU) then
  begin
    OldMode := FPPU.Mode;
    OldLY := FPPU.LY;
    FPPU.Update(EffectivePPU);
    NewMode := FPPU.Mode;
    MaybeStepHBlankHDMA(OldMode, NewMode, OldLY, EffectivePPU);
  end;
  if FDMAActive then
  begin
    FDMACycles := FDMACycles + EffectivePPU;
    if FDMACycles >= 160 * 4 then
      FDMAActive := False;
  end;
end;

procedure TGBMMU.CpuTickTimerOnly(Cycles: Cardinal);
begin
  { 扫描线调度下，CPU 与 PPU 在更高层分开推进，这里只推 timer/APU/serial。 }
  UpdateSerial(Cycles);
  if Assigned(FAPU) then
    FAPU.Update(Cycles);
  if Assigned(FTimer) then
    FTimer.Update(Cycles);
  if FDMAActive then
  begin
    FDMACycles := FDMACycles + Cycles;
    if FDMACycles >= 160 * 4 then
      FDMAActive := False;
  end;
end;

function TGBMMU.HandleStop: Boolean;
begin
  { CGB STOP + KEY1.bit0=1 触发速度切换。
    这里返回 True 告诉 CPU: STOP 已被“速度切换”消费，不进入普通停机。 }
  Result := False;
  if FCGBMode and ((FKEY1 and $01) <> 0) then
  begin
    if Assigned(FTimer) then
      FTimer.Write($FF04, 0); { CGB speed switch resets DIV }
    FDoubleSpeed := not FDoubleSpeed;
    FKEY1 := 0;
    if FDoubleSpeed then
      FKEY1 := $80;
    Inc(FStopSwitches);
    Result := True;
  end;
end;

procedure TGBMMU.OnCpuBusAccess(Addr: Word; IsWrite: Boolean);
var
  Ticks: UInt64;
begin
  { CPU 普通总线访问回调（来自 TCpu 的 OnBusAccess）。 }
  if FCGBMode then
  begin
    FPendingBusOAMValid := False;
    Exit;
  end;

  if Assigned(FCpu) then
    Ticks := FCpu.TotalTicks
  else
    Ticks := 0;

  FlushPendingBusOAM(Ticks);

  { Bus reads/writes to $FE00-$FEFF during mode 2 can corrupt OAM.
    Delay application one callback so IDU in the same M-cycle can combine. }
  if (Addr >= $FE00) and (Addr <= $FEFF) and Assigned(FPPU) and FPPU.InMode2 then
  begin
    FPendingBusOAMValid := True;
    FPendingBusOAMRead := not IsWrite;
    FPendingBusTicks := Ticks;
  end;
end;

procedure TGBMMU.OnCpuIDUOp(Addr: Word; Kind: Byte);
var
  Ticks: UInt64;
  IDUWrite: Boolean;
  IDUInOAM: Boolean;
  Combined: Boolean;
begin
  { CPU 内部 IDU 地址更新操作回调（来自 TCpu 的 OnIDUOp）。 }
  if FCGBMode then
  begin
    FPendingBusOAMValid := False;
    Exit;
  end;

  if Assigned(FCpu) then
    Ticks := FCpu.TotalTicks
  else
    Ticks := 0;

  FlushPendingBusOAM(Ticks);

  { IDU operations glitch as write-like corruption when register is in OAM range.
    POP/RET quirk: second SP increment (kind=4) has no glitched write. }
  IDUWrite := (Kind <> 4);
  IDUInOAM := (Addr >= $FE00) and (Addr <= $FEFF) and Assigned(FPPU) and FPPU.InMode2;
  Combined := False;

  if FPendingBusOAMValid and (FPendingBusTicks = Ticks) and IDUWrite and IDUInOAM then
  begin
    if FPendingBusOAMRead then
      ApplyOAMCorruptionKind(2) { read + glitched write in same M-cycle }
    else
      ApplyOAMCorruptionKind(1); { write + glitched write behaves like write }
    FPendingBusOAMValid := False;
    Combined := True;
  end;

  if (not Combined) and IDUWrite and IDUInOAM then
    ApplyOAMCorruptionKind(1);
end;

function TGBMMU.Read16(Addr: Word): Word;
begin
  { 小端序 16-bit 读。 }
  Result := Read8(Addr) or (Word(Read8((Addr + 1) and $FFFF)) shl 8);
end;

procedure TGBMMU.Write16(Addr: Word; Value: Word);
begin
  { 小端序 16-bit 写，低字节在前。 }
  Addr := Addr and $FFFF;
  Write8(Addr, Byte(Value and $FF));
  Write8((Addr + 1) and $FFFF, Byte(Value shr 8));
end;

end.
