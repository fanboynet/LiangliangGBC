unit gb_core;
{ 单元定义: 模拟器核心编排层（CPU+MMU+Cart 连接）。 }
{ 负责内容: ROM 装载、运行调度（按周期/按帧/按扫描线）、串口转发与输入状态下发。 }



interface

{
  编排层职责:
  - 连接 CPU<->MMU 回调。
  - 在不同调度模式下推进系统（逐指令 or 按扫描线时隙）。
  - 提供 ROM 装载、输入注入、串口输出转发。
  说明:
  这里不实现硬件细节，硬件语义在 gb_cpu/gb_mmu/gb_ppu 等单元内。
}

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
    procedure SaveBatteryRAM;
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
  { 创建顺序: Cart -> MMU -> CPU，随后连接双向回调。 }
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
  { UI/SDL 层按扩展名 .gbc 提示强制 CGB，供双模式 ROM 切换运行目标。 }
  FMmu.ForceCGBMode := SameText(ExtractFileExt(ARomPath), '.gbc');
  FMmu.Cart := FCart;
  Reset;
end;

procedure TGBCore.Reset;
begin
  { 先 MMU 再 CPU，确保 CPU 首次取指看到的是 reset 后映射。 }
  FMmu.Reset;
  FCpu.Reset;
  if FMmu.IsCGBMode then
  begin
    { CGB 无 boot ROM 直入常见寄存器初值。 }
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

procedure TGBCore.SaveBatteryRAM;
begin
  FCart.SaveRAMToFile;
end;

procedure TGBCore.SetScheduleMode(const Value: TGBScheduleMode);
begin
  if FScheduleMode = Value then
    Exit;
  FScheduleMode := Value;

  if FScheduleMode = smScanline then
  begin
    { 扫描线模式:
      - PPU 在绘制时隙回调 CPU 运行，提升与 PPU 时序测试的一致性。 }
    FCpu.OnTick := FMmu.CpuTickTimerOnly;
    FMmu.PPU.OnBeforeTile := OnBeforeTile;
    FMmu.PPU.OnRunCpuForScanline := OnRunCpuForScanline;
  end
  else
  begin
    { 普通模式: 每条指令结束后由 MMU.CpuTick 推进外设。 }
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
  { VBlank 扫描线不渲染时，CPU 仍需跑满整行 456 cycles。 }
  FMmu.RunCpuAndTimer(GB_CYCLES_PER_SCANLINE);
end;

procedure TGBCore.RunCycles(ACycles: Cardinal);
var
  Remaining: Cardinal;
begin
  { Normal: 按“CPU 实际消耗 cycles”扣减预算；
    Scanline: 交给 MMU.Update 统一推进。 }
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
  FrameCpuCycles: Cardinal;
begin
  { 双速模式下，CPU 每帧预算需翻倍，PPU 帧长度不变。 }
  if FScheduleMode = smScanline then
  begin
    for I := 0 to GB_SCANLINES_PER_FRAME - 1 do
      FMmu.Update(GB_CYCLES_PER_SCANLINE);
  end
  else
  begin
    FrameCpuCycles := GB_CYCLES_PER_FRAME;
    if FMmu.IsDoubleSpeed then
      FrameCpuCycles := FrameCpuCycles * 2;
    RunCycles(FrameCpuCycles);
  end;
end;

procedure TGBCore.SetJoypadState(AButtons, ADirections: Byte);
begin
  FMmu.SetJoypadState(AButtons, ADirections);
end;

end.
