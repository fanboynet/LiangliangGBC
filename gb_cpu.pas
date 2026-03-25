unit gb_cpu;
{ 单元定义: LR35902 CPU 指令执行核心。 }
{ 负责内容: 寄存器/标志位维护、取指译码执行、中断响应、HALT/STOP、每条指令周期计数与总线访问回调。 }
{
  注释规范（本单元）:
  1) 为什么这样写: 对齐 LR35902 实机行为与 Pan Docs 约束。
  2) 这是什么操作: 在关键路径标注指令语义（LD/ADD/JP/BIT 等）。
  3) 周期数: 通过 FCycles + 4T 总线拍确保时序正确。
  4) 边缘情况: HALT bug、EI 延迟生效、半进位/借位、条件分支周期差。
  参考:
  - Pan Docs: https://gbdev.io/pandocs/
  - CPU 指令集: https://gbdev.io/pandocs/CPU_Instruction_Set.html
  - 中断行为: https://gbdev.io/pandocs/Interrupts.html
}



{ Game Boy (LR35902) CPU unit. Full instruction set, classic Delphi, no generics. }

interface

type
  { MMU 读总线回调（8-bit）。 }
  TRead8Func = function(Addr: Word): Byte of object;
  { MMU 写总线回调（8-bit）。 }
  TWrite8Proc = procedure(Addr: Word; Value: Byte) of object;
  { 时钟推进回调，单位为 T-cycle。 }
  TTickProc = procedure(Cycles: Cardinal) of object;
  { STOP 指令回调（用于 CGB 速度切换）。 }
  TStopFunc = function: Boolean of object;
  { CPU 总线访问通知（用于 MMU 的 OAM bug / 监控逻辑）。 }
  TBusAccessProc = procedure(Addr: Word; IsWrite: Boolean) of object;
  { IDU（内部地址单元）操作通知。 }
  TIDUOpProc = procedure(Addr: Word; Kind: Byte) of object;

  TCpu = class
  private
    FRegA: Byte;
    FRegF: Byte;
    FRegB: Byte;
    FRegC: Byte;
    FRegD: Byte;
    FRegE: Byte;
    FRegH: Byte;
    FRegL: Byte;
    FSP: Word;
    FPC: Word;
    FIME: Boolean;           { Interrupt Master Enable }
    FIMEDelaySteps: Byte;    { EI takes effect after next instruction }
    FStopped: Boolean;       { STOP executed }
    FHalted: Boolean;        { HALT executed }
    FHaltBug: Boolean;       { HALT bug: next opcode fetch does not increment PC }
    FCycles: Cardinal;      { Cycles consumed by last Step }
    FTotalTicks: UInt64;    { Total T-cycles elapsed since reset }
    FStepTickCycles: Cardinal;
    FOnRead8: TRead8Func;
    FOnWrite8: TWrite8Proc;
    FOnTick: TTickProc;
    FOnStop: TStopFunc;
    FOnBusAccess: TBusAccessProc;
    FOnIDUOp: TIDUOpProc;
    procedure NotifyIDUOp(Addr: Word; Kind: Byte);
    procedure TickBus(Cycles: Cardinal);
    procedure DrainTicks;
    function Peek8(Addr: Word): Byte;
    function Read8(Addr: Word): Byte;
    procedure Write8(Addr: Word; Value: Byte);
    function Read16(Addr: Word): Word;
    procedure Write16(Addr: Word; Value: Word);
    { Flag helpers. F only uses bits 7-4: Z N H C }
    function GetZ: Boolean;
    function GetN: Boolean;
    function GetH: Boolean;
    function GetC: Boolean;
    procedure SetZ(Value: Boolean);
    procedure SetN(Value: Boolean);
    procedure SetH(Value: Boolean);
    procedure SetC(Value: Boolean);
    function GetR8(Index: Byte): Byte;
    procedure SetR8(Index: Byte; Value: Byte);
    function GetHL: Word;
    procedure SetHL(const Value: Word);
  public
    procedure Reset;
    procedure Step;
    { Memory bus: assign from MMU }
    property OnRead8: TRead8Func read FOnRead8 write FOnRead8;
    property OnWrite8: TWrite8Proc read FOnWrite8 write FOnWrite8;
    property OnTick: TTickProc read FOnTick write FOnTick;
    property OnStop: TStopFunc read FOnStop write FOnStop;
    property OnBusAccess: TBusAccessProc read FOnBusAccess write FOnBusAccess;
    property OnIDUOp: TIDUOpProc read FOnIDUOp write FOnIDUOp;
    { State }
    property Cycles: Cardinal read FCycles;
    property TotalTicks: UInt64 read FTotalTicks;
    property IME: Boolean read FIME write FIME;
    property Stopped: Boolean read FStopped;
    property Halted: Boolean read FHalted write FHalted;
    { Registers }
    property A: Byte read FRegA write FRegA;
    property F: Byte read FRegF write FRegF;
    property B: Byte read FRegB write FRegB;
    property C: Byte read FRegC write FRegC;
    property D: Byte read FRegD write FRegD;
    property E: Byte read FRegE write FRegE;
    property H: Byte read FRegH write FRegH;
    property L: Byte read FRegL write FRegL;
    property SP: Word read FSP write FSP;
    property PC: Word read FPC write FPC;
    function GetAF: Word;
    function GetBC: Word;
    function GetDE: Word;
    function GetHLValue: Word;
    procedure SetAF(const Value: Word);
    procedure SetBC(const Value: Word);
    procedure SetDE(const Value: Word);
    procedure SetHLValue(const Value: Word);
  end;

const
  { Optional: set to True to trace each Step to console }
  CPU_TRACE = False;

implementation

uses
{$IFDEF FPC}
  SysUtils;
{$ELSE}
  System.SysUtils;
{$ENDIF}

const
  { F 寄存器仅高 4 位有效（Z N H C）。低 4 位硬件上恒为 0。 }
  FLAG_Z = $80;
  FLAG_N = $40;
  FLAG_H = $20;
  FLAG_C = $10;

{ 统一的“时钟记账”入口。
  为什么:
  - 指令由多个总线拍组成，不能只在 Step 末尾一次性推进。
  - MMU/PPU/Timer/APU 都依赖精确时钟推进。
  参考: Pan Docs -> CPU Timing。 }
procedure TCpu.TickBus(Cycles: Cardinal);
begin
  Inc(FStepTickCycles, Cycles);
  Inc(FTotalTicks, Cycles);
  if Assigned(FOnTick) then
    FOnTick(Cycles);
end;

{ 将本条指令承诺的 FCycles 与已推进时钟对齐。
  某些路径会提前 Exit（如中断受理），此处保证周期闭合。 }
procedure TCpu.DrainTicks;
begin
  if FCycles > FStepTickCycles then
    TickBus(FCycles - FStepTickCycles);
end;

{ IDU 通知:
  LR35902 某些地址变化属于“内部地址单元”行为，不等同于普通读写总线。
  MMU 可用该信息模拟 OAM bug 等硬件细节。 }
procedure TCpu.NotifyIDUOp(Addr: Word; Kind: Byte);
begin
  if Assigned(FOnIDUOp) then
    FOnIDUOp(Addr and $FFFF, Kind);
end;

{ Peek8: 不消耗总线周期的“窥视读取”。
  用于 IE/IF 判定等场景，避免误增周期。 }
function TCpu.Peek8(Addr: Word): Byte;
begin
  Addr := Addr and $FFFF;
  if Assigned(FOnRead8) then
    Result := FOnRead8(Addr)
  else
    Result := $FF;
end;

{ Read8:
  - 执行一次 8-bit 总线读（4T）。
  - 并通知 OnBusAccess，供 MMU 做读总线副作用。 }
function TCpu.Read8(Addr: Word): Byte;
begin
  TickBus(4);
  Result := Peek8(Addr);
  if Assigned(FOnBusAccess) then
    FOnBusAccess(Addr and $FFFF, False);
end;

{ Write8:
  - 执行一次 8-bit 总线写（4T）。
  - 并通知 OnBusAccess，供 MMU 做写总线副作用。 }
procedure TCpu.Write8(Addr: Word; Value: Byte);
begin
  TickBus(4);
  Addr := Addr and $FFFF;
  if Assigned(FOnWrite8) then
    FOnWrite8(Addr, Value);
  if Assigned(FOnBusAccess) then
    FOnBusAccess(Addr, True);
end;

{ 16-bit 读采用 little-endian（低字节在前，高字节在后），总计 8T。 }
function TCpu.Read16(Addr: Word): Word;
begin
  Result := Read8(Addr) or (Word(Read8((Addr + 1) and $FFFF)) shl 8);
end;

{ 16-bit 写采用 little-endian，总计 8T。 }
procedure TCpu.Write16(Addr: Word; Value: Word);
begin
  Addr := Addr and $FFFF;
  Write8(Addr, Byte(Value and $FF));
  Write8((Addr + 1) and $FFFF, Byte(Value shr 8));
end;

{ 标志位读取辅助函数（Z/N/H/C）。 }
function TCpu.GetZ: Boolean;
begin
  Result := (FRegF and FLAG_Z) <> 0;
end;

function TCpu.GetN: Boolean;
begin
  Result := (FRegF and FLAG_N) <> 0;
end;

function TCpu.GetH: Boolean;
begin
  Result := (FRegF and FLAG_H) <> 0;
end;

function TCpu.GetC: Boolean;
begin
  Result := (FRegF and FLAG_C) <> 0;
end;

procedure TCpu.SetZ(Value: Boolean);
begin
  if Value then
    FRegF := FRegF or FLAG_Z
  else
    FRegF := FRegF and (not FLAG_Z);
end;

procedure TCpu.SetN(Value: Boolean);
begin
  if Value then
    FRegF := FRegF or FLAG_N
  else
    FRegF := FRegF and (not FLAG_N);
end;

procedure TCpu.SetH(Value: Boolean);
begin
  if Value then
    FRegF := FRegF or FLAG_H
  else
    FRegF := FRegF and (not FLAG_H);
end;

procedure TCpu.SetC(Value: Boolean);
begin
  if Value then
    FRegF := FRegF or FLAG_C
  else
    FRegF := FRegF and (not FLAG_C);
end;

{ r8 编码表（Pan Docs 指令编码约定）:
  0=B, 1=C, 2=D, 3=E, 4=H, 5=L, 6=(HL), 7=A
  注意:
  - 访问 (HL) 会触发一次真实总线读/写（额外 4T）。
  - 这也是 LD r,(HL) 与 LD r,r 周期不同的根因。 }
function TCpu.GetR8(Index: Byte): Byte;
var
  HL: Word;
begin
  case Index of
    0: Result := FRegB;
    1: Result := FRegC;
    2: Result := FRegD;
    3: Result := FRegE;
    4: Result := FRegH;
    5: Result := FRegL;
    6: begin
         HL := (Word(FRegH) shl 8) or FRegL;
         Result := Read8(HL);
       end;
  else
    Result := FRegA;
  end;
end;

procedure TCpu.SetR8(Index: Byte; Value: Byte);
var
  HL: Word;
begin
  case Index of
    0: FRegB := Value;
    1: FRegC := Value;
    2: FRegD := Value;
    3: FRegE := Value;
    4: FRegH := Value;
    5: FRegL := Value;
    6: begin
         HL := (Word(FRegH) shl 8) or FRegL;
         Write8(HL, Value);
       end;
  else
    FRegA := Value;
  end;
end;

function TCpu.GetHL: Word;
begin
  Result := (Word(FRegH) shl 8) or FRegL;
end;

procedure TCpu.SetHL(const Value: Word);
begin
  FRegH := Byte(Value shr 8);
  FRegL := Byte(Value and $FF);
end;

procedure TCpu.Reset;
begin
  { 这里采用“Boot ROM 结束后”常用初值（直接从 $0100 开跑）。
    说明: 这是模拟器常见快速启动策略，不是严格上电随机态。 }
  FRegA := $01;   { DMG boot ROM passes $01 when jumping to $100 }
  FRegF := $B0;   { DMG post-boot flags }
  FRegB := 0;
  FRegC := $13;
  FRegD := 0;
  FRegE := $D8;
  FRegH := $01;
  FRegL := $4D;
  FSP := $FFFE;
  FPC := $100;
  FIME := False;
  FIMEDelaySteps := 0;
  FStopped := False;
  FHalted := False;
  FHaltBug := False;
  FCycles := 0;
  FTotalTicks := 0;
end;

const
  { 中断入口向量（按优先级顺序）:
    VBlank, LCD STAT, Timer, Serial, Joypad
    参考: Pan Docs -> Interrupts。 }
  IRQ_VECTORS: array[0..4] of Word = ($40, $48, $50, $58, $60);

procedure TCpu.Step;
var
  Opcode, CBByte: Byte;
  Imm8: Byte;
  Imm16: Word;
  Tmp8: Byte;
  Tmp16: Word;
  Tmp32: Cardinal;
  Tmp16S: Integer;
  HL, BC, DE: Word;
  IE, IFreg, CurIF: Byte;
  I: Integer;
  { 以下局部过程用于把“栈/PC 的地址变化”拆成与硬件一致的 IDU 粒度。 }
  procedure SPDec1;
  begin
    NotifyIDUOp(FSP, 0);
    FSP := (FSP - 1) and $FFFF;
  end;
  procedure SPInc1;
  begin
    NotifyIDUOp(FSP, 0);
    FSP := (FSP + 1) and $FFFF;
  end;
  procedure SPDec2;
  begin
    SPDec1;
    SPDec1;
  end;
  procedure PCInc1;
  begin
    NotifyIDUOp(FPC, 0);
    FPC := (FPC + 1) and $FFFF;
  end;
  procedure PCInc2;
  begin
    PCInc1;
    PCInc1;
  end;
  procedure SPInc2;
  begin
    SPInc1;
    SPInc1;
  end;
  procedure Push16(Value: Word);
  begin
    SPDec1;
    Write8(FSP, Byte(Value shr 8));
    SPDec1;
    Write8(FSP, Byte(Value and $FF));
  end;
  function Pop16IsRetFamily: Word;
  var
    Lo, Hi: Byte;
  begin
    { RET/RETI/POP 的弹栈路径:
      这里把两次 SP 自增拆开并发出不同 Kind（3/4），用于 MMU 侧复现
      OAM bug 的 RET/POP 特殊时序差异。 }
    Lo := Read8(FSP);
    NotifyIDUOp(FSP, 3);
    FSP := (FSP + 1) and $FFFF;
    Hi := Read8(FSP);
    NotifyIDUOp(FSP, 4);
    FSP := (FSP + 1) and $FFFF;
    Result := Word(Lo) or (Word(Hi) shl 8);
  end;
begin
  { Step 执行流程（教学视角）:
    1) 处理 STOP/HALT 暂停态与唤醒条件
    2) 若 IME=1 且有 pending IRQ，优先受理中断
    3) 取指（含 HALT bug 的 PC 行为）
    4) 执行 opcode，并设置 FCycles
    5) 处理 EI 延迟生效，再用 DrainTicks 校准周期

    参考:
    - Pan Docs: Interrupts / HALT / STOP / Instruction Set。 }
  FCycles := 0;
  FStepTickCycles := 0;
  if FStopped then
  begin
    { STOP 状态下，无中断则仅空转 4T。 }
    if (Peek8($FFFF) and Peek8($FF0F) and $1F) = 0 then
    begin
      FCycles := 4;
      DrainTicks;
      Exit;
    end;
    FStopped := False;
  end;
  if FHalted then
  begin
    { HALT 状态下:
      - 无 pending IRQ: 每步空转 4T
      - 有 pending IRQ: 立即唤醒；IME=1 时本步可进入中断受理 }
    if (Peek8($FFFF) and Peek8($FF0F) and $1F) = 0 then
    begin
      FCycles := 4;
      DrainTicks;
      Exit;
    end;
    { Pending IRQ wakes HALT immediately. With IME=1, IRQ service starts in this step. }
    FHalted := False;
    if not FIME then
    begin
      FCycles := 4;
      DrainTicks;
      Exit;
    end;
  end;

  { 中断受理（IME=1 才允许）:
    - 优先级固定: VBlank > STAT > Timer > Serial > Joypad
    - 典型时序: 2 个空 M-cycle + Push PC + 跳向向量（总计约 20T） }
  if FIME then
  begin
    IE := Peek8($FFFF);
    IFreg := Peek8($FF0F);
    IFreg := IFreg and $1F;
    for I := 0 to 4 do
      if ((IE and IFreg) and (1 shl I)) <> 0 then
      begin
        if FHaltBug then
        begin
          { Clear HALT bug latch before servicing IRQ. }
          FHaltBug := False;
        end;
        FIME := False;
        { Interrupt sequence timing: 2 idle M-cycles, push PC, vector fetch. }
        TickBus(8);
        CurIF := Peek8($FF0F) and $1F;
        if Assigned(FOnWrite8) then
          FOnWrite8($FF0F, CurIF and (not (1 shl I)));
        Push16(FPC);
        TickBus(4);
        FPC := IRQ_VECTORS[I];
        FCycles := 20;
        DrainTicks;
        Exit;
      end;
  end;

  { 取指:
    普通情况下取指后 PC+1。
    若触发 HALT bug，本次取指不自增 PC（下一条从同地址再次取）。 }
  Opcode := Read8(FPC);
  if FHaltBug then
    FHaltBug := False
  else
    PCInc1;
  FCycles := 4;

  if CPU_TRACE then
    WriteLn(Format('PC=$%.4x OP=$%.2x', [FPC - 1, Opcode]));

  case Opcode of
    { $00-$3F: 基础控制流、8/16位装载、算术旋转、相对跳转。 }
    $00: ; { NOP }
    { LD r16,d16 / LD (r16),A / INC/DEC r16 这组指令用于 16-bit 地址寄存器准备与更新。 }
    $01: begin
           Imm16 := Read16(FPC); PCInc2;
           FRegB := Byte(Imm16 shr 8); FRegC := Byte(Imm16 and $FF);
           FCycles := 12;
         end;
    $02: begin
           BC := (Word(FRegB) shl 8) or FRegC;
           Write8(BC, FRegA);
           FCycles := 8;
         end;
    $03: begin
           BC := (Word(FRegB) shl 8) or FRegC;
           NotifyIDUOp(BC, 0);
           BC := (BC + 1) and $FFFF;
           FRegB := Byte(BC shr 8); FRegC := Byte(BC and $FF);
           FCycles := 8;
         end;
    $04: begin
           { INC r:
             标志位: Z 按结果，N=0，H 按低 4 位是否溢出（0x0F->0x10）。 }
           Inc(FRegB);
           SetZ(FRegB = 0);
           SetN(False);
           SetH((FRegB and $0F) = 0);
           FCycles := 4;
         end;
    $05: begin
           { DEC r:
             标志位: Z 按结果，N=1，H 按低 4 位是否借位（0x00->0x0F）。 }
           Dec(FRegB);
           SetZ(FRegB = 0);
           SetN(True);
           SetH((FRegB and $0F) = $0F);
           FCycles := 4;
         end;
    $06: begin
           FRegB := Read8(FPC); PCInc1;
           FCycles := 8;
         end;
    $07: begin { RLCA }
           { 非 CB 旋转类（RLCA/RRCA/RLA/RRA）统一规则: Z 强制清零。 }
           Tmp8 := (FRegA shr 7) and 1;
           FRegA := ((FRegA shl 1) or Tmp8) and $FF;
           SetZ(False);
           SetN(False);
           SetH(False);
           SetC(Tmp8 <> 0);
           FCycles := 4;
         end;
    $08: begin
           Imm16 := Read16(FPC); PCInc2;
           Write16(Imm16, FSP);
           FCycles := 20;
         end;
    $09: begin
           { ADD HL,BC（16-bit）:
             N=0；H 检查 bit11 进位；C 检查 bit15 进位；Z 保持不变。
             参考: Pan Docs -> CPU Instruction Set / ADD HL,r16。 }
           HL := GetHL;
           BC := (Word(FRegB) shl 8) or FRegC;
           Tmp32 := Cardinal(HL) + Cardinal(BC);
           SetN(False);
           SetH((HL and $0FFF) + (BC and $0FFF) > $0FFF);
           SetC(Tmp32 > $FFFF);
           SetHL(Word(Tmp32 and $FFFF));
           FCycles := 8;
         end;
    $0A: begin
           BC := (Word(FRegB) shl 8) or FRegC;
           FRegA := Read8(BC);
           FCycles := 8;
         end;
    $0B: begin
           BC := (Word(FRegB) shl 8) or FRegC;
           NotifyIDUOp(BC, 0);
           BC := (BC - 1) and $FFFF;
           FRegB := Byte(BC shr 8); FRegC := Byte(BC and $FF);
           FCycles := 8;
         end;
    $0C: begin
           Inc(FRegC);
           SetZ(FRegC = 0);
           SetN(False);
           SetH((FRegC and $0F) = 0);
           FCycles := 4;
         end;
    $0D: begin
           Dec(FRegC);
           SetZ(FRegC = 0);
           SetN(True);
           SetH((FRegC and $0F) = $0F);
           FCycles := 4;
         end;
    $0E: begin
           FRegC := Read8(FPC); PCInc1;
           FCycles := 8;
         end;
    $0F: begin { RRCA }
           Tmp8 := FRegA and 1;
           FRegA := (FRegA shr 1) or (Tmp8 shl 7);
           SetZ(False);
           SetN(False);
           SetH(False);
           SetC(Tmp8 <> 0);
           FCycles := 4;
         end;
    $10: begin { STOP; next byte consumed }
           { STOP 会吞掉后续 1 字节（硬件行为）。
             在 CGB 场景下通过 OnStop 回调处理倍速切换。 }
           Read8(FPC);
           PCInc1;
           if Assigned(FOnStop) and FOnStop then
           begin
             FStopped := False;
             FCycles := 4;
           end
           else
           begin
             FStopped := True;
             FCycles := 4;
           end;
         end;
    $11: begin
           Imm16 := Read16(FPC); PCInc2;
           FRegD := Byte(Imm16 shr 8); FRegE := Byte(Imm16 and $FF);
           FCycles := 12;
         end;
    $12: begin
           DE := (Word(FRegD) shl 8) or FRegE;
           Write8(DE, FRegA);
           FCycles := 8;
         end;
    $13: begin
           DE := (Word(FRegD) shl 8) or FRegE;
           NotifyIDUOp(DE, 0);
           DE := (DE + 1) and $FFFF;
           FRegD := Byte(DE shr 8); FRegE := Byte(DE and $FF);
           FCycles := 8;
         end;
    $14: begin
           Inc(FRegD);
           SetZ(FRegD = 0);
           SetN(False);
           SetH((FRegD and $0F) = 0);
           FCycles := 4;
         end;
    $15: begin
           Dec(FRegD);
           SetZ(FRegD = 0);
           SetN(True);
           SetH((FRegD and $0F) = $0F);
           FCycles := 4;
         end;
    $16: begin
           FRegD := Read8(FPC); PCInc1;
           FCycles := 8;
         end;
    $17: begin { RLA }
           { RLA: A 左移一位并经由 C 循环（旧 bit7 -> C，旧 C -> bit0）。 }
           Tmp8 := Byte(Ord(GetC));
           SetC((FRegA and $80) <> 0);
           FRegA := ((FRegA shl 1) or Tmp8) and $FF;
           SetZ(False);
           SetN(False);
           SetH(False);
           FCycles := 4;
         end;
    $18: begin
           Imm8 := Read8(FPC); PCInc1;
           FPC := (FPC + ShortInt(Imm8)) and $FFFF;
           FCycles := 12;
         end;
    $19: begin
           { ADD HL,DE，与 ADD HL,BC 标志位规则相同。 }
           HL := GetHL;
           DE := (Word(FRegD) shl 8) or FRegE;
           Tmp32 := Cardinal(HL) + Cardinal(DE);
           SetN(False);
           SetH((HL and $0FFF) + (DE and $0FFF) > $0FFF);
           SetC(Tmp32 > $FFFF);
           SetHL(Word(Tmp32 and $FFFF));
           FCycles := 8;
         end;
    $1A: begin
           DE := (Word(FRegD) shl 8) or FRegE;
           FRegA := Read8(DE);
           FCycles := 8;
         end;
    $1B: begin
           DE := (Word(FRegD) shl 8) or FRegE;
           NotifyIDUOp(DE, 0);
           DE := (DE - 1) and $FFFF;
           FRegD := Byte(DE shr 8); FRegE := Byte(DE and $FF);
           FCycles := 8;
         end;
    $1C: begin
           Inc(FRegE);
           SetZ(FRegE = 0);
           SetN(False);
           SetH((FRegE and $0F) = 0);
           FCycles := 4;
         end;
    $1D: begin
           Dec(FRegE);
           SetZ(FRegE = 0);
           SetN(True);
           SetH((FRegE and $0F) = $0F);
           FCycles := 4;
         end;
    $1E: begin
           FRegE := Read8(FPC); PCInc1;
           FCycles := 8;
         end;
    $1F: begin { RRA }
           { RRA: A 右移一位并经由 C 循环（旧 bit0 -> C，旧 C -> bit7）。 }
           Tmp8 := Byte(Ord(GetC));
           SetC((FRegA and 1) <> 0);
           FRegA := (FRegA shr 1) or (Tmp8 shl 7);
           SetZ(False);
           SetN(False);
           SetH(False);
           FCycles := 4;
         end;
    $20: begin { JR NZ }
           { 条件 JR 周期:
             条件成立（跳转）=12T；不成立=8T。 }
           Imm8 := Read8(FPC); PCInc1;
           if not GetZ then
           begin
             FPC := (FPC + ShortInt(Imm8)) and $FFFF;
             FCycles := 12;
           end
           else
             FCycles := 8;
         end;
    $21: begin
           Imm16 := Read16(FPC); PCInc2;
           FRegH := Byte(Imm16 shr 8); FRegL := Byte(Imm16 and $FF);
           FCycles := 12;
         end;
    $22: begin
           { LD (HL+),A:
             内存写完成后 HL 自增。此处发出 Kind=2 的 IDU 通知。 }
           HL := GetHL;
           Write8(HL, FRegA);
           NotifyIDUOp(HL, 2);
           SetHL((HL + 1) and $FFFF);
           FCycles := 8;
         end;
    $23: begin
           HL := GetHL;
           NotifyIDUOp(HL, 0);
           SetHL((HL + 1) and $FFFF);
           FCycles := 8;
         end;
    $24: begin
           Inc(FRegH);
           SetZ(FRegH = 0);
           SetN(False);
           SetH((FRegH and $0F) = 0);
           FCycles := 4;
         end;
    $25: begin
           Dec(FRegH);
           SetZ(FRegH = 0);
           SetN(True);
           SetH((FRegH and $0F) = $0F);
           FCycles := 4;
         end;
    $26: begin
           FRegH := Read8(FPC); PCInc1;
           FCycles := 8;
         end;
    $27: begin { DAA }
           { DAA（十进制调整）是最易错指令之一。
             规则依赖上一条是否减法（N 标志）以及 C/H 当前值。
             参考: Pan Docs -> CPU Instruction Set / DAA。 }
           Tmp8 := FRegA;
           if not GetN then
           begin
             if GetC or (Tmp8 > $99) then begin Inc(Tmp8, $60); SetC(True); end;
             if GetH or ((Tmp8 and $0F) > 9) then Inc(Tmp8, $06);
           end
           else
           begin
             if GetC then Dec(Tmp8, $60);
             if GetH then Dec(Tmp8, $06);
           end;
           FRegA := Tmp8 and $FF;
           SetZ(FRegA = 0);
           SetH(False);
           FCycles := 4;
         end;
    $28: begin { JR Z }
           Imm8 := Read8(FPC); PCInc1;
           if GetZ then
           begin
             FPC := (FPC + ShortInt(Imm8)) and $FFFF;
             FCycles := 12;
           end
           else
             FCycles := 8;
         end;
    $29: begin
           { ADD HL,HL:
             仍按 16-bit ADD 规则计算 H/C（不是按 8-bit）。 }
           HL := GetHL;
           Tmp32 := Cardinal(HL) + Cardinal(HL);
           SetN(False);
           SetH((HL and $0FFF) * 2 > $0FFF);
           SetC(Tmp32 > $FFFF);
           SetHL(Word(Tmp32 and $FFFF));
           FCycles := 8;
         end;
    $2A: begin
           { LD A,(HL+):
             读内存后 HL 自增。Kind=1 用于区分读后自增路径。 }
           HL := GetHL;
           FRegA := Read8(HL);
           NotifyIDUOp(HL, 1);
           SetHL((HL + 1) and $FFFF);
           FCycles := 8;
         end;
    $2B: begin
           HL := GetHL;
           NotifyIDUOp(HL, 0);
           SetHL((HL - 1) and $FFFF);
           FCycles := 8;
         end;
    $2C: begin
           Inc(FRegL);
           SetZ(FRegL = 0);
           SetN(False);
           SetH((FRegL and $0F) = 0);
           FCycles := 4;
         end;
    $2D: begin
           Dec(FRegL);
           SetZ(FRegL = 0);
           SetN(True);
           SetH((FRegL and $0F) = $0F);
           FCycles := 4;
         end;
    $2E: begin
           FRegL := Read8(FPC); PCInc1;
           FCycles := 8;
         end;
    $2F: begin { CPL }
           FRegA := (not FRegA) and $FF;
           SetN(True);
           SetH(True);
           FCycles := 4;
         end;
    $30: begin { JR NC }
           Imm8 := Read8(FPC); PCInc1;
           if not GetC then
           begin
             FPC := (FPC + ShortInt(Imm8)) and $FFFF;
             FCycles := 12;
           end
           else
             FCycles := 8;
         end;
    $31: begin
           { LD SP,d16: 常用于函数栈初始化与上下文切换前准备。 }
           Imm16 := Read16(FPC); PCInc2;
           FSP := Imm16;
           FCycles := 12;
         end;
    $32: begin
           { LD (HL-),A:
             写内存后 HL 自减。 }
           HL := GetHL;
           Write8(HL, FRegA);
           NotifyIDUOp(HL, 2);
           SetHL((HL - 1) and $FFFF);
           FCycles := 8;
         end;
    $33: begin
           SPInc1;
           FCycles := 8;
         end;
    $34: begin
           { INC (HL) / DEC (HL) 是“读-改-写”三段式:
             读 4T + 写 4T + 额外内部时序，最终 12T。 }
           HL := GetHL;
           Tmp8 := Read8(HL);
           Inc(Tmp8);
           Write8(HL, Tmp8);
           SetZ(Tmp8 = 0);
           SetN(False);
           SetH((Tmp8 and $0F) = 0);
           FCycles := 12;
         end;
    $35: begin
           HL := GetHL;
           Tmp8 := Read8(HL);
           Dec(Tmp8);
           Write8(HL, Tmp8);
           SetZ(Tmp8 = 0);
           SetN(True);
           SetH((Tmp8 and $0F) = $0F);
           FCycles := 12;
         end;
    $36: begin
           HL := GetHL;
           Imm8 := Read8(FPC); PCInc1;
           Write8(HL, Imm8);
           FCycles := 12;
         end;
    $37: begin { SCF }
           { SCF: C=1, N=0, H=0, Z 不变。 }
           SetN(False);
           SetH(False);
           SetC(True);
           FCycles := 4;
         end;
    $38: begin { JR C }
           Imm8 := Read8(FPC); PCInc1;
           if GetC then
           begin
             FPC := (FPC + ShortInt(Imm8)) and $FFFF;
             FCycles := 12;
           end
           else
             FCycles := 8;
         end;
    $39: begin
           { ADD HL,SP，与 ADD HL,r16 相同标志位规则。 }
           HL := GetHL;
           Tmp32 := Cardinal(HL) + Cardinal(FSP);
           SetN(False);
           SetH((HL and $0FFF) + (FSP and $0FFF) > $0FFF);
           SetC(Tmp32 > $FFFF);
           SetHL(Word(Tmp32 and $FFFF));
           FCycles := 8;
         end;
    $3A: begin
           { LD A,(HL-):
             读内存后 HL 自减。 }
           HL := GetHL;
           FRegA := Read8(HL);
           NotifyIDUOp(HL, 1);
           SetHL((HL - 1) and $FFFF);
           FCycles := 8;
         end;
    $3B: begin
           SPDec1;
           FCycles := 8;
         end;
    $3C: begin
           Inc(FRegA);
           SetZ(FRegA = 0);
           SetN(False);
           SetH((FRegA and $0F) = 0);
           FCycles := 4;
         end;
    $3D: begin
           Dec(FRegA);
           SetZ(FRegA = 0);
           SetN(True);
           SetH((FRegA and $0F) = $0F);
           FCycles := 4;
         end;
    $3E: begin
           FRegA := Read8(FPC); PCInc1;
           FCycles := 8;
         end;
    $3F: begin { CCF }
           { CCF: C 取反，N=0，H=0，Z 不变。 }
           SetN(False);
           SetH(False);
           SetC(not GetC);
           FCycles := 4;
         end;
    { $40-$7F: 8-bit LD 矩阵与 HALT。 }
    $40..$75, $77..$7F: begin { LD r8, r8 (excluding $76 = HALT) }
           { LD r,r:
             - 寄存器到寄存器: 4T
             - 涉及 (HL) 的读或写: 8T（多一次总线访问） }
           SetR8((Opcode shr 3) and 7, GetR8(Opcode and 7));
           if ((Opcode and 7) = 6) or (((Opcode shr 3) and 7) = 6) then
             FCycles := 8
           else
             FCycles := 4;
         end;
    $76: begin { HALT }
           { HALT bug:
             IME=0 且存在 pending IRQ 时，CPU 不真正 Halt，但下一次取指 PC 不自增。
             参考: Pan Docs -> HALT。 }
           if (not FIME) and ((Peek8($FFFF) and Peek8($FF0F) and $1F) <> 0) then
             FHaltBug := True
           else
             FHalted := True;
           FCycles := 4;
         end;
    { $80-$BF: 8-bit ALU 组（ADD/ADC/SUB/SBC/AND/XOR/OR/CP）。 }
    $80..$87: begin { ADD A, r8 }
           { 8-bit 加法族（ADD/ADC）:
             H 标志使用低 4 位进位规则，C 标志使用 8-bit 溢出规则。 }
           Tmp8 := GetR8(Opcode and 7);
           SetZ((FRegA + Tmp8) and $FF = 0);
           SetN(False);
           SetH((FRegA and $0F) + (Tmp8 and $0F) > $0F);
           SetC(FRegA + Tmp8 > $FF);
           FRegA := (FRegA + Tmp8) and $FF;
           if (Opcode and 7) = 6 then FCycles := 8 else FCycles := 4;
         end;
    $88..$8F: begin { ADC A, r8 }
           Tmp8 := GetR8(Opcode and 7);
           Tmp16 := FRegA + Tmp8 + Byte(Ord(GetC));
           SetZ(Byte(Tmp16 and $FF) = 0);
           SetN(False);
           SetH((FRegA and $0F) + (Tmp8 and $0F) + Ord(GetC) > $0F);
           SetC(Tmp16 > $FF);
           FRegA := Byte(Tmp16 and $FF);
           if (Opcode and 7) = 6 then FCycles := 8 else FCycles := 4;
         end;
    $90..$97: begin { SUB A, r8 }
           { 8-bit 减法族（SUB/SBC/CP）:
             H 标志表示低 4 位借位，C 标志表示整体借位。 }
           Tmp8 := GetR8(Opcode and 7);
           SetZ((FRegA - Tmp8) and $FF = 0);
           SetN(True);
           SetH((FRegA and $0F) < (Tmp8 and $0F));
           SetC(FRegA < Tmp8);
           FRegA := (FRegA - Tmp8) and $FF;
           if (Opcode and 7) = 6 then FCycles := 8 else FCycles := 4;
         end;
    $98..$9F: begin { SBC A, r8 }
           Tmp8 := GetR8(Opcode and 7);
           Tmp16S := Integer(FRegA) - Integer(Tmp8) - Integer(Ord(GetC));
           SetZ(Byte(Tmp16S and $FF) = 0);
           SetN(True);
           SetH((FRegA and $0F) < (Tmp8 and $0F) + Ord(GetC));
           SetC(Tmp16S < 0);
           FRegA := Byte(Tmp16S and $FF);
           if (Opcode and 7) = 6 then FCycles := 8 else FCycles := 4;
         end;
    $A0..$A7: begin { AND A, r8 }
           FRegA := FRegA and GetR8(Opcode and 7);
           SetZ(FRegA = 0);
           SetN(False);
           SetH(True);
           SetC(False);
           if (Opcode and 7) = 6 then FCycles := 8 else FCycles := 4;
         end;
    $A8..$AF: begin { XOR A, r8 }
           FRegA := FRegA xor GetR8(Opcode and 7);
           SetZ(FRegA = 0);
           SetN(False);
           SetH(False);
           SetC(False);
           if (Opcode and 7) = 6 then FCycles := 8 else FCycles := 4;
         end;
    $B0..$B7: begin { OR A, r8 }
           FRegA := FRegA or GetR8(Opcode and 7);
           SetZ(FRegA = 0);
           SetN(False);
           SetH(False);
           SetC(False);
           if (Opcode and 7) = 6 then FCycles := 8 else FCycles := 4;
         end;
    $B8..$BF: begin { CP A, r8 }
           { CP: 按减法更新标志位，但 A 不写回。 }
           Tmp8 := GetR8(Opcode and 7);
           SetZ(FRegA = Tmp8);
           SetN(True);
           SetH((FRegA and $0F) < (Tmp8 and $0F));
           SetC(FRegA < Tmp8);
           if (Opcode and 7) = 6 then FCycles := 8 else FCycles := 4;
         end;
    { $C0-$FF: 控制流、栈、立即数 ALU、IO 高页访问、中断控制。 }
    $C0: begin { RET NZ }
           { 条件 RET 周期:
             成立（执行弹栈）=20T；不成立=8T。 }
           if not GetZ then
           begin
             FPC := Pop16IsRetFamily;
             FCycles := 20;
           end
           else
             FCycles := 8;
         end;
    $C1: begin
           { POP r16: 从栈弹出低字节+高字节，周期固定 12T。 }
           Tmp16 := Pop16IsRetFamily;
           FRegB := Byte(Tmp16 shr 8);
           FRegC := Byte(Tmp16 and $FF);
           FCycles := 12;
         end;
    $C2: begin { JP NZ, imm16 }
           Imm16 := Read16(FPC); PCInc2;
           if not GetZ then
           begin
             FPC := Imm16;
             FCycles := 16;
           end
           else
             FCycles := 12;
         end;
    $C3: begin
           Imm16 := Read16(FPC); PCInc2;
           FPC := Imm16;
           FCycles := 16;
         end;
    $C4: begin { CALL NZ, imm16 }
           { 条件 CALL 周期:
             成立（压栈+跳转）=24T；不成立=12T。 }
           Imm16 := Read16(FPC); PCInc2;
           if not GetZ then
           begin
             Push16(FPC);
             FPC := Imm16;
             FCycles := 24;
           end
           else
             FCycles := 12;
         end;
    $C5: begin
           { PUSH r16: 先写高字节再写低字节，SP 向下增长。 }
           Push16((Word(FRegB) shl 8) or FRegC);
           FCycles := 16;
         end;
    $C6: begin
           { ADD A,d8: 与 ADD A,r 的标志位计算一致，仅操作数来源不同。 }
           Imm8 := Read8(FPC); PCInc1;
           SetZ((FRegA + Imm8) and $FF = 0);
           SetN(False);
           SetH((FRegA and $0F) + (Imm8 and $0F) > $0F);
           SetC(FRegA + Imm8 > $FF);
           FRegA := (FRegA + Imm8) and $FF;
           FCycles := 8;
         end;
    $C7: begin
           { RST 00h（固定向量调用）。 }
           Push16(FPC);
           FPC := $00;
           FCycles := 16;
         end;
    $C8: begin { RET Z }
           if GetZ then
           begin
             FPC := Pop16IsRetFamily;
             FCycles := 20;
           end
           else
             FCycles := 8;
         end;
    $C9: begin
           { RET（无条件）固定 16T。 }
           FPC := Pop16IsRetFamily;
           FCycles := 16;
         end;
    $CA: begin { JP Z, imm16 }
           Imm16 := Read16(FPC); PCInc2;
           if GetZ then
           begin
             FPC := Imm16;
             FCycles := 16;
           end
           else
             FCycles := 12;
         end;
    $CB: begin
           CBByte := Read8(FPC);
           PCInc1;
           FCycles := 8;
           { CB 前缀扩展指令:
             基础周期 8T；若目标是 (HL)，再追加 8T（总 16T）。
             参考: Pan Docs -> Prefix Opcodes。 }
           case CBByte of
             { RLC/RRC/RL/RR/SLA/SRA/SWAP/SRL:
               - 对寄存器目标: 8T
               - 对 (HL) 目标: 16T
               - 绝大多数会写回并更新 Z/N/H/C（与非 CB 旋转指令不同）。 }
             $00..$07: begin { RLC r8 }
                        Tmp8 := GetR8(CBByte and 7);
                        Tmp16 := (Tmp8 shl 1) or (Tmp8 shr 7);
                        SetR8(CBByte and 7, Byte(Tmp16 and $FF));
                        SetZ(Byte(Tmp16) = 0);
                        SetN(False);
                        SetH(False);
                        SetC((Tmp8 and $80) <> 0);
                        if (CBByte and 7) = 6 then Inc(FCycles, 8);
                      end;
             $08..$0F: begin { RRC r8 }
                        Tmp8 := GetR8(CBByte and 7);
                        Tmp16 := (Tmp8 shr 1) or ((Tmp8 and 1) shl 7);
                        SetR8(CBByte and 7, Byte(Tmp16));
                        SetZ(Byte(Tmp16) = 0);
                        SetN(False);
                        SetH(False);
                        SetC((Tmp8 and 1) <> 0);
                        if (CBByte and 7) = 6 then Inc(FCycles, 8);
                      end;
             $10..$17: begin { RL r8 }
                        Tmp8 := GetR8(CBByte and 7);
                        Tmp16 := (Tmp8 shl 1) or Byte(Ord(GetC));
                        SetR8(CBByte and 7, Byte(Tmp16 and $FF));
                        SetZ(Byte(Tmp16 and $FF) = 0);
                        SetN(False);
                        SetH(False);
                        SetC((Tmp8 and $80) <> 0);
                        if (CBByte and 7) = 6 then Inc(FCycles, 8);
                      end;
             $18..$1F: begin { RR r8 }
                        Tmp8 := GetR8(CBByte and 7);
                        Tmp16 := (Tmp8 shr 1) or (Byte(Ord(GetC)) shl 7);
                        SetR8(CBByte and 7, Byte(Tmp16));
                        SetZ(Byte(Tmp16) = 0);
                        SetN(False);
                        SetH(False);
                        SetC((Tmp8 and 1) <> 0);
                        if (CBByte and 7) = 6 then Inc(FCycles, 8);
                      end;
             $20..$27: begin { SLA r8 }
                        Tmp8 := GetR8(CBByte and 7);
                        SetC((Tmp8 and $80) <> 0);
                        Tmp8 := (Tmp8 shl 1) and $FF;
                        SetR8(CBByte and 7, Tmp8);
                        SetZ(Tmp8 = 0);
                        SetN(False);
                        SetH(False);
                        if (CBByte and 7) = 6 then Inc(FCycles, 8);
                      end;
             $28..$2F: begin { SRA r8 }
                        Tmp8 := GetR8(CBByte and 7);
                        SetC((Tmp8 and 1) <> 0);
                        Tmp8 := (Tmp8 shr 1) or (Tmp8 and $80);
                        SetR8(CBByte and 7, Tmp8);
                        SetZ(Tmp8 = 0);
                        SetN(False);
                        SetH(False);
                        if (CBByte and 7) = 6 then Inc(FCycles, 8);
                      end;
             $30..$37: begin { SWAP r8 }
                        Tmp8 := GetR8(CBByte and 7);
                        Tmp8 := ((Tmp8 and $0F) shl 4) or (Tmp8 shr 4);
                        SetR8(CBByte and 7, Tmp8);
                        SetZ(Tmp8 = 0);
                        SetN(False);
                        SetH(False);
                        SetC(False);
                        if (CBByte and 7) = 6 then Inc(FCycles, 8);
                      end;
             $38..$3F: begin { SRL r8 }
                        Tmp8 := GetR8(CBByte and 7);
                        SetC((Tmp8 and 1) <> 0);
                        Tmp8 := Tmp8 shr 1;
                        SetR8(CBByte and 7, Tmp8);
                        SetZ(Tmp8 = 0);
                        SetN(False);
                        SetH(False);
                        if (CBByte and 7) = 6 then Inc(FCycles, 8);
                      end;
             { BIT b,r:
               只测试位，不写回目标。N=0, H=1, C 保持不变。 }
             $40..$7F: begin { BIT b, r8 }
                        Tmp8 := GetR8(CBByte and 7);
                        SetZ((Tmp8 and (1 shl ((CBByte shr 3) and 7))) = 0);
                        SetN(False);
                        SetH(True);
                        if (CBByte and 7) = 6 then Inc(FCycles, 4);
                      end;
             { RES/SET:
               对目标位清零/置位，不修改 Z/N/H/C。 }
             $80..$BF: begin { RES b, r8 }
                        Tmp8 := GetR8(CBByte and 7);
                        Tmp8 := Tmp8 and (not (1 shl ((CBByte shr 3) and 7)));
                        SetR8(CBByte and 7, Tmp8);
                        if (CBByte and 7) = 6 then Inc(FCycles, 8);
                      end;
            $C0..$FF: begin { SET b, r8 }
                        Tmp8 := GetR8(CBByte and 7);
                        Tmp8 := Tmp8 or (1 shl ((CBByte shr 3) and 7));
                        SetR8(CBByte and 7, Tmp8);
                        if (CBByte and 7) = 6 then Inc(FCycles, 8);
                      end;
           end;
           if FIMEDelaySteps > 0 then
           begin
             { CB 指令同样算“下一条指令”，因此会推进 EI 延迟计数。 }
             Dec(FIMEDelaySteps);
             if FIMEDelaySteps = 0 then
               FIME := True;
           end;
           DrainTicks;
           Exit;
         end;
    $CC: begin { CALL Z, imm16 }
           Imm16 := Read16(FPC); PCInc2;
           if GetZ then
           begin
             Push16(FPC);
             FPC := Imm16;
             FCycles := 24;
           end
           else
             FCycles := 12;
         end;
    $CD: begin
           { CALL a16: Push 返回地址后跳转，固定 24T。 }
           Imm16 := Read16(FPC); PCInc2;
           Push16(FPC);
           FPC := Imm16;
           FCycles := 24;
         end;
    $CE: begin
           { ADC A,d8: 把当前 C 作为第 3 个加数参与。 }
           Imm8 := Read8(FPC); PCInc1;
           Tmp16 := FRegA + Imm8 + Byte(Ord(GetC));
           SetZ(Byte(Tmp16 and $FF) = 0);
           SetN(False);
           SetH((FRegA and $0F) + (Imm8 and $0F) + Ord(GetC) > $0F);
           SetC(Tmp16 > $FF);
           FRegA := Byte(Tmp16 and $FF);
           FCycles := 8;
         end;
    $CF: begin
           { RST 08h。 }
           Push16(FPC);
           FPC := $08;
           FCycles := 16;
         end;
    $D0: begin { RET NC }
           if not GetC then
           begin
             FPC := Pop16IsRetFamily;
             FCycles := 20;
           end
           else
             FCycles := 8;
         end;
    $D1: begin
           Tmp16 := Pop16IsRetFamily;
           FRegD := Byte(Tmp16 shr 8);
           FRegE := Byte(Tmp16 and $FF);
           FCycles := 12;
         end;
    $D2: begin { JP NC, imm16 }
           Imm16 := Read16(FPC); PCInc2;
           if not GetC then
           begin
             FPC := Imm16;
             FCycles := 16;
           end
           else
             FCycles := 12;
         end;
    $D4: begin { CALL NC, imm16 }
           Imm16 := Read16(FPC); PCInc2;
           if not GetC then
           begin
             Push16(FPC);
             FPC := Imm16;
             FCycles := 24;
           end
           else
             FCycles := 12;
         end;
    $D5: begin
           Push16((Word(FRegD) shl 8) or FRegE);
           FCycles := 16;
         end;
    { LR35902 未定义 opcode（不会像某些 Z80 进入锁死），此实现按 NOP 处理。 }
    $D3, $DB, $DD, $E3, $E4, $EB, $EC, $ED, $F4, $FC, $FD: ;
    $D6: begin
           { SUB A,d8: 与 SUB A,r 的借位/半借位规则一致。 }
           Imm8 := Read8(FPC); PCInc1;
           SetZ((FRegA - Imm8) and $FF = 0);
           SetN(True);
           SetH((FRegA and $0F) < (Imm8 and $0F));
           SetC(FRegA < Imm8);
           FRegA := (FRegA - Imm8) and $FF;
           FCycles := 8;
         end;
    $D7: begin
           Push16(FPC);
           FPC := $10;
           FCycles := 16;
         end;
    $D8: begin { RET C }
           if GetC then
           begin
             FPC := Pop16IsRetFamily;
             FCycles := 20;
           end
           else
             FCycles := 8;
         end;
    $D9: begin { RETI }
           { RETI: 立即 IME=1（不同于 EI 的延迟生效）。 }
           FPC := Pop16IsRetFamily;
           FIME := True;
           FCycles := 16;
         end;
    $DA: begin { JP C, imm16 }
           Imm16 := Read16(FPC); PCInc2;
           if GetC then
           begin
             FPC := Imm16;
             FCycles := 16;
           end
           else
             FCycles := 12;
         end;
    $DC: begin { CALL C, imm16 }
           Imm16 := Read16(FPC); PCInc2;
           if GetC then
           begin
             Push16(FPC);
             FPC := Imm16;
             FCycles := 24;
           end
           else
             FCycles := 12;
         end;
    $DE: begin
           { SBC A,d8: 减法时把当前 C 当作借位输入。 }
           Imm8 := Read8(FPC); PCInc1;
           Tmp16S := Integer(FRegA) - Integer(Imm8) - Integer(Ord(GetC));
           SetZ(Byte(Tmp16S and $FF) = 0);
           SetN(True);
           SetH((FRegA and $0F) < (Imm8 and $0F) + Ord(GetC));
           SetC(Tmp16S < 0);
           FRegA := Byte(Tmp16S and $FF);
           FCycles := 8;
         end;
    $DF: begin
           { RST 18h。 }
           Push16(FPC);
           FPC := $18;
           FCycles := 16;
         end;
    $E0: begin
           { LDH (a8),A: 写入 $FF00 + imm8（高页 IO 寄存器区）。 }
           Imm8 := Read8(FPC); PCInc1;
           Write8($FF00 or Imm8, FRegA);
           FCycles := 12;
         end;
    $E1: begin
           { POP HL。 }
           Tmp16 := Pop16IsRetFamily;
           FRegH := Byte(Tmp16 shr 8);
           FRegL := Byte(Tmp16 and $FF);
           FCycles := 12;
         end;
    $E2: begin
           { LD (C),A: 写入 $FF00 + C。 }
           Write8($FF00 or FRegC, FRegA);
           FCycles := 8;
         end;
    $E5: begin
           { PUSH HL。 }
           Push16(GetHL);
           FCycles := 16;
         end;
    $E6: begin
           { AND A,d8: H 恒置 1，N/C 清零（LR35902 约定）。 }
           Imm8 := Read8(FPC); PCInc1;
           FRegA := FRegA and Imm8;
           SetZ(FRegA = 0);
           SetN(False);
           SetH(True);
           SetC(False);
           FCycles := 8;
         end;
    $E7: begin
           { RST 20h。 }
           Push16(FPC);
           FPC := $20;
           FCycles := 16;
         end;
    $E8: begin { ADD SP, imm8 }
           { ADD SP,e8:
             e8 为有符号 8-bit 立即数。
             Z=0, N=0，H/C 只按低字节加法计算（不是按 16-bit 全宽）。
             这是与普通 16-bit ADD 不同的关键点。 }
           Imm8 := Read8(FPC); PCInc1;
           Tmp16 := (FSP + ShortInt(Imm8)) and $FFFF;
           SetZ(False);
           SetN(False);
           SetH(((FSP and $FF) and $0F) + (Byte(ShortInt(Imm8)) and $0F) > $0F);
           SetC((FSP and $FF) + Byte(ShortInt(Imm8)) > $FF);
           FSP := Tmp16;
           FCycles := 16;
         end;
    $E9: begin
           FPC := GetHL;
           FCycles := 4;
         end;
    $EA: begin
           { LD (a16),A: 16-bit 绝对地址写。 }
           Imm16 := Read16(FPC); PCInc2;
           Write8(Imm16, FRegA);
           FCycles := 16;
         end;
    $EE: begin
           { XOR A,d8: N/H/C 清零，仅 Z 由结果决定。 }
           Imm8 := Read8(FPC); PCInc1;
           FRegA := FRegA xor Imm8;
           SetZ(FRegA = 0);
           SetN(False);
           SetH(False);
           SetC(False);
           FCycles := 8;
         end;
    $EF: begin
           { RST 28h。 }
           Push16(FPC);
           FPC := $28;
           FCycles := 16;
         end;
    $F0: begin
           { LDH A,(a8): 读取 $FF00 + imm8。 }
           Imm8 := Read8(FPC); PCInc1;
           FRegA := Read8($FF00 or Imm8);
           FCycles := 12;
         end;
    $F1: begin
           { POP AF: F 的低 4 bit 无效，必须清零（and $F0）。 }
           Tmp16 := Pop16IsRetFamily;
           FRegA := Byte(Tmp16 shr 8);
           FRegF := Byte(Tmp16 and $F0);
           FCycles := 12;
         end;
    $F2: begin
           { LD A,(C): 读取 $FF00 + C。 }
           FRegA := Read8($FF00 or FRegC);
           FCycles := 8;
         end;
    $F3: begin
           { DI: 立即关中断（IME 立刻清零）。 }
           FIME := False;
           FIMEDelaySteps := 0;
           FCycles := 4;
         end;
    $F5: begin
           { PUSH AF: F 的低 4 bit 已在写入前屏蔽。 }
           Push16((Word(FRegA) shl 8) or (FRegF and $F0));
           FCycles := 16;
         end;
    $F6: begin
           { OR A,d8: N/H/C 清零，仅 Z 按结果。 }
           Imm8 := Read8(FPC); PCInc1;
           FRegA := FRegA or Imm8;
           SetZ(FRegA = 0);
           SetN(False);
           SetH(False);
           SetC(False);
           FCycles := 8;
         end;
    $F7: begin
           { RST 30h。 }
           Push16(FPC);
           FPC := $30;
           FCycles := 16;
         end;
    $F8: begin { LD HL, SP+imm8 }
           { LD HL,SP+e8:
             标志位规则与 ADD SP,e8 完全一致（Z=0,N=0，H/C 按低字节）。
             参考: Pan Docs -> Instruction Set（ADD SP,e8 / LD HL,SP+e8）。 }
           Imm8 := Read8(FPC); PCInc1;
           Tmp16 := (FSP + ShortInt(Imm8)) and $FFFF;
           SetHL(Tmp16);
           SetZ(False);
           SetN(False);
           SetH(((FSP and $FF) and $0F) + (Byte(ShortInt(Imm8)) and $0F) > $0F);
           SetC((FSP and $FF) + Byte(ShortInt(Imm8)) > $FF);
           FCycles := 12;
         end;
    $F9: begin
           { LD SP,HL: 不改标志位，固定 8T。 }
           FSP := GetHL;
           FCycles := 8;
         end;
    $FA: begin
           { LD A,(a16): 16-bit 绝对地址读。 }
           Imm16 := Read16(FPC); PCInc2;
           FRegA := Read8(Imm16);
           FCycles := 16;
         end;
    $FB: begin
           { EI 延迟生效:
             IME 不会在本条 EI 结束时立刻置 1，而是在“下一条指令后”生效。 }
           FIMEDelaySteps := 2;
           FCycles := 4;
         end;
    $FE: begin
           { CP A,d8: 与 SUB A,d8 同标志位规则，但不回写 A。 }
           Imm8 := Read8(FPC); PCInc1;
           SetZ(FRegA = Imm8);
           SetN(True);
           SetH((FRegA and $0F) < (Imm8 and $0F));
           SetC(FRegA < Imm8);
           FCycles := 8;
         end;
    $FF: begin
           { RST 38h。 }
           Push16(FPC);
           FPC := $38;
           FCycles := 16;
         end;
  else
    { 未实现/非法 opcode: 按 NOP 处理，保持模拟器健壮性。 }
  end;

  if FIMEDelaySteps > 0 then
  begin
    { 统一处理 EI 延迟计数。 }
    Dec(FIMEDelaySteps);
    if FIMEDelaySteps = 0 then
      FIME := True;
  end;
  DrainTicks;
end;

function TCpu.GetAF: Word;
begin
  Result := (Word(FRegA) shl 8) or (FRegF and $F0);
end;

function TCpu.GetBC: Word;
begin
  Result := (Word(FRegB) shl 8) or FRegC;
end;

function TCpu.GetDE: Word;
begin
  Result := (Word(FRegD) shl 8) or FRegE;
end;

function TCpu.GetHLValue: Word;
begin
  Result := (Word(FRegH) shl 8) or FRegL;
end;

procedure TCpu.SetAF(const Value: Word);
begin
  FRegA := Byte(Value shr 8);
  FRegF := Byte(Value and $FF) and $F0;
end;

procedure TCpu.SetBC(const Value: Word);
begin
  FRegB := Byte(Value shr 8);
  FRegC := Byte(Value and $FF);
end;

procedure TCpu.SetDE(const Value: Word);
begin
  FRegD := Byte(Value shr 8);
  FRegE := Byte(Value and $FF);
end;

procedure TCpu.SetHLValue(const Value: Word);
begin
  FRegH := Byte(Value shr 8);
  FRegL := Byte(Value and $FF);
end;

end.
