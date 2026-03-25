unit gb_timer;
{ 单元定义: 定时器子系统（DIV/TIMA/TMA/TAC）。 }
{ 负责内容: 分频计数、边沿触发、溢出重装与定时器中断请求。 }



{
  Game Boy timer: DIV/TIMA/TMA/TAC.
  核心模型:
  - 以内部 16-bit 分频计数器 FDivCounter 的某一位作为“输入信号”。
  - TIMA 在该信号出现 1->0 的下降沿时递增（falling-edge model）。
  - TIMA 溢出后延迟 4 T-cycles 才装载 TMA 并请求 Timer IRQ(bit2)。
  参考: Pan Docs / Timer and Divider Registers.
}

interface

type
  TRequestIrqProc = procedure(IrqBit: Byte) of object;

  TGBTimer = class
  private
    FDivCounter: Word;      { Internal 16-bit divider counter }
    FTIMA: Byte;
    FTMA: Byte;
    FTAC: Byte;
    FReloadDelay: Integer;  { -1 = none, otherwise cycles until TIMA reload+IRQ }
    FIsCGB: Boolean;
    FOnRequestIrq: TRequestIrqProc;
    function GetDIV: Byte;
    function GetTimerBitMask: Word;
    function TimerSignal: Boolean;
    procedure IncrementTIMA;
    procedure TickOneCycle;
  public
    procedure Reset;
    procedure Update(Cycles: Cardinal);
    function Read(Addr: Word): Byte;
    procedure Write(Addr: Word; Value: Byte);
    property OnRequestIrq: TRequestIrqProc read FOnRequestIrq write FOnRequestIrq;
    property TIMA: Byte read FTIMA write FTIMA;
    property TMA: Byte read FTMA write FTMA;
    property TAC: Byte read FTAC write FTAC;
    property IsCGB: Boolean read FIsCGB write FIsCGB;
  end;

implementation

function TGBTimer.GetDIV: Byte;
begin
  { FF04 只暴露内部 16-bit 计数器的高 8 位。 }
  Result := Byte(FDivCounter shr 8);
end;

procedure TGBTimer.Reset;
begin
  { DMG without boot ROM typically starts with DIV around $ABxx. }
  FDivCounter := $AB00;
  FTIMA := 0;
  FTMA := 0;
  FTAC := 0;
  FReloadDelay := -1;
end;

function TGBTimer.GetTimerBitMask: Word;
begin
  { TAC bits1..0 选择输入分频位（对应不同频率）。 }
  case (FTAC and 3) of
    0: Result := Word(1 shl 9); { 4096 Hz }
    1: Result := Word(1 shl 3); { 262144 Hz }
    2: Result := Word(1 shl 5); { 65536 Hz }
  else
    Result := Word(1 shl 7);    { 16384 Hz }
  end;
end;

function TGBTimer.TimerSignal: Boolean;
begin
  { 计时器输入信号 = (TAC 使能) AND (被选中的 DIV 位为 1)。 }
  Result := ((FTAC and 4) <> 0) and ((FDivCounter and GetTimerBitMask) <> 0);
end;

procedure TGBTimer.IncrementTIMA;
begin
  { 溢出重装窗口内忽略新的边沿，避免重复计数。 }
  if FReloadDelay >= 0 then
    Exit;
  if FTIMA = $FF then
  begin
    FTIMA := 0;
    FReloadDelay := 4;
  end
  else
    Inc(FTIMA);
end;

procedure TGBTimer.TickOneCycle;
var
  OldSignal, NewSignal: Boolean;
begin
  { 逐 T-cycle 推进，保证时序测试可观察到中间态。 }
  if FReloadDelay > 0 then
  begin
    Dec(FReloadDelay);
    if FReloadDelay = 0 then
    begin
      FTIMA := FTMA;
      if Assigned(FOnRequestIrq) then
        FOnRequestIrq(2);
      FReloadDelay := -1;
    end;
  end;

  OldSignal := TimerSignal;
  FDivCounter := (FDivCounter + 1) and $FFFF;
  NewSignal := TimerSignal;
  if OldSignal and (not NewSignal) then
    IncrementTIMA;
end;

procedure TGBTimer.Update(Cycles: Cardinal);
begin
  { 不做批量公式，逐周期推进以保持边沿/重装语义正确。 }
  while Cycles > 0 do
  begin
    TickOneCycle;
    Dec(Cycles);
  end;
end;

function TGBTimer.Read(Addr: Word): Byte;
begin
  Addr := Addr and $FFFF;
  case Addr of
    $FF04: Result := GetDIV;
    $FF05: Result := FTIMA;
    $FF06: Result := FTMA;
    $FF07: Result := FTAC or $F8;
  else
    Result := $FF;
  end;
end;

procedure TGBTimer.Write(Addr: Word; Value: Byte);
var
  OldSignal, NewSignal: Boolean;
  OldEnable, NewEnable: Boolean;
begin
  Addr := Addr and $FFFF;
  case Addr of
    $FF04:
      begin
        { 写 DIV 会将内部 16-bit 计数器清零，可能制造一次下降沿并触发 TIMA+1。 }
        OldSignal := TimerSignal;
        FDivCounter := 0;
        NewSignal := TimerSignal;
        if OldSignal and (not NewSignal) then
          IncrementTIMA;
      end;
    $FF05:
      begin
        { 写 TIMA:
          本实现采用“取消 pending reload”模型，和常见测试 ROM 行为一致。 }
        FTIMA := Value;
        FReloadDelay := -1; { Writing TIMA cancels pending reload in this model }
      end;
    $FF06: FTMA := Value;
    $FF07:
      begin
        { 改 TAC 可能改变输入信号电平，从而产生下降沿副作用。 }
        OldSignal := TimerSignal;
        OldEnable := (FTAC and 4) <> 0;
        FTAC := Value and 7;
        NewSignal := TimerSignal;
        NewEnable := (FTAC and 4) <> 0;
        if OldSignal and (not NewSignal) then
        begin
          { DMG: disable-induced falling edge ticks TIMA.
            CGB: disabling timer does not tick. }
          if (not FIsCGB) or (OldEnable and NewEnable) then
            IncrementTIMA;
        end;
      end;
  end;
end;

end.
