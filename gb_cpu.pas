unit gb_cpu;

{ Game Boy (LR35902) CPU unit. Full instruction set, classic Delphi, no generics. }

interface

type
  TRead8Func = function(Addr: Word): Byte of object;
  TWrite8Proc = procedure(Addr: Word; Value: Byte) of object;
  TTickProc = procedure(Cycles: Cardinal) of object;
  TStopFunc = function: Boolean of object;
  TBusAccessProc = procedure(Addr: Word; IsWrite: Boolean) of object;
  TIDUOpProc = procedure(Addr: Word; Kind: Byte) of object;

  TCpu = class
  private
    FRegA: Byte;
    FRegF: Byte;
    FRegB: Byte;
    FRegC: Byte;
    FRegD: Byte;
    FRegE: Byte;
    FRegH: Byte;
    FRegL: Byte;
    FSP: Word;
    FPC: Word;
    FIME: Boolean;           { Interrupt Master Enable }
    FIMEDelaySteps: Byte;    { EI takes effect after next instruction }
    FStopped: Boolean;       { STOP executed }
    FHalted: Boolean;        { HALT executed }
    FHaltBug: Boolean;       { HALT bug: next opcode fetch does not increment PC }
    FCycles: Cardinal;      { Cycles consumed by last Step }
    FTotalTicks: UInt64;    { Total T-cycles elapsed since reset }
    FStepTickCycles: Cardinal;
    FOnRead8: TRead8Func;
    FOnWrite8: TWrite8Proc;
    FOnTick: TTickProc;
    FOnStop: TStopFunc;
    FOnBusAccess: TBusAccessProc;
    FOnIDUOp: TIDUOpProc;
    procedure NotifyIDUOp(Addr: Word; Kind: Byte);
    procedure TickBus(Cycles: Cardinal);
    procedure DrainTicks;
    function Peek8(Addr: Word): Byte;
    function Read8(Addr: Word): Byte;
    procedure Write8(Addr: Word; Value: Byte);
    function Read16(Addr: Word): Word;
    procedure Write16(Addr: Word; Value: Word);
    { Flag helpers. F only uses bits 7-4: Z N H C }
    function GetZ: Boolean;
    function GetN: Boolean;
    function GetH: Boolean;
    function GetC: Boolean;
    procedure SetZ(Value: Boolean);
    procedure SetN(Value: Boolean);
    procedure SetH(Value: Boolean);
    procedure SetC(Value: Boolean);
    function GetR8(Index: Byte): Byte;
    procedure SetR8(Index: Byte; Value: Byte);
    function GetHL: Word;
    procedure SetHL(const Value: Word);
  public
    procedure Reset;
    procedure Step;
    { Memory bus: assign from MMU }
    property OnRead8: TRead8Func read FOnRead8 write FOnRead8;
    property OnWrite8: TWrite8Proc read FOnWrite8 write FOnWrite8;
    property OnTick: TTickProc read FOnTick write FOnTick;
    property OnStop: TStopFunc read FOnStop write FOnStop;
    property OnBusAccess: TBusAccessProc read FOnBusAccess write FOnBusAccess;
    property OnIDUOp: TIDUOpProc read FOnIDUOp write FOnIDUOp;
    { State }
    property Cycles: Cardinal read FCycles;
    property TotalTicks: UInt64 read FTotalTicks;
    property IME: Boolean read FIME write FIME;
    property Stopped: Boolean read FStopped;
    property Halted: Boolean read FHalted write FHalted;
    { Registers }
    property A: Byte read FRegA write FRegA;
    property F: Byte read FRegF write FRegF;
    property B: Byte read FRegB write FRegB;
    property C: Byte read FRegC write FRegC;
    property D: Byte read FRegD write FRegD;
    property E: Byte read FRegE write FRegE;
    property H: Byte read FRegH write FRegH;
    property L: Byte read FRegL write FRegL;
    property SP: Word read FSP write FSP;
    property PC: Word read FPC write FPC;
    function GetAF: Word;
    function GetBC: Word;
    function GetDE: Word;
    function GetHLValue: Word;
    procedure SetAF(const Value: Word);
    procedure SetBC(const Value: Word);
    procedure SetDE(const Value: Word);
    procedure SetHLValue(const Value: Word);
  end;

const
  { Optional: set to True to trace each Step to console }
  CPU_TRACE = False;

implementation

uses
{$IFDEF FPC}
  SysUtils;
{$ELSE}
  System.SysUtils;
{$ENDIF}

const
  FLAG_Z = $80;
  FLAG_N = $40;
  FLAG_H = $20;
  FLAG_C = $10;

procedure TCpu.TickBus(Cycles: Cardinal);
begin
  Inc(FStepTickCycles, Cycles);
  Inc(FTotalTicks, Cycles);
  if Assigned(FOnTick) then
    FOnTick(Cycles);
end;

procedure TCpu.DrainTicks;
begin
  if FCycles > FStepTickCycles then
    TickBus(FCycles - FStepTickCycles);
end;

procedure TCpu.NotifyIDUOp(Addr: Word; Kind: Byte);
begin
  if Assigned(FOnIDUOp) then
    FOnIDUOp(Addr and $FFFF, Kind);
end;

function TCpu.Peek8(Addr: Word): Byte;
begin
  Addr := Addr and $FFFF;
  if Assigned(FOnRead8) then
    Result := FOnRead8(Addr)
  else
    Result := $FF;
end;

function TCpu.Read8(Addr: Word): Byte;
begin
  TickBus(4);
  Result := Peek8(Addr);
  if Assigned(FOnBusAccess) then
    FOnBusAccess(Addr and $FFFF, False);
end;

procedure TCpu.Write8(Addr: Word; Value: Byte);
begin
  TickBus(4);
  Addr := Addr and $FFFF;
  if Assigned(FOnWrite8) then
    FOnWrite8(Addr, Value);
  if Assigned(FOnBusAccess) then
    FOnBusAccess(Addr, True);
end;

function TCpu.Read16(Addr: Word): Word;
begin
  Result := Read8(Addr) or (Word(Read8((Addr + 1) and $FFFF)) shl 8);
end;

procedure TCpu.Write16(Addr: Word; Value: Word);
begin
  Addr := Addr and $FFFF;
  Write8(Addr, Byte(Value and $FF));
  Write8((Addr + 1) and $FFFF, Byte(Value shr 8));
end;

function TCpu.GetZ: Boolean;
begin
  Result := (FRegF and FLAG_Z) <> 0;
end;

function TCpu.GetN: Boolean;
begin
  Result := (FRegF and FLAG_N) <> 0;
end;

function TCpu.GetH: Boolean;
begin
  Result := (FRegF and FLAG_H) <> 0;
end;

function TCpu.GetC: Boolean;
begin
  Result := (FRegF and FLAG_C) <> 0;
end;

procedure TCpu.SetZ(Value: Boolean);
begin
  if Value then
    FRegF := FRegF or FLAG_Z
  else
    FRegF := FRegF and (not FLAG_Z);
end;

procedure TCpu.SetN(Value: Boolean);
begin
  if Value then
    FRegF := FRegF or FLAG_N
  else
    FRegF := FRegF and (not FLAG_N);
end;

procedure TCpu.SetH(Value: Boolean);
begin
  if Value then
    FRegF := FRegF or FLAG_H
  else
    FRegF := FRegF and (not FLAG_H);
end;

procedure TCpu.SetC(Value: Boolean);
begin
  if Value then
    FRegF := FRegF or FLAG_C
  else
    FRegF := FRegF and (not FLAG_C);
end;

{ r8 index: 0=B,1=C,2=D,3=E,4=H,5=L,6=(HL),7=A }
function TCpu.GetR8(Index: Byte): Byte;
var
  HL: Word;
begin
  case Index of
    0: Result := FRegB;
    1: Result := FRegC;
    2: Result := FRegD;
    3: Result := FRegE;
    4: Result := FRegH;
    5: Result := FRegL;
    6: begin
         HL := (Word(FRegH) shl 8) or FRegL;
         Result := Read8(HL);
       end;
  else
    Result := FRegA;
  end;
end;

procedure TCpu.SetR8(Index: Byte; Value: Byte);
var
  HL: Word;
begin
  case Index of
    0: FRegB := Value;
    1: FRegC := Value;
    2: FRegD := Value;
    3: FRegE := Value;
    4: FRegH := Value;
    5: FRegL := Value;
    6: begin
         HL := (Word(FRegH) shl 8) or FRegL;
         Write8(HL, Value);
       end;
  else
    FRegA := Value;
  end;
end;

function TCpu.GetHL: Word;
begin
  Result := (Word(FRegH) shl 8) or FRegL;
end;

procedure TCpu.SetHL(const Value: Word);
begin
  FRegH := Byte(Value shr 8);
  FRegL := Byte(Value and $FF);
end;

procedure TCpu.Reset;
begin
  FRegA := $01;   { DMG boot ROM passes $01 when jumping to $100 }
  FRegF := $B0;   { DMG post-boot flags }
  FRegB := 0;
  FRegC := $13;
  FRegD := 0;
  FRegE := $D8;
  FRegH := $01;
  FRegL := $4D;
  FSP := $FFFE;
  FPC := $100;
  FIME := False;
  FIMEDelaySteps := 0;
  FStopped := False;
  FHalted := False;
  FHaltBug := False;
  FCycles := 0;
  FTotalTicks := 0;
end;

const
  IRQ_VECTORS: array[0..4] of Word = ($40, $48, $50, $58, $60);

procedure TCpu.Step;
var
  Opcode, CBByte: Byte;
  Imm8: Byte;
  Imm16: Word;
  Tmp8: Byte;
  Tmp16: Word;
  Tmp32: Cardinal;
  Tmp16S: Integer;
  HL, BC, DE: Word;
  IE, IFreg, CurIF: Byte;
  I: Integer;
  procedure SPDec1;
  begin
    NotifyIDUOp(FSP, 0);
    FSP := (FSP - 1) and $FFFF;
  end;
  procedure SPInc1;
  begin
    NotifyIDUOp(FSP, 0);
    FSP := (FSP + 1) and $FFFF;
  end;
  procedure SPDec2;
  begin
    SPDec1;
    SPDec1;
  end;
  procedure PCInc1;
  begin
    NotifyIDUOp(FPC, 0);
    FPC := (FPC + 1) and $FFFF;
  end;
  procedure PCInc2;
  begin
    PCInc1;
    PCInc1;
  end;
  procedure SPInc2;
  begin
    SPInc1;
    SPInc1;
  end;
  procedure Push16(Value: Word);
  begin
    SPDec1;
    Write8(FSP, Byte(Value shr 8));
    SPDec1;
    Write8(FSP, Byte(Value and $FF));
  end;
  function Pop16IsRetFamily: Word;
  var
    Lo, Hi: Byte;
  begin
    Lo := Read8(FSP);
    NotifyIDUOp(FSP, 3);
    FSP := (FSP + 1) and $FFFF;
    Hi := Read8(FSP);
    NotifyIDUOp(FSP, 4);
    FSP := (FSP + 1) and $FFFF;
    Result := Word(Lo) or (Word(Hi) shl 8);
  end;
begin
  FCycles := 0;
  FStepTickCycles := 0;
  if FStopped then
  begin
    if (Peek8($FFFF) and Peek8($FF0F) and $1F) = 0 then
    begin
      FCycles := 4;
      DrainTicks;
      Exit;
    end;
    FStopped := False;
  end;
  if FHalted then
  begin
    if (Peek8($FFFF) and Peek8($FF0F) and $1F) = 0 then
    begin
      FCycles := 4;
      DrainTicks;
      Exit;
    end;
    { Pending IRQ wakes HALT immediately. With IME=1, IRQ service starts in this step. }
    FHalted := False;
    if not FIME then
    begin
      FCycles := 4;
      DrainTicks;
      Exit;
    end;
  end;

  { Service interrupt if IME set and pending (priority: VBlank, STAT, Timer, Serial, Joypad) }
  if FIME then
  begin
    IE := Peek8($FFFF);
    IFreg := Peek8($FF0F);
    IFreg := IFreg and $1F;
    for I := 0 to 4 do
      if ((IE and IFreg) and (1 shl I)) <> 0 then
      begin
        if FHaltBug then
        begin
          { Clear HALT bug latch before servicing IRQ. }
          FHaltBug := False;
        end;
        FIME := False;
        { Interrupt sequence timing: 2 idle M-cycles, push PC, vector fetch. }
        TickBus(8);
        CurIF := Peek8($FF0F) and $1F;
        if Assigned(FOnWrite8) then
          FOnWrite8($FF0F, CurIF and (not (1 shl I)));
        Push16(FPC);
        TickBus(4);
        FPC := IRQ_VECTORS[I];
        FCycles := 20;
        DrainTicks;
        Exit;
      end;
  end;

  Opcode := Read8(FPC);
  if FHaltBug then
    FHaltBug := False
  else
    PCInc1;
  FCycles := 4;

  if CPU_TRACE then
    WriteLn(Format('PC=$%.4x OP=$%.2x', [FPC - 1, Opcode]));

  case Opcode of
    $00: ; { NOP }
    $01: begin
           Imm16 := Read16(FPC); PCInc2;
           FRegB := Byte(Imm16 shr 8); FRegC := Byte(Imm16 and $FF);
           FCycles := 12;
         end;
    $02: begin
           BC := (Word(FRegB) shl 8) or FRegC;
           Write8(BC, FRegA);
           FCycles := 8;
         end;
    $03: begin
           BC := (Word(FRegB) shl 8) or FRegC;
           NotifyIDUOp(BC, 0);
           BC := (BC + 1) and $FFFF;
           FRegB := Byte(BC shr 8); FRegC := Byte(BC and $FF);
           FCycles := 8;
         end;
    $04: begin
           Inc(FRegB);
           SetZ(FRegB = 0);
           SetN(False);
           SetH((FRegB and $0F) = 0);
           FCycles := 4;
         end;
    $05: begin
           Dec(FRegB);
           SetZ(FRegB = 0);
           SetN(True);
           SetH((FRegB and $0F) = $0F);
           FCycles := 4;
         end;
    $06: begin
           FRegB := Read8(FPC); PCInc1;
           FCycles := 8;
         end;
    $07: begin { RLCA }
           Tmp8 := (FRegA shr 7) and 1;
           FRegA := ((FRegA shl 1) or Tmp8) and $FF;
           SetZ(False);
           SetN(False);
           SetH(False);
           SetC(Tmp8 <> 0);
           FCycles := 4;
         end;
    $08: begin
           Imm16 := Read16(FPC); PCInc2;
           Write16(Imm16, FSP);
           FCycles := 20;
         end;
    $09: begin
           HL := GetHL;
           BC := (Word(FRegB) shl 8) or FRegC;
           Tmp32 := Cardinal(HL) + Cardinal(BC);
           SetN(False);
           SetH((HL and $0FFF) + (BC and $0FFF) > $0FFF);
           SetC(Tmp32 > $FFFF);
           SetHL(Word(Tmp32 and $FFFF));
           FCycles := 8;
         end;
    $0A: begin
           BC := (Word(FRegB) shl 8) or FRegC;
           FRegA := Read8(BC);
           FCycles := 8;
         end;
    $0B: begin
           BC := (Word(FRegB) shl 8) or FRegC;
           NotifyIDUOp(BC, 0);
           BC := (BC - 1) and $FFFF;
           FRegB := Byte(BC shr 8); FRegC := Byte(BC and $FF);
           FCycles := 8;
         end;
    $0C: begin
           Inc(FRegC);
           SetZ(FRegC = 0);
           SetN(False);
           SetH((FRegC and $0F) = 0);
           FCycles := 4;
         end;
    $0D: begin
           Dec(FRegC);
           SetZ(FRegC = 0);
           SetN(True);
           SetH((FRegC and $0F) = $0F);
           FCycles := 4;
         end;
    $0E: begin
           FRegC := Read8(FPC); PCInc1;
           FCycles := 8;
         end;
    $0F: begin { RRCA }
           Tmp8 := FRegA and 1;
           FRegA := (FRegA shr 1) or (Tmp8 shl 7);
           SetZ(False);
           SetN(False);
           SetH(False);
           SetC(Tmp8 <> 0);
           FCycles := 4;
         end;
    $10: begin { STOP; next byte consumed }
           Read8(FPC);
           PCInc1;
           if Assigned(FOnStop) and FOnStop then
           begin
             FStopped := False;
             FCycles := 4;
           end
           else
           begin
             FStopped := True;
             FCycles := 4;
           end;
         end;
    $11: begin
           Imm16 := Read16(FPC); PCInc2;
           FRegD := Byte(Imm16 shr 8); FRegE := Byte(Imm16 and $FF);
           FCycles := 12;
         end;
    $12: begin
           DE := (Word(FRegD) shl 8) or FRegE;
           Write8(DE, FRegA);
           FCycles := 8;
         end;
    $13: begin
           DE := (Word(FRegD) shl 8) or FRegE;
           NotifyIDUOp(DE, 0);
           DE := (DE + 1) and $FFFF;
           FRegD := Byte(DE shr 8); FRegE := Byte(DE and $FF);
           FCycles := 8;
         end;
    $14: begin
           Inc(FRegD);
           SetZ(FRegD = 0);
           SetN(False);
           SetH((FRegD and $0F) = 0);
           FCycles := 4;
         end;
    $15: begin
           Dec(FRegD);
           SetZ(FRegD = 0);
           SetN(True);
           SetH((FRegD and $0F) = $0F);
           FCycles := 4;
         end;
    $16: begin
           FRegD := Read8(FPC); PCInc1;
           FCycles := 8;
         end;
    $17: begin { RLA }
           Tmp8 := Byte(Ord(GetC));
           SetC((FRegA and $80) <> 0);
           FRegA := ((FRegA shl 1) or Tmp8) and $FF;
           SetZ(False);
           SetN(False);
           SetH(False);
           FCycles := 4;
         end;
    $18: begin
           Imm8 := Read8(FPC); PCInc1;
           FPC := (FPC + ShortInt(Imm8)) and $FFFF;
           FCycles := 12;
         end;
    $19: begin
           HL := GetHL;
           DE := (Word(FRegD) shl 8) or FRegE;
           Tmp32 := Cardinal(HL) + Cardinal(DE);
           SetN(False);
           SetH((HL and $0FFF) + (DE and $0FFF) > $0FFF);
           SetC(Tmp32 > $FFFF);
           SetHL(Word(Tmp32 and $FFFF));
           FCycles := 8;
         end;
    $1A: begin
           DE := (Word(FRegD) shl 8) or FRegE;
           FRegA := Read8(DE);
           FCycles := 8;
         end;
    $1B: begin
           DE := (Word(FRegD) shl 8) or FRegE;
           NotifyIDUOp(DE, 0);
           DE := (DE - 1) and $FFFF;
           FRegD := Byte(DE shr 8); FRegE := Byte(DE and $FF);
           FCycles := 8;
         end;
    $1C: begin
           Inc(FRegE);
           SetZ(FRegE = 0);
           SetN(False);
           SetH((FRegE and $0F) = 0);
           FCycles := 4;
         end;
    $1D: begin
           Dec(FRegE);
           SetZ(FRegE = 0);
           SetN(True);
           SetH((FRegE and $0F) = $0F);
           FCycles := 4;
         end;
    $1E: begin
           FRegE := Read8(FPC); PCInc1;
           FCycles := 8;
         end;
    $1F: begin { RRA }
           Tmp8 := Byte(Ord(GetC));
           SetC((FRegA and 1) <> 0);
           FRegA := (FRegA shr 1) or (Tmp8 shl 7);
           SetZ(False);
           SetN(False);
           SetH(False);
           FCycles := 4;
         end;
    $20: begin { JR NZ }
           Imm8 := Read8(FPC); PCInc1;
           if not GetZ then
           begin
             FPC := (FPC + ShortInt(Imm8)) and $FFFF;
             FCycles := 12;
           end
           else
             FCycles := 8;
         end;
    $21: begin
           Imm16 := Read16(FPC); PCInc2;
           FRegH := Byte(Imm16 shr 8); FRegL := Byte(Imm16 and $FF);
           FCycles := 12;
         end;
    $22: begin
           HL := GetHL;
           Write8(HL, FRegA);
           NotifyIDUOp(HL, 2);
           SetHL((HL + 1) and $FFFF);
           FCycles := 8;
         end;
    $23: begin
           HL := GetHL;
           NotifyIDUOp(HL, 0);
           SetHL((HL + 1) and $FFFF);
           FCycles := 8;
         end;
    $24: begin
           Inc(FRegH);
           SetZ(FRegH = 0);
           SetN(False);
           SetH((FRegH and $0F) = 0);
           FCycles := 4;
         end;
    $25: begin
           Dec(FRegH);
           SetZ(FRegH = 0);
           SetN(True);
           SetH((FRegH and $0F) = $0F);
           FCycles := 4;
         end;
    $26: begin
           FRegH := Read8(FPC); PCInc1;
           FCycles := 8;
         end;
    $27: begin { DAA }
           Tmp8 := FRegA;
           if not GetN then
           begin
             if GetC or (Tmp8 > $99) then begin Inc(Tmp8, $60); SetC(True); end;
             if GetH or ((Tmp8 and $0F) > 9) then Inc(Tmp8, $06);
           end
           else
           begin
             if GetC then Dec(Tmp8, $60);
             if GetH then Dec(Tmp8, $06);
           end;
           FRegA := Tmp8 and $FF;
           SetZ(FRegA = 0);
           SetH(False);
           FCycles := 4;
         end;
    $28: begin { JR Z }
           Imm8 := Read8(FPC); PCInc1;
           if GetZ then
           begin
             FPC := (FPC + ShortInt(Imm8)) and $FFFF;
             FCycles := 12;
           end
           else
             FCycles := 8;
         end;
    $29: begin
           HL := GetHL;
           Tmp32 := Cardinal(HL) + Cardinal(HL);
           SetN(False);
           SetH((HL and $0FFF) * 2 > $0FFF);
           SetC(Tmp32 > $FFFF);
           SetHL(Word(Tmp32 and $FFFF));
           FCycles := 8;
         end;
    $2A: begin
           HL := GetHL;
           FRegA := Read8(HL);
           NotifyIDUOp(HL, 1);
           SetHL((HL + 1) and $FFFF);
           FCycles := 8;
         end;
    $2B: begin
           HL := GetHL;
           NotifyIDUOp(HL, 0);
           SetHL((HL - 1) and $FFFF);
           FCycles := 8;
         end;
    $2C: begin
           Inc(FRegL);
           SetZ(FRegL = 0);
           SetN(False);
           SetH((FRegL and $0F) = 0);
           FCycles := 4;
         end;
    $2D: begin
           Dec(FRegL);
           SetZ(FRegL = 0);
           SetN(True);
           SetH((FRegL and $0F) = $0F);
           FCycles := 4;
         end;
    $2E: begin
           FRegL := Read8(FPC); PCInc1;
           FCycles := 8;
         end;
    $2F: begin { CPL }
           FRegA := (not FRegA) and $FF;
           SetN(True);
           SetH(True);
           FCycles := 4;
         end;
    $30: begin { JR NC }
           Imm8 := Read8(FPC); PCInc1;
           if not GetC then
           begin
             FPC := (FPC + ShortInt(Imm8)) and $FFFF;
             FCycles := 12;
           end
           else
             FCycles := 8;
         end;
    $31: begin
           Imm16 := Read16(FPC); PCInc2;
           FSP := Imm16;
           FCycles := 12;
         end;
    $32: begin
           HL := GetHL;
           Write8(HL, FRegA);
           NotifyIDUOp(HL, 2);
           SetHL((HL - 1) and $FFFF);
           FCycles := 8;
         end;
    $33: begin
           SPInc1;
           FCycles := 8;
         end;
    $34: begin
           HL := GetHL;
           Tmp8 := Read8(HL);
           Inc(Tmp8);
           Write8(HL, Tmp8);
           SetZ(Tmp8 = 0);
           SetN(False);
           SetH((Tmp8 and $0F) = 0);
           FCycles := 12;
         end;
    $35: begin
           HL := GetHL;
           Tmp8 := Read8(HL);
           Dec(Tmp8);
           Write8(HL, Tmp8);
           SetZ(Tmp8 = 0);
           SetN(True);
           SetH((Tmp8 and $0F) = $0F);
           FCycles := 12;
         end;
    $36: begin
           HL := GetHL;
           Imm8 := Read8(FPC); PCInc1;
           Write8(HL, Imm8);
           FCycles := 12;
         end;
    $37: begin { SCF }
           SetN(False);
           SetH(False);
           SetC(True);
           FCycles := 4;
         end;
    $38: begin { JR C }
           Imm8 := Read8(FPC); PCInc1;
           if GetC then
           begin
             FPC := (FPC + ShortInt(Imm8)) and $FFFF;
             FCycles := 12;
           end
           else
             FCycles := 8;
         end;
    $39: begin
           HL := GetHL;
           Tmp32 := Cardinal(HL) + Cardinal(FSP);
           SetN(False);
           SetH((HL and $0FFF) + (FSP and $0FFF) > $0FFF);
           SetC(Tmp32 > $FFFF);
           SetHL(Word(Tmp32 and $FFFF));
           FCycles := 8;
         end;
    $3A: begin
           HL := GetHL;
           FRegA := Read8(HL);
           NotifyIDUOp(HL, 1);
           SetHL((HL - 1) and $FFFF);
           FCycles := 8;
         end;
    $3B: begin
           SPDec1;
           FCycles := 8;
         end;
    $3C: begin
           Inc(FRegA);
           SetZ(FRegA = 0);
           SetN(False);
           SetH((FRegA and $0F) = 0);
           FCycles := 4;
         end;
    $3D: begin
           Dec(FRegA);
           SetZ(FRegA = 0);
           SetN(True);
           SetH((FRegA and $0F) = $0F);
           FCycles := 4;
         end;
    $3E: begin
           FRegA := Read8(FPC); PCInc1;
           FCycles := 8;
         end;
    $3F: begin { CCF }
           SetN(False);
           SetH(False);
           SetC(not GetC);
           FCycles := 4;
         end;
    $40..$75, $77..$7F: begin { LD r8, r8 (excluding $76 = HALT) }
           SetR8((Opcode shr 3) and 7, GetR8(Opcode and 7));
           if ((Opcode and 7) = 6) or (((Opcode shr 3) and 7) = 6) then
             FCycles := 8
           else
             FCycles := 4;
         end;
    $76: begin { HALT }
           if (not FIME) and ((Peek8($FFFF) and Peek8($FF0F) and $1F) <> 0) then
             FHaltBug := True
           else
             FHalted := True;
           FCycles := 4;
         end;
    $80..$87: begin { ADD A, r8 }
           Tmp8 := GetR8(Opcode and 7);
           SetZ((FRegA + Tmp8) and $FF = 0);
           SetN(False);
           SetH((FRegA and $0F) + (Tmp8 and $0F) > $0F);
           SetC(FRegA + Tmp8 > $FF);
           FRegA := (FRegA + Tmp8) and $FF;
           if (Opcode and 7) = 6 then FCycles := 8 else FCycles := 4;
         end;
    $88..$8F: begin { ADC A, r8 }
           Tmp8 := GetR8(Opcode and 7);
           Tmp16 := FRegA + Tmp8 + Byte(Ord(GetC));
           SetZ(Byte(Tmp16 and $FF) = 0);
           SetN(False);
           SetH((FRegA and $0F) + (Tmp8 and $0F) + Ord(GetC) > $0F);
           SetC(Tmp16 > $FF);
           FRegA := Byte(Tmp16 and $FF);
           if (Opcode and 7) = 6 then FCycles := 8 else FCycles := 4;
         end;
    $90..$97: begin { SUB A, r8 }
           Tmp8 := GetR8(Opcode and 7);
           SetZ((FRegA - Tmp8) and $FF = 0);
           SetN(True);
           SetH((FRegA and $0F) < (Tmp8 and $0F));
           SetC(FRegA < Tmp8);
           FRegA := (FRegA - Tmp8) and $FF;
           if (Opcode and 7) = 6 then FCycles := 8 else FCycles := 4;
         end;
    $98..$9F: begin { SBC A, r8 }
           Tmp8 := GetR8(Opcode and 7);
           Tmp16S := Integer(FRegA) - Integer(Tmp8) - Integer(Ord(GetC));
           SetZ(Byte(Tmp16S and $FF) = 0);
           SetN(True);
           SetH((FRegA and $0F) < (Tmp8 and $0F) + Ord(GetC));
           SetC(Tmp16S < 0);
           FRegA := Byte(Tmp16S and $FF);
           if (Opcode and 7) = 6 then FCycles := 8 else FCycles := 4;
         end;
    $A0..$A7: begin { AND A, r8 }
           FRegA := FRegA and GetR8(Opcode and 7);
           SetZ(FRegA = 0);
           SetN(False);
           SetH(True);
           SetC(False);
           if (Opcode and 7) = 6 then FCycles := 8 else FCycles := 4;
         end;
    $A8..$AF: begin { XOR A, r8 }
           FRegA := FRegA xor GetR8(Opcode and 7);
           SetZ(FRegA = 0);
           SetN(False);
           SetH(False);
           SetC(False);
           if (Opcode and 7) = 6 then FCycles := 8 else FCycles := 4;
         end;
    $B0..$B7: begin { OR A, r8 }
           FRegA := FRegA or GetR8(Opcode and 7);
           SetZ(FRegA = 0);
           SetN(False);
           SetH(False);
           SetC(False);
           if (Opcode and 7) = 6 then FCycles := 8 else FCycles := 4;
         end;
    $B8..$BF: begin { CP A, r8 }
           Tmp8 := GetR8(Opcode and 7);
           SetZ(FRegA = Tmp8);
           SetN(True);
           SetH((FRegA and $0F) < (Tmp8 and $0F));
           SetC(FRegA < Tmp8);
           if (Opcode and 7) = 6 then FCycles := 8 else FCycles := 4;
         end;
    $C0: begin { RET NZ }
           if not GetZ then
           begin
             FPC := Pop16IsRetFamily;
             FCycles := 20;
           end
           else
             FCycles := 8;
         end;
    $C1: begin
           Tmp16 := Pop16IsRetFamily;
           FRegB := Byte(Tmp16 shr 8);
           FRegC := Byte(Tmp16 and $FF);
           FCycles := 12;
         end;
    $C2: begin { JP NZ, imm16 }
           Imm16 := Read16(FPC); PCInc2;
           if not GetZ then
           begin
             FPC := Imm16;
             FCycles := 16;
           end
           else
             FCycles := 12;
         end;
    $C3: begin
           Imm16 := Read16(FPC); PCInc2;
           FPC := Imm16;
           FCycles := 16;
         end;
    $C4: begin { CALL NZ, imm16 }
           Imm16 := Read16(FPC); PCInc2;
           if not GetZ then
           begin
             Push16(FPC);
             FPC := Imm16;
             FCycles := 24;
           end
           else
             FCycles := 12;
         end;
    $C5: begin
           Push16((Word(FRegB) shl 8) or FRegC);
           FCycles := 16;
         end;
    $C6: begin
           Imm8 := Read8(FPC); PCInc1;
           SetZ((FRegA + Imm8) and $FF = 0);
           SetN(False);
           SetH((FRegA and $0F) + (Imm8 and $0F) > $0F);
           SetC(FRegA + Imm8 > $FF);
           FRegA := (FRegA + Imm8) and $FF;
           FCycles := 8;
         end;
    $C7: begin
           Push16(FPC);
           FPC := $00;
           FCycles := 16;
         end;
    $C8: begin { RET Z }
           if GetZ then
           begin
             FPC := Pop16IsRetFamily;
             FCycles := 20;
           end
           else
             FCycles := 8;
         end;
    $C9: begin
           FPC := Pop16IsRetFamily;
           FCycles := 16;
         end;
    $CA: begin { JP Z, imm16 }
           Imm16 := Read16(FPC); PCInc2;
           if GetZ then
           begin
             FPC := Imm16;
             FCycles := 16;
           end
           else
             FCycles := 12;
         end;
    $CB: begin
           CBByte := Read8(FPC);
           PCInc1;
           FCycles := 8;
           { CB prefix handled below in separate block }
           case CBByte of
             $00..$07: begin { RLC r8 }
                        Tmp8 := GetR8(CBByte and 7);
                        Tmp16 := (Tmp8 shl 1) or (Tmp8 shr 7);
                        SetR8(CBByte and 7, Byte(Tmp16 and $FF));
                        SetZ(Byte(Tmp16) = 0);
                        SetN(False);
                        SetH(False);
                        SetC((Tmp8 and $80) <> 0);
                        if (CBByte and 7) = 6 then Inc(FCycles, 8);
                      end;
             $08..$0F: begin { RRC r8 }
                        Tmp8 := GetR8(CBByte and 7);
                        Tmp16 := (Tmp8 shr 1) or ((Tmp8 and 1) shl 7);
                        SetR8(CBByte and 7, Byte(Tmp16));
                        SetZ(Byte(Tmp16) = 0);
                        SetN(False);
                        SetH(False);
                        SetC((Tmp8 and 1) <> 0);
                        if (CBByte and 7) = 6 then Inc(FCycles, 8);
                      end;
             $10..$17: begin { RL r8 }
                        Tmp8 := GetR8(CBByte and 7);
                        Tmp16 := (Tmp8 shl 1) or Byte(Ord(GetC));
                        SetR8(CBByte and 7, Byte(Tmp16 and $FF));
                        SetZ(Byte(Tmp16 and $FF) = 0);
                        SetN(False);
                        SetH(False);
                        SetC((Tmp8 and $80) <> 0);
                        if (CBByte and 7) = 6 then Inc(FCycles, 8);
                      end;
             $18..$1F: begin { RR r8 }
                        Tmp8 := GetR8(CBByte and 7);
                        Tmp16 := (Tmp8 shr 1) or (Byte(Ord(GetC)) shl 7);
                        SetR8(CBByte and 7, Byte(Tmp16));
                        SetZ(Byte(Tmp16) = 0);
                        SetN(False);
                        SetH(False);
                        SetC((Tmp8 and 1) <> 0);
                        if (CBByte and 7) = 6 then Inc(FCycles, 8);
                      end;
             $20..$27: begin { SLA r8 }
                        Tmp8 := GetR8(CBByte and 7);
                        SetC((Tmp8 and $80) <> 0);
                        Tmp8 := (Tmp8 shl 1) and $FF;
                        SetR8(CBByte and 7, Tmp8);
                        SetZ(Tmp8 = 0);
                        SetN(False);
                        SetH(False);
                        if (CBByte and 7) = 6 then Inc(FCycles, 8);
                      end;
             $28..$2F: begin { SRA r8 }
                        Tmp8 := GetR8(CBByte and 7);
                        SetC((Tmp8 and 1) <> 0);
                        Tmp8 := (Tmp8 shr 1) or (Tmp8 and $80);
                        SetR8(CBByte and 7, Tmp8);
                        SetZ(Tmp8 = 0);
                        SetN(False);
                        SetH(False);
                        if (CBByte and 7) = 6 then Inc(FCycles, 8);
                      end;
             $30..$37: begin { SWAP r8 }
                        Tmp8 := GetR8(CBByte and 7);
                        Tmp8 := ((Tmp8 and $0F) shl 4) or (Tmp8 shr 4);
                        SetR8(CBByte and 7, Tmp8);
                        SetZ(Tmp8 = 0);
                        SetN(False);
                        SetH(False);
                        SetC(False);
                        if (CBByte and 7) = 6 then Inc(FCycles, 8);
                      end;
             $38..$3F: begin { SRL r8 }
                        Tmp8 := GetR8(CBByte and 7);
                        SetC((Tmp8 and 1) <> 0);
                        Tmp8 := Tmp8 shr 1;
                        SetR8(CBByte and 7, Tmp8);
                        SetZ(Tmp8 = 0);
                        SetN(False);
                        SetH(False);
                        if (CBByte and 7) = 6 then Inc(FCycles, 8);
                      end;
             $40..$7F: begin { BIT b, r8 }
                        Tmp8 := GetR8(CBByte and 7);
                        SetZ((Tmp8 and (1 shl ((CBByte shr 3) and 7))) = 0);
                        SetN(False);
                        SetH(True);
                        if (CBByte and 7) = 6 then Inc(FCycles, 4);
                      end;
             $80..$BF: begin { RES b, r8 }
                        Tmp8 := GetR8(CBByte and 7);
                        Tmp8 := Tmp8 and (not (1 shl ((CBByte shr 3) and 7)));
                        SetR8(CBByte and 7, Tmp8);
                        if (CBByte and 7) = 6 then Inc(FCycles, 8);
                      end;
            $C0..$FF: begin { SET b, r8 }
                        Tmp8 := GetR8(CBByte and 7);
                        Tmp8 := Tmp8 or (1 shl ((CBByte shr 3) and 7));
                        SetR8(CBByte and 7, Tmp8);
                        if (CBByte and 7) = 6 then Inc(FCycles, 8);
                      end;
           end;
           if FIMEDelaySteps > 0 then
           begin
             Dec(FIMEDelaySteps);
             if FIMEDelaySteps = 0 then
               FIME := True;
           end;
           DrainTicks;
           Exit;
         end;
    $CC: begin { CALL Z, imm16 }
           Imm16 := Read16(FPC); PCInc2;
           if GetZ then
           begin
             Push16(FPC);
             FPC := Imm16;
             FCycles := 24;
           end
           else
             FCycles := 12;
         end;
    $CD: begin
           Imm16 := Read16(FPC); PCInc2;
           Push16(FPC);
           FPC := Imm16;
           FCycles := 24;
         end;
    $CE: begin
           Imm8 := Read8(FPC); PCInc1;
           Tmp16 := FRegA + Imm8 + Byte(Ord(GetC));
           SetZ(Byte(Tmp16 and $FF) = 0);
           SetN(False);
           SetH((FRegA and $0F) + (Imm8 and $0F) + Ord(GetC) > $0F);
           SetC(Tmp16 > $FF);
           FRegA := Byte(Tmp16 and $FF);
           FCycles := 8;
         end;
    $CF: begin
           Push16(FPC);
           FPC := $08;
           FCycles := 16;
         end;
    $D0: begin { RET NC }
           if not GetC then
           begin
             FPC := Pop16IsRetFamily;
             FCycles := 20;
           end
           else
             FCycles := 8;
         end;
    $D1: begin
           Tmp16 := Pop16IsRetFamily;
           FRegD := Byte(Tmp16 shr 8);
           FRegE := Byte(Tmp16 and $FF);
           FCycles := 12;
         end;
    $D2: begin { JP NC, imm16 }
           Imm16 := Read16(FPC); PCInc2;
           if not GetC then
           begin
             FPC := Imm16;
             FCycles := 16;
           end
           else
             FCycles := 12;
         end;
    $D4: begin { CALL NC, imm16 }
           Imm16 := Read16(FPC); PCInc2;
           if not GetC then
           begin
             Push16(FPC);
             FPC := Imm16;
             FCycles := 24;
           end
           else
             FCycles := 12;
         end;
    $D5: begin
           Push16((Word(FRegD) shl 8) or FRegE);
           FCycles := 16;
         end;
    $D3, $DB, $DD, $E3, $E4, $EB, $EC, $ED, $F4, $FC, $FD: ; { Invalid: NOP (no lock) }
    $D6: begin
           Imm8 := Read8(FPC); PCInc1;
           SetZ((FRegA - Imm8) and $FF = 0);
           SetN(True);
           SetH((FRegA and $0F) < (Imm8 and $0F));
           SetC(FRegA < Imm8);
           FRegA := (FRegA - Imm8) and $FF;
           FCycles := 8;
         end;
    $D7: begin
           Push16(FPC);
           FPC := $10;
           FCycles := 16;
         end;
    $D8: begin { RET C }
           if GetC then
           begin
             FPC := Pop16IsRetFamily;
             FCycles := 20;
           end
           else
             FCycles := 8;
         end;
    $D9: begin { RETI }
           FPC := Pop16IsRetFamily;
           FIME := True;
           FCycles := 16;
         end;
    $DA: begin { JP C, imm16 }
           Imm16 := Read16(FPC); PCInc2;
           if GetC then
           begin
             FPC := Imm16;
             FCycles := 16;
           end
           else
             FCycles := 12;
         end;
    $DC: begin { CALL C, imm16 }
           Imm16 := Read16(FPC); PCInc2;
           if GetC then
           begin
             Push16(FPC);
             FPC := Imm16;
             FCycles := 24;
           end
           else
             FCycles := 12;
         end;
    $DE: begin
           Imm8 := Read8(FPC); PCInc1;
           Tmp16S := Integer(FRegA) - Integer(Imm8) - Integer(Ord(GetC));
           SetZ(Byte(Tmp16S and $FF) = 0);
           SetN(True);
           SetH((FRegA and $0F) < (Imm8 and $0F) + Ord(GetC));
           SetC(Tmp16S < 0);
           FRegA := Byte(Tmp16S and $FF);
           FCycles := 8;
         end;
    $DF: begin
           Push16(FPC);
           FPC := $18;
           FCycles := 16;
         end;
    $E0: begin
           Imm8 := Read8(FPC); PCInc1;
           Write8($FF00 or Imm8, FRegA);
           FCycles := 12;
         end;
    $E1: begin
           Tmp16 := Pop16IsRetFamily;
           FRegH := Byte(Tmp16 shr 8);
           FRegL := Byte(Tmp16 and $FF);
           FCycles := 12;
         end;
    $E2: begin
           Write8($FF00 or FRegC, FRegA);
           FCycles := 8;
         end;
    $E5: begin
           Push16(GetHL);
           FCycles := 16;
         end;
    $E6: begin
           Imm8 := Read8(FPC); PCInc1;
           FRegA := FRegA and Imm8;
           SetZ(FRegA = 0);
           SetN(False);
           SetH(True);
           SetC(False);
           FCycles := 8;
         end;
    $E7: begin
           Push16(FPC);
           FPC := $20;
           FCycles := 16;
         end;
    $E8: begin { ADD SP, imm8 }
           Imm8 := Read8(FPC); PCInc1;
           Tmp16 := (FSP + ShortInt(Imm8)) and $FFFF;
           SetZ(False);
           SetN(False);
           SetH(((FSP and $FF) and $0F) + (Byte(ShortInt(Imm8)) and $0F) > $0F);
           SetC((FSP and $FF) + Byte(ShortInt(Imm8)) > $FF);
           FSP := Tmp16;
           FCycles := 16;
         end;
    $E9: begin
           FPC := GetHL;
           FCycles := 4;
         end;
    $EA: begin
           Imm16 := Read16(FPC); PCInc2;
           Write8(Imm16, FRegA);
           FCycles := 16;
         end;
    $EE: begin
           Imm8 := Read8(FPC); PCInc1;
           FRegA := FRegA xor Imm8;
           SetZ(FRegA = 0);
           SetN(False);
           SetH(False);
           SetC(False);
           FCycles := 8;
         end;
    $EF: begin
           Push16(FPC);
           FPC := $28;
           FCycles := 16;
         end;
    $F0: begin
           Imm8 := Read8(FPC); PCInc1;
           FRegA := Read8($FF00 or Imm8);
           FCycles := 12;
         end;
    $F1: begin
           Tmp16 := Pop16IsRetFamily;
           FRegA := Byte(Tmp16 shr 8);
           FRegF := Byte(Tmp16 and $F0);
           FCycles := 12;
         end;
    $F2: begin
           FRegA := Read8($FF00 or FRegC);
           FCycles := 8;
         end;
    $F3: begin
           FIME := False;
           FIMEDelaySteps := 0;
           FCycles := 4;
         end;
    $F5: begin
           Push16((Word(FRegA) shl 8) or (FRegF and $F0));
           FCycles := 16;
         end;
    $F6: begin
           Imm8 := Read8(FPC); PCInc1;
           FRegA := FRegA or Imm8;
           SetZ(FRegA = 0);
           SetN(False);
           SetH(False);
           SetC(False);
           FCycles := 8;
         end;
    $F7: begin
           Push16(FPC);
           FPC := $30;
           FCycles := 16;
         end;
    $F8: begin { LD HL, SP+imm8 }
           Imm8 := Read8(FPC); PCInc1;
           Tmp16 := (FSP + ShortInt(Imm8)) and $FFFF;
           SetHL(Tmp16);
           SetZ(False);
           SetN(False);
           SetH(((FSP and $FF) and $0F) + (Byte(ShortInt(Imm8)) and $0F) > $0F);
           SetC((FSP and $FF) + Byte(ShortInt(Imm8)) > $FF);
           FCycles := 12;
         end;
    $F9: begin
           FSP := GetHL;
           FCycles := 8;
         end;
    $FA: begin
           Imm16 := Read16(FPC); PCInc2;
           FRegA := Read8(Imm16);
           FCycles := 16;
         end;
    $FB: begin
           FIMEDelaySteps := 2;
           FCycles := 4;
         end;
    $FE: begin
           Imm8 := Read8(FPC); PCInc1;
           SetZ(FRegA = Imm8);
           SetN(True);
           SetH((FRegA and $0F) < (Imm8 and $0F));
           SetC(FRegA < Imm8);
           FCycles := 8;
         end;
    $FF: begin
           Push16(FPC);
           FPC := $38;
           FCycles := 16;
         end;
  else
    { Unknown opcode: treat as NOP }
  end;

  if FIMEDelaySteps > 0 then
  begin
    Dec(FIMEDelaySteps);
    if FIMEDelaySteps = 0 then
      FIME := True;
  end;
  DrainTicks;
end;

function TCpu.GetAF: Word;
begin
  Result := (Word(FRegA) shl 8) or (FRegF and $F0);
end;

function TCpu.GetBC: Word;
begin
  Result := (Word(FRegB) shl 8) or FRegC;
end;

function TCpu.GetDE: Word;
begin
  Result := (Word(FRegD) shl 8) or FRegE;
end;

function TCpu.GetHLValue: Word;
begin
  Result := (Word(FRegH) shl 8) or FRegL;
end;

procedure TCpu.SetAF(const Value: Word);
begin
  FRegA := Byte(Value shr 8);
  FRegF := Byte(Value and $FF) and $F0;
end;

procedure TCpu.SetBC(const Value: Word);
begin
  FRegB := Byte(Value shr 8);
  FRegC := Byte(Value and $FF);
end;

procedure TCpu.SetDE(const Value: Word);
begin
  FRegD := Byte(Value shr 8);
  FRegE := Byte(Value and $FF);
end;

procedure TCpu.SetHLValue(const Value: Word);
begin
  FRegH := Byte(Value shr 8);
  FRegL := Byte(Value and $FF);
end;

end.
