unit gb_mmu;

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
    property ForceCGBMode: Boolean read FForceCGBMode write FForceCGBMode;
    function ReadCGBPaletteColor(IsOBJ: Boolean; PaletteIndex, ColorIndex: Byte): Word;
  end;

implementation

function TGBMMU.WRAMBank1To7: Byte;
begin
  if not FCGBMode then
    Exit(1);
  Result := FSVBK and 7;
  if Result = 0 then
    Result := 1;
end;

function TGBMMU.VRAMBank0or1: Byte;
begin
  if not FCGBMode then
    Exit(0);
  Result := FVBK and 1;
end;

constructor TGBMMU.Create;
begin
  inherited Create;
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
  for I := 0 to 16383 do
    FVRAMDisplay[I] := FVRAM[I];
end;

procedure TGBMMU.UpdateSerial(Cycles: Cardinal);
var
  ByteCycles: Cardinal;
begin
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

function TGBMMU.Read8ForDisplay(Addr: Word): Byte;
var
  Off: Word;
begin
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
begin
  UpdateSerial(Cycles);
  if Assigned(FAPU) then
    FAPU.Update(Cycles);
  if Assigned(FTimer) then
    FTimer.Update(Cycles);
  if Assigned(FPPU) then
    FPPU.Update(Cycles);
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
  Addr := Addr and $FFFF;
  case Addr shr 8 of
    $00..$3F, $40..$7F:
      if Assigned(FCart) then
        Result := FCart.ReadROM(Addr)
      else
        Result := $FF;
    $80..$9F:
      begin
        Off := Addr - $8000;
        Result := FVRAM[Off + Word(VRAMBank0or1) * $2000];
      end;
    $A0..$BF:
      if Assigned(FCart) then
        Result := FCart.ReadRAM(Addr)
      else
        Result := $FF;
    $C0..$DF:
      begin
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
        if Assigned(FPPU) and ((FPPU.LCDC and $80) <> 0) and (FPPU.Mode in [2, 3]) then
          Result := $FF
        else
          Result := FOAM[Addr - $FE00];
      end
      else
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
  Addr := Addr and $FFFF;
  case Addr shr 8 of
    $00..$3F, $40..$7F:
      if Assigned(FCart) then
        FCart.WriteROM(Addr, Value);
    $80..$9F:
      begin
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
            FKEY1 := (FKEY1 and $80) or (Value and 1);
            Inc(FKey1Writes);
          end;
        $FF68:
          if FCGBMode then
            FBGPI := Value;
        $FF69:
          if FCGBMode then
          begin
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
begin
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
    FPPU.Update(EffectivePPU);
  if FDMAActive then
  begin
    FDMACycles := FDMACycles + EffectivePPU;
    if FDMACycles >= 160 * 4 then
      FDMAActive := False;
  end;
end;

procedure TGBMMU.CpuTickTimerOnly(Cycles: Cardinal);
begin
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
  Result := Read8(Addr) or (Word(Read8((Addr + 1) and $FFFF)) shl 8);
end;

procedure TGBMMU.Write16(Addr: Word; Value: Word);
begin
  Addr := Addr and $FFFF;
  Write8(Addr, Byte(Value and $FF));
  Write8((Addr + 1) and $FFFF, Byte(Value shr 8));
end;

end.
