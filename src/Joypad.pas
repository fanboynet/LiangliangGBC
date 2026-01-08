unit Joypad;

interface

type
  TJoypadButton = (jpRight, jpLeft, jpUp, jpDown, jpA, jpB, jpSelect, jpStart);

  TJoypad = class
  private
    FSelectAction: Boolean;
    FSelectDirection: Boolean;
    FButtons: array[TJoypadButton] of Boolean;
    function ReadDirectionNibble: Byte;
    function ReadActionNibble: Byte;
  public
    procedure Reset;
    function ReadRegister: Byte;
    procedure WriteRegister(Value: Byte);
    procedure SetButton(Button: TJoypadButton; Pressed: Boolean);
  end;

implementation

procedure TJoypad.Reset;
var
  Button: TJoypadButton;
begin
  FSelectAction := False;
  FSelectDirection := False;
  for Button := Low(TJoypadButton) to High(TJoypadButton) do
    FButtons[Button] := False;
end;

procedure TJoypad.SetButton(Button: TJoypadButton; Pressed: Boolean);
begin
  FButtons[Button] := Pressed;
end;

function TJoypad.ReadDirectionNibble: Byte;
begin
  Result := $0F;
  if FButtons[jpRight] then
    Result := Result and $0E;
  if FButtons[jpLeft] then
    Result := Result and $0D;
  if FButtons[jpUp] then
    Result := Result and $0B;
  if FButtons[jpDown] then
    Result := Result and $07;
end;

function TJoypad.ReadActionNibble: Byte;
begin
  Result := $0F;
  if FButtons[jpA] then
    Result := Result and $0E;
  if FButtons[jpB] then
    Result := Result and $0D;
  if FButtons[jpSelect] then
    Result := Result and $0B;
  if FButtons[jpStart] then
    Result := Result and $07;
end;

function TJoypad.ReadRegister: Byte;
var
  ResultValue: Byte;
begin
  ResultValue := $CF;
  if FSelectDirection then
    ResultValue := (ResultValue and $F0) or ReadDirectionNibble;
  if FSelectAction then
    ResultValue := (ResultValue and $F0) or ReadActionNibble;
  if (not FSelectAction) and (not FSelectDirection) then
    ResultValue := (ResultValue and $F0) or $0F;
  if FSelectAction then
    ResultValue := ResultValue and not $20
  else
    ResultValue := ResultValue or $20;
  if FSelectDirection then
    ResultValue := ResultValue and not $10
  else
    ResultValue := ResultValue or $10;
  Result := ResultValue;
end;

procedure TJoypad.WriteRegister(Value: Byte);
begin
  FSelectAction := (Value and $20) = 0;
  FSelectDirection := (Value and $10) = 0;
end;

end.
