unit gb_cart;

{ Game Boy cartridge: header parse, ROM/RAM access. ROM ONLY + MBC1. }

interface

type
  TCartridgeType = (ctROMOnly, ctMBC1, ctMBC1RAM, ctMBC1RAMBattery, ctUnknown);

  TCartridge = class
  private
    FROM: array of Byte;
    FRAM: array of Byte;
    FCartType: TCartridgeType;
    FROMBanks: Word;
    FRAMBanks: Word;
    FRAMSizeBytes: Cardinal;
    FROMBankLo: Byte;   { 5-bit for 4000-7FFF }
    FROMBankHi: Byte;   { 2-bit for MBC1 large ROM }
    FRAMBank: Byte;
    FRAMEnabled: Boolean;
    FMBC1Mode: Byte;    { 0 = simple, 1 = advanced }
    FTitle: string;
    FCGBFlag: Byte;
  public
    destructor Destroy; override;
    function LoadFromFile(const FileName: string): Boolean;
    function LoadFromBuffer(const Buffer: array of Byte; Count: Integer): Boolean;
    function ReadROM(Addr: Word): Byte;
    procedure WriteROM(Addr: Word; Value: Byte);
    function ReadRAM(Addr: Word): Byte;
    procedure WriteRAM(Addr: Word; Value: Byte);
    property CartType: TCartridgeType read FCartType;
    property Title: string read FTitle;
    property ROMBanks: Word read FROMBanks;
    property RAMBanks: Word read FRAMBanks;
    property CGBFlag: Byte read FCGBFlag;
    function SupportsCGB: Boolean;
    function RequiresCGB: Boolean;
  end;

implementation

uses
{$IFDEF FPC}
  SysUtils, Classes;
{$ELSE}
  System.SysUtils, System.Classes;
{$ENDIF}

destructor TCartridge.Destroy;
begin
  SetLength(FROM, 0);
  SetLength(FRAM, 0);
  inherited;
end;

function TCartridge.LoadFromBuffer(const Buffer: array of Byte; Count: Integer): Boolean;
var
  I: Integer;
  RomSizeCode, RamSizeCode, TypeCode: Byte;
begin
  Result := False;
  if Count < $8000 then
    Exit;
  SetLength(FROM, Count);
  for I := 0 to Count - 1 do
    FROM[I] := Buffer[I];

  TypeCode := FROM[$147];
  FCGBFlag := FROM[$143];
  case TypeCode of
    $00: FCartType := ctROMOnly;
    $01: FCartType := ctMBC1;
    $02: FCartType := ctMBC1RAM;
    $03: FCartType := ctMBC1RAMBattery;
  else
    FCartType := ctUnknown;
  end;

  RomSizeCode := FROM[$148];
  case RomSizeCode of
    $00: FROMBanks := 2;
    $01: FROMBanks := 4;
    $02: FROMBanks := 8;
    $03: FROMBanks := 16;
    $04: FROMBanks := 32;
    $05: FROMBanks := 64;
    $06: FROMBanks := 128;
    $07: FROMBanks := 256;
  else
    FROMBanks := 2;
  end;

  RamSizeCode := FROM[$149];
  case RamSizeCode of
    $00: begin FRAMBanks := 0; FRAMSizeBytes := 0; end;
    $01: begin FRAMBanks := 0; FRAMSizeBytes := 0; end; { unused }
    $02: begin FRAMBanks := 1; FRAMSizeBytes := 8 * 1024; end;
    $03: begin FRAMBanks := 4; FRAMSizeBytes := 32 * 1024; end;
    $04: begin FRAMBanks := 16; FRAMSizeBytes := 128 * 1024; end;
    $05: begin FRAMBanks := 8; FRAMSizeBytes := 64 * 1024; end;
  else
    FRAMBanks := 0;
    FRAMSizeBytes := 0;
  end;

  if FRAMSizeBytes > 0 then
    SetLength(FRAM, FRAMSizeBytes)
  else
    SetLength(FRAM, 0);

  FTitle := '';
  for I := 0 to 15 do
    if (FROM[$134 + I] >= 32) and (FROM[$134 + I] < 127) then
      FTitle := FTitle + Chr(FROM[$134 + I])
    else
      Break;

  FROMBankLo := 1;
  FROMBankHi := 0;
  FRAMBank := 0;
  FRAMEnabled := False;
  FMBC1Mode := 0;
  Result := True;
end;

function TCartridge.SupportsCGB: Boolean;
begin
  Result := (FCGBFlag = $80) or (FCGBFlag = $C0);
end;

function TCartridge.RequiresCGB: Boolean;
begin
  Result := FCGBFlag = $C0;
end;

function TCartridge.LoadFromFile(const FileName: string): Boolean;
var
  Stream: TFileStream;
  Buf: array of Byte;
  Sz: Int64;
begin
  Result := False;
  if not FileExists(FileName) then
    Exit;
  Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    Sz := Stream.Size;
    if Sz > 8 * 1024 * 1024 then
      Sz := 8 * 1024 * 1024;
    SetLength(Buf, Sz);
    Stream.Read(Buf[0], Sz);
    Result := LoadFromBuffer(Buf, Integer(Sz));
  finally
    Stream.Free;
  end;
end;

function TCartridge.ReadROM(Addr: Word): Byte;
var
  Offset: Cardinal;
  Bank: Word;
begin
  Addr := Addr and $FFFF;
  if Length(FROM) = 0 then
  begin
    Result := $FF;
    Exit;
  end;
  if Addr < $4000 then
  begin
    if (FCartType in [ctMBC1, ctMBC1RAM, ctMBC1RAMBattery]) and (FMBC1Mode = 1) and (FROMBanks > 16) then
    begin
      Bank := (FROMBankHi shl 5);
      if FROMBanks > 0 then
        Bank := Word(Cardinal(Bank) mod Cardinal(FROMBanks));
    end
    else
      Bank := 0;
    Offset := (Cardinal(Bank) * $4000) + Addr;
  end
  else if Addr < $8000 then
  begin
    Bank := (FROMBankHi shl 5) or (FROMBankLo and $1F);
    if Bank = 0 then
      Bank := 1;
    if FROMBanks > 0 then
      Bank := Word(Cardinal(Bank) mod Cardinal(FROMBanks));
    if Bank = 0 then
      Bank := 1;
    Offset := (Cardinal(Bank) * $4000) + Cardinal(Addr - $4000);
  end
  else
  begin
    Result := $FF;
    Exit;
  end;
  if Offset < Cardinal(Length(FROM)) then
    Result := FROM[Offset]
  else
    Result := $FF;
end;

procedure TCartridge.WriteROM(Addr: Word; Value: Byte);
var
  Lo: Byte;
begin
  Addr := Addr and $FFFF;
  if FCartType = ctROMOnly then
    Exit;
  if (FCartType in [ctMBC1, ctMBC1RAM, ctMBC1RAMBattery]) then
  begin
    if Addr < $2000 then
    begin
      FRAMEnabled := (Value and $0F) = $0A;
    end
    else if Addr < $4000 then
    begin
      Lo := Value and $1F;
      if Lo = 0 then
        Lo := 1;
      FROMBankLo := Lo;
    end
    else if Addr < $6000 then
    begin
      FROMBankHi := Value and 3;
      if FRAMBanks > 0 then
        FRAMBank := FROMBankHi and (FRAMBanks - 1);
    end
    else if Addr < $8000 then
      FMBC1Mode := Value and 1;
  end;
end;

function TCartridge.ReadRAM(Addr: Word): Byte;
var
  Offset: Cardinal;
begin
  Addr := Addr and $FFFF;
  if (Addr < $A000) or (Addr > $BFFF) or (Length(FRAM) = 0) or not FRAMEnabled then
  begin
    Result := $FF;
    Exit;
  end;
  if FMBC1Mode = 0 then
    Offset := Cardinal(Addr - $A000)
  else
    Offset := (Cardinal(FRAMBank) * $2000) + Cardinal(Addr - $A000);
  if Offset < Cardinal(Length(FRAM)) then
    Result := FRAM[Offset]
  else
    Result := $FF;
end;

procedure TCartridge.WriteRAM(Addr: Word; Value: Byte);
var
  Offset: Cardinal;
begin
  Addr := Addr and $FFFF;
  if (Addr < $A000) or (Addr > $BFFF) or (Length(FRAM) = 0) or not FRAMEnabled then
    Exit;
  if FMBC1Mode = 0 then
    Offset := Cardinal(Addr - $A000)
  else
    Offset := (Cardinal(FRAMBank) * $2000) + Cardinal(Addr - $A000);
  if Offset < Cardinal(Length(FRAM)) then
    FRAM[Offset] := Value;
end;

end.
