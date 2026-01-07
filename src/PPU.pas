unit PPU;

interface

uses
  Common;

type
  TRGBColor = Word;
  TFrameBuffer = array[0..143, 0..159] of TRGBColor;

  TPPU = class
  private
    FCycles: Integer;
    FDotCounter: Integer;
    FMode: Byte;
    FLCDC: Byte;
    FSTAT: Byte;
    FSCY: Byte;
    FSCX: Byte;
    FLY: Byte;
    FLYC: Byte;
    FBGP: Byte;
    FOBP0: Byte;
    FOBP1: Byte;
    FWY: Byte;
    FWX: Byte;
    FVBK: Byte;
    FBGPI: Byte;
    FBGPD: array[0..$3F] of Byte;
    FOBPI: Byte;
    FOBPD: array[0..$3F] of Byte;
    FVRAM: array[0..1, 0..$1FFF] of Byte;
    FOAM: array[0..$9F] of Byte;
    FFrameBuffer: TFrameBuffer;
    FWindowLine: Byte;
    FCGBMode: Boolean;
    function LCDEnabled: Boolean;
    procedure SetMode(Value: Byte);
    procedure UpdateLYC;
    function GetTileDataAddress(TileIndex: Byte; UnsignedMode: Boolean): Word;
    function ReadVRAMBank(Address: Word): Byte;
    procedure WriteVRAMBank(Address: Word; Value: Byte);
    function ReadPaletteData(const Data: array of Byte; Index: Integer): TRGBColor;
    function MapDMGColor(Palette: Byte; ColorIndex: Byte): TRGBColor;
    procedure RenderScanline;
    procedure RenderBackgroundLine;
    procedure RenderWindowLine;
    procedure RenderSpriteLine;
  public
    procedure Reset;
    procedure Step(Cycles: Integer);
    function ReadVRAM(Address: Word): Byte;
    procedure WriteVRAM(Address: Word; Value: Byte);
    function ReadOAM(Address: Word): Byte;
    procedure WriteOAM(Address: Word; Value: Byte);
    function ReadRegister(Address: Word): Byte;
    procedure WriteRegister(Address: Word; Value: Byte);
    property Cycles: Integer read FCycles;
    property FrameBuffer: TFrameBuffer read FFrameBuffer;
    property CGBMode: Boolean read FCGBMode write FCGBMode;
type
  TPPU = class
  private
    FCycles: Integer;
  public
    procedure Reset;
    procedure Step(Cycles: Integer);
    property Cycles: Integer read FCycles;
  end;

implementation

const
  ScreenWidth = 160;
  ScreenHeight = 144;

  ModeHBlank = 0;
  ModeVBlank = 1;
  ModeOAM = 2;
  ModeTransfer = 3;

  OAMCycles = 80;
  TransferCycles = 172;
  HBlankCycles = 204;
  LineCycles = 456;

procedure TPPU.Reset;
begin
  FCycles := 0;
  FDotCounter := 0;
  FMode := ModeOAM;
  FLCDC := $91;
  FSTAT := 0;
  FSCY := 0;
  FSCX := 0;
  FLY := 0;
  FLYC := 0;
  FBGP := $FC;
  FOBP0 := $FF;
  FOBP1 := $FF;
  FWY := 0;
  FWX := 0;
  FVBK := 0;
  FBGPI := 0;
  FOBPI := 0;
  FillChar(FBGPD, SizeOf(FBGPD), 0);
  FillChar(FOBPD, SizeOf(FOBPD), 0);
  FillChar(FVRAM, SizeOf(FVRAM), 0);
  FillChar(FOAM, SizeOf(FOAM), 0);
  FillChar(FFrameBuffer, SizeOf(FFrameBuffer), 0);
  FWindowLine := 0;
  UpdateLYC;
end;

function TPPU.LCDEnabled: Boolean;
begin
  Result := (FLCDC and $80) <> 0;
end;

procedure TPPU.SetMode(Value: Byte);
begin
  FMode := Value and $03;
  FSTAT := (FSTAT and $FC) or FMode;
end;

procedure TPPU.UpdateLYC;
begin
  if FLY = FLYC then
    FSTAT := FSTAT or $04
  else
    FSTAT := FSTAT and not $04;
end;

function TPPU.GetTileDataAddress(TileIndex: Byte; UnsignedMode: Boolean): Word;
var
  SignedIndex: ShortInt;
begin
  if UnsignedMode then
    Result := Word(TileIndex) * 16
  else
  begin
    SignedIndex := ShortInt(TileIndex);
    Result := Word($1000 + (SignedIndex * 16));
  end;
end;

function TPPU.ReadVRAMBank(Address: Word): Byte;
var
  Bank: Integer;
  Offset: Word;
begin
  Bank := FVBK and $01;
  Offset := Address and $1FFF;
  Result := FVRAM[Bank, Offset];
end;

procedure TPPU.WriteVRAMBank(Address: Word; Value: Byte);
var
  Bank: Integer;
  Offset: Word;
begin
  Bank := FVBK and $01;
  Offset := Address and $1FFF;
  FVRAM[Bank, Offset] := Value;
end;

function TPPU.ReadPaletteData(const Data: array of Byte; Index: Integer): TRGBColor;
var
  Lo, Hi: Byte;
  Raw: Word;
  R, G, B: Byte;
begin
  Lo := Data[Index and $3E];
  Hi := Data[(Index and $3E) + 1];
  Raw := Word(Lo) or (Word(Hi) shl 8);
  R := Byte(Raw and $1F);
  G := Byte((Raw shr 5) and $1F);
  B := Byte((Raw shr 10) and $1F);
  Result := TRGBColor((R shl 10) or (G shl 5) or B);
end;

function TPPU.MapDMGColor(Palette: Byte; ColorIndex: Byte): TRGBColor;
var
  Shade: Byte;
begin
  Shade := (Palette shr (ColorIndex * 2)) and $03;
  case Shade of
    0: Result := $7FFF;
    1: Result := $56B5;
    2: Result := $2D6B;
  else
    Result := $0000;
  end;
end;

procedure TPPU.RenderBackgroundLine;
var
  TileMapBase: Word;
  UnsignedMode: Boolean;
  X, Y: Integer;
  TileX, TileY: Integer;
  TileIndex: Byte;
  TileAttr: Byte;
  LineInTile: Byte;
  TileAddress: Word;
  LowByte, HighByte: Byte;
  BitIndex: Integer;
  ColorIndex: Byte;
  PaletteIndex: Byte;
  PixelX: Integer;
  VRAMBank: Byte;
begin
  if (FLCDC and $01) = 0 then
  begin
    for X := 0 to ScreenWidth - 1 do
      FFrameBuffer[FLY, X] := MapDMGColor(FBGP, 0);
    Exit;
  end;

  TileMapBase := $1800;
  if (FLCDC and $08) <> 0 then
    TileMapBase := $1C00;

  UnsignedMode := (FLCDC and $10) <> 0;
  Y := (Integer(FSCY) + FLY) and $FF;
  TileY := Y div 8;
  LineInTile := Byte(Y and $07);

  for X := 0 to ScreenWidth - 1 do
  begin
    PixelX := (Integer(FSCX) + X) and $FF;
    TileX := PixelX div 8;
    TileIndex := FVRAM[0, TileMapBase + (TileY * 32) + TileX];
    TileAttr := FVRAM[1, TileMapBase + (TileY * 32) + TileX];
    VRAMBank := (TileAttr shr 3) and $01;
    TileAddress := GetTileDataAddress(TileIndex, UnsignedMode);
    if (TileAttr and $08) <> 0 then
      TileAddress := TileAddress + $2000;
    TileAddress := TileAddress + (Word(LineInTile) * 2);
    LowByte := FVRAM[VRAMBank, TileAddress];
    HighByte := FVRAM[VRAMBank, TileAddress + 1];
    BitIndex := 7 - (PixelX and 7);
    ColorIndex := ((HighByte shr BitIndex) and 1) shl 1 or ((LowByte shr BitIndex) and 1);
    if FCGBMode then
    begin
      PaletteIndex := TileAttr and $07;
      FFrameBuffer[FLY, X] := ReadPaletteData(FBGPD, (PaletteIndex * 8) + (ColorIndex * 2));
    end
    else
    begin
      FFrameBuffer[FLY, X] := MapDMGColor(FBGP, ColorIndex);
    end;
  end;
end;

procedure TPPU.RenderWindowLine;
var
  TileMapBase: Word;
  UnsignedMode: Boolean;
  X, Y: Integer;
  TileX, TileY: Integer;
  TileIndex: Byte;
  TileAttr: Byte;
  LineInTile: Byte;
  TileAddress: Word;
  LowByte, HighByte: Byte;
  BitIndex: Integer;
  ColorIndex: Byte;
  PaletteIndex: Byte;
  WindowX: Integer;
  VRAMBank: Byte;
begin
  if (FLCDC and $20) = 0 then
    Exit;
  if FLY < FWY then
    Exit;

  TileMapBase := $1800;
  if (FLCDC and $40) <> 0 then
    TileMapBase := $1C00;

  UnsignedMode := (FLCDC and $10) <> 0;
  Y := FWindowLine;
  TileY := Y div 8;
  LineInTile := Byte(Y and $07);
  WindowX := Integer(FWX) - 7;
  for X := 0 to ScreenWidth - 1 do
  begin
    if X < WindowX then
      Continue;
    TileX := (X - WindowX) div 8;
    TileIndex := FVRAM[0, TileMapBase + (TileY * 32) + TileX];
    TileAttr := FVRAM[1, TileMapBase + (TileY * 32) + TileX];
    VRAMBank := (TileAttr shr 3) and $01;
    TileAddress := GetTileDataAddress(TileIndex, UnsignedMode);
    if (TileAttr and $08) <> 0 then
      TileAddress := TileAddress + $2000;
    TileAddress := TileAddress + (Word(LineInTile) * 2);
    LowByte := FVRAM[VRAMBank, TileAddress];
    HighByte := FVRAM[VRAMBank, TileAddress + 1];
    BitIndex := 7 - ((X - WindowX) and 7);
    ColorIndex := ((HighByte shr BitIndex) and 1) shl 1 or ((LowByte shr BitIndex) and 1);
    if FCGBMode then
    begin
      PaletteIndex := TileAttr and $07;
      FFrameBuffer[FLY, X] := ReadPaletteData(FBGPD, (PaletteIndex * 8) + (ColorIndex * 2));
    end
    else
    begin
      FFrameBuffer[FLY, X] := MapDMGColor(FBGP, ColorIndex);
    end;
  end;
end;

procedure TPPU.RenderSpriteLine;
var
  SpriteHeight: Integer;
  SpriteCount: Integer;
  Index: Integer;
  SpriteY: Integer;
  SpriteX: Integer;
  TileIndex: Byte;
  Attr: Byte;
  Line: Integer;
  TileAddress: Word;
  LowByte, HighByte: Byte;
  BitIndex: Integer;
  ColorIndex: Byte;
  PaletteIndex: Byte;
  X: Integer;
  UsePalette1: Boolean;
  VRAMBank: Byte;
  XFlip: Boolean;
  YFlip: Boolean;
begin
  if (FLCDC and $02) = 0 then
    Exit;

  SpriteHeight := 8;
  if (FLCDC and $04) <> 0 then
    SpriteHeight := 16;

  SpriteCount := 0;
  for Index := 0 to 39 do
  begin
    SpriteY := FOAM[Index * 4] - 16;
    SpriteX := FOAM[Index * 4 + 1] - 8;
    TileIndex := FOAM[Index * 4 + 2];
    Attr := FOAM[Index * 4 + 3];

    if (FLY < SpriteY) or (FLY >= SpriteY + SpriteHeight) then
      Continue;

    Inc(SpriteCount);
    if SpriteCount > 10 then
      Break;

    Line := FLY - SpriteY;
    XFlip := (Attr and $20) <> 0;
    YFlip := (Attr and $40) <> 0;
    if YFlip then
      Line := SpriteHeight - 1 - Line;

    if SpriteHeight = 16 then
      TileIndex := TileIndex and $FE;

    TileAddress := Word(TileIndex) * 16 + Word(Line) * 2;
    VRAMBank := 0;
    if FCGBMode then
      VRAMBank := (Attr shr 3) and $01;

    LowByte := FVRAM[VRAMBank, TileAddress];
    HighByte := FVRAM[VRAMBank, TileAddress + 1];

    for X := 0 to 7 do
    begin
      if XFlip then
        BitIndex := X
      else
        BitIndex := 7 - X;
      ColorIndex := ((HighByte shr BitIndex) and 1) shl 1 or ((LowByte shr BitIndex) and 1);
      if ColorIndex = 0 then
        Continue;
      if (SpriteX + X < 0) or (SpriteX + X >= ScreenWidth) then
        Continue;
      if FCGBMode then
      begin
        PaletteIndex := Attr and $07;
        FFrameBuffer[FLY, SpriteX + X] := ReadPaletteData(FOBPD, (PaletteIndex * 8) + (ColorIndex * 2));
      end
      else
      begin
        UsePalette1 := (Attr and $10) <> 0;
        if UsePalette1 then
          FFrameBuffer[FLY, SpriteX + X] := MapDMGColor(FOBP1, ColorIndex)
        else
          FFrameBuffer[FLY, SpriteX + X] := MapDMGColor(FOBP0, ColorIndex);
      end;
    end;
  end;
end;

procedure TPPU.RenderScanline;
begin
  if FLY >= ScreenHeight then
    Exit;
  RenderBackgroundLine;
  RenderWindowLine;
  RenderSpriteLine;
end;

procedure TPPU.Step(Cycles: Integer);
var
  Remaining: Integer;
begin
  Inc(FCycles, Cycles);
  if not LCDEnabled then
  begin
    FDotCounter := 0;
    FLY := 0;
    FWindowLine := 0;
    SetMode(ModeHBlank);
    UpdateLYC;
    Exit;
  end;

  Remaining := Cycles;
  while Remaining > 0 do
  begin
    Inc(FDotCounter);
    Dec(Remaining);

    case FMode of
      ModeOAM:
        if FDotCounter >= OAMCycles then
        begin
          SetMode(ModeTransfer);
        end;
      ModeTransfer:
        if FDotCounter >= OAMCycles + TransferCycles then
        begin
          RenderScanline;
          SetMode(ModeHBlank);
        end;
      ModeHBlank:
        if FDotCounter >= LineCycles then
        begin
          FDotCounter := 0;
          Inc(FLY);
          if FLY = ScreenHeight then
          begin
            SetMode(ModeVBlank);
          end
          else
          begin
            SetMode(ModeOAM);
          end;
          if (FLY >= FWY) and (FLY < ScreenHeight) then
            Inc(FWindowLine);
          UpdateLYC;
        end;
      ModeVBlank:
        if FDotCounter >= LineCycles then
        begin
          FDotCounter := 0;
          Inc(FLY);
          if FLY > 153 then
          begin
            FLY := 0;
            FWindowLine := 0;
            SetMode(ModeOAM);
            UpdateLYC;
          end;
        end;
    end;
  end;
end;

function TPPU.ReadVRAM(Address: Word): Byte;
begin
  Result := ReadVRAMBank(Address - $8000);
end;

procedure TPPU.WriteVRAM(Address: Word; Value: Byte);
begin
  WriteVRAMBank(Address - $8000, Value);
end;

function TPPU.ReadOAM(Address: Word): Byte;
begin
  Result := FOAM[Address - $FE00];
end;

procedure TPPU.WriteOAM(Address: Word; Value: Byte);
begin
  FOAM[Address - $FE00] := Value;
end;

function TPPU.ReadRegister(Address: Word): Byte;
begin
  case Address of
    $FF40: Result := FLCDC;
    $FF41: Result := FSTAT;
    $FF42: Result := FSCY;
    $FF43: Result := FSCX;
    $FF44: Result := FLY;
    $FF45: Result := FLYC;
    $FF47: Result := FBGP;
    $FF48: Result := FOBP0;
    $FF49: Result := FOBP1;
    $FF4A: Result := FWY;
    $FF4B: Result := FWX;
    $FF4F: Result := FVBK or $FE;
    $FF68: Result := FBGPI or $40;
    $FF69: Result := FBGPD[FBGPI and $3F];
    $FF6A: Result := FOBPI or $40;
    $FF6B: Result := FOBPD[FOBPI and $3F];
  else
    Result := $FF;
  end;
end;

procedure TPPU.WriteRegister(Address: Word; Value: Byte);
begin
  case Address of
    $FF40: FLCDC := Value;
    $FF41: FSTAT := (FSTAT and $07) or (Value and $F8);
    $FF42: FSCY := Value;
    $FF43: FSCX := Value;
    $FF44: FLY := 0;
    $FF45:
      begin
        FLYC := Value;
        UpdateLYC;
      end;
    $FF47: FBGP := Value;
    $FF48: FOBP0 := Value;
    $FF49: FOBP1 := Value;
    $FF4A: FWY := Value;
    $FF4B: FWX := Value;
    $FF4F: FVBK := Value and $01;
    $FF68: FBGPI := Value and $BF;
    $FF69:
      begin
        FBGPD[FBGPI and $3F] := Value;
        if (FBGPI and $80) <> 0 then
          FBGPI := (FBGPI + 1) and $BF;
      end;
    $FF6A: FOBPI := Value and $BF;
    $FF6B:
      begin
        FOBPD[FOBPI and $3F] := Value;
        if (FOBPI and $80) <> 0 then
          FOBPI := (FOBPI + 1) and $BF;
      end;
  end;
procedure TPPU.Reset;
begin
  FCycles := 0;
end;

procedure TPPU.Step(Cycles: Integer);
begin
  Inc(FCycles, Cycles);
end;

end.
