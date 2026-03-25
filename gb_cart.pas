unit gb_cart;
{ 单元定义: 卡带子系统与 MBC 映射层。 }
{ 负责内容: ROM 头解析、ROM/RAM 银行切换、MBC 类型分支、电池存档加载与保存。 }



{
  Game Boy cartridge / MBC abstraction.
  目标:
  - 解析 ROM 头部($0147/$0148/$0149/$0143)并建立银行参数。
  - 统一 ReadROM/WriteROM/ReadRAM/WriteRAM 供 MMU 调用。
  - 对电池 RAM 做最小化持久化（仅 dirty 时写盘）。
  参考: Pan Docs / The Cartridge Header / MBC1 / MBC2 / MBC3 / MBC5.
}

interface

type
  TCartridgeType = (
    ctROMOnly,
    ctMBC1, ctMBC1RAM, ctMBC1RAMBattery,
    ctMBC2, ctMBC2Battery,
    ctMMM01, ctMMM01RAM, ctMMM01RAMBattery,
    ctMBC3TimerBattery, ctMBC3TimerRAMBattery, ctMBC3, ctMBC3RAM, ctMBC3RAMBattery,
    ctMBC5, ctMBC5RAM, ctMBC5RAMBattery,
    ctMBC5Rumble, ctMBC5RumbleRAM, ctMBC5RumbleRAMBattery,
    ctMBC7SensorRumbleRAMBattery,
    ctHuC1RAMBattery,
    ctUnknown
  );

  TCartridge = class
  private
    FROM: array of Byte;
    FRAM: array of Byte;
    FCartType: TCartridgeType;
    FROMBanks: Word;
    FRAMBanks: Word;
    FRAMSizeBytes: Cardinal;
    FROMBankLo: Byte;     { 5-bit for MBC1 4000-7FFF }
    FROMBankHi: Byte;     { 2-bit for MBC1 large ROM }
    FRAMBank: Byte;
    FRAMEnabled: Boolean;
    FMBC1Mode: Byte;      { 0 = simple, 1 = advanced }
    FMBC5ROMBankLo: Byte; { 8-bit for MBC5 4000-7FFF }
    FMBC5ROMBankHi: Byte; { 1-bit for MBC5 4000-7FFF }
    FMBC5RAMBank: Byte;   { 0..15 }
    FTitle: string;
    FCGBFlag: Byte;
    FRomPath: string;
    FSavePath: string;
    FRAMDirty: Boolean;
    function IsBatteryBacked: Boolean;
  public
    destructor Destroy; override;
    function LoadFromFile(const FileName: string): Boolean;
    function LoadFromBuffer(const Buffer: array of Byte; Count: Integer): Boolean;
    function LoadRAMFromFile: Boolean;
    function SaveRAMToFile: Boolean;
    function ReadROM(Addr: Word): Byte;
    procedure WriteROM(Addr: Word; Value: Byte);
    function ReadRAM(Addr: Word): Byte;
    procedure WriteRAM(Addr: Word; Value: Byte);
    property CartType: TCartridgeType read FCartType;
    property Title: string read FTitle;
    property ROMBanks: Word read FROMBanks;
    property RAMBanks: Word read FRAMBanks;
    property CGBFlag: Byte read FCGBFlag;
    property SavePath: string read FSavePath write FSavePath;
    function SupportsCGB: Boolean;
    function RequiresCGB: Boolean;
    function HasRTC: Boolean;
  end;

implementation

uses
{$IFDEF FPC}
  SysUtils, Classes;
{$ELSE}
  System.SysUtils, System.Classes;
{$ENDIF}

function IsMBC5Type(AType: TCartridgeType): Boolean;
begin
  { MBC5 家族共享 ROM/RAM banking 寄存器布局。 }
  Result := AType in [ctMBC5, ctMBC5RAM, ctMBC5RAMBattery,
    ctMBC5Rumble, ctMBC5RumbleRAM, ctMBC5RumbleRAMBattery];
end;

destructor TCartridge.Destroy;
begin
  try
    SaveRAMToFile;
  except
    { never raise during shutdown }
  end;
  SetLength(FROM, 0);
  SetLength(FRAM, 0);
  inherited;
end;

function TCartridge.IsBatteryBacked: Boolean;
begin
  { 是否应启用 .sav 持久化。 }
  Result := FCartType in [
    ctMBC1RAMBattery,
    ctMBC2Battery,
    ctMMM01RAMBattery,
    ctMBC3TimerBattery, ctMBC3TimerRAMBattery, ctMBC3RAMBattery,
    ctMBC5RAMBattery, ctMBC5RumbleRAMBattery,
    ctMBC7SensorRumbleRAMBattery,
    ctHuC1RAMBattery
  ];
end;

function TCartridge.LoadFromBuffer(const Buffer: array of Byte; Count: Integer): Boolean;
var
  I: Integer;
  RomSizeCode, RamSizeCode, TypeCode: Byte;
begin
  { 解析 ROM 头并初始化 MBC 状态寄存器。
    这里只实现当前核心已支持的 bank 语义，不含 RTC 实时推进。 }
  Result := False;
  if Count < $8000 then
    Exit;

  SetLength(FROM, Count);
  for I := 0 to Count - 1 do
    FROM[I] := Buffer[I];

  TypeCode := FROM[$147];
  FCGBFlag := FROM[$143];
  { $0147 Cartridge Type。 }
  case TypeCode of
    $00: FCartType := ctROMOnly;
    $01: FCartType := ctMBC1;
    $02: FCartType := ctMBC1RAM;
    $03: FCartType := ctMBC1RAMBattery;
    $05: FCartType := ctMBC2;
    $06: FCartType := ctMBC2Battery;
    $0B: FCartType := ctMMM01;
    $0C: FCartType := ctMMM01RAM;
    $0D: FCartType := ctMMM01RAMBattery;
    $0F: FCartType := ctMBC3TimerBattery;
    $10: FCartType := ctMBC3TimerRAMBattery;
    $11: FCartType := ctMBC3;
    $12: FCartType := ctMBC3RAM;
    $13: FCartType := ctMBC3RAMBattery;
    $19: FCartType := ctMBC5;
    $1A: FCartType := ctMBC5RAM;
    $1B: FCartType := ctMBC5RAMBattery;
    $1C: FCartType := ctMBC5Rumble;
    $1D: FCartType := ctMBC5RumbleRAM;
    $1E: FCartType := ctMBC5RumbleRAMBattery;
    $22: FCartType := ctMBC7SensorRumbleRAMBattery;
    $FF: FCartType := ctHuC1RAMBattery;
  else
    FCartType := ctUnknown;
  end;

  RomSizeCode := FROM[$148];
  { $0148 ROM Size -> ROM bank 数。 }
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

  RamSizeCode := FROM[$149];
  { $0149 RAM Size -> RAM 容量。 }
  case RamSizeCode of
    $00: begin FRAMBanks := 0; FRAMSizeBytes := 0; end;
    $01: begin FRAMBanks := 0; FRAMSizeBytes := 0; end; { usually unused on GB }
    $02: begin FRAMBanks := 1; FRAMSizeBytes := 8 * 1024; end;
    $03: begin FRAMBanks := 4; FRAMSizeBytes := 32 * 1024; end;
    $04: begin FRAMBanks := 16; FRAMSizeBytes := 128 * 1024; end;
    $05: begin FRAMBanks := 8; FRAMSizeBytes := 64 * 1024; end;
  else
    FRAMBanks := 0;
    FRAMSizeBytes := 0;
  end;

  { MBC2 contains internal 512 x 4-bit RAM. We store one byte per entry. }
  if (FCartType in [ctMBC2, ctMBC2Battery]) and (FRAMSizeBytes = 0) then
  begin
    FRAMBanks := 1;
    FRAMSizeBytes := 512;
  end;

  if FRAMSizeBytes > 0 then
    SetLength(FRAM, FRAMSizeBytes)
  else
    SetLength(FRAM, 0);

  FTitle := '';
  { 标题字段通常在 $0134..$0143。 }
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
  FMBC5ROMBankLo := 1;
  FMBC5ROMBankHi := 0;
  FMBC5RAMBank := 0;
  FRAMDirty := False;
  Result := True;
end;

function TCartridge.SupportsCGB: Boolean;
begin
  { $0143: $80=支持 CGB，$C0=仅 CGB。 }
  Result := (FCGBFlag = $80) or (FCGBFlag = $C0);
end;

function TCartridge.RequiresCGB: Boolean;
begin
  Result := FCGBFlag = $C0;
end;

function TCartridge.HasRTC: Boolean;
begin
  { 仅声明能力；当前实现未推进 RTC 寄存器。 }
  Result := FCartType in [ctMBC3TimerBattery, ctMBC3TimerRAMBattery];
end;

function TCartridge.LoadFromFile(const FileName: string): Boolean;
var
  Stream: TFileStream;
  Buf: array of Byte;
  Sz: Int64;
begin
  { 装载新 ROM 前先落盘旧 cartridge RAM，避免热切换丢档。 }
  Result := False;
  if not FileExists(FileName) then
    Exit;

  { Persist previous cartridge RAM before replacing state. }
  SaveRAMToFile;
  FRomPath := ExpandFileName(FileName);
  FSavePath := ChangeFileExt(FRomPath, '.sav');

  Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    Sz := Stream.Size;
    if Sz > 8 * 1024 * 1024 then
      Sz := 8 * 1024 * 1024;
    SetLength(Buf, Sz);
    if Sz > 0 then
      Stream.Read(Buf[0], Sz);
    Result := LoadFromBuffer(Buf, Integer(Sz));
    if Result then
      LoadRAMFromFile;
  finally
    Stream.Free;
  end;
end;

function TCartridge.LoadRAMFromFile: Boolean;
var
  Stream: TFileStream;
  BytesToRead: Integer;
begin
  Result := False;
  if (Length(FRAM) = 0) or (not IsBatteryBacked) or (FSavePath = '') then
  begin
    Result := True;
    Exit;
  end;

  if not FileExists(FSavePath) then
  begin
    Result := True;
    Exit;
  end;

  Stream := TFileStream.Create(FSavePath, fmOpenRead or fmShareDenyWrite);
  try
    BytesToRead := Length(FRAM);
    if Stream.Size < BytesToRead then
      BytesToRead := Stream.Size;
    if BytesToRead > 0 then
      Stream.Read(FRAM[0], BytesToRead);
    FRAMDirty := False;
    Result := True;
  finally
    Stream.Free;
  end;
end;

function TCartridge.SaveRAMToFile: Boolean;
var
  Stream: TFileStream;
  SaveDir: string;
begin
  { 仅在 dirty 时写盘，降低频繁 IO。 }
  Result := False;
  if (Length(FRAM) = 0) or (not IsBatteryBacked) or (FSavePath = '') then
  begin
    Result := True;
    Exit;
  end;

  if not FRAMDirty then
  begin
    Result := True;
    Exit;
  end;

  SaveDir := ExtractFilePath(FSavePath);
  if SaveDir <> '' then
    ForceDirectories(SaveDir);

  Stream := TFileStream.Create(FSavePath, fmCreate);
  try
    Stream.Write(FRAM[0], Length(FRAM));
    FRAMDirty := False;
    Result := True;
  finally
    Stream.Free;
  end;
end;

function TCartridge.ReadROM(Addr: Word): Byte;
var
  Offset: Cardinal;
  Bank: Word;
begin
  { ROM banking 读取:
    0000-3FFF 固定/半固定区，4000-7FFF 可切换区。 }
  Addr := Addr and $FFFF;
  if Length(FROM) = 0 then
  begin
    Result := $FF;
    Exit;
  end;

  if Addr < $4000 then
  begin
    { MBC1 mode1 + 大 ROM 时，低区也受高位银行影响。 }
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
    { MBC5 为 9-bit ROM bank；MBC1 为高低位拼接。 }
    if IsMBC5Type(FCartType) then
      Bank := (Word(FMBC5ROMBankHi and 1) shl 8) or Word(FMBC5ROMBankLo)
    else
      Bank := (FROMBankHi shl 5) or (FROMBankLo and $1F);

    if not IsMBC5Type(FCartType) then
      { 非 MBC5 控制器通常禁止 bank 0 映射到可切区。 }
      if Bank = 0 then
        Bank := 1;

    if FROMBanks > 0 then
      Bank := Word(Cardinal(Bank) mod Cardinal(FROMBanks));

    if not IsMBC5Type(FCartType) then
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
  { ROM 区写入映射到 MBC 控制寄存器，不会改写 FROM 内容。 }
  Addr := Addr and $FFFF;
  if FCartType = ctROMOnly then
    Exit;

  if (FCartType in [ctMBC1, ctMBC1RAM, ctMBC1RAMBattery]) then
  begin
    { MBC1:
      0000-1FFF RAM enable
      2000-3FFF ROM bank low 5
      4000-5FFF ROM bank high 2 / RAM bank
      6000-7FFF mode select }
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

  if IsMBC5Type(FCartType) then
  begin
    { MBC5:
      2000-2FFF ROM bank low 8
      3000-3FFF ROM bank high 1
      4000-5FFF RAM bank (rumble 变体含马达位)。 }
    if Addr < $2000 then
    begin
      FRAMEnabled := (Value and $0F) = $0A;
    end
    else if Addr < $3000 then
    begin
      FMBC5ROMBankLo := Value;
    end
    else if Addr < $4000 then
    begin
      FMBC5ROMBankHi := Value and 1;
    end
    else if Addr < $6000 then
    begin
      { For rumble variants, bit 3 is rumble control and bits 0..2 are RAM bank.
        We ignore rumble and keep usable RAM-bank bits only. }
      if (FCartType in [ctMBC5Rumble, ctMBC5RumbleRAM, ctMBC5RumbleRAMBattery]) then
        FMBC5RAMBank := Value and $07
      else
        FMBC5RAMBank := Value and $0F;
    end;
  end;
end;

function TCartridge.ReadRAM(Addr: Word): Byte;
var
  Offset: Cardinal;
begin
  { A000-BFFF 外部 RAM 读取，需 RAM enable 且 offset 在容量内。 }
  Addr := Addr and $FFFF;
  if (Addr < $A000) or (Addr > $BFFF) or (Length(FRAM) = 0) or not FRAMEnabled then
  begin
    Result := $FF;
    Exit;
  end;

  if IsMBC5Type(FCartType) then
    Offset := (Cardinal(FMBC5RAMBank) * $2000) + Cardinal(Addr - $A000)
  else if FMBC1Mode = 0 then
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
  NewValue: Byte;
begin
  { 外部 RAM 写入并置 dirty。
    MBC2 仅低 4 位有效，高 4 位通常固定为 1。 }
  Addr := Addr and $FFFF;
  if (Addr < $A000) or (Addr > $BFFF) or (Length(FRAM) = 0) or not FRAMEnabled then
    Exit;

  if IsMBC5Type(FCartType) then
    Offset := (Cardinal(FMBC5RAMBank) * $2000) + Cardinal(Addr - $A000)
  else if FMBC1Mode = 0 then
    Offset := Cardinal(Addr - $A000)
  else
    Offset := (Cardinal(FRAMBank) * $2000) + Cardinal(Addr - $A000);

  if Offset < Cardinal(Length(FRAM)) then
  begin
    NewValue := Value;
    if FCartType in [ctMBC2, ctMBC2Battery] then
      NewValue := (Value and $0F) or $F0;
    if FRAM[Offset] <> NewValue then
    begin
      FRAM[Offset] := NewValue;
      FRAMDirty := True;
    end;
  end;
end;

end.
