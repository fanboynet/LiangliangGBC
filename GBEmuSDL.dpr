program GBEmuSDL;

{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  gb_core in 'gb_core.pas',
  sdl2_dyn in 'sdl2_dyn.pas';

const
  GB_WIDTH = 160;
  GB_HEIGHT = 144;
  SCALE = 2;

type
  TSDLApp = class
  private
    FCore: TGBCore;
    FWindow: PSDL_Window;
    FRenderer: PSDL_Renderer;
    FTexture: PSDL_Texture;
    FRunning: Boolean;
    FButtons: Byte;
    FDirections: Byte;
    FAccumMs: Double;
    FLastTicks: Cardinal;
    FFrameCount: Cardinal;
    FAudioDevice: TSDL_AudioDeviceID;
    FAudioBuffer: array of SmallInt;
    FAudioCount: Integer;
    FStatLastTicks: Cardinal;
    FStatEmuFrames: Cardinal;
    FStatRenderFrames: Cardinal;
    FPixels: array[0..GB_WIDTH * GB_HEIGHT - 1] of Cardinal;
    FDestRect: TSDL_Rect;
    procedure OnSerialByte(AByte: Byte);
    procedure OnAudioSample(ALeft, ARight: SmallInt);
    procedure SetKey(AKey: Integer; APressed: Boolean);
    procedure PumpEvents;
    procedure FlushAudio;
    procedure UpdateStats(ANowTicks: Cardinal);
    procedure BuildFrame;
    procedure Present;
  public
    constructor Create;
    destructor Destroy; override;
    function Init(const ARomPath: string): Boolean;
    procedure Run;
  end;

constructor TSDLApp.Create;
begin
  inherited Create;
  FCore := TGBCore.Create;
  FCore.OnSerialByte := OnSerialByte;
  FCore.ScheduleMode := smNormal;
  FWindow := nil;
  FRenderer := nil;
  FTexture := nil;
  FRunning := False;
  FButtons := $0F;
  FDirections := $0F;
  FAccumMs := 0.0;
  FLastTicks := 0;
  FFrameCount := 0;
  FAudioDevice := 0;
  FAudioCount := 0;
  SetLength(FAudioBuffer, 48000 * 2); { ~1 second stereo buffer }
  FStatLastTicks := 0;
  FStatEmuFrames := 0;
  FStatRenderFrames := 0;
  FDestRect.X := 0;
  FDestRect.Y := 0;
  FDestRect.W := GB_WIDTH * SCALE;
  FDestRect.H := GB_HEIGHT * SCALE;
end;

destructor TSDLApp.Destroy;
begin
  if (FAudioDevice <> 0) and Assigned(SDL_CloseAudioDevice) then
    SDL_CloseAudioDevice(FAudioDevice);
  if FTexture <> nil then
    SDL_DestroyTexture(FTexture);
  if FRenderer <> nil then
    SDL_DestroyRenderer(FRenderer);
  if FWindow <> nil then
    SDL_DestroyWindow(FWindow);
  if Assigned(SDL_Quit) then
    SDL_Quit;
  SDL_Unload;
  FCore.Free;
  inherited;
end;

procedure TSDLApp.OnSerialByte(AByte: Byte);
begin
  if AByte = 13 then
    Exit;
  if AByte = 10 then
    WriteLn
  else if (AByte >= 32) and (AByte < 127) then
    Write(Char(AByte))
  else
    Write('[', AByte, ']');
end;

procedure TSDLApp.OnAudioSample(ALeft, ARight: SmallInt);
begin
  if FAudioCount + 2 > Length(FAudioBuffer) then
    Exit;
  FAudioBuffer[FAudioCount] := ALeft;
  Inc(FAudioCount);
  FAudioBuffer[FAudioCount] := ARight;
  Inc(FAudioCount);
end;

procedure TSDLApp.FlushAudio;
const
  MAX_QUEUED = 48000 * 4; { bytes, about 0.5s stereo s16 }
var
  Queued: Cardinal;
  Bytes: Cardinal;
begin
  if (FAudioDevice = 0) or (FAudioCount <= 0) then
    Exit;
  Queued := SDL_GetQueuedAudioSize(FAudioDevice);
  if Queued > MAX_QUEUED then
  begin
    FAudioCount := 0;
    Exit;
  end;
  Bytes := Cardinal(FAudioCount * SizeOf(SmallInt));
  if SDL_QueueAudio(FAudioDevice, @FAudioBuffer[0], Bytes) <> 0 then
  begin
    WriteLn('SDL_QueueAudio failed: ', SDL_ErrorText);
    FAudioCount := 0;
    Exit;
  end;
  FAudioCount := 0;
end;

procedure TSDLApp.SetKey(AKey: Integer; APressed: Boolean);
  procedure SetBit(var B: Byte; Mask: Byte);
  begin
    if APressed then
      B := B and (not Mask)
    else
      B := B or Mask;
  end;
begin
  case AKey of
    SDLK_w: SetBit(FDirections, $04); { Up }
    SDLK_a: SetBit(FDirections, $02); { Left }
    SDLK_s: SetBit(FDirections, $08); { Down }
    SDLK_d: SetBit(FDirections, $01); { Right }
    SDLK_j: SetBit(FButtons, $01);    { A }
    SDLK_k: SetBit(FButtons, $02);    { B }
    SDLK_z: SetBit(FButtons, $04);    { Select }
    SDLK_x, SDLK_RETURN: SetBit(FButtons, $08); { Start }
  end;
  FCore.SetJoypadState(FButtons, FDirections);
end;

procedure TSDLApp.PumpEvents;
var
  Ev: TSDL_Event;
  Kb: ^TSDL_KeyboardEvent;
begin
  while SDL_PollEvent(@Ev) <> 0 do
  begin
    case Ev.EventType of
      SDL_EVENT_QUIT:
        FRunning := False;
      SDL_EVENT_KEYDOWN:
        begin
          Kb := Pointer(@Ev);
          if Kb^.Keysym.Sym = SDLK_ESCAPE then
            FRunning := False
          else
            SetKey(Kb^.Keysym.Sym, True);
        end;
      SDL_EVENT_KEYUP:
        begin
          Kb := Pointer(@Ev);
          SetKey(Kb^.Keysym.Sym, False);
        end;
    end;
  end;
end;

procedure TSDLApp.BuildFrame;
var
  BGP, OBP0, OBP1: Byte;
  Pal: array[0..3] of Byte;
  X, Y, I: Integer;
  Idx, Obj: Byte;
  G: Byte;
  AllSame: Boolean;
  FirstIdx: Byte;
  Color15: Word;
  R5, G5, B5: Byte;
  CgbPal: Byte;
  IsObj: Boolean;
begin
  BGP := FCore.Mmu.BGP;
  OBP0 := FCore.Mmu.OBP0;
  OBP1 := FCore.Mmu.OBP1;

  AllSame := True;
  FirstIdx := FCore.Mmu.PPU.FFramebuffer[0, 0] and 3;
  for Y := 0 to GB_HEIGHT - 1 do
    for X := 0 to GB_WIDTH - 1 do
      if (FCore.Mmu.PPU.FFramebuffer[Y, X] and 3) <> FirstIdx then
        AllSame := False;

  I := 0;
  for Y := 0 to GB_HEIGHT - 1 do
  begin
    for X := 0 to GB_WIDTH - 1 do
    begin
      if AllSame and (FFrameCount > 60) then
        Idx := Byte(((X shr 2) + (Y shr 2)) and 1) * 2
      else
        Idx := FCore.Mmu.PPU.FFramebuffer[Y, X] and 3;
      Obj := FCore.Mmu.PPU.FObjBuffer[Y, X];
      if FCore.Mmu.IsCGBMode then
      begin
        IsObj := Obj <> 0;
        if IsObj then
          CgbPal := FCore.Mmu.PPU.FObjPalBuffer[Y, X] and 7
        else
          CgbPal := FCore.Mmu.PPU.FBGPalBuffer[Y, X] and 7;
        Color15 := FCore.Mmu.ReadCGBPaletteColor(IsObj, CgbPal, Idx and 3);
        R5 := Byte(Color15 and $1F);
        G5 := Byte((Color15 shr 5) and $1F);
        B5 := Byte((Color15 shr 10) and $1F);
        FPixels[I] := $FF000000 or
          (Cardinal((R5 shl 3) or (R5 shr 2)) shl 16) or
          (Cardinal((G5 shl 3) or (G5 shr 2)) shl 8) or
          Cardinal((B5 shl 3) or (B5 shr 2));
        Inc(I);
        Continue;
      end;
      if Obj = 1 then
      begin
        Pal[0] := 255 - (OBP0 and 3) * 85;
        Pal[1] := 255 - ((OBP0 shr 2) and 3) * 85;
        Pal[2] := 255 - ((OBP0 shr 4) and 3) * 85;
        Pal[3] := 255 - ((OBP0 shr 6) and 3) * 85;
      end
      else if Obj = 2 then
      begin
        Pal[0] := 255 - (OBP1 and 3) * 85;
        Pal[1] := 255 - ((OBP1 shr 2) and 3) * 85;
        Pal[2] := 255 - ((OBP1 shr 4) and 3) * 85;
        Pal[3] := 255 - ((OBP1 shr 6) and 3) * 85;
      end
      else
      begin
        Pal[0] := 255 - (BGP and 3) * 85;
        Pal[1] := 255 - ((BGP shr 2) and 3) * 85;
        Pal[2] := 255 - ((BGP shr 4) and 3) * 85;
        Pal[3] := 255 - ((BGP shr 6) and 3) * 85;
      end;
      G := Pal[Idx];
      FPixels[I] := $FF000000 or (Cardinal(G) shl 16) or (Cardinal(G) shl 8) or Cardinal(G);
      Inc(I);
    end;
  end;
end;

procedure TSDLApp.Present;
begin
  BuildFrame;
  SDL_UpdateTexture(FTexture, nil, @FPixels[0], GB_WIDTH * SizeOf(Cardinal));
  SDL_RenderClear(FRenderer);
  SDL_RenderCopy(FRenderer, FTexture, nil, @FDestRect);
  SDL_RenderPresent(FRenderer);
  Inc(FStatRenderFrames);
end;

procedure TSDLApp.UpdateStats(ANowTicks: Cardinal);
const
  TARGET_FPS = 59.7275;
var
  DtMs: Cardinal;
  EmuFps, RenderFps, SpeedPct: Double;
  Title: AnsiString;
begin
  if FStatLastTicks = 0 then
  begin
    FStatLastTicks := ANowTicks;
    Exit;
  end;
  DtMs := ANowTicks - FStatLastTicks;
  if DtMs < 1000 then
    Exit;

  EmuFps := (FStatEmuFrames * 1000.0) / DtMs;
  RenderFps := (FStatRenderFrames * 1000.0) / DtMs;
  if TARGET_FPS > 0 then
    SpeedPct := (EmuFps / TARGET_FPS) * 100.0
  else
    SpeedPct := 0.0;

  if Assigned(SDL_SetWindowTitle) and (FWindow <> nil) then
  begin
    Title := AnsiString(Format('GBEmu SDL | Emu %.2f FPS | Render %.2f FPS | Speed %.1f%%',
      [EmuFps, RenderFps, SpeedPct]));
    SDL_SetWindowTitle(FWindow, PAnsiChar(Title));
  end;

  FStatLastTicks := ANowTicks;
  FStatEmuFrames := 0;
  FStatRenderFrames := 0;
end;

function TSDLApp.Init(const ARomPath: string): Boolean;
var
  Desired: TSDL_AudioSpec;
begin
  Result := False;
  if not SDL_Load then
  begin
    WriteLn('Failed to load SDL2.dll. Put SDL2.dll next to GBEmuSDL.exe or in PATH.');
    Exit;
  end;

  if SDL_Init(SDL_INIT_VIDEO or SDL_INIT_AUDIO) <> 0 then
  begin
    WriteLn('SDL_Init failed: ', SDL_ErrorText);
    Exit;
  end;

  if Assigned(SDL_SetHint) then
    SDL_SetHint('SDL_RENDER_SCALE_QUALITY', '0');

  FWindow := SDL_CreateWindow('GBEmu SDL', SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
    GB_WIDTH * SCALE, GB_HEIGHT * SCALE, SDL_WINDOW_SHOWN);
  if FWindow = nil then
  begin
    WriteLn('SDL_CreateWindow failed: ', SDL_ErrorText);
    Exit;
  end;

  FRenderer := SDL_CreateRenderer(FWindow, -1, SDL_RENDERER_ACCELERATED or SDL_RENDERER_PRESENTVSYNC);
  if FRenderer = nil then
    FRenderer := SDL_CreateRenderer(FWindow, -1, SDL_RENDERER_ACCELERATED);
  if FRenderer = nil then
    FRenderer := SDL_CreateRenderer(FWindow, -1, SDL_RENDERER_SOFTWARE);
  if FRenderer = nil then
  begin
    WriteLn('SDL_CreateRenderer failed: ', SDL_ErrorText);
    Exit;
  end;

  FTexture := SDL_CreateTexture(FRenderer, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STREAMING,
    GB_WIDTH, GB_HEIGHT);
  if FTexture = nil then
  begin
    WriteLn('SDL_CreateTexture failed: ', SDL_ErrorText);
    Exit;
  end;

  FCore.LoadROM(ARomPath);
  FillChar(Desired, SizeOf(Desired), 0);
  Desired.Freq := 48000;
  Desired.Format := AUDIO_S16SYS;
  Desired.Channels := 2;
  Desired.Samples := 1024;
  FAudioDevice := SDL_OpenAudioDevice(nil, 0, @Desired, nil, 0);
  if FAudioDevice = 0 then
  begin
    WriteLn('SDL_OpenAudioDevice failed: ', SDL_ErrorText);
    Exit;
  end;
  FCore.Mmu.APU.SampleRate := Desired.Freq;
  FCore.Mmu.APU.OnSample := OnAudioSample;
  SDL_PauseAudioDevice(FAudioDevice, 0);

  FCore.SetJoypadState(FButtons, FDirections);
  FLastTicks := SDL_GetTicks;
  FStatLastTicks := FLastTicks;
  Result := True;
end;

procedure TSDLApp.Run;
const
  FRAME_MS: Double = 1000.0 / 59.7275;
var
  NowTicks, DeltaTicks: Cardinal;
  WaitMs: Integer;
begin
  FRunning := True;
  while FRunning do
  begin
    PumpEvents;

    NowTicks := SDL_GetTicks;
    DeltaTicks := NowTicks - FLastTicks;
    FLastTicks := NowTicks;
    FAccumMs := FAccumMs + DeltaTicks;
    if FAccumMs > 250.0 then
      FAccumMs := 250.0;

    while FAccumMs >= FRAME_MS do
    begin
      FCore.RunFrame;
      Inc(FFrameCount);
      Inc(FStatEmuFrames);
      FAccumMs := FAccumMs - FRAME_MS;
    end;

    FlushAudio;
    Present;
    NowTicks := SDL_GetTicks;
    UpdateStats(NowTicks);

    { Full-speed cap: avoid running faster than real GB speed. }
    WaitMs := Trunc(FRAME_MS - FAccumMs);
    if WaitMs > 1 then
      SDL_Delay(Cardinal(WaitMs - 1))
    else
      SDL_Delay(1);
  end;
end;

var
  App: TSDLApp;
  RomPath: string;
begin
  if ParamCount < 1 then
  begin
    WriteLn('Usage: GBEmuSDL <rom.gb>');
    Halt(1);
  end;

  RomPath := ParamStr(1);
  if not FileExists(RomPath) then
  begin
    WriteLn('ROM not found: ', RomPath);
    Halt(1);
  end;

  App := TSDLApp.Create;
  try
    if not App.Init(RomPath) then
      Halt(2);
    App.Run;
  finally
    App.Free;
  end;
end.
