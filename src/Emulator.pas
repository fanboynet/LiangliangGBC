unit Emulator;

interface

uses
  System.SysUtils,
  Common,
  CPU,
  Memory,
  PPU,
  APU,
  Cartridge,
  Joypad;
  Cartridge;

type
  TGBEmulator = class
  private
    FCPU: TCPU;
    FMemory: TMemory;
    FPPU: TPPU;
    FAPU: TAPU;
    FCartridge: TCartridge;
    FJoypad: TJoypad;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Reset;
    function LoadCartridge(const FileName: string): Boolean;
    procedure Step;
    procedure RunFrame;
    property Joypad: TJoypad read FJoypad;
  end;

implementation

constructor TGBEmulator.Create;
begin
  inherited Create;
  FMemory := TMemory.Create;
  FPPU := TPPU.Create;
  FCartridge := TCartridge.Create;
  FJoypad := TJoypad.Create;
  FMemory.AttachPPU(FPPU);
  FMemory.AttachCartridge(FCartridge);
  FMemory.AttachJoypad(FJoypad);
  FCPU := TCPU.Create(FMemory);
  FAPU := TAPU.Create;
  FMemory.AttachPPU(FPPU);
  FMemory.AttachCartridge(FCartridge);
  FCPU := TCPU.Create(FMemory);
  FAPU := TAPU.Create;
  FMemory.AttachPPU(FPPU);
  FCPU := TCPU.Create(FMemory);
  FCPU := TCPU.Create(FMemory);
  FPPU := TPPU.Create;
  FAPU := TAPU.Create;
  FCartridge := TCartridge.Create;
  Reset;
end;

destructor TGBEmulator.Destroy;
begin
  FJoypad.Free;
  FCartridge.Free;
  FAPU.Free;
  FCPU.Free;
  FPPU.Free;
  FPPU.Free;
  FCPU.Free;
  FMemory.Free;
  inherited Destroy;
end;

procedure TGBEmulator.Reset;
begin
  FMemory.Reset;
  FCPU.Reset;
  FPPU.Reset;
  FAPU.Reset;
  FJoypad.Reset;
end;

function TGBEmulator.LoadCartridge(const FileName: string): Boolean;
begin
  Result := FCartridge.LoadFromFile(FileName);
  if Result then
    FMemory.LoadCartridge(FCartridge.Data);
end;

procedure TGBEmulator.Step;
var
  Cycles: Integer;
begin
  Cycles := FCPU.Step;
  FPPU.Step(Cycles);
  FAPU.Step(Cycles);
end;

procedure TGBEmulator.RunFrame;
var
  CycleCount: Integer;
begin
  CycleCount := 0;
  while CycleCount < FrameCycles do
  begin
    Step;
    Inc(CycleCount, 4);
  end;
end;

end.
