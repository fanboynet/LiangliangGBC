unit Emulator;

interface

uses
  System.SysUtils,
  Common,
  CPU,
  Memory,
  PPU,
  APU,
  Cartridge;

type
  TGBEmulator = class
  private
    FCPU: TCPU;
    FMemory: TMemory;
    FPPU: TPPU;
    FAPU: TAPU;
    FCartridge: TCartridge;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Reset;
    function LoadCartridge(const FileName: string): Boolean;
    procedure Step;
    procedure RunFrame;
  end;

implementation

constructor TGBEmulator.Create;
begin
  inherited Create;
  FMemory := TMemory.Create;
  FCPU := TCPU.Create(FMemory);
  FPPU := TPPU.Create;
  FAPU := TAPU.Create;
  FCartridge := TCartridge.Create;
  Reset;
end;

destructor TGBEmulator.Destroy;
begin
  FCartridge.Free;
  FAPU.Free;
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
