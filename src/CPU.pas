unit CPU;

interface

uses
  Common, Memory;

type
  TCPU = class
  private
    FRegisters: TRegisters;
    FMemory: TMemory;
    FCycles: Integer;
    FIME: Boolean;
    FEnableIMEPending: Boolean;
    FHalted: Boolean;
    FStopped: Boolean;
    function GetAF: TWord;
    function GetBC: TWord;
    function GetDE: TWord;
    function GetHL: TWord;
    procedure SetAF(Value: TWord);
    procedure SetBC(Value: TWord);
    procedure SetDE(Value: TWord);
    procedure SetHL(Value: TWord);
    function ReadByte(Address: TWord): TByte;
    function ReadWord(Address: TWord): TWord;
    procedure WriteByte(Address: TWord; Value: TByte);
    procedure WriteWord(Address: TWord; Value: TWord);
    function FetchByte: TByte;
    function FetchWord: TWord;
    procedure PushWord(Value: TWord);
    function PopWord: TWord;
    procedure SetFlag(Flag: TByte; Enabled: Boolean);
    function GetFlag(Flag: TByte): Boolean;
    function Add8(A, B: TByte; Carry: Boolean): TByte;
    function Sub8(A, B: TByte; Carry: Boolean): TByte;
    function Inc8(Value: TByte): TByte;
    function Dec8(Value: TByte): TByte;
    function Add16(A, B: TWord): TWord;
    function Add16Signed(A: TWord; B: ShortInt): TWord;
    procedure And8(Value: TByte);
    procedure Or8(Value: TByte);
    procedure Xor8(Value: TByte);
    procedure Cp8(Value: TByte);
    procedure DAA;
    function RLC(Value: TByte): TByte;
    function RRC(Value: TByte): TByte;
    function RL(Value: TByte): TByte;
    function RR(Value: TByte): TByte;
    function SLA(Value: TByte): TByte;
    function SRA(Value: TByte): TByte;
    function SRL(Value: TByte): TByte;
    function SWAP(Value: TByte): TByte;
    procedure BitTest(Bit: Integer; Value: TByte);
    function GetReg8(Index: Integer): TByte;
    procedure SetReg8(Index: Integer; Value: TByte);
  public
    constructor Create(AMemory: TMemory);
    procedure Reset;
    function Step: Integer;
    property Registers: TRegisters read FRegisters;
    property Cycles: Integer read FCycles;
    property IME: Boolean read FIME;
    property Halted: Boolean read FHalted;
    property Stopped: Boolean read FStopped;
  end;

implementation

const
  FlagZ = $80;
  FlagN = $40;
  FlagH = $20;
  FlagC = $10;

constructor TCPU.Create(AMemory: TMemory);
begin
  inherited Create;
  FMemory := AMemory;
  Reset;
end;

procedure TCPU.Reset;
begin
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FRegisters.SP := $FFFE;
  FRegisters.PC := $0100;
  FRegisters.F := 0;
  FCycles := 0;
  FIME := False;
  FEnableIMEPending := False;
  FHalted := False;
  FStopped := False;
end;

function TCPU.GetAF: TWord;
begin
  Result := (TWord(FRegisters.A) shl 8) or (FRegisters.F and $F0);
end;

function TCPU.GetBC: TWord;
begin
  Result := (TWord(FRegisters.B) shl 8) or FRegisters.C;
end;

function TCPU.GetDE: TWord;
begin
  Result := (TWord(FRegisters.D) shl 8) or FRegisters.E;
end;

function TCPU.GetHL: TWord;
begin
  Result := (TWord(FRegisters.H) shl 8) or FRegisters.L;
end;

procedure TCPU.SetAF(Value: TWord);
begin
  FRegisters.A := TByte(Value shr 8);
  FRegisters.F := TByte(Value and $F0);
end;

procedure TCPU.SetBC(Value: TWord);
begin
  FRegisters.B := TByte(Value shr 8);
  FRegisters.C := TByte(Value and $FF);
end;

procedure TCPU.SetDE(Value: TWord);
begin
  FRegisters.D := TByte(Value shr 8);
  FRegisters.E := TByte(Value and $FF);
end;

procedure TCPU.SetHL(Value: TWord);
begin
  FRegisters.H := TByte(Value shr 8);
  FRegisters.L := TByte(Value and $FF);
end;

function TCPU.ReadByte(Address: TWord): TByte;
begin
  Result := FMemory.ReadByte(Address);
end;

function TCPU.ReadWord(Address: TWord): TWord;
var
  Lo, Hi: TByte;
begin
  Lo := ReadByte(Address);
  Hi := ReadByte(Address + 1);
  Result := TWord(Lo) or (TWord(Hi) shl 8);
end;

procedure TCPU.WriteByte(Address: TWord; Value: TByte);
begin
  FMemory.WriteByte(Address, Value);
end;

procedure TCPU.WriteWord(Address: TWord; Value: TWord);
begin
  WriteByte(Address, TByte(Value and $FF));
  WriteByte(Address + 1, TByte(Value shr 8));
end;

function TCPU.FetchByte: TByte;
begin
  Result := ReadByte(FRegisters.PC);
  Inc(FRegisters.PC);
end;

function TCPU.FetchWord: TWord;
var
  Lo, Hi: TByte;
begin
  Lo := FetchByte;
  Hi := FetchByte;
  Result := TWord(Lo) or (TWord(Hi) shl 8);
end;

procedure TCPU.PushWord(Value: TWord);
begin
  Dec(FRegisters.SP, 2);
  WriteWord(FRegisters.SP, Value);
end;

function TCPU.PopWord: TWord;
begin
  Result := ReadWord(FRegisters.SP);
  Inc(FRegisters.SP, 2);
end;

procedure TCPU.SetFlag(Flag: TByte; Enabled: Boolean);
begin
  if Enabled then
    FRegisters.F := FRegisters.F or Flag
  else
    FRegisters.F := FRegisters.F and not Flag;
  FRegisters.F := FRegisters.F and $F0;
end;

function TCPU.GetFlag(Flag: TByte): Boolean;
begin
  Result := (FRegisters.F and Flag) <> 0;
end;

function TCPU.Add8(A, B: TByte; Carry: Boolean): TByte;
var
  CarryVal: Integer;
  Sum: Integer;
begin
  CarryVal := Ord(Carry);
  Sum := A + B + CarryVal;
  SetFlag(FlagZ, (Sum and $FF) = 0);
  SetFlag(FlagN, False);
  SetFlag(FlagH, ((A and $0F) + (B and $0F) + CarryVal) > $0F);
  SetFlag(FlagC, Sum > $FF);
  Result := TByte(Sum and $FF);
end;

function TCPU.Sub8(A, B: TByte; Carry: Boolean): TByte;
var
  CarryVal: Integer;
  Diff: Integer;
begin
  CarryVal := Ord(Carry);
  Diff := A - B - CarryVal;
  SetFlag(FlagZ, (Diff and $FF) = 0);
  SetFlag(FlagN, True);
  SetFlag(FlagH, ((A and $0F) - (B and $0F) - CarryVal) < 0);
  SetFlag(FlagC, Diff < 0);
  Result := TByte(Diff and $FF);
end;

function TCPU.Inc8(Value: TByte): TByte;
var
  ResultValue: TByte;
begin
  ResultValue := TByte((Value + 1) and $FF);
  SetFlag(FlagZ, ResultValue = 0);
  SetFlag(FlagN, False);
  SetFlag(FlagH, (Value and $0F) = $0F);
  Result := ResultValue;
end;

function TCPU.Dec8(Value: TByte): TByte;
var
  ResultValue: TByte;
begin
  ResultValue := TByte((Value - 1) and $FF);
  SetFlag(FlagZ, ResultValue = 0);
  SetFlag(FlagN, True);
  SetFlag(FlagH, (Value and $0F) = 0);
  Result := ResultValue;
end;

function TCPU.Add16(A, B: TWord): TWord;
var
  Sum: Integer;
begin
  Sum := A + B;
  SetFlag(FlagN, False);
  SetFlag(FlagH, ((A and $0FFF) + (B and $0FFF)) > $0FFF);
  SetFlag(FlagC, Sum > $FFFF);
  Result := TWord(Sum and $FFFF);
end;

function TCPU.Add16Signed(A: TWord; B: ShortInt): TWord;
var
  Sum: Integer;
  UnsignedB: Word;
begin
  UnsignedB := Word(ShortInt(B));
  Sum := Integer(A) + Integer(B);
  SetFlag(FlagZ, False);
  SetFlag(FlagN, False);
  SetFlag(FlagH, ((A and $0F) + (UnsignedB and $0F)) > $0F);
  SetFlag(FlagC, ((A and $FF) + (UnsignedB and $FF)) > $FF);
  Result := TWord(Sum and $FFFF);
end;

procedure TCPU.And8(Value: TByte);
begin
  FRegisters.A := FRegisters.A and Value;
  SetFlag(FlagZ, FRegisters.A = 0);
  SetFlag(FlagN, False);
  SetFlag(FlagH, True);
  SetFlag(FlagC, False);
end;

procedure TCPU.Or8(Value: TByte);
begin
  FRegisters.A := FRegisters.A or Value;
  SetFlag(FlagZ, FRegisters.A = 0);
  SetFlag(FlagN, False);
  SetFlag(FlagH, False);
  SetFlag(FlagC, False);
end;

procedure TCPU.Xor8(Value: TByte);
begin
  FRegisters.A := FRegisters.A xor Value;
  SetFlag(FlagZ, FRegisters.A = 0);
  SetFlag(FlagN, False);
  SetFlag(FlagH, False);
  SetFlag(FlagC, False);
end;

procedure TCPU.Cp8(Value: TByte);
begin
  Sub8(FRegisters.A, Value, False);
end;

procedure TCPU.DAA;
var
  Adjust: Byte;
  Carry: Boolean;
begin
  Adjust := 0;
  Carry := GetFlag(FlagC);
  if not GetFlag(FlagN) then
  begin
    if GetFlag(FlagH) or ((FRegisters.A and $0F) > 9) then
      Adjust := Adjust or $06;
    if Carry or (FRegisters.A > $99) then
    begin
      Adjust := Adjust or $60;
      Carry := True;
    end;
    FRegisters.A := TByte((FRegisters.A + Adjust) and $FF);
  end
  else
  begin
    if GetFlag(FlagH) then
      Adjust := Adjust or $06;
    if Carry then
      Adjust := Adjust or $60;
    FRegisters.A := TByte((FRegisters.A - Adjust) and $FF);
  end;
  SetFlag(FlagZ, FRegisters.A = 0);
  SetFlag(FlagH, False);
  SetFlag(FlagC, Carry);
end;

function TCPU.RLC(Value: TByte): TByte;
var
  Carry: Boolean;
begin
  Carry := (Value and $80) <> 0;
  Result := TByte(((Value shl 1) or Ord(Carry)) and $FF);
  SetFlag(FlagZ, Result = 0);
  SetFlag(FlagN, False);
  SetFlag(FlagH, False);
  SetFlag(FlagC, Carry);
end;

function TCPU.RRC(Value: TByte): TByte;
var
  Carry: Boolean;
begin
  Carry := (Value and $01) <> 0;
  Result := TByte((Value shr 1) or (Ord(Carry) shl 7));
  SetFlag(FlagZ, Result = 0);
  SetFlag(FlagN, False);
  SetFlag(FlagH, False);
  SetFlag(FlagC, Carry);
end;

function TCPU.RL(Value: TByte): TByte;
var
  CarryIn: Boolean;
  CarryOut: Boolean;
begin
  CarryIn := GetFlag(FlagC);
  CarryOut := (Value and $80) <> 0;
  Result := TByte(((Value shl 1) or Ord(CarryIn)) and $FF);
  SetFlag(FlagZ, Result = 0);
  SetFlag(FlagN, False);
  SetFlag(FlagH, False);
  SetFlag(FlagC, CarryOut);
end;

function TCPU.RR(Value: TByte): TByte;
var
  CarryIn: Boolean;
  CarryOut: Boolean;
begin
  CarryIn := GetFlag(FlagC);
  CarryOut := (Value and $01) <> 0;
  Result := TByte((Value shr 1) or (Ord(CarryIn) shl 7));
  SetFlag(FlagZ, Result = 0);
  SetFlag(FlagN, False);
  SetFlag(FlagH, False);
  SetFlag(FlagC, CarryOut);
end;

function TCPU.SLA(Value: TByte): TByte;
var
  Carry: Boolean;
begin
  Carry := (Value and $80) <> 0;
  Result := TByte((Value shl 1) and $FF);
  SetFlag(FlagZ, Result = 0);
  SetFlag(FlagN, False);
  SetFlag(FlagH, False);
  SetFlag(FlagC, Carry);
end;

function TCPU.SRA(Value: TByte): TByte;
var
  Carry: Boolean;
begin
  Carry := (Value and $01) <> 0;
  Result := TByte((Value shr 1) or (Value and $80));
  SetFlag(FlagZ, Result = 0);
  SetFlag(FlagN, False);
  SetFlag(FlagH, False);
  SetFlag(FlagC, Carry);
end;

function TCPU.SRL(Value: TByte): TByte;
var
  Carry: Boolean;
begin
  Carry := (Value and $01) <> 0;
  Result := TByte(Value shr 1);
  SetFlag(FlagZ, Result = 0);
  SetFlag(FlagN, False);
  SetFlag(FlagH, False);
  SetFlag(FlagC, Carry);
end;

function TCPU.SWAP(Value: TByte): TByte;
begin
  Result := TByte(((Value and $0F) shl 4) or ((Value and $F0) shr 4));
  SetFlag(FlagZ, Result = 0);
  SetFlag(FlagN, False);
  SetFlag(FlagH, False);
  SetFlag(FlagC, False);
end;

procedure TCPU.BitTest(Bit: Integer; Value: TByte);
begin
  SetFlag(FlagZ, (Value and (1 shl Bit)) = 0);
  SetFlag(FlagN, False);
  SetFlag(FlagH, True);
end;

function TCPU.GetReg8(Index: Integer): TByte;
begin
  case Index of
    0: Result := FRegisters.B;
    1: Result := FRegisters.C;
    2: Result := FRegisters.D;
    3: Result := FRegisters.E;
    4: Result := FRegisters.H;
    5: Result := FRegisters.L;
    6: Result := ReadByte(GetHL);
    7: Result := FRegisters.A;
  else
    Result := 0;
  end;
end;

procedure TCPU.SetReg8(Index: Integer; Value: TByte);
begin
  case Index of
    0: FRegisters.B := Value;
    1: FRegisters.C := Value;
    2: FRegisters.D := Value;
    3: FRegisters.E := Value;
    4: FRegisters.H := Value;
    5: FRegisters.L := Value;
    6: WriteByte(GetHL, Value);
    7: FRegisters.A := Value;
  end;
  FCycles := 0;
end;

function TCPU.Step: Integer;
var
  OpCode: TByte;
  Temp8: TByte;
  Temp16: TWord;
  Signed8: ShortInt;
  BitIndex: Integer;
  RegIndex: Integer;
  EnableIMEAfter: Boolean;
begin
  EnableIMEAfter := FEnableIMEPending;
begin
  if FHalted or FStopped then
  begin
    Inc(FCycles, 4);
    Exit(4);
  end;

  OpCode := FetchByte;
  Result := 0;

  case OpCode of
    $00: Result := 4;
    $01:
      begin
        SetBC(FetchWord);
        Result := 12;
      end;
    $02:
      begin
        WriteByte(GetBC, FRegisters.A);
        Result := 8;
      end;
    $03:
      begin
        SetBC(TWord((GetBC + 1) and $FFFF));
        Result := 8;
      end;
    $04:
      begin
        FRegisters.B := Inc8(FRegisters.B);
        Result := 4;
      end;
    $05:
      begin
        FRegisters.B := Dec8(FRegisters.B);
        Result := 4;
      end;
    $06:
      begin
        FRegisters.B := FetchByte;
        Result := 8;
      end;
    $07:
      begin
        FRegisters.A := RLC(FRegisters.A);
        SetFlag(FlagZ, False);
        Result := 4;
      end;
    $08:
      begin
        WriteWord(FetchWord, FRegisters.SP);
        Result := 20;
      end;
    $09:
      begin
        SetHL(Add16(GetHL, GetBC));
        Result := 8;
      end;
    $0A:
      begin
        FRegisters.A := ReadByte(GetBC);
        Result := 8;
      end;
    $0B:
      begin
        SetBC(TWord((GetBC - 1) and $FFFF));
        Result := 8;
      end;
    $0C:
      begin
        FRegisters.C := Inc8(FRegisters.C);
        Result := 4;
      end;
    $0D:
      begin
        FRegisters.C := Dec8(FRegisters.C);
        Result := 4;
      end;
    $0E:
      begin
        FRegisters.C := FetchByte;
        Result := 8;
      end;
    $0F:
      begin
        FRegisters.A := RRC(FRegisters.A);
        SetFlag(FlagZ, False);
        Result := 4;
      end;
    $10:
      begin
        FetchByte;
        FStopped := True;
        Result := 4;
      end;
    $11:
      begin
        SetDE(FetchWord);
        Result := 12;
      end;
    $12:
      begin
        WriteByte(GetDE, FRegisters.A);
        Result := 8;
      end;
    $13:
      begin
        SetDE(TWord((GetDE + 1) and $FFFF));
        Result := 8;
      end;
    $14:
      begin
        FRegisters.D := Inc8(FRegisters.D);
        Result := 4;
      end;
    $15:
      begin
        FRegisters.D := Dec8(FRegisters.D);
        Result := 4;
      end;
    $16:
      begin
        FRegisters.D := FetchByte;
        Result := 8;
      end;
    $17:
      begin
        FRegisters.A := RL(FRegisters.A);
        SetFlag(FlagZ, False);
        Result := 4;
      end;
    $18:
      begin
        Signed8 := ShortInt(FetchByte);
        FRegisters.PC := TWord(Integer(FRegisters.PC) + Signed8);
        Result := 12;
      end;
    $19:
      begin
        SetHL(Add16(GetHL, GetDE));
        Result := 8;
      end;
    $1A:
      begin
        FRegisters.A := ReadByte(GetDE);
        Result := 8;
      end;
    $1B:
      begin
        SetDE(TWord((GetDE - 1) and $FFFF));
        Result := 8;
      end;
    $1C:
      begin
        FRegisters.E := Inc8(FRegisters.E);
        Result := 4;
      end;
    $1D:
      begin
        FRegisters.E := Dec8(FRegisters.E);
        Result := 4;
      end;
    $1E:
      begin
        FRegisters.E := FetchByte;
        Result := 8;
      end;
    $1F:
      begin
        FRegisters.A := RR(FRegisters.A);
        SetFlag(FlagZ, False);
        Result := 4;
      end;
    $20:
      begin
        Signed8 := ShortInt(FetchByte);
        if not GetFlag(FlagZ) then
        begin
          FRegisters.PC := TWord(Integer(FRegisters.PC) + Signed8);
          Result := 12;
        end
        else
          Result := 8;
      end;
    $21:
      begin
        SetHL(FetchWord);
        Result := 12;
      end;
    $22:
      begin
        WriteByte(GetHL, FRegisters.A);
        SetHL(TWord((GetHL + 1) and $FFFF));
        Result := 8;
      end;
    $23:
      begin
        SetHL(TWord((GetHL + 1) and $FFFF));
        Result := 8;
      end;
    $24:
      begin
        FRegisters.H := Inc8(FRegisters.H);
        Result := 4;
      end;
    $25:
      begin
        FRegisters.H := Dec8(FRegisters.H);
        Result := 4;
      end;
    $26:
      begin
        FRegisters.H := FetchByte;
        Result := 8;
      end;
    $27:
      begin
        DAA;
        Result := 4;
      end;
    $28:
      begin
        Signed8 := ShortInt(FetchByte);
        if GetFlag(FlagZ) then
        begin
          FRegisters.PC := TWord(Integer(FRegisters.PC) + Signed8);
          Result := 12;
        end
        else
          Result := 8;
      end;
    $29:
      begin
        SetHL(Add16(GetHL, GetHL));
        Result := 8;
      end;
    $2A:
      begin
        FRegisters.A := ReadByte(GetHL);
        SetHL(TWord((GetHL + 1) and $FFFF));
        Result := 8;
      end;
    $2B:
      begin
        SetHL(TWord((GetHL - 1) and $FFFF));
        Result := 8;
      end;
    $2C:
      begin
        FRegisters.L := Inc8(FRegisters.L);
        Result := 4;
      end;
    $2D:
      begin
        FRegisters.L := Dec8(FRegisters.L);
        Result := 4;
      end;
    $2E:
      begin
        FRegisters.L := FetchByte;
        Result := 8;
      end;
    $2F:
      begin
        FRegisters.A := FRegisters.A xor $FF;
        SetFlag(FlagN, True);
        SetFlag(FlagH, True);
        Result := 4;
      end;
    $30:
      begin
        Signed8 := ShortInt(FetchByte);
        if not GetFlag(FlagC) then
        begin
          FRegisters.PC := TWord(Integer(FRegisters.PC) + Signed8);
          Result := 12;
        end
        else
          Result := 8;
      end;
    $31:
      begin
        FRegisters.SP := FetchWord;
        Result := 12;
      end;
    $32:
      begin
        WriteByte(GetHL, FRegisters.A);
        SetHL(TWord((GetHL - 1) and $FFFF));
        Result := 8;
      end;
    $33:
      begin
        FRegisters.SP := TWord((FRegisters.SP + 1) and $FFFF);
        Result := 8;
      end;
    $34:
      begin
        Temp8 := ReadByte(GetHL);
        Temp8 := Inc8(Temp8);
        WriteByte(GetHL, Temp8);
        Result := 12;
      end;
    $35:
      begin
        Temp8 := ReadByte(GetHL);
        Temp8 := Dec8(Temp8);
        WriteByte(GetHL, Temp8);
        Result := 12;
      end;
    $36:
      begin
        WriteByte(GetHL, FetchByte);
        Result := 12;
      end;
    $37:
      begin
        SetFlag(FlagC, True);
        SetFlag(FlagN, False);
        SetFlag(FlagH, False);
        Result := 4;
      end;
    $38:
      begin
        Signed8 := ShortInt(FetchByte);
        if GetFlag(FlagC) then
        begin
          FRegisters.PC := TWord(Integer(FRegisters.PC) + Signed8);
          Result := 12;
        end
        else
          Result := 8;
      end;
    $39:
      begin
        SetHL(Add16(GetHL, FRegisters.SP));
        Result := 8;
      end;
    $3A:
      begin
        FRegisters.A := ReadByte(GetHL);
        SetHL(TWord((GetHL - 1) and $FFFF));
        Result := 8;
      end;
    $3B:
      begin
        FRegisters.SP := TWord((FRegisters.SP - 1) and $FFFF);
        Result := 8;
      end;
    $3C:
      begin
        FRegisters.A := Inc8(FRegisters.A);
        Result := 4;
      end;
    $3D:
      begin
        FRegisters.A := Dec8(FRegisters.A);
        Result := 4;
      end;
    $3E:
      begin
        FRegisters.A := FetchByte;
        Result := 8;
      end;
    $3F:
      begin
        SetFlag(FlagC, not GetFlag(FlagC));
        SetFlag(FlagN, False);
        SetFlag(FlagH, False);
        Result := 4;
      end;
    $40..$7F:
      begin
        if OpCode = $76 then
        begin
          FHalted := True;
          Result := 4;
        end
        else
        begin
          RegIndex := (OpCode shr 3) and $07;
          Temp8 := GetReg8(OpCode and $07);
          SetReg8(RegIndex, Temp8);
          if ((OpCode and $07) = 6) or (RegIndex = 6) then
            Result := 8
          else
            Result := 4;
        end;
      end;
    $80..$87:
      begin
        Temp8 := GetReg8(OpCode and $07);
        FRegisters.A := Add8(FRegisters.A, Temp8, False);
        Result := 4 + Ord((OpCode and $07) = 6) * 4;
      end;
    $88..$8F:
      begin
        Temp8 := GetReg8(OpCode and $07);
        FRegisters.A := Add8(FRegisters.A, Temp8, GetFlag(FlagC));
        Result := 4 + Ord((OpCode and $07) = 6) * 4;
      end;
    $90..$97:
      begin
        Temp8 := GetReg8(OpCode and $07);
        FRegisters.A := Sub8(FRegisters.A, Temp8, False);
        Result := 4 + Ord((OpCode and $07) = 6) * 4;
      end;
    $98..$9F:
      begin
        Temp8 := GetReg8(OpCode and $07);
        FRegisters.A := Sub8(FRegisters.A, Temp8, GetFlag(FlagC));
        Result := 4 + Ord((OpCode and $07) = 6) * 4;
      end;
    $A0..$A7:
      begin
        Temp8 := GetReg8(OpCode and $07);
        And8(Temp8);
        Result := 4 + Ord((OpCode and $07) = 6) * 4;
      end;
    $A8..$AF:
      begin
        Temp8 := GetReg8(OpCode and $07);
        Xor8(Temp8);
        Result := 4 + Ord((OpCode and $07) = 6) * 4;
      end;
    $B0..$B7:
      begin
        Temp8 := GetReg8(OpCode and $07);
        Or8(Temp8);
        Result := 4 + Ord((OpCode and $07) = 6) * 4;
      end;
    $B8..$BF:
      begin
        Temp8 := GetReg8(OpCode and $07);
        Cp8(Temp8);
        Result := 4 + Ord((OpCode and $07) = 6) * 4;
      end;
    $C0:
      begin
        if not GetFlag(FlagZ) then
        begin
          FRegisters.PC := PopWord;
          Result := 20;
        end
        else
          Result := 8;
      end;
    $C1:
      begin
        SetBC(PopWord);
        Result := 12;
      end;
    $C2:
      begin
        Temp16 := FetchWord;
        if not GetFlag(FlagZ) then
        begin
          FRegisters.PC := Temp16;
          Result := 16;
        end
        else
          Result := 12;
      end;
    $C3:
      begin
        FRegisters.PC := FetchWord;
        Result := 16;
      end;
    $C4:
      begin
        Temp16 := FetchWord;
        if not GetFlag(FlagZ) then
        begin
          PushWord(FRegisters.PC);
          FRegisters.PC := Temp16;
          Result := 24;
        end
        else
          Result := 12;
      end;
    $C5:
      begin
        PushWord(GetBC);
        Result := 16;
      end;
    $C6:
      begin
        FRegisters.A := Add8(FRegisters.A, FetchByte, False);
        Result := 8;
      end;
    $C7:
      begin
        PushWord(FRegisters.PC);
        FRegisters.PC := $00;
        Result := 16;
      end;
    $C8:
      begin
        if GetFlag(FlagZ) then
        begin
          FRegisters.PC := PopWord;
          Result := 20;
        end
        else
          Result := 8;
      end;
    $C9:
      begin
        FRegisters.PC := PopWord;
        Result := 16;
      end;
    $CA:
      begin
        Temp16 := FetchWord;
        if GetFlag(FlagZ) then
        begin
          FRegisters.PC := Temp16;
          Result := 16;
        end
        else
          Result := 12;
      end;
    $CB:
      begin
        OpCode := FetchByte;
        RegIndex := OpCode and $07;
        BitIndex := (OpCode shr 3) and $07;
        case OpCode of
          $00..$07:
            begin
              Temp8 := RLC(GetReg8(RegIndex));
              SetReg8(RegIndex, Temp8);
            end;
          $08..$0F:
            begin
              Temp8 := RRC(GetReg8(RegIndex));
              SetReg8(RegIndex, Temp8);
            end;
          $10..$17:
            begin
              Temp8 := RL(GetReg8(RegIndex));
              SetReg8(RegIndex, Temp8);
            end;
          $18..$1F:
            begin
              Temp8 := RR(GetReg8(RegIndex));
              SetReg8(RegIndex, Temp8);
            end;
          $20..$27:
            begin
              Temp8 := SLA(GetReg8(RegIndex));
              SetReg8(RegIndex, Temp8);
            end;
          $28..$2F:
            begin
              Temp8 := SRA(GetReg8(RegIndex));
              SetReg8(RegIndex, Temp8);
            end;
          $30..$37:
            begin
              Temp8 := SWAP(GetReg8(RegIndex));
              SetReg8(RegIndex, Temp8);
            end;
          $38..$3F:
            begin
              Temp8 := SRL(GetReg8(RegIndex));
              SetReg8(RegIndex, Temp8);
            end;
          $40..$7F:
            begin
              BitTest(BitIndex, GetReg8(RegIndex));
            end;
          $80..$BF:
            begin
              Temp8 := GetReg8(RegIndex);
              Temp8 := Temp8 and not (1 shl BitIndex);
              SetReg8(RegIndex, Temp8);
            end;
          $C0..$FF:
            begin
              Temp8 := GetReg8(RegIndex);
              Temp8 := Temp8 or (1 shl BitIndex);
              SetReg8(RegIndex, Temp8);
            end;
        end;
        if RegIndex = 6 then
        begin
          if (OpCode >= $40) and (OpCode <= $7F) then
            Result := 12
          else
            Result := 16;
        end
        else
          Result := 8;
      end;
    $CC:
      begin
        Temp16 := FetchWord;
        if GetFlag(FlagZ) then
        begin
          PushWord(FRegisters.PC);
          FRegisters.PC := Temp16;
          Result := 24;
        end
        else
          Result := 12;
      end;
    $CD:
      begin
        Temp16 := FetchWord;
        PushWord(FRegisters.PC);
        FRegisters.PC := Temp16;
        Result := 24;
      end;
    $CE:
      begin
        FRegisters.A := Add8(FRegisters.A, FetchByte, GetFlag(FlagC));
        Result := 8;
      end;
    $CF:
      begin
        PushWord(FRegisters.PC);
        FRegisters.PC := $08;
        Result := 16;
      end;
    $D0:
      begin
        if not GetFlag(FlagC) then
        begin
          FRegisters.PC := PopWord;
          Result := 20;
        end
        else
          Result := 8;
      end;
    $D1:
      begin
        SetDE(PopWord);
        Result := 12;
      end;
    $D2:
      begin
        Temp16 := FetchWord;
        if not GetFlag(FlagC) then
        begin
          FRegisters.PC := Temp16;
          Result := 16;
        end
        else
          Result := 12;
      end;
    $D3:
      begin
        Result := 4;
      end;
    $D4:
      begin
        Temp16 := FetchWord;
        if not GetFlag(FlagC) then
        begin
          PushWord(FRegisters.PC);
          FRegisters.PC := Temp16;
          Result := 24;
        end
        else
          Result := 12;
      end;
    $D5:
      begin
        PushWord(GetDE);
        Result := 16;
      end;
    $D6:
      begin
        FRegisters.A := Sub8(FRegisters.A, FetchByte, False);
        Result := 8;
      end;
    $D7:
      begin
        PushWord(FRegisters.PC);
        FRegisters.PC := $10;
        Result := 16;
      end;
    $D8:
      begin
        if GetFlag(FlagC) then
        begin
          FRegisters.PC := PopWord;
          Result := 20;
        end
        else
          Result := 8;
      end;
    $D9:
      begin
        FRegisters.PC := PopWord;
        FIME := True;
        Result := 16;
      end;
    $DA:
      begin
        Temp16 := FetchWord;
        if GetFlag(FlagC) then
        begin
          FRegisters.PC := Temp16;
          Result := 16;
        end
        else
          Result := 12;
      end;
    $DB:
      begin
        Result := 4;
      end;
    $DC:
      begin
        Temp16 := FetchWord;
        if GetFlag(FlagC) then
        begin
          PushWord(FRegisters.PC);
          FRegisters.PC := Temp16;
          Result := 24;
        end
        else
          Result := 12;
      end;
    $DD:
      begin
        Result := 4;
      end;
    $DE:
      begin
        FRegisters.A := Sub8(FRegisters.A, FetchByte, GetFlag(FlagC));
        Result := 8;
      end;
    $DF:
      begin
        PushWord(FRegisters.PC);
        FRegisters.PC := $18;
        Result := 16;
      end;
    $E0:
      begin
        WriteByte($FF00 + FetchByte, FRegisters.A);
        Result := 12;
      end;
    $E1:
      begin
        SetHL(PopWord);
        Result := 12;
      end;
    $E2:
      begin
        WriteByte($FF00 + FRegisters.C, FRegisters.A);
        Result := 8;
      end;
    $E3:
      begin
        Result := 4;
      end;
    $E4:
      begin
        Result := 4;
      end;
    $E5:
      begin
        PushWord(GetHL);
        Result := 16;
      end;
    $E6:
      begin
        And8(FetchByte);
        Result := 8;
      end;
    $E7:
      begin
        PushWord(FRegisters.PC);
        FRegisters.PC := $20;
        Result := 16;
      end;
    $E8:
      begin
        Signed8 := ShortInt(FetchByte);
        FRegisters.SP := Add16Signed(FRegisters.SP, Signed8);
        Result := 16;
      end;
    $E9:
      begin
        FRegisters.PC := GetHL;
        Result := 4;
      end;
    $EA:
      begin
        WriteByte(FetchWord, FRegisters.A);
        Result := 16;
      end;
    $EB:
      begin
        Result := 4;
      end;
    $EC:
      begin
        Result := 4;
      end;
    $ED:
      begin
        Result := 4;
      end;
    $EE:
      begin
        Xor8(FetchByte);
        Result := 8;
      end;
    $EF:
      begin
        PushWord(FRegisters.PC);
        FRegisters.PC := $28;
        Result := 16;
      end;
    $F0:
      begin
        FRegisters.A := ReadByte($FF00 + FetchByte);
        Result := 12;
      end;
    $F1:
      begin
        SetAF(PopWord);
        Result := 12;
      end;
    $F2:
      begin
        FRegisters.A := ReadByte($FF00 + FRegisters.C);
        Result := 8;
      end;
    $F3:
      begin
        FIME := False;
        FEnableIMEPending := False;
        Result := 4;
      end;
    $F4:
      begin
        Result := 4;
      end;
    $F5:
      begin
        PushWord(GetAF);
        Result := 16;
      end;
    $F6:
      begin
        Or8(FetchByte);
        Result := 8;
      end;
    $F7:
      begin
        PushWord(FRegisters.PC);
        FRegisters.PC := $30;
        Result := 16;
      end;
    $F8:
      begin
        Signed8 := ShortInt(FetchByte);
        SetHL(Add16Signed(FRegisters.SP, Signed8));
        Result := 12;
      end;
    $F9:
      begin
        FRegisters.SP := GetHL;
        Result := 8;
      end;
    $FA:
      begin
        FRegisters.A := ReadByte(FetchWord);
        Result := 16;
      end;
    $FB:
      begin
        FEnableIMEPending := True;
        Result := 4;
      end;
    $FC:
      begin
        Result := 4;
      end;
    $FD:
      begin
        FIME := True;
        Result := 4;
      end;
    $FE:
      begin
        Cp8(FetchByte);
        Result := 8;
      end;
    $FF:
      begin
        PushWord(FRegisters.PC);
        FRegisters.PC := $38;
        Result := 16;
      end;
  else
    Result := 4;
  end;

  Inc(FCycles, Result);
  if EnableIMEAfter then
  begin
    FIME := True;
    FEnableIMEPending := False;
begin
  OpCode := FMemory.ReadByte(FRegisters.PC);
  Inc(FRegisters.PC);
  Inc(FCycles, 4);
  Result := 4;
  case OpCode of
    $00: ;
  else
    ;
  end;
end;

end.
