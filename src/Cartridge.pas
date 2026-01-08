unit Cartridge;

interface

uses
  System.SysUtils;

type
  TMBCType = (mbcNone, mbc1);

  TCartridge = class
  private
    FData: TBytes;
    FRAM: TBytes;
    FTitle: string;
    FCartridgeType: Byte;
    FROMBanks: Integer;
    FRAMBanks: Integer;
    FMBCType: TMBCType;
    FHasRAM: Boolean;
    FRAMEnabled: Boolean;
    FROMBank: Integer;
    FRAMBank: Integer;
    FBankMode: Byte;
    procedure ParseHeader;
    function GetROMByte(Address: Word): Byte;
    function GetRAMByte(Address: Word): Byte;
    procedure SetRAMByte(Address: Word; Value: Byte);
    procedure HandleBanking(Address: Word; Value: Byte);
  public
    function LoadFromFile(const FileName: string): Boolean;
    function ReadByte(Address: Word): Byte;
    procedure WriteByte(Address: Word; Value: Byte);
    function Title: string;
  TCartridge = class
  private
    FData: TBytes;
  public
    function LoadFromFile(const FileName: string): Boolean;
    function Data: TBytes;
  end;

implementation

const
  HeaderTitleStart = $0134;
  HeaderTitleEnd = $0143;
  HeaderType = $0147;
  HeaderROMSize = $0148;
  HeaderRAMSize = $0149;

function TCartridge.LoadFromFile(const FileName: string): Boolean;
begin
  if not FileExists(FileName) then
    Exit(False);
  FData := TFile.ReadAllBytes(FileName);
  Result := Length(FData) > 0;
  if Result then
    ParseHeader;
end;

procedure TCartridge.ParseHeader;
var
  Index: Integer;
  TitleBytes: TBytes;
  RomSizeCode: Byte;
  RamSizeCode: Byte;
begin
  SetLength(TitleBytes, HeaderTitleEnd - HeaderTitleStart + 1);
  for Index := HeaderTitleStart to HeaderTitleEnd do
    TitleBytes[Index - HeaderTitleStart] := FData[Index];
  FTitle := TEncoding.ASCII.GetString(TitleBytes).Trim;

  FCartridgeType := FData[HeaderType];
  RomSizeCode := FData[HeaderROMSize];
  RamSizeCode := FData[HeaderRAMSize];

  case RomSizeCode of
    $00: FROMBanks := 2;
    $01: FROMBanks := 4;
    $02: FROMBanks := 8;
    $03: FROMBanks := 16;
    $04: FROMBanks := 32;
    $05: FROMBanks := 64;
    $06: FROMBanks := 128;
    $07: FROMBanks := 256;
    $08: FROMBanks := 512;
  else
    FROMBanks := 2;
  end;

  case RamSizeCode of
    $00: FRAMBanks := 0;
    $01: FRAMBanks := 1;
    $02: FRAMBanks := 1;
    $03: FRAMBanks := 4;
    $04: FRAMBanks := 16;
    $05: FRAMBanks := 8;
  else
    FRAMBanks := 0;
  end;

  FHasRAM := FRAMBanks > 0;
  if FHasRAM then
    SetLength(FRAM, FRAMBanks * $2000)
  else
    SetLength(FRAM, 0);

  case FCartridgeType of
    $00: FMBCType := mbcNone;
    $01, $02, $03: FMBCType := mbc1;
  else
    FMBCType := mbcNone;
  end;

  FROMBank := 1;
  FRAMBank := 0;
  FRAMEnabled := False;
  FBankMode := 0;
end;

function TCartridge.Title: string;
begin
  Result := FTitle;
end;

function TCartridge.GetROMByte(Address: Word): Byte;
var
  Bank: Integer;
  Offset: Integer;
begin
  if Address < $4000 then
  begin
    if (FMBCType = mbc1) and (FBankMode = 1) then
      Bank := (FRAMBank shl 5) mod FROMBanks
    else
      Bank := 0;
  end
  else
  begin
    Bank := FROMBank mod FROMBanks;
    if Bank = 0 then
      Bank := 1;
    if (FMBCType = mbc1) then
      Bank := (Bank or (FRAMBank shl 5)) mod FROMBanks;
  end;
  Offset := (Bank * $4000) + (Address and $3FFF);
  if Offset < Length(FData) then
    Result := FData[Offset]
  else
    Result := $FF;
end;

function TCartridge.GetRAMByte(Address: Word): Byte;
var
  Bank: Integer;
  Offset: Integer;
begin
  if not FHasRAM then
    Exit($FF);
  if not FRAMEnabled then
    Exit($FF);
  Bank := 0;
  if (FMBCType = mbc1) and (FBankMode = 1) then
    Bank := FRAMBank mod FRAMBanks;
  Offset := (Bank * $2000) + (Address and $1FFF);
  if Offset < Length(FRAM) then
    Result := FRAM[Offset]
  else
    Result := $FF;
end;

procedure TCartridge.SetRAMByte(Address: Word; Value: Byte);
var
  Bank: Integer;
  Offset: Integer;
begin
  if not FHasRAM then
    Exit;
  if not FRAMEnabled then
    Exit;
  Bank := 0;
  if (FMBCType = mbc1) and (FBankMode = 1) then
    Bank := FRAMBank mod FRAMBanks;
  Offset := (Bank * $2000) + (Address and $1FFF);
  if Offset < Length(FRAM) then
    FRAM[Offset] := Value;
end;

procedure TCartridge.HandleBanking(Address: Word; Value: Byte);
begin
  case Address of
    $0000..$1FFF:
      begin
        FRAMEnabled := (Value and $0F) = $0A;
      end;
    $2000..$3FFF:
      begin
        FROMBank := Value and $1F;
        if FROMBank = 0 then
          FROMBank := 1;
      end;
    $4000..$5FFF:
      begin
        FRAMBank := Value and $03;
      end;
    $6000..$7FFF:
      begin
        FBankMode := Value and $01;
      end;
  end;
end;

function TCartridge.ReadByte(Address: Word): Byte;
begin
  if Address <= $7FFF then
    Result := GetROMByte(Address)
  else if (Address >= $A000) and (Address <= $BFFF) then
    Result := GetRAMByte(Address)
  else
    Result := $FF;
end;

procedure TCartridge.WriteByte(Address: Word; Value: Byte);
begin
  if Address <= $7FFF then
    HandleBanking(Address, Value)
  else if (Address >= $A000) and (Address <= $BFFF) then
    SetRAMByte(Address, Value);
end;

function TCartridge.Data: TBytes;
begin
  Result := FData;
end;

end.
