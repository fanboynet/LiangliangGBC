unit gb_core;

interface

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  gb_cpu, gb_cart, gb_mmu;

const
  GB_CYCLES_PER_SCANLINE = 456;
  GB_SCANLINES_PER_FRAME = 154;
  GB_CYCLES_PER_FRAME = GB_CYCLES_PER_SCANLINE * GB_SCANLINES_PER_FRAME;

type
  TGBScheduleMode = (smNormal, smScanline);
  TGBSerialByteProc = procedure(AByte: Byte) of object;

  TGBCore = class
  private
    FCpu: TCpu;
    FMmu: TGBMMU;
    FCart: TCartridge;
    FScheduleMode: TGBScheduleMode;
    FOnSerialByte: TGBSerialByteProc;
    procedure SetScheduleMode(const Value: TGBScheduleMode);
    procedure ForwardSerial(AByte: Byte);
    procedure OnBeforeTile(LineY, TileCol: Integer);
    procedure OnRunCpuForScanline;
  public
    constructor Create;
    destructor Destroy; override;
    procedure LoadROM(const ARomPath: string);
    procedure Reset;
    procedure RunCycles(ACycles: Cardinal);
    procedure RunFrame;
    procedure SetJoypadState(AButtons, ADirections: Byte);
    property Cpu: TCpu read FCpu;
    property Mmu: TGBMMU read FMmu;
    property Cart: TCartridge read FCart;
    property ScheduleMode: TGBScheduleMode read FScheduleMode write SetScheduleMode;
    property OnSerialByte: TGBSerialByteProc read FOnSerialByte write FOnSerialByte;
  end;

implementation

constructor TGBCore.Create;
begin
  inherited Create;
  FCart := TCartridge.Create;
  FMmu := TGBMMU.Create;
  FMmu.Cart := FCart;
  FMmu.OnSerialByte := ForwardSerial;

  FCpu := TCpu.Create;
  FCpu.OnRead8 := FMmu.Read8;
  FCpu.OnWrite8 := FMmu.Write8;
  FCpu.OnStop := FMmu.HandleStop;
  FCpu.OnBusAccess := FMmu.OnCpuBusAccess;
  FCpu.OnIDUOp := FMmu.OnCpuIDUOp;
  FMmu.Cpu := FCpu;

  { Force first SetScheduleMode call to apply callbacks. }
  FScheduleMode := smScanline;
  SetScheduleMode(smNormal);
end;

destructor TGBCore.Destroy;
begin
  FCpu.Free;
  FMmu.Free;
  FCart.Free;
  inherited;
end;

procedure TGBCore.ForwardSerial(AByte: Byte);
begin
  if Assigned(FOnSerialByte) then
    FOnSerialByte(AByte);
end;

procedure TGBCore.LoadROM(const ARomPath: string);
begin
  FCart.LoadFromFile(ARomPath);
  FMmu.ForceCGBMode := SameText(ExtractFileExt(ARomPath), '.gbc');
  FMmu.Cart := FCart;
  Reset;
end;

procedure TGBCore.Reset;
begin
  FMmu.Reset;
  FCpu.Reset;
  if FMmu.IsCGBMode then
  begin
    FCpu.A := $11;
    FCpu.F := $80;
    FCpu.B := $00;
    FCpu.C := $00;
    FCpu.D := $FF;
    FCpu.E := $56;
    FCpu.H := $00;
    FCpu.L := $0D;
  end;
end;

procedure TGBCore.SetScheduleMode(const Value: TGBScheduleMode);
begin
  if FScheduleMode = Value then
    Exit;
  FScheduleMode := Value;

  if FScheduleMode = smScanline then
  begin
    FCpu.OnTick := FMmu.CpuTickTimerOnly;
    FMmu.PPU.OnBeforeTile := OnBeforeTile;
    FMmu.PPU.OnRunCpuForScanline := OnRunCpuForScanline;
  end
  else
  begin
    FCpu.OnTick := FMmu.CpuTick;
    FMmu.PPU.OnBeforeTile := nil;
    FMmu.PPU.OnRunCpuForScanline := nil;
  end;
end;

procedure TGBCore.OnBeforeTile(LineY, TileCol: Integer);
begin
  { 456 T-cycles per scanline: mode2=80, mode3 split into 20 tile slots (19*19 + 15). }
  if TileCol < 0 then
    FMmu.RunCpuAndTimer(80)
  else if TileCol < 19 then
    FMmu.RunCpuAndTimer(19)
  else
    FMmu.RunCpuAndTimer(15);
end;

procedure TGBCore.OnRunCpuForScanline;
begin
  FMmu.RunCpuAndTimer(GB_CYCLES_PER_SCANLINE);
end;

procedure TGBCore.RunCycles(ACycles: Cardinal);
var
  Remaining: Cardinal;
begin
  if FScheduleMode = smScanline then
  begin
    FMmu.Update(ACycles);
    Exit;
  end;

  Remaining := ACycles;
  while Remaining > 0 do
  begin
    FCpu.Step;
    if FCpu.Cycles >= Remaining then
      Remaining := 0
    else
      Dec(Remaining, FCpu.Cycles);
  end;
end;

procedure TGBCore.RunFrame;
var
  I: Integer;
begin
  if FScheduleMode = smScanline then
  begin
    for I := 0 to GB_SCANLINES_PER_FRAME - 1 do
      FMmu.Update(GB_CYCLES_PER_SCANLINE);
  end
  else
    RunCycles(GB_CYCLES_PER_FRAME);
end;

procedure TGBCore.SetJoypadState(AButtons, ADirections: Byte);
begin
  FMmu.SetJoypadState(AButtons, ADirections);
end;

end.
