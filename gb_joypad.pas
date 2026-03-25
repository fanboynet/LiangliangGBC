unit gb_joypad;
{ 单元定义: 手柄输入寄存器（P1）抽象层。 }
{ 负责内容: 按键状态映射、行选择、下降沿触发 Joypad 中断请求。 }



interface

{
  Joypad(P1/FF00) 模型:
  - bit4/bit5 由 CPU 选择行（方向键行 / 按钮键行）。
  - bit0..3 为低有效（0=按下, 1=松开）。
  - 任一可见键位出现 1->0 下降沿时请求 Joypad IRQ(bit4)。
  参考: Pan Docs / Joypad Input.
}

type
  TJoypadIrqProc = procedure(IrqBit: Byte) of object;

  TGBJoypad = class
  private
    FP1Select: Byte;      { FF00 bits 4-5 as last written by CPU }
    FButtons: Byte;       { Bits 0-3: A,B,Select,Start; 1=released }
    FDirections: Byte;    { Bits 0-3: Right,Left,Up,Down; 1=released }
    FOnRequestIrq: TJoypadIrqProc;
    function BuildP1Value: Byte;
    procedure CheckIrqEdge(OldP1, NewP1: Byte);
  public
    procedure Reset;
    procedure SetState(AButtons, ADirections: Byte);
    function ReadP1: Byte;
    procedure WriteP1(Value: Byte);
    property OnRequestIrq: TJoypadIrqProc read FOnRequestIrq write FOnRequestIrq;
  end;

implementation

function TGBJoypad.BuildP1Value: Byte;
var
  LowNibble: Byte;
begin
  { 高两位通常读作 1；中间选择位保留 CPU 最近写入。 }
  Result := $C0 or (FP1Select and $30);
  LowNibble := $0F;

  { JOYP bit4=0 selects directions, bit5=0 selects buttons. }
  if (FP1Select and $10) = 0 then
    LowNibble := LowNibble and (FDirections and $0F);
  if (FP1Select and $20) = 0 then
    LowNibble := LowNibble and (FButtons and $0F);

  Result := Result or LowNibble;
end;

procedure TGBJoypad.CheckIrqEdge(OldP1, NewP1: Byte);
var
  Falling: Byte;
begin
  { Joypad interrupt on any 1->0 transition in bits 0..3. }
  Falling := (OldP1 and (not NewP1)) and $0F;
  if (Falling <> 0) and Assigned(FOnRequestIrq) then
    FOnRequestIrq(4);
end;

procedure TGBJoypad.Reset;
begin
  { DMG boot-like default: FF00 reads as $CF when no key is pressed. }
  FP1Select := $00;
  FButtons := $0F;
  FDirections := $0F;
end;

procedure TGBJoypad.SetState(AButtons, ADirections: Byte);
var
  OldP1, NewP1: Byte;
begin
  { AButtons/ADirections 约定为低 4 位，1=松开，0=按下。 }
  OldP1 := BuildP1Value;
  FButtons := AButtons and $0F;
  FDirections := ADirections and $0F;
  NewP1 := BuildP1Value;
  CheckIrqEdge(OldP1, NewP1);
end;

function TGBJoypad.ReadP1: Byte;
begin
  Result := BuildP1Value;
end;

procedure TGBJoypad.WriteP1(Value: Byte);
var
  OldP1, NewP1: Byte;
begin
  { 仅 bit4/bit5 可写，其余位忽略。 }
  OldP1 := BuildP1Value;
  FP1Select := Value and $30;
  NewP1 := BuildP1Value;
  CheckIrqEdge(OldP1, NewP1);
end;

end.
