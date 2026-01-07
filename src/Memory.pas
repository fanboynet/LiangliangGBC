unit Memory;

interface

uses
  Common;

type
  TMemory = class
  private
    FData: array[0..MemorySize - 1] of TByte;
  public
    procedure Reset;
    function ReadByte(Address: TWord): TByte;
    procedure WriteByte(Address: TWord; Value: TByte);
    procedure LoadBootRom(const Data: TBytes);
    procedure LoadCartridge(const Data: TBytes);
  end;

implementation

procedure TMemory.Reset;
begin
  FillChar(FData, SizeOf(FData), 0);
end;

function TMemory.ReadByte(Address: TWord): TByte;
begin
  Result := FData[Address];
end;

procedure TMemory.WriteByte(Address: TWord; Value: TByte);
begin
  FData[Address] := Value;
end;

procedure TMemory.LoadBootRom(const Data: TBytes);
var
  Index: Integer;
begin
  for Index := 0 to High(Data) do
  begin
    if Index >= MemorySize then
      Break;
    FData[Index] := Data[Index];
  end;
end;

procedure TMemory.LoadCartridge(const Data: TBytes);
var
  Index: Integer;
begin
  for Index := 0 to High(Data) do
  begin
    if Index >= MemorySize then
      Break;
    FData[Index] := Data[Index];
  end;
end;

end.
