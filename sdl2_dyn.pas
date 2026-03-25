unit sdl2_dyn;

interface

uses
{$IFDEF MSWINDOWS}
  Winapi.Windows,
{$ELSE}
  {$IFDEF FPC}
  Dynlibs,
  {$ELSE}
  Posix.Dlfcn,
  {$ENDIF}
{$ENDIF}
{$IFDEF FPC}
  SysUtils;
{$ELSE}
  System.SysUtils;
{$ENDIF}

const
  SDL_INIT_VIDEO = $00000020;
  SDL_INIT_AUDIO = $00000010;
  SDL_WINDOWPOS_CENTERED = $2FFF0000;
  SDL_WINDOW_SHOWN = $00000004;
  SDL_RENDERER_ACCELERATED = $00000002;
  SDL_RENDERER_PRESENTVSYNC = $00000004;
  SDL_RENDERER_SOFTWARE = $00000001;
  SDL_TEXTUREACCESS_STREAMING = 1;
  SDL_PIXELFORMAT_ARGB8888 = $16362004;

  SDL_EVENT_QUIT = $100;
  SDL_EVENT_KEYDOWN = $300;
  SDL_EVENT_KEYUP = $301;

  SDLK_RETURN = 13;
  SDLK_ESCAPE = 27;
  SDLK_x = 120;
  SDLK_z = 122;
  SDLK_j = 106;
  SDLK_k = 107;
  SDLK_w = 119;
  SDLK_a = 97;
  SDLK_s = 115;
  SDLK_d = 100;
  AUDIO_S16SYS = $8010;

type
  TSDL_AudioDeviceID = Cardinal;

  PSDL_Window = Pointer;
  PSDL_Renderer = Pointer;
  PSDL_Texture = Pointer;

  TSDL_Rect = record
    X: Integer;
    Y: Integer;
    W: Integer;
    H: Integer;
  end;

  TSDL_Keysym = record
    Scancode: Cardinal;
    Sym: Integer;
    Modif: Word;
    Unused: Cardinal;
  end;

  TSDL_KeyboardEvent = record
    EventType: Cardinal;
    Timestamp: Cardinal;
    WindowID: Cardinal;
    State: Byte;
    Repeat_: Byte;
    Padding2: Byte;
    Padding3: Byte;
    Keysym: TSDL_Keysym;
  end;

  TSDL_Event = packed record
    EventType: Cardinal;
    Data: array[0..55] of Byte;
  end;
  PSDL_Event = ^TSDL_Event;

  TSDL_AudioSpec = record
    Freq: Integer;
    Format: Word;
    Channels: Byte;
    Silence: Byte;
    Samples: Word;
    Padding: Word;
    Size: Cardinal;
    Callback: Pointer;
    UserData: Pointer;
  end;

  TSDL_Init = function(flags: Cardinal): Integer; cdecl;
  TSDL_Quit = procedure; cdecl;
  TSDL_CreateWindow = function(title: PAnsiChar; x, y, w, h, flags: Integer): PSDL_Window; cdecl;
  TSDL_DestroyWindow = procedure(window: PSDL_Window); cdecl;
  TSDL_CreateRenderer = function(window: PSDL_Window; index: Integer; flags: Cardinal): PSDL_Renderer; cdecl;
  TSDL_DestroyRenderer = procedure(renderer: PSDL_Renderer); cdecl;
  TSDL_CreateTexture = function(renderer: PSDL_Renderer; format, access, w, h: Integer): PSDL_Texture; cdecl;
  TSDL_DestroyTexture = procedure(texture: PSDL_Texture); cdecl;
  TSDL_PollEvent = function(event: PSDL_Event): Integer; cdecl;
  TSDL_UpdateTexture = function(texture: PSDL_Texture; rect: Pointer; pixels: Pointer; pitch: Integer): Integer; cdecl;
  TSDL_RenderClear = function(renderer: PSDL_Renderer): Integer; cdecl;
  TSDL_RenderCopy = function(renderer: PSDL_Renderer; texture: PSDL_Texture; srcrect, dstrect: Pointer): Integer; cdecl;
  TSDL_RenderPresent = procedure(renderer: PSDL_Renderer); cdecl;
  TSDL_Delay = procedure(ms: Cardinal); cdecl;
  TSDL_GetTicks = function: Cardinal; cdecl;
  TSDL_GetError = function: PAnsiChar; cdecl;
  TSDL_SetHint = function(name, value: PAnsiChar): Integer; cdecl;
  TSDL_SetWindowTitle = procedure(window: PSDL_Window; title: PAnsiChar); cdecl;
  TSDL_OpenAudioDevice = function(device: PAnsiChar; iscapture: Integer; desired, obtained: Pointer; allowed_changes: Integer): TSDL_AudioDeviceID; cdecl;
  TSDL_CloseAudioDevice = procedure(devid: TSDL_AudioDeviceID); cdecl;
  TSDL_PauseAudioDevice = procedure(devid: TSDL_AudioDeviceID; pause_on: Integer); cdecl;
  TSDL_QueueAudio = function(devid: TSDL_AudioDeviceID; data: Pointer; len: Cardinal): Integer; cdecl;
  TSDL_GetQueuedAudioSize = function(devid: TSDL_AudioDeviceID): Cardinal; cdecl;

var
  SDL_Init: TSDL_Init = nil;
  SDL_Quit: TSDL_Quit = nil;
  SDL_CreateWindow: TSDL_CreateWindow = nil;
  SDL_DestroyWindow: TSDL_DestroyWindow = nil;
  SDL_CreateRenderer: TSDL_CreateRenderer = nil;
  SDL_DestroyRenderer: TSDL_DestroyRenderer = nil;
  SDL_CreateTexture: TSDL_CreateTexture = nil;
  SDL_DestroyTexture: TSDL_DestroyTexture = nil;
  SDL_PollEvent: TSDL_PollEvent = nil;
  SDL_UpdateTexture: TSDL_UpdateTexture = nil;
  SDL_RenderClear: TSDL_RenderClear = nil;
  SDL_RenderCopy: TSDL_RenderCopy = nil;
  SDL_RenderPresent: TSDL_RenderPresent = nil;
  SDL_Delay: TSDL_Delay = nil;
  SDL_GetTicks: TSDL_GetTicks = nil;
  SDL_GetError: TSDL_GetError = nil;
  SDL_SetHint: TSDL_SetHint = nil;
  SDL_SetWindowTitle: TSDL_SetWindowTitle = nil;
  SDL_OpenAudioDevice: TSDL_OpenAudioDevice = nil;
  SDL_CloseAudioDevice: TSDL_CloseAudioDevice = nil;
  SDL_PauseAudioDevice: TSDL_PauseAudioDevice = nil;
  SDL_QueueAudio: TSDL_QueueAudio = nil;
  SDL_GetQueuedAudioSize: TSDL_GetQueuedAudioSize = nil;

function SDL_Load(const ADllName: string = ''): Boolean;
procedure SDL_Unload;
function SDL_ErrorText: string;

implementation

var
  GSDLHandle: Pointer = nil;

function HasSDLHandle: Boolean;
begin
  Result := GSDLHandle <> nil;
end;

function OpenDynLib(const AName: string): Pointer;
{$IFNDEF MSWINDOWS}
{$IFNDEF FPC}
var
  N: UTF8String;
{$ENDIF}
{$ENDIF}
begin
{$IFDEF MSWINDOWS}
  Result := Pointer(LoadLibrary(PChar(AName)));
{$ELSE}
  {$IFDEF FPC}
  Result := Pointer(PtrUInt(LoadLibrary(PChar(AName))));
  {$ELSE}
  N := UTF8String(AName);
  Result := dlopen(PAnsiChar(N), RTLD_NOW);
  {$ENDIF}
{$ENDIF}
end;

procedure CloseDynLib(AHandle: Pointer);
begin
{$IFDEF MSWINDOWS}
  if AHandle <> nil then
    FreeLibrary(HMODULE(AHandle));
{$ELSE}
  if AHandle <> nil then
  begin
    {$IFDEF FPC}
    UnloadLibrary(TLibHandle(PtrUInt(AHandle)));
    {$ELSE}
    dlclose(AHandle);
    {$ENDIF}
  end;
{$ENDIF}
end;

function LoadProc(const AName: AnsiString): Pointer;
begin
{$IFDEF MSWINDOWS}
  Result := GetProcAddress(HMODULE(GSDLHandle), PAnsiChar(AName));
{$ELSE}
  {$IFDEF FPC}
  Result := GetProcAddress(TLibHandle(PtrUInt(GSDLHandle)), PChar(AName));
  {$ELSE}
  Result := dlsym(GSDLHandle, PAnsiChar(AName));
  {$ENDIF}
{$ENDIF}
end;

function TryLoadOne(const ALibName: string): Boolean;
begin
  Result := False;
  GSDLHandle := OpenDynLib(ALibName);
  if GSDLHandle = nil then
    Exit;

  @SDL_Init := LoadProc('SDL_Init');
  @SDL_Quit := LoadProc('SDL_Quit');
  @SDL_CreateWindow := LoadProc('SDL_CreateWindow');
  @SDL_DestroyWindow := LoadProc('SDL_DestroyWindow');
  @SDL_CreateRenderer := LoadProc('SDL_CreateRenderer');
  @SDL_DestroyRenderer := LoadProc('SDL_DestroyRenderer');
  @SDL_CreateTexture := LoadProc('SDL_CreateTexture');
  @SDL_DestroyTexture := LoadProc('SDL_DestroyTexture');
  @SDL_PollEvent := LoadProc('SDL_PollEvent');
  @SDL_UpdateTexture := LoadProc('SDL_UpdateTexture');
  @SDL_RenderClear := LoadProc('SDL_RenderClear');
  @SDL_RenderCopy := LoadProc('SDL_RenderCopy');
  @SDL_RenderPresent := LoadProc('SDL_RenderPresent');
  @SDL_Delay := LoadProc('SDL_Delay');
  @SDL_GetTicks := LoadProc('SDL_GetTicks');
  @SDL_GetError := LoadProc('SDL_GetError');
  @SDL_SetHint := LoadProc('SDL_SetHint');
  @SDL_SetWindowTitle := LoadProc('SDL_SetWindowTitle');
  @SDL_OpenAudioDevice := LoadProc('SDL_OpenAudioDevice');
  @SDL_CloseAudioDevice := LoadProc('SDL_CloseAudioDevice');
  @SDL_PauseAudioDevice := LoadProc('SDL_PauseAudioDevice');
  @SDL_QueueAudio := LoadProc('SDL_QueueAudio');
  @SDL_GetQueuedAudioSize := LoadProc('SDL_GetQueuedAudioSize');

  Result := Assigned(SDL_Init) and Assigned(SDL_Quit) and Assigned(SDL_CreateWindow) and
            Assigned(SDL_DestroyWindow) and Assigned(SDL_CreateRenderer) and
            Assigned(SDL_DestroyRenderer) and Assigned(SDL_CreateTexture) and
            Assigned(SDL_DestroyTexture) and Assigned(SDL_PollEvent) and
            Assigned(SDL_UpdateTexture) and Assigned(SDL_RenderClear) and
            Assigned(SDL_RenderCopy) and Assigned(SDL_RenderPresent) and
            Assigned(SDL_Delay) and Assigned(SDL_GetTicks) and Assigned(SDL_GetError) and
            Assigned(SDL_OpenAudioDevice) and Assigned(SDL_CloseAudioDevice) and
            Assigned(SDL_PauseAudioDevice) and Assigned(SDL_QueueAudio) and
            Assigned(SDL_GetQueuedAudioSize);
  if not Result then
    SDL_Unload;
end;

function SDL_Load(const ADllName: string): Boolean;
var
  Candidates: array[0..7] of string;
  Count, I: Integer;
begin
  Result := False;
  if GSDLHandle <> nil then
    Exit(True);

  if ADllName <> '' then
    Exit(TryLoadOne(ADllName));

  Count := 0;
{$IFDEF MSWINDOWS}
  Candidates[Count] := 'SDL2.dll'; Inc(Count);
{$ENDIF}
{$IFDEF MACOS}
  Candidates[Count] := 'libSDL2-2.0.0.dylib'; Inc(Count);
  Candidates[Count] := 'libSDL2.dylib'; Inc(Count);
{$ENDIF}
{$IFDEF LINUX}
  Candidates[Count] := 'libSDL2-2.0.so.0'; Inc(Count);
  Candidates[Count] := 'libSDL2.so'; Inc(Count);
{$ENDIF}
  { Fallback generic names if platform macro is unavailable at compile time. }
  Candidates[Count] := 'SDL2.dll'; Inc(Count);
  Candidates[Count] := 'libSDL2-2.0.so.0'; Inc(Count);
  Candidates[Count] := 'libSDL2-2.0.0.dylib'; Inc(Count);

  for I := 0 to Count - 1 do
    if TryLoadOne(Candidates[I]) then
      Exit(True);
end;

procedure SDL_Unload;
begin
  @SDL_Init := nil;
  @SDL_Quit := nil;
  @SDL_CreateWindow := nil;
  @SDL_DestroyWindow := nil;
  @SDL_CreateRenderer := nil;
  @SDL_DestroyRenderer := nil;
  @SDL_CreateTexture := nil;
  @SDL_DestroyTexture := nil;
  @SDL_PollEvent := nil;
  @SDL_UpdateTexture := nil;
  @SDL_RenderClear := nil;
  @SDL_RenderCopy := nil;
  @SDL_RenderPresent := nil;
  @SDL_Delay := nil;
  @SDL_GetTicks := nil;
  @SDL_GetError := nil;
  @SDL_SetHint := nil;
  @SDL_SetWindowTitle := nil;
  @SDL_OpenAudioDevice := nil;
  @SDL_CloseAudioDevice := nil;
  @SDL_PauseAudioDevice := nil;
  @SDL_QueueAudio := nil;
  @SDL_GetQueuedAudioSize := nil;
  if HasSDLHandle then
  begin
    CloseDynLib(GSDLHandle);
    GSDLHandle := nil;
  end;
end;

function SDL_ErrorText: string;
var
  P: PAnsiChar;
begin
  if Assigned(SDL_GetError) then
  begin
    P := SDL_GetError;
    if P <> nil then
      Exit(string(AnsiString(P)));
  end;
  Result := 'unknown SDL error';
end;

end.
