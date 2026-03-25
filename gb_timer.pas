unit gb_timer;

{ Game Boy timer: DIV, TIMA, TMA, TAC. Update(cycles). Requests IRQ on overflow. }

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
  Result := ((FTAC and 4) <> 0) and ((FDivCounter and GetTimerBitMask) <> 0);
end;

procedure TGBTimer.IncrementTIMA;
begin
  { While overflow reload is pending, additional falling edges are ignored. }
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
        OldSignal := TimerSignal;
        FDivCounter := 0;
        NewSignal := TimerSignal;
        if OldSignal and (not NewSignal) then
          IncrementTIMA;
      end;
    $FF05:
      begin
        FTIMA := Value;
        FReloadDelay := -1; { Writing TIMA cancels pending reload in this model }
      end;
    $FF06: FTMA := Value;
    $FF07:
      begin
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
