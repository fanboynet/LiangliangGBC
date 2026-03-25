unit gb_ppu;
{ 单元定义: 像素处理器（PPU）扫描线渲染与显示时序核心。 }
{ 负责内容: LCD 模式切换、BG/Window/Sprite 合成、LY/STAT/LCDC 寄存器行为、VBlank/STAT 中断请求。 }



{
  Game Boy PPU timing/render core.
  本单元重点:
  - 456 dots/line, 154 lines/frame 的模式机（mode2/3/0 + vblank mode1）。
  - BG/Window/OBJ 合成与优先级规则（DMG 与 CGB 有差异）。
  - STAT 线与中断边沿行为（LYC、mode 中断源）。
  参考: Pan Docs / Rendering / LCD Status Registers / Pixel FIFO 概述。
}

interface

const
  GB_WIDTH = 160;
  GB_HEIGHT = 144;
  { 一个扫描线固定 456 dots（T-cycle 粒度）。 }
  DOTS_PER_SCANLINE = 456;
  CYCLES_PER_DOT = 1; { Use T-cycles directly; CPU Step cycle table is already in T-cycles. }
  CYCLES_PER_SCANLINE = DOTS_PER_SCANLINE * CYCLES_PER_DOT;
  { 可见线 144 + VBlank 10 = 154。 }
  SCANLINES_PER_FRAME = 154;
  CYCLES_PER_FRAME = CYCLES_PER_SCANLINE * SCANLINES_PER_FRAME;

type
  TRequestIrqProc = procedure(IrqBit: Byte) of object;
  TRead8Func = function(Addr: Word): Byte of object;
  TReadVRAMBankedFunc = function(Addr: Word; Bank: Byte): Byte of object;
  TFrameStartProc = procedure of object;
  TBeforeTileProc = procedure(LineY, TileCol: Integer) of object;
  TFramebuffer = array[0..GB_HEIGHT - 1, 0..GB_WIDTH - 1] of Byte;

  TGBPPU = class
  private
    FDotCounter: Cardinal;
    FLY: Byte;
    FMode: Byte;
    FLCDC: Byte;
    FLCDC_Latch: Byte;  { LCDC latched at start of scanline (before mode 2 CPU); used for WIN_EN this line (m2_win_en_toggle). }
    FSTAT: Byte;
    FSCY: Byte;
    FSCX: Byte;
    FLYC: Byte;
    FWy: Byte;
    FWx: Byte;
    FWinLineCounter: Integer;  { Window internal line counter; only increments when window is drawn }
    FOnRequestIrq: TRequestIrqProc;
    FOnRead8: TRead8Func;
    FOnRead8ForDisplay: TRead8Func;
    FOnReadVRAMBanked: TReadVRAMBankedFunc;
    FOnReadVRAMBankedForDisplay: TReadVRAMBankedFunc;
    FOnFrameStart: TFrameStartProc;
    FOnBeforeTile: TBeforeTileProc;
    FOnRunCpuForScanline: TFrameStartProc;  { run CPU for 1824 cycles (VBlank scanlines when we do not render) }
    FVBlankRequested: Boolean;
    FUseDisplayVRAM: Boolean;
    FStatLine: Boolean;
    FMode3Dots: Integer;
    FCGBMode: Boolean;
    FLCDEnableDelay: Integer;
    procedure SetMode(AMode: Byte; RequestEdge: Boolean);
    procedure UpdateStatLine(RequestEdge: Boolean);
    function CalcMode3Dots: Integer;
    procedure RenderScanline(LineY: Integer);
    function ReadVRAM(Addr: Word): Byte;
    function ReadVRAMBanked(Addr: Word; Bank: Byte): Byte;
    function ReadOAM(Offset: Byte): Byte;
    procedure RenderSprites(LineY: Integer);
  public
    FFramebuffer: TFramebuffer;
    FBGColorBuffer: TFramebuffer; { BG/WIN color index before OBJ composition }
    FObjBuffer: TFramebuffer;  { 0=BG/win, 1=OBP0, 2=OBP1 }
    FBGPalBuffer: TFramebuffer; { CGB: BG palette index 0..7 }
    FObjPalBuffer: TFramebuffer; { CGB: OBJ palette index 0..7 }
    FBGPriorityBuffer: TFramebuffer; { CGB: BG attr bit7 at pixel }
    procedure Reset;
    procedure Update(Cycles: Cardinal);
    function Read(Addr: Word): Byte;
    procedure Write(Addr: Word; Value: Byte);
    property OnRequestIrq: TRequestIrqProc read FOnRequestIrq write FOnRequestIrq;
    property OnRead8: TRead8Func read FOnRead8 write FOnRead8;
    property OnRead8ForDisplay: TRead8Func read FOnRead8ForDisplay write FOnRead8ForDisplay;
    property OnReadVRAMBanked: TReadVRAMBankedFunc read FOnReadVRAMBanked write FOnReadVRAMBanked;
    property OnReadVRAMBankedForDisplay: TReadVRAMBankedFunc read FOnReadVRAMBankedForDisplay write FOnReadVRAMBankedForDisplay;
    property OnFrameStart: TFrameStartProc read FOnFrameStart write FOnFrameStart;
    property OnBeforeTile: TBeforeTileProc read FOnBeforeTile write FOnBeforeTile;
    property OnRunCpuForScanline: TFrameStartProc read FOnRunCpuForScanline write FOnRunCpuForScanline;
    property LY: Byte read FLY;
    property Mode: Byte read FMode;
    property LCDC: Byte read FLCDC write FLCDC;
    property CGBMode: Boolean read FCGBMode write FCGBMode;
    function InMode2: Boolean;
    function CurrentOAMRow: Integer;
  end;

implementation

function TGBPPU.ReadVRAM(Addr: Word): Byte;
begin
  { 渲染路径可选读取“显示快照 VRAM”，减少同帧写入造成的抖动差异。 }
  if FUseDisplayVRAM and Assigned(FOnRead8ForDisplay) then
    Result := FOnRead8ForDisplay(Addr)
  else if Assigned(FOnRead8) then
    Result := FOnRead8(Addr)
  else
    Result := $FF;
end;

function TGBPPU.ReadVRAMBanked(Addr: Word; Bank: Byte): Byte;
begin
  { CGB 需要根据属性位读取 bank0/1。 }
  if FUseDisplayVRAM and Assigned(FOnReadVRAMBankedForDisplay) then
    Result := FOnReadVRAMBankedForDisplay(Addr, Bank)
  else if Assigned(FOnReadVRAMBanked) then
    Result := FOnReadVRAMBanked(Addr, Bank)
  else if Bank = 0 then
    Result := ReadVRAM(Addr)
  else
    Result := $FF;
end;

function TGBPPU.ReadOAM(Offset: Byte): Byte;
begin
  { OAM 读取统一走 MMU 回调，以共享访问限制策略。 }
  if Assigned(FOnRead8) then
    Result := FOnRead8($FE00 + Word(Offset))
  else
    Result := $FF;
end;

procedure TGBPPU.RenderScanline(LineY: Integer);
var
  MapBase, WinMapBase: Word;
  SignedTiles: Boolean;
  TileY, TileYInTile: Integer;
  MapRowOffset: Word;
  X, TileCol, Tc: Integer;
  TileIdx: Integer;
  TileAddr: Word;
  Lo, Hi: Byte;
  ColorIdx: Byte;
  WinX: Integer;
  WinMapRowOff: Word;
  Attr: Byte;
  TileBank: Byte;
  PalIdx: Byte;
  XFlip, YFlip: Boolean;
  BitIdx: Integer;
  BGMasterPriority: Boolean;
  TileRow: Word;
begin
  FUseDisplayVRAM := True;
  try
  if (FLCDC and $80) = 0 then
    Exit;
  BGMasterPriority := (FLCDC and $01) <> 0;
  if (not FCGBMode) and (not BGMasterPriority) then
  begin
    for X := 0 to GB_WIDTH - 1 do
    begin
      FFramebuffer[LineY, X] := 0;
      FBGColorBuffer[LineY, X] := 0;
      FObjBuffer[LineY, X] := 0;
      FBGPalBuffer[LineY, X] := 0;
      FObjPalBuffer[LineY, X] := 0;
      FBGPriorityBuffer[LineY, X] := 0;
    end;
    Exit;
  end;
  { Run CPU for mode 2 (OAM scan, 80 dots = 320 cycles) so LYC/STAT/LCDC changes take effect before we draw. }
  if Assigned(FOnBeforeTile) then
    FOnBeforeTile(LineY, -1);
  { BG: draw in 20 tiles so we can run CPU and re-read registers before each tile (mode 3 timing). }
  for Tc := 0 to 19 do
  begin
    if Assigned(FOnBeforeTile) then
      FOnBeforeTile(LineY, Tc);
    if FLCDC and 8 <> 0 then
      MapBase := $9C00
    else
      MapBase := $9800;
    if FLCDC and 16 <> 0 then
      SignedTiles := False
    else
      SignedTiles := True;
    TileY := (LineY + FSCY) and $FF;
    TileYInTile := TileY and 7;
    MapRowOffset := ((TileY shr 3) and 31) * 32;
    for X := Tc * 8 to Tc * 8 + 7 do
    begin
      TileCol := (X + FSCX) and $FF;
      TileIdx := ReadVRAM(MapBase + MapRowOffset + (TileCol shr 3));
      if FCGBMode then
      begin
        Attr := ReadVRAMBanked(MapBase + MapRowOffset + (TileCol shr 3), 1);
        TileBank := (Attr shr 3) and 1;
        PalIdx := Attr and 7;
        XFlip := (Attr and $20) <> 0;
        YFlip := (Attr and $40) <> 0;
      end
      else
      begin
        Attr := 0;
        TileBank := 0;
        PalIdx := 0;
        XFlip := False;
        YFlip := False;
      end;
      if SignedTiles then
        TileIdx := ShortInt(Byte(TileIdx));
      { LCDC bit4=0 时使用“有符号 tile 编号”寻址到 $8800 区。 }
      if SignedTiles then
        TileAddr := $8800 + Word((TileIdx + 128) and $FF) * 16
      else
        TileAddr := $8000 + Word(TileIdx and $FF) * 16;
      if YFlip then
        TileRow := (7 - TileYInTile) * 2
      else
        TileRow := TileYInTile * 2;
      Lo := ReadVRAMBanked(TileAddr + TileRow, TileBank);
      Hi := ReadVRAMBanked(TileAddr + TileRow + 1, TileBank);
      if XFlip then
        BitIdx := (TileCol and 7)
      else
        BitIdx := 7 - (TileCol and 7);
      ColorIdx := (((Hi shr BitIdx) and 1) shl 1) or ((Lo shr BitIdx) and 1);
      FBGColorBuffer[LineY, X] := ColorIdx;
      FFramebuffer[LineY, X] := ColorIdx;
      FBGPalBuffer[LineY, X] := PalIdx;
      FBGPriorityBuffer[LineY, X] := (Attr shr 7) and 1;
    end;
  end;
  { Window layer: WIN_EN (bit 5) sampled at start of mode 3 (after 320 cycles); toggling during mode 2 affects this scanline. }
  if (FLCDC and $20) <> 0 then
  begin
    if ((FCGBMode or ((FLCDC and $01) <> 0)) and (LineY >= FWy) and (FWx <= 166)) then
    begin
      if FLCDC and $40 <> 0 then
        WinMapBase := $9C00
      else
        WinMapBase := $9800;
      WinMapRowOff := ((FWinLineCounter shr 3) and 31) * 32;
      for X := 0 to GB_WIDTH - 1 do
      begin
        if X < FWx - 7 then
          Continue;
        WinX := X - (FWx - 7);
        TileIdx := ReadVRAM(WinMapBase + WinMapRowOff + (WinX shr 3));
        if FCGBMode then
        begin
          Attr := ReadVRAMBanked(WinMapBase + WinMapRowOff + (WinX shr 3), 1);
          TileBank := (Attr shr 3) and 1;
          PalIdx := Attr and 7;
          XFlip := (Attr and $20) <> 0;
          YFlip := (Attr and $40) <> 0;
        end
        else
        begin
          Attr := 0;
          TileBank := 0;
          PalIdx := 0;
          XFlip := False;
          YFlip := False;
        end;
        if SignedTiles then
          TileIdx := ShortInt(Byte(TileIdx));
        { Window 与 BG 共用 tile addressing 规则。 }
        if SignedTiles then
          TileAddr := $8800 + Word((TileIdx + 128) and $FF) * 16
        else
          TileAddr := $8000 + Word(TileIdx and $FF) * 16;
        if YFlip then
          TileRow := (7 - (FWinLineCounter and 7)) * 2
        else
          TileRow := (FWinLineCounter and 7) * 2;
        Lo := ReadVRAMBanked(TileAddr + TileRow, TileBank);
        Hi := ReadVRAMBanked(TileAddr + TileRow + 1, TileBank);
        if XFlip then
          BitIdx := (WinX and 7)
        else
          BitIdx := 7 - (WinX and 7);
        ColorIdx := (((Hi shr BitIdx) and 1) shl 1) or
                    ((Lo shr BitIdx) and 1);
        FBGColorBuffer[LineY, X] := ColorIdx;
        FFramebuffer[LineY, X] := ColorIdx;
        FBGPalBuffer[LineY, X] := PalIdx;
        FBGPriorityBuffer[LineY, X] := (Attr shr 7) and 1;
      end;
      Inc(FWinLineCounter);
    end;
  end;
  { Sprites (DMG: 8x8 or 8x16, max 10 per scanline, priority by X then OAM index) }
  if (FLCDC and $02) <> 0 then
    RenderSprites(LineY);
  finally
    FUseDisplayVRAM := False;
  end;
end;

procedure TGBPPU.RenderSprites(LineY: Integer);
const
  MAX_SPRITES_PER_LINE = 10;
type
  TSpriteInfo = record
    X, TileRow, TileIdx: Integer;
    Flags: Byte;
    OAMIdx: Integer;
  end;
var
  SpriteHeight: Integer;
  Sprites: array[0..MAX_SPRITES_PER_LINE - 1] of TSpriteInfo;
  NumSprites: Integer;
  i, n: Integer;
  OY, OX, Tile, Flags: Byte;
  ScreenY, ScreenX: Integer;
  Tmp: TSpriteInfo;
  X, S: Integer;
  Lo, Hi: Byte;
  ColorIdx: Byte;
  LocalX, BitIdx: Integer;
  BGOverObj: Boolean;
  BGMasterPriority: Boolean;
  BgColor: Byte;
begin
  BGMasterPriority := (FLCDC and $01) <> 0;
  if (FLCDC and $04) <> 0 then
    SpriteHeight := 16
  else
    SpriteHeight := 8;
  NumSprites := 0;
  for i := 0 to 39 do
  begin
    if NumSprites >= MAX_SPRITES_PER_LINE then
      Break;
    OY := ReadOAM(Byte(i * 4 + 0));
    OX := ReadOAM(Byte(i * 4 + 1));
    Tile := ReadOAM(Byte(i * 4 + 2));
    Flags := ReadOAM(Byte(i * 4 + 3));
    ScreenY := Integer(OY) - 16;
    ScreenX := Integer(OX) - 8;
    if (OY >= 160) or (OX = 0) or (OX >= 168) then
      Continue;
    if (LineY < ScreenY) or (LineY >= ScreenY + SpriteHeight) then
      Continue;
    Sprites[NumSprites].X := ScreenX;
    Sprites[NumSprites].Flags := Flags;
    Sprites[NumSprites].OAMIdx := i;
    if (Flags and $40) <> 0 then
      Sprites[NumSprites].TileRow := SpriteHeight - 1 - (LineY - ScreenY)
    else
      Sprites[NumSprites].TileRow := LineY - ScreenY;
    if SpriteHeight = 8 then
      Sprites[NumSprites].TileIdx := Tile and $FF
    else
    begin
      if Sprites[NumSprites].TileRow < 8 then
        Sprites[NumSprites].TileIdx := (Tile and $FE) and $FF
      else
        Sprites[NumSprites].TileIdx := ((Tile and $FE) or 1) and $FF;
    end;
    Inc(NumSprites);
  end;
  { Sort by X ascending, then by OAM index ascending (DMG priority) }
  if not FCGBMode then
    for i := 0 to NumSprites - 2 do
      for n := i + 1 to NumSprites - 1 do
        if (Sprites[n].X < Sprites[i].X) or
           ((Sprites[n].X = Sprites[i].X) and (Sprites[n].OAMIdx < Sprites[i].OAMIdx)) then
        begin
          Tmp := Sprites[i];
          Sprites[i] := Sprites[n];
          Sprites[n] := Tmp;
        end;
  for X := 0 to GB_WIDTH - 1 do
    FObjBuffer[LineY, X] := 0;
  { Draw sprites in reverse order so higher-priority (lower X, lower OAM idx) is drawn on top. }
  for S := NumSprites - 1 downto 0 do
  begin
    ScreenX := Sprites[S].X;
    if ScreenX + 8 <= 0 then
      Continue;
    if ScreenX >= GB_WIDTH then
      Continue;
    Lo := ReadVRAMBanked($8000 + Word(Sprites[S].TileIdx) * 16 + Byte(Sprites[S].TileRow and 7) * 2,
      Byte((Sprites[S].Flags shr 3) and 1));
    Hi := ReadVRAMBanked($8000 + Word(Sprites[S].TileIdx) * 16 + Byte(Sprites[S].TileRow and 7) * 2 + 1,
      Byte((Sprites[S].Flags shr 3) and 1));
    for X := 0 to GB_WIDTH - 1 do
    begin
      if (X < ScreenX) or (X >= ScreenX + 8) then
        Continue;
      LocalX := X - ScreenX;
      if (Sprites[S].Flags and $20) <> 0 then
        BitIdx := LocalX      { X flip: screen left = tile right (bit 0) }
      else
        BitIdx := 7 - LocalX; { normal: screen left = tile left (bit 7) }
      ColorIdx := (((Hi shr BitIdx) and 1) shl 1) or ((Lo shr BitIdx) and 1);
      { OBJ color 0 恒透明，不覆盖背景。 }
      if ColorIdx = 0 then
        Continue;
      if FCGBMode then
      begin
        { CGB: 同时受 OBJ 优先位、BG 主开关与 BG attr 优先位影响。 }
        BgColor := FBGColorBuffer[LineY, X] and 3;
        if BGMasterPriority then
          BGOverObj :=
            (((Sprites[S].Flags and $80) <> 0) and (BgColor <> 0)) or
            ((FBGPriorityBuffer[LineY, X] <> 0) and (BgColor <> 0))
        else
          BGOverObj := False;
      end
      else
      begin
        BgColor := FBGColorBuffer[LineY, X] and 3;
        BGOverObj := ((Sprites[S].Flags and $80) <> 0) and (BgColor <> 0);
      end;
      if BGOverObj then
        Continue;
      FFramebuffer[LineY, X] := ColorIdx;
      if FCGBMode then
      begin
        FObjBuffer[LineY, X] := 1;
        FObjPalBuffer[LineY, X] := Sprites[S].Flags and 7;
      end
      else
      begin
        FObjBuffer[LineY, X] := 1 + ((Sprites[S].Flags shr 4) and 1);
        FObjPalBuffer[LineY, X] := 0;
      end;
    end;
  end;
end;

procedure TGBPPU.Reset;
var
  Y, X: Integer;
begin
  { 采用“无 boot ROM”常见初值，保持测试 ROM 上电后可预测。 }
  FDotCounter := 0;
  FLY := 0;
  FMode := 2;
  FLCDC := $91;
  FLCDC_Latch := $91;
  FSTAT := 2;
  FSCY := 0;
  FSCX := 0;
  FLYC := 0;
  FWy := 0;
  FWx := 0;
  FWinLineCounter := 0;
  FVBlankRequested := False;
  FStatLine := False;
  FMode3Dots := 172;
  FLCDEnableDelay := 0;
  for Y := 0 to GB_HEIGHT - 1 do
    for X := 0 to GB_WIDTH - 1 do
    begin
      FFramebuffer[Y, X] := 0;
      FBGColorBuffer[Y, X] := 0;
      FObjBuffer[Y, X] := 0;
      FBGPalBuffer[Y, X] := 0;
      FObjPalBuffer[Y, X] := 0;
      FBGPriorityBuffer[Y, X] := 0;
    end;
  UpdateStatLine(False);
end;

function TGBPPU.CalcMode3Dots: Integer;
begin
  { Baseline mode 3 is 172 dots on DMG. Add common penalties from scroll and window start. }
  Result := 172 + (FSCX and 7);
  if ((FLCDC_Latch and $20) <> 0) and (FLY >= FWy) and (FWx <= 166) then
    Inc(Result, 6);
  if Result < 172 then
    Result := 172;
  if Result > (DOTS_PER_SCANLINE - 80) then
    Result := DOTS_PER_SCANLINE - 80;
end;

procedure TGBPPU.SetMode(AMode: Byte; RequestEdge: Boolean);
begin
  { mode 仅 0..3，低两位写回 STAT[1:0]。 }
  if FMode <> (AMode and 3) then
  begin
    FMode := AMode and 3;
    FSTAT := (FSTAT and $FC) or FMode;
    UpdateStatLine(RequestEdge);
  end;
end;

procedure TGBPPU.UpdateStatLine(RequestEdge: Boolean);
var
  Coincidence: Boolean;
  NewStatLine: Boolean;
begin
  { STAT 中断并非“电平持续触发”，而是 STAT 条件线的上升沿触发一次 IRQ。 }
  Coincidence := (FLY = FLYC);
  if Coincidence then
    FSTAT := FSTAT or $04
  else
    FSTAT := FSTAT and (not $04);

  NewStatLine :=
    (((FSTAT and $40) <> 0) and Coincidence) or
    (((FSTAT and $20) <> 0) and (FMode = 2)) or
    (((FSTAT and $10) <> 0) and (FMode = 1)) or
    (((FSTAT and $08) <> 0) and (FMode = 0));

  if RequestEdge and NewStatLine and (not FStatLine) then
    if Assigned(FOnRequestIrq) then
      FOnRequestIrq(1);
  FStatLine := NewStatLine;
end;

procedure TGBPPU.Update(Cycles: Cardinal);
var
  LcdOn: Boolean;
  LineStep, OldCycles, NewCycles: Cardinal;
  DelayStep: Cardinal;
begin
  { 按 T-cycle 推进 PPU 模式机。 }
  LcdOn := (FLCDC and $80) <> 0;
  if not LcdOn then
  begin
    { LCD 关闭时 LY=0，模式视作 HBlank（mode0）。 }
    FDotCounter := 0;
    FLY := 0;
    SetMode(0, True);
    Exit;
  end;

  while Cycles > 0 do
  begin
    if FLCDEnableDelay > 0 then
    begin
      DelayStep := Cardinal(FLCDEnableDelay);
      if DelayStep > Cycles then
        DelayStep := Cycles;
      Dec(FLCDEnableDelay, Integer(DelayStep));
      Dec(Cycles, DelayStep);
      Continue;
    end;

    LineStep := CYCLES_PER_SCANLINE - FDotCounter;
    if LineStep > Cycles then
      LineStep := Cycles;

    OldCycles := FDotCounter;
    NewCycles := FDotCounter + LineStep;

    if FLY < 144 then
    begin
      if (OldCycles < (80 * CYCLES_PER_DOT)) and (NewCycles >= (80 * CYCLES_PER_DOT)) then
      begin
        { mode2->mode3: 进入像素传输。 }
        FMode3Dots := CalcMode3Dots;
        SetMode(3, True);
      end;
      if (OldCycles < Cardinal((80 + FMode3Dots) * CYCLES_PER_DOT)) and
         (NewCycles >= Cardinal((80 + FMode3Dots) * CYCLES_PER_DOT)) then
      begin
        { mode3->mode0: 扫描线像素完成，进入 HBlank 并提交本行。 }
        SetMode(0, True);
        RenderScanline(FLY);
      end;
    end;

    FDotCounter := NewCycles;
    Dec(Cycles, LineStep);

    if FDotCounter >= CYCLES_PER_SCANLINE then
    begin
      FDotCounter := 0;
      Inc(FLY);

      if FLY = 144 then
      begin
        { 进入 VBlank（mode1）并请求 VBlank IRQ(bit0)。 }
        SetMode(1, True);
        if not FVBlankRequested then
        begin
          FVBlankRequested := True;
          if Assigned(FOnRequestIrq) then
            FOnRequestIrq(0);
        end;
      end
      else if FLY >= SCANLINES_PER_FRAME then
      begin
        { 一帧结束，回到第 0 行并触发 OnFrameStart。 }
        FLY := 0;
        FWinLineCounter := 0;
        FVBlankRequested := False;
        SetMode(2, True);
        if Assigned(FOnFrameStart) then
          FOnFrameStart;
      end
      else if FLY < 144 then
      begin
        FLCDC_Latch := FLCDC;
        SetMode(2, True);
      end
      else
        SetMode(1, True);

      if (FLY >= 144) and Assigned(FOnRunCpuForScanline) then
        FOnRunCpuForScanline;
    end;
  end;
end;

function TGBPPU.Read(Addr: Word): Byte;
begin
  { PPU I/O 寄存器读（FF40..FF4B）。 }
  Addr := Addr and $FFFF;
  case Addr of
    $FF40: Result := FLCDC;
    $FF41: Result := FSTAT or $80;
    $FF42: Result := FSCY;
    $FF43: Result := FSCX;
    $FF44: Result := FLY;
    $FF45: Result := FLYC;
    $FF4A: Result := FWy;
    $FF4B: Result := FWx;
  else
    Result := $FF;
  end;
end;

procedure TGBPPU.Write(Addr: Word; Value: Byte);
begin
  { PPU I/O 寄存器写。重点处理 LCD 开关边沿。 }
  Addr := Addr and $FFFF;
  case Addr of
    $FF40:
      begin
        { LCD off->on 与 on->off 都会重置部分内部时序计数。 }
        if ((Value and $80) <> 0) and ((FLCDC and $80) = 0) then
        begin
          FDotCounter := 4; { LCD-on alignment: start one M-cycle into line 0 }
          FLY := 0;
          FVBlankRequested := False;
          SetMode(2, True);
          FLCDEnableDelay := 0;
        end
        else if ((Value and $80) = 0) and ((FLCDC and $80) <> 0) then
        begin
          FDotCounter := 0;
          FLY := 0;
          FVBlankRequested := False;
          SetMode(0, True);
          FLCDEnableDelay := 0;
        end;
        FLCDC := Value;
        UpdateStatLine(True);
      end;
    $FF41:
      begin
        FSTAT := (Value and $78) or (FSTAT and $87);
        UpdateStatLine(True);
      end;
    $FF42: FSCY := Value;
    $FF43: FSCX := Value;
    $FF44: ; { LY read-only }
    $FF45:
      begin
        FLYC := Value;
        UpdateStatLine(True);
      end;
    $FF4A: FWy := Value;
    $FF4B: FWx := Value;
  end;
end;

function TGBPPU.InMode2: Boolean;
begin
  { mode2 判定给 MMU/OAM bug 模型使用。 }
  Result := ((FLCDC and $80) <> 0) and
            (FLY < 144) and
            (FDotCounter < (80 * CYCLES_PER_DOT));
end;

function TGBPPU.CurrentOAMRow: Integer;
begin
  { mode2 每 4 dots 扫过 1 个 OAM row（共 20 个）。 }
  if InMode2 then
    Result := Integer((FDotCounter + (4 * CYCLES_PER_DOT)) div (4 * CYCLES_PER_DOT))
  else
    Result := -1;
  if Result > 19 then
    Result := -1;
end;

end.
