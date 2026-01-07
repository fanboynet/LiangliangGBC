unit Memory;

interface

uses
  Common, PPU;

type
  TMemory = class
  private
    FData: array[0..MemorySize - 1] of TByte;
    FPPU: TPPU;
  public
    procedure AttachPPU(APPU: TPPU);
    procedure Reset;
    function ReadByte(Address: TWord): TByte;
    procedure WriteByte(Address: TWord; Value: TByte);
    procedure LoadBootRom(const Data: TBytes);
    procedure LoadCartridge(const Data: TBytes);
  end;

implementation

procedure TMemory.AttachPPU(APPU: TPPU);
begin
  FPPU := APPU;
end;

procedure TMemory.Reset;
begin
  FillChar(FData, SizeOf(FData), 0);
end;

function TMemory.ReadByte(Address: TWord): TByte;
begin
  if Assigned(FPPU) then
  begin
    if (Address >= $8000) and (Address <= $9FFF) then
      Exit(FPPU.ReadVRAM(Address));
    if (Address >= $FE00) and (Address <= $FE9F) then
      Exit(FPPU.ReadOAM(Address));
    if (Address >= $FF40) and (Address <= $FF4B) then
      Exit(FPPU.ReadRegister(Address));
    if (Address >= $FF68) and (Address <= $FF6B) then
      Exit(FPPU.ReadRegister(Address));
    if Address = $FF4F then
      Exit(FPPU.ReadRegister(Address));
  end;
  Result := FData[Address];
end;

procedure TMemory.WriteByte(Address: TWord; Value: TByte);
begin
  if Assigned(FPPU) then
  begin
    if (Address >= $8000) and (Address <= $9FFF) then
    begin
      FPPU.WriteVRAM(Address, Value);
      Exit;
    end;
    if (Address >= $FE00) and (Address <= $FE9F) then
    begin
      FPPU.WriteOAM(Address, Value);
      Exit;
    end;
    if (Address >= $FF40) and (Address <= $FF4B) then
    begin
      FPPU.WriteRegister(Address, Value);
      Exit;
    end;
    if (Address >= $FF68) and (Address <= $FF6B) then
    begin
      FPPU.WriteRegister(Address, Value);
      Exit;
    end;
    if Address = $FF4F then
    begin
      FPPU.WriteRegister(Address, Value);
      Exit;
    end;
  end;
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
