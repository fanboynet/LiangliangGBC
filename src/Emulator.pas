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
  Reset;
end;

destructor TGBEmulator.Destroy;
begin
  FJoypad.Free;
  FCartridge.Free;
  FAPU.Free;
  FCPU.Free;
  FPPU.Free;
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
