unit gb_apu;

interface

type
  TAPUSampleProc = procedure(ALeft, ARight: SmallInt) of object;

  TGBAPU = class
  private
    const
      GB_CPU_HZ = 4194304.0;
      DUTY_TABLE: array[0..3, 0..7] of Byte = (
        (0,0,0,0,0,0,0,1),
        (1,0,0,0,0,0,0,1),
        (1,0,0,0,0,1,1,1),
        (0,1,1,1,1,1,1,0)
      );
      NOISE_DIVISOR: array[0..7] of Integer = (8,16,32,48,64,80,96,112);
  private
    type
      TSquareChannel = record
        Enabled: Boolean;
        DutyStep: Integer;
        FreqTimer: Integer;
        SweepShadow: Integer;
        SweepPeriod: Integer;
        SweepCounter: Integer;
        SweepShift: Integer;
        SweepNegate: Boolean;
        SweepDidNegate: Boolean;
        SweepEnabled: Boolean;
        LengthCounter: Integer;
        LengthEnabled: Boolean;
        EnvelopeVolume: Integer;
        EnvelopePeriod: Integer;
        EnvelopeCounter: Integer;
        EnvelopeIncrease: Boolean;
      end;

      TWaveChannel = record
        Enabled: Boolean;
        Position: Integer; { 0..31 samples }
        CurrentByteIndex: Integer; { 0..15 wave RAM byte currently exposed while playing }
        SampleBuffer: Integer; { latched 4-bit sample }
        FreqTimer: Integer;
        LengthCounter: Integer;
        LengthEnabled: Boolean;
      end;

      TNoiseChannel = record
        Enabled: Boolean;
        LFSR: Word;
        FreqTimer: Integer;
        LengthCounter: Integer;
        LengthEnabled: Boolean;
        EnvelopeVolume: Integer;
        EnvelopePeriod: Integer;
        EnvelopeCounter: Integer;
        EnvelopeIncrease: Boolean;
      end;
  private
    FRegs: array[0..$2F] of Byte; { FF10..FF3F }
    FOnSample: TAPUSampleProc;
    FSampleRate: Integer;
    FCycleFrac: Double;
    FSampleCycleAcc: Double;
    FFrameSeqCycles: Integer;
    FFrameSeqStep: Integer;
    FMasterEnabled: Boolean;
    FHPPrevInL: Double;
    FHPPrevInR: Double;
    FHPPrevOutL: Double;
    FHPPrevOutR: Double;
    FCh1: TSquareChannel;
    FCh2: TSquareChannel;
    FCh3: TWaveChannel;
    FCh4: TNoiseChannel;
    function GetRegIndex(Addr: Word): Integer;
    function IsApuReg(Addr: Word): Boolean;
    function IsDAC1On: Boolean;
    function IsDAC2On: Boolean;
    function IsDAC3On: Boolean;
    function IsDAC4On: Boolean;
    function Ch1FreqReg: Integer;
    function Ch2FreqReg: Integer;
    function Ch3FreqReg: Integer;
    procedure ClockFrameSequencer;
    procedure ClockLength;
    procedure ClockSweep;
    procedure ClockEnvelope;
    function ComputeSweepTarget(var DisableChannel: Boolean): Integer;
    function EffectiveEnvelopePeriod(APeriod: Integer): Integer;
    function LengthWillClockNext: Boolean;
    function ApplyHighPass(InputValue: Integer; var PrevIn, PrevOut: Double): Integer;
    procedure LoadCh3SampleBuffer;
    procedure ReloadCh1Timer;
    procedure ReloadCh2Timer;
    procedure ReloadCh3Timer;
    procedure ReloadCh4Timer;
    procedure TriggerCh1;
    procedure TriggerCh2;
    procedure TriggerCh3;
    procedure TriggerCh4;
    function SampleCh1: Integer;
    function SampleCh2: Integer;
    function SampleCh3: Integer;
    function SampleCh4: Integer;
    function DigitalToAnalog(ADigital4: Integer): Double;
    procedure MixAndEmitSample;
    procedure UpdateNR52;
  public
    constructor Create;
    procedure Reset;
    procedure Update(Cycles: Cardinal);
    function Read(Addr: Word): Byte;
    procedure Write(Addr: Word; Value: Byte);
    property SampleRate: Integer read FSampleRate write FSampleRate;
    property OnSample: TAPUSampleProc read FOnSample write FOnSample;
  end;

implementation

uses
{$IFDEF FPC}
  Math;
{$ELSE}
  System.Math;
{$ENDIF}

constructor TGBAPU.Create;
begin
  inherited Create;
  FSampleRate := 48000;
  Reset;
end;

function TGBAPU.GetRegIndex(Addr: Word): Integer;
begin
  Result := Integer(Addr) - $FF10;
end;

function TGBAPU.IsApuReg(Addr: Word): Boolean;
begin
  Result := (Addr >= $FF10) and (Addr <= $FF3F);
end;

function TGBAPU.IsDAC1On: Boolean;
begin
  Result := (FRegs[$12 - $10] and $F8) <> 0;
end;

function TGBAPU.IsDAC2On: Boolean;
begin
  Result := (FRegs[$17 - $10] and $F8) <> 0;
end;

function TGBAPU.IsDAC3On: Boolean;
begin
  Result := (FRegs[$1A - $10] and $80) <> 0;
end;

function TGBAPU.IsDAC4On: Boolean;
begin
  Result := (FRegs[$21 - $10] and $F8) <> 0;
end;

function TGBAPU.Ch1FreqReg: Integer;
begin
  Result := FRegs[$13 - $10] or ((FRegs[$14 - $10] and 7) shl 8);
end;

function TGBAPU.Ch2FreqReg: Integer;
begin
  Result := FRegs[$18 - $10] or ((FRegs[$19 - $10] and 7) shl 8);
end;

function TGBAPU.Ch3FreqReg: Integer;
begin
  Result := FRegs[$1D - $10] or ((FRegs[$1E - $10] and 7) shl 8);
end;

procedure TGBAPU.ReloadCh1Timer;
var
  D: Integer;
begin
  D := 2048 - Ch1FreqReg;
  if D <= 0 then
    D := 1;
  FCh1.FreqTimer := D * 4;
end;

procedure TGBAPU.ReloadCh2Timer;
var
  D: Integer;
begin
  D := 2048 - Ch2FreqReg;
  if D <= 0 then
    D := 1;
  FCh2.FreqTimer := D * 4;
end;

procedure TGBAPU.ReloadCh3Timer;
var
  D: Integer;
begin
  D := 2048 - Ch3FreqReg;
  if D <= 0 then
    D := 1;
  FCh3.FreqTimer := D * 2;
end;

procedure TGBAPU.ReloadCh4Timer;
var
  DivCode, Shift: Integer;
begin
  DivCode := FRegs[$22 - $10] and 7;
  Shift := (FRegs[$22 - $10] shr 4) and $0F;
  FCh4.FreqTimer := NOISE_DIVISOR[DivCode] shl Shift;
  if FCh4.FreqTimer <= 0 then
    FCh4.FreqTimer := 8;
end;

procedure TGBAPU.TriggerCh1;
var
  DisableNow: Boolean;
begin
  DisableNow := False;
  FCh1.Enabled := FMasterEnabled and IsDAC1On;
  if FCh1.LengthCounter = 0 then
    FCh1.LengthCounter := 64;
  FCh1.DutyStep := 0;
  ReloadCh1Timer;
  FCh1.EnvelopeVolume := (FRegs[$12 - $10] shr 4) and $0F;
  FCh1.EnvelopePeriod := FRegs[$12 - $10] and 7;
  FCh1.EnvelopeCounter := EffectiveEnvelopePeriod(FCh1.EnvelopePeriod);
  FCh1.EnvelopeIncrease := (FRegs[$12 - $10] and 8) <> 0;
  FCh1.SweepShadow := Ch1FreqReg;
  FCh1.SweepPeriod := (FRegs[$10 - $10] shr 4) and 7;
  FCh1.SweepCounter := EffectiveEnvelopePeriod(FCh1.SweepPeriod);
  FCh1.SweepShift := FRegs[$10 - $10] and 7;
  FCh1.SweepNegate := (FRegs[$10 - $10] and 8) <> 0;
  FCh1.SweepDidNegate := False;
  FCh1.SweepEnabled := (FCh1.SweepPeriod <> 0) or (FCh1.SweepShift <> 0);
  if FCh1.SweepShift <> 0 then
    ComputeSweepTarget(DisableNow);
  if DisableNow then
    FCh1.Enabled := False;
end;

procedure TGBAPU.TriggerCh2;
begin
  FCh2.Enabled := FMasterEnabled and IsDAC2On;
  if FCh2.LengthCounter = 0 then
    FCh2.LengthCounter := 64;
  FCh2.DutyStep := 0;
  ReloadCh2Timer;
  FCh2.EnvelopeVolume := (FRegs[$17 - $10] shr 4) and $0F;
  FCh2.EnvelopePeriod := FRegs[$17 - $10] and 7;
  FCh2.EnvelopeCounter := EffectiveEnvelopePeriod(FCh2.EnvelopePeriod);
  FCh2.EnvelopeIncrease := (FRegs[$17 - $10] and 8) <> 0;
end;

procedure TGBAPU.TriggerCh3;
begin
  FCh3.Enabled := FMasterEnabled and IsDAC3On;
  if FCh3.LengthCounter = 0 then
    FCh3.LengthCounter := 256;
  FCh3.Position := 0;
  LoadCh3SampleBuffer;
  ReloadCh3Timer;
end;

procedure TGBAPU.TriggerCh4;
begin
  FCh4.Enabled := FMasterEnabled and IsDAC4On;
  if FCh4.LengthCounter = 0 then
    FCh4.LengthCounter := 64;
  FCh4.LFSR := $7FFF;
  ReloadCh4Timer;
  FCh4.EnvelopeVolume := (FRegs[$21 - $10] shr 4) and $0F;
  FCh4.EnvelopePeriod := FRegs[$21 - $10] and 7;
  FCh4.EnvelopeCounter := EffectiveEnvelopePeriod(FCh4.EnvelopePeriod);
  FCh4.EnvelopeIncrease := (FRegs[$21 - $10] and 8) <> 0;
end;

function TGBAPU.EffectiveEnvelopePeriod(APeriod: Integer): Integer;
begin
  if APeriod = 0 then
    Result := 8
  else
    Result := APeriod;
end;

function TGBAPU.LengthWillClockNext: Boolean;
begin
  { Frame sequencer clocks length on steps 0/2/4/6. }
  Result := (FFrameSeqStep and 1) = 1;
end;

procedure TGBAPU.LoadCh3SampleBuffer;
var
  Pos: Integer;
  WaveByte: Byte;
begin
  Pos := FCh3.Position and 31;
  FCh3.CurrentByteIndex := (Pos shr 1) and $0F;
  WaveByte := FRegs[$30 - $10 + FCh3.CurrentByteIndex];
  if (Pos and 1) = 0 then
    FCh3.SampleBuffer := (WaveByte shr 4) and $0F
  else
    FCh3.SampleBuffer := WaveByte and $0F;
end;

procedure TGBAPU.ClockLength;
begin
  if FCh1.LengthEnabled and FCh1.Enabled and (FCh1.LengthCounter > 0) then
  begin
    Dec(FCh1.LengthCounter);
    if FCh1.LengthCounter = 0 then
      FCh1.Enabled := False;
  end;
  if FCh2.LengthEnabled and FCh2.Enabled and (FCh2.LengthCounter > 0) then
  begin
    Dec(FCh2.LengthCounter);
    if FCh2.LengthCounter = 0 then
      FCh2.Enabled := False;
  end;
  if FCh3.LengthEnabled and FCh3.Enabled and (FCh3.LengthCounter > 0) then
  begin
    Dec(FCh3.LengthCounter);
    if FCh3.LengthCounter = 0 then
      FCh3.Enabled := False;
  end;
  if FCh4.LengthEnabled and FCh4.Enabled and (FCh4.LengthCounter > 0) then
  begin
    Dec(FCh4.LengthCounter);
    if FCh4.LengthCounter = 0 then
      FCh4.Enabled := False;
  end;
end;

function TGBAPU.ComputeSweepTarget(var DisableChannel: Boolean): Integer;
var
  Freq, Shift: Integer;
begin
  DisableChannel := False;
  Freq := FCh1.SweepShadow;
  Shift := FRegs[$10 - $10] and 7;
  if Shift = 0 then
    Exit(Freq);
  if (FRegs[$10 - $10] and 8) = 0 then
    Result := Freq + (Freq shr Shift)
  else
  begin
    FCh1.SweepDidNegate := True;
    Result := Freq - (Freq shr Shift);
  end;
  if Result > 2047 then
  begin
    DisableChannel := True;
    Result := 2047;
  end;
end;

procedure TGBAPU.ClockSweep;
var
  SweepPeriod, NewFreq: Integer;
  DisableCh1: Boolean;
begin
  if not FCh1.Enabled or not FCh1.SweepEnabled then
    Exit;
  Dec(FCh1.SweepCounter);
  if FCh1.SweepCounter > 0 then
    Exit;
  SweepPeriod := EffectiveEnvelopePeriod(FCh1.SweepPeriod);
  FCh1.SweepCounter := SweepPeriod;
  if FCh1.SweepPeriod = 0 then
    Exit;

  NewFreq := ComputeSweepTarget(DisableCh1);
  if DisableCh1 or (NewFreq > 2047) then
  begin
    FCh1.Enabled := False;
    Exit;
  end;
  if FCh1.SweepShift <> 0 then
  begin
    FCh1.SweepShadow := NewFreq;
    FRegs[$13 - $10] := Byte(NewFreq and $FF);
    FRegs[$14 - $10] := (FRegs[$14 - $10] and $F8) or Byte((NewFreq shr 8) and 7);
    ReloadCh1Timer;
    ComputeSweepTarget(DisableCh1);
    if DisableCh1 then
      FCh1.Enabled := False;
  end;
end;

procedure TGBAPU.ClockEnvelope;
begin
  if FCh1.Enabled and (FCh1.EnvelopePeriod > 0) then
  begin
    Dec(FCh1.EnvelopeCounter);
    if FCh1.EnvelopeCounter <= 0 then
    begin
      FCh1.EnvelopeCounter := FCh1.EnvelopePeriod;
      if FCh1.EnvelopeCounter = 0 then
        FCh1.EnvelopeCounter := 8;
      if FCh1.EnvelopeIncrease then
      begin
        if FCh1.EnvelopeVolume < 15 then
          Inc(FCh1.EnvelopeVolume);
      end
      else if FCh1.EnvelopeVolume > 0 then
        Dec(FCh1.EnvelopeVolume);
    end;
  end;

  if FCh2.Enabled and (FCh2.EnvelopePeriod > 0) then
  begin
    Dec(FCh2.EnvelopeCounter);
    if FCh2.EnvelopeCounter <= 0 then
    begin
      FCh2.EnvelopeCounter := FCh2.EnvelopePeriod;
      if FCh2.EnvelopeCounter = 0 then
        FCh2.EnvelopeCounter := 8;
      if FCh2.EnvelopeIncrease then
      begin
        if FCh2.EnvelopeVolume < 15 then
          Inc(FCh2.EnvelopeVolume);
      end
      else if FCh2.EnvelopeVolume > 0 then
        Dec(FCh2.EnvelopeVolume);
    end;
  end;

  if FCh4.Enabled and (FCh4.EnvelopePeriod > 0) then
  begin
    Dec(FCh4.EnvelopeCounter);
    if FCh4.EnvelopeCounter <= 0 then
    begin
      FCh4.EnvelopeCounter := FCh4.EnvelopePeriod;
      if FCh4.EnvelopeCounter = 0 then
        FCh4.EnvelopeCounter := 8;
      if FCh4.EnvelopeIncrease then
      begin
        if FCh4.EnvelopeVolume < 15 then
          Inc(FCh4.EnvelopeVolume);
      end
      else if FCh4.EnvelopeVolume > 0 then
        Dec(FCh4.EnvelopeVolume);
    end;
  end;
end;

function TGBAPU.ApplyHighPass(InputValue: Integer; var PrevIn, PrevOut: Double): Integer;
const
  R = 0.996;
var
  X, Y: Double;
begin
  X := InputValue;
  Y := (X - PrevIn) + (R * PrevOut);
  PrevIn := X;
  PrevOut := Y;
  Result := EnsureRange(Round(Y), -32768, 32767);
end;

procedure TGBAPU.ClockFrameSequencer;
begin
  Inc(FFrameSeqStep);
  FFrameSeqStep := FFrameSeqStep and 7;

  if (FFrameSeqStep = 0) or (FFrameSeqStep = 2) or (FFrameSeqStep = 4) or (FFrameSeqStep = 6) then
    ClockLength;
  if (FFrameSeqStep = 2) or (FFrameSeqStep = 6) then
    ClockSweep;
  if FFrameSeqStep = 7 then
    ClockEnvelope;
end;

function TGBAPU.SampleCh1: Integer;
var
  Duty: Integer;
begin
  if not FCh1.Enabled then
    Exit(0);
  if not IsDAC1On then
    Exit(0);
  Duty := (FRegs[$11 - $10] shr 6) and 3;
  if DUTY_TABLE[Duty, FCh1.DutyStep and 7] <> 0 then
    Result := EnsureRange(FCh1.EnvelopeVolume, 0, 15)
  else
    Result := 0;
end;

function TGBAPU.SampleCh2: Integer;
var
  Duty: Integer;
begin
  if not FCh2.Enabled then
    Exit(0);
  if not IsDAC2On then
    Exit(0);
  Duty := (FRegs[$16 - $10] shr 6) and 3;
  if DUTY_TABLE[Duty, FCh2.DutyStep and 7] <> 0 then
    Result := EnsureRange(FCh2.EnvelopeVolume, 0, 15)
  else
    Result := 0;
end;

function TGBAPU.SampleCh3: Integer;
var
  Raw4: Integer;
  ShiftCode: Integer;
begin
  if not FCh3.Enabled then
    Exit(0);
  if not IsDAC3On then
    Exit(0);

  Raw4 := FCh3.SampleBuffer and $0F;

  ShiftCode := (FRegs[$1C - $10] shr 5) and 3;
  case ShiftCode of
    0: Raw4 := 0;
    1: ; { 100% }
    2: Raw4 := Raw4 shr 1; { 50% }
    3: Raw4 := Raw4 shr 2; { 25% }
  end;
  Result := EnsureRange(Raw4, 0, 15);
end;

function TGBAPU.SampleCh4: Integer;
var
  Bit0: Integer;
begin
  if not FCh4.Enabled then
    Exit(0);
  if not IsDAC4On then
    Exit(0);
  Bit0 := Integer((not FCh4.LFSR) and 1);
  if Bit0 <> 0 then
    Result := EnsureRange(FCh4.EnvelopeVolume, 0, 15)
  else
    Result := 0;
end;

function TGBAPU.DigitalToAnalog(ADigital4: Integer): Double;
begin
  { GB DAC maps 0..15 into roughly -1..+1 domain. }
  Result := (EnsureRange(ADigital4, 0, 15) / 7.5) - 1.0;
end;

procedure TGBAPU.MixAndEmitSample;
var
  C1, C2, C3, C4: Integer;
  L, R: Double;
  VolL, VolR: Double;
  OutL, OutR: Integer;
begin
  if not Assigned(FOnSample) then
    Exit;
  if not FMasterEnabled then
  begin
    FOnSample(0, 0);
    Exit;
  end;

  C1 := SampleCh1;
  C2 := SampleCh2;
  C3 := SampleCh3;
  C4 := SampleCh4;

  L := 0.0;
  R := 0.0;
  if (FRegs[$25 - $10] and $10) <> 0 then L := L + DigitalToAnalog(C1);
  if (FRegs[$25 - $10] and $20) <> 0 then L := L + DigitalToAnalog(C2);
  if (FRegs[$25 - $10] and $40) <> 0 then L := L + DigitalToAnalog(C3);
  if (FRegs[$25 - $10] and $80) <> 0 then L := L + DigitalToAnalog(C4);
  if (FRegs[$25 - $10] and $01) <> 0 then R := R + DigitalToAnalog(C1);
  if (FRegs[$25 - $10] and $02) <> 0 then R := R + DigitalToAnalog(C2);
  if (FRegs[$25 - $10] and $04) <> 0 then R := R + DigitalToAnalog(C3);
  if (FRegs[$25 - $10] and $08) <> 0 then R := R + DigitalToAnalog(C4);

  L := L / 4.0;
  R := R / 4.0;
  VolR := ((FRegs[$24 - $10] and 7) + 1) / 8.0;
  VolL := (((FRegs[$24 - $10] shr 4) and 7) + 1) / 8.0;
  OutL := EnsureRange(Round(L * VolL * 32767.0), -32768, 32767);
  OutR := EnsureRange(Round(R * VolR * 32767.0), -32768, 32767);
  OutL := ApplyHighPass(OutL, FHPPrevInL, FHPPrevOutL);
  OutR := ApplyHighPass(OutR, FHPPrevInR, FHPPrevOutR);
  FOnSample(SmallInt(OutL), SmallInt(OutR));
end;

procedure TGBAPU.UpdateNR52;
begin
  FRegs[$26 - $10] := (FRegs[$26 - $10] and $F0) or
                      (Ord(FCh1.Enabled) shl 0) or
                      (Ord(FCh2.Enabled) shl 1) or
                      (Ord(FCh3.Enabled) shl 2) or
                      (Ord(FCh4.Enabled) shl 3);
end;

procedure TGBAPU.Reset;
var
  I: Integer;
begin
  for I := 0 to High(FRegs) do
    FRegs[I] := 0;

  { DMG post-boot defaults }
  FRegs[$10 - $10] := $80;
  FRegs[$11 - $10] := $BF;
  FRegs[$12 - $10] := $F3;
  FRegs[$14 - $10] := $BF;
  FRegs[$16 - $10] := $3F;
  FRegs[$17 - $10] := $00;
  FRegs[$19 - $10] := $BF;
  FRegs[$1A - $10] := $7F;
  FRegs[$1B - $10] := $FF;
  FRegs[$1C - $10] := $9F;
  FRegs[$1E - $10] := $BF;
  FRegs[$20 - $10] := $FF;
  FRegs[$21 - $10] := $00;
  FRegs[$22 - $10] := $00;
  FRegs[$23 - $10] := $BF;
  FRegs[$24 - $10] := $77;
  FRegs[$25 - $10] := $F3;
  FRegs[$26 - $10] := $F0;

  FCycleFrac := 0.0;
  FSampleCycleAcc := 0.0;
  FFrameSeqCycles := 0;
  FFrameSeqStep := 7;
  FMasterEnabled := True;
  FHPPrevInL := 0;
  FHPPrevInR := 0;
  FHPPrevOutL := 0;
  FHPPrevOutR := 0;
  FillChar(FCh1, SizeOf(FCh1), 0);
  FillChar(FCh2, SizeOf(FCh2), 0);
  FillChar(FCh3, SizeOf(FCh3), 0);
  FillChar(FCh4, SizeOf(FCh4), 0);
  FCh4.LFSR := $7FFF;
  ReloadCh1Timer;
  ReloadCh2Timer;
  ReloadCh3Timer;
  ReloadCh4Timer;
  UpdateNR52;
end;

procedure TGBAPU.Update(Cycles: Cardinal);
var
  I: Integer;
  XorBit: Integer;
  CyclesPerSample: Double;
begin
  if FSampleRate <= 0 then
    Exit;

  FFrameSeqCycles := FFrameSeqCycles + Integer(Cycles);
  while FFrameSeqCycles >= 8192 do
  begin
    Dec(FFrameSeqCycles, 8192);
    ClockFrameSequencer;
  end;

  if FCh1.Enabled then
  begin
    FCh1.FreqTimer := FCh1.FreqTimer - Integer(Cycles);
    while FCh1.FreqTimer <= 0 do
    begin
      ReloadCh1Timer;
      Inc(FCh1.DutyStep);
      FCh1.DutyStep := FCh1.DutyStep and 7;
    end;
  end;

  if FCh2.Enabled then
  begin
    FCh2.FreqTimer := FCh2.FreqTimer - Integer(Cycles);
    while FCh2.FreqTimer <= 0 do
    begin
      ReloadCh2Timer;
      Inc(FCh2.DutyStep);
      FCh2.DutyStep := FCh2.DutyStep and 7;
    end;
  end;

  if FCh3.Enabled then
  begin
    FCh3.FreqTimer := FCh3.FreqTimer - Integer(Cycles);
    while FCh3.FreqTimer <= 0 do
    begin
      ReloadCh3Timer;
      Inc(FCh3.Position);
      FCh3.Position := FCh3.Position and 31;
      LoadCh3SampleBuffer;
    end;
  end;

  if FCh4.Enabled then
  begin
    FCh4.FreqTimer := FCh4.FreqTimer - Integer(Cycles);
    while FCh4.FreqTimer <= 0 do
    begin
      ReloadCh4Timer;
      XorBit := (FCh4.LFSR and 1) xor ((FCh4.LFSR shr 1) and 1);
      FCh4.LFSR := (FCh4.LFSR shr 1) or (Word(XorBit) shl 14);
      if (FRegs[$22 - $10] and $08) <> 0 then
      begin
        I := FCh4.LFSR and (not (1 shl 6));
        FCh4.LFSR := Word(I or (XorBit shl 6));
      end;
    end;
  end;

  FCycleFrac := FCycleFrac + Cycles;
  CyclesPerSample := GB_CPU_HZ / FSampleRate;
  while FCycleFrac >= CyclesPerSample do
  begin
    FCycleFrac := FCycleFrac - CyclesPerSample;
    MixAndEmitSample;
  end;

  UpdateNR52;
end;

function TGBAPU.Read(Addr: Word): Byte;
var
  I, CurWaveIndex: Integer;
begin
  if not IsApuReg(Addr) then
    Exit($FF);
  I := GetRegIndex(Addr);

  case Addr of
    $FF10: Result := FRegs[I] or $80;
    $FF11, $FF16: Result := FRegs[I] or $3F;
    $FF12, $FF17, $FF1A, $FF1C, $FF21, $FF22, $FF24, $FF25: Result := FRegs[I];
    $FF13, $FF15, $FF18, $FF1B, $FF1D, $FF1F, $FF20, $FF23: Result := $FF;
    $FF14, $FF19, $FF1E: Result := FRegs[I] or $BF;
    $FF26:
      begin
        UpdateNR52;
        Result := (FRegs[I] and $8F) or $70;
      end;
    $FF30..$FF3F:
      begin
        if FCh3.Enabled and IsDAC3On then
        begin
          CurWaveIndex := FCh3.CurrentByteIndex and $0F;
          Result := FRegs[$30 - $10 + CurWaveIndex];
        end
        else
          Result := FRegs[I];
      end;
  else
    Result := FRegs[I];
  end;
end;

procedure TGBAPU.Write(Addr: Word; Value: Byte);
var
  I, CurWaveIndex: Integer;
  OldLenEnable, NewLenEnable, NeedExtraLenClock: Boolean;
begin
  if not IsApuReg(Addr) then
    Exit;

  I := GetRegIndex(Addr);

  if (not FMasterEnabled) and (Addr <> $FF26) and (Addr < $FF30) then
  begin
    if (Addr = $FF11) or (Addr = $FF16) or (Addr = $FF1B) or (Addr = $FF20) then
      FRegs[I] := Value;
    Exit;
  end;

  case Addr of
    $FF10:
      begin
        { NR10 quirk: clearing negate after it has been used disables CH1. }
        if FCh1.SweepDidNegate and ((FRegs[$10 - $10] and 8) <> 0) and ((Value and 8) = 0) then
          FCh1.Enabled := False;
        FRegs[I] := Value and $7F;
        FCh1.SweepPeriod := (FRegs[I] shr 4) and 7;
        FCh1.SweepShift := FRegs[I] and 7;
        FCh1.SweepNegate := (FRegs[I] and 8) <> 0;
      end;
    $FF11:
      begin
        FRegs[I] := Value;
        FCh1.LengthCounter := 64 - (Value and $3F);
      end;
    $FF12:
      begin
        FRegs[I] := Value;
        if not IsDAC1On then
          FCh1.Enabled := False;
      end;
    $FF13: FRegs[I] := Value;
    $FF14:
      begin
        NeedExtraLenClock := LengthWillClockNext;
        OldLenEnable := FCh1.LengthEnabled;
        NewLenEnable := (Value and $40) <> 0;
        if (not OldLenEnable) and NewLenEnable and NeedExtraLenClock and (FCh1.LengthCounter > 0) then
        begin
          Dec(FCh1.LengthCounter);
          if FCh1.LengthCounter = 0 then
            FCh1.Enabled := False;
        end;
        FRegs[I] := Value;
        FCh1.LengthEnabled := NewLenEnable;
        if (Value and $80) <> 0 then
        begin
          TriggerCh1;
          if FCh1.LengthEnabled and NeedExtraLenClock and (FCh1.LengthCounter > 0) then
          begin
            Dec(FCh1.LengthCounter);
            if FCh1.LengthCounter = 0 then
              FCh1.Enabled := False;
          end;
        end;
      end;

    $FF16:
      begin
        FRegs[I] := Value;
        FCh2.LengthCounter := 64 - (Value and $3F);
      end;
    $FF17:
      begin
        FRegs[I] := Value;
        if not IsDAC2On then
          FCh2.Enabled := False;
      end;
    $FF18: FRegs[I] := Value;
    $FF19:
      begin
        NeedExtraLenClock := LengthWillClockNext;
        OldLenEnable := FCh2.LengthEnabled;
        NewLenEnable := (Value and $40) <> 0;
        if (not OldLenEnable) and NewLenEnable and NeedExtraLenClock and (FCh2.LengthCounter > 0) then
        begin
          Dec(FCh2.LengthCounter);
          if FCh2.LengthCounter = 0 then
            FCh2.Enabled := False;
        end;
        FRegs[I] := Value;
        FCh2.LengthEnabled := NewLenEnable;
        if (Value and $80) <> 0 then
        begin
          TriggerCh2;
          if FCh2.LengthEnabled and NeedExtraLenClock and (FCh2.LengthCounter > 0) then
          begin
            Dec(FCh2.LengthCounter);
            if FCh2.LengthCounter = 0 then
              FCh2.Enabled := False;
          end;
        end;
      end;

    $FF1A:
      begin
        FRegs[I] := Value and $80;
        if not IsDAC3On then
          FCh3.Enabled := False;
      end;
    $FF1B:
      begin
        FRegs[I] := Value;
        FCh3.LengthCounter := 256 - Value;
      end;
    $FF1C: FRegs[I] := Value and $60;
    $FF1D: FRegs[I] := Value;
    $FF1E:
      begin
        NeedExtraLenClock := LengthWillClockNext;
        OldLenEnable := FCh3.LengthEnabled;
        NewLenEnable := (Value and $40) <> 0;
        if (not OldLenEnable) and NewLenEnable and NeedExtraLenClock and (FCh3.LengthCounter > 0) then
        begin
          Dec(FCh3.LengthCounter);
          if FCh3.LengthCounter = 0 then
            FCh3.Enabled := False;
        end;
        FRegs[I] := Value;
        FCh3.LengthEnabled := NewLenEnable;
        if (Value and $80) <> 0 then
        begin
          TriggerCh3;
          if FCh3.LengthEnabled and NeedExtraLenClock and (FCh3.LengthCounter > 0) then
          begin
            Dec(FCh3.LengthCounter);
            if FCh3.LengthCounter = 0 then
              FCh3.Enabled := False;
          end;
        end;
      end;

    $FF20:
      begin
        FRegs[I] := Value and $3F;
        FCh4.LengthCounter := 64 - (Value and $3F);
      end;
    $FF21:
      begin
        FRegs[I] := Value;
        if not IsDAC4On then
          FCh4.Enabled := False;
      end;
    $FF22:
      begin
        FRegs[I] := Value;
        ReloadCh4Timer;
      end;
    $FF23:
      begin
        NeedExtraLenClock := LengthWillClockNext;
        OldLenEnable := FCh4.LengthEnabled;
        NewLenEnable := (Value and $40) <> 0;
        if (not OldLenEnable) and NewLenEnable and NeedExtraLenClock and (FCh4.LengthCounter > 0) then
        begin
          Dec(FCh4.LengthCounter);
          if FCh4.LengthCounter = 0 then
            FCh4.Enabled := False;
        end;
        FRegs[I] := Value;
        FCh4.LengthEnabled := NewLenEnable;
        if (Value and $80) <> 0 then
        begin
          TriggerCh4;
          if FCh4.LengthEnabled and NeedExtraLenClock and (FCh4.LengthCounter > 0) then
          begin
            Dec(FCh4.LengthCounter);
            if FCh4.LengthCounter = 0 then
              FCh4.Enabled := False;
          end;
        end;
      end;

    $FF24, $FF25:
      FRegs[I] := Value;

    $FF26:
      begin
        FMasterEnabled := (Value and $80) <> 0;
        if not FMasterEnabled then
        begin
          FillChar(FRegs[0], $16, 0); { FF10..FF25 clear when power off }
          FillChar(FCh1, SizeOf(FCh1), 0);
          FillChar(FCh2, SizeOf(FCh2), 0);
          FillChar(FCh3, SizeOf(FCh3), 0);
          FillChar(FCh4, SizeOf(FCh4), 0);
          FCh4.LFSR := $7FFF;
          FHPPrevInL := 0;
          FHPPrevInR := 0;
          FHPPrevOutL := 0;
          FHPPrevOutR := 0;
        end;
        FRegs[I] := (Value and $80) or $70;
      end;

    $FF30..$FF3F:
      begin
        if FCh3.Enabled and IsDAC3On then
        begin
          CurWaveIndex := FCh3.CurrentByteIndex and $0F;
          FRegs[$30 - $10 + CurWaveIndex] := Value;
          LoadCh3SampleBuffer;
        end
        else
          FRegs[I] := Value;
      end;
  else
    FRegs[I] := Value;
  end;

  UpdateNR52;
end;

end.
