unit APU;

interface

type
  TApuChannelState = record
    Enabled: Boolean;
    DACEnabled: Boolean;
    LengthCounter: Integer;
    LengthEnabled: Boolean;
    Frequency: Word;
  end;

  TAPU = class
  private
    FCycles: Integer;
    FFrameSequencer: Integer;
    FSequencerStep: Integer;
    FNR50: Byte;
    FNR51: Byte;
    FNR52: Byte;

    FCh1: TApuChannelState;
    FCh2: TApuChannelState;
    FCh3: TApuChannelState;
    FCh4: TApuChannelState;

    FNR10: Byte;
    FNR11: Byte;
    FNR12: Byte;
    FNR13: Byte;
    FNR14: Byte;

    FNR21: Byte;
    FNR22: Byte;
    FNR23: Byte;
    FNR24: Byte;

    FNR30: Byte;
    FNR31: Byte;
    FNR32: Byte;
    FNR33: Byte;
    FNR34: Byte;

    FNR41: Byte;
    FNR42: Byte;
    FNR43: Byte;
    FNR44: Byte;

    FWaveRAM: array[0..$0F] of Byte;

    procedure StepFrameSequencer;
    procedure ClockLengthCounters;
    procedure UpdateChannelEnable;
    function ChannelEnabled(const Channel: TApuChannelState): Boolean;
  public
    procedure Reset;
    procedure Step(Cycles: Integer);
    function ReadRegister(Address: Word): Byte;
    procedure WriteRegister(Address: Word; Value: Byte);
  TAPU = class
  private
    FCycles: Integer;
  public
    procedure Reset;
    procedure Step(Cycles: Integer);
    property Cycles: Integer read FCycles;
  end;

implementation

const
  SequencerRate = 8192;

procedure TAPU.Reset;
begin
  FCycles := 0;
  FFrameSequencer := 0;
  FSequencerStep := 0;
  FNR50 := 0;
  FNR51 := 0;
  FNR52 := $F1;

  FNR10 := 0;
  FNR11 := 0;
  FNR12 := 0;
  FNR13 := 0;
  FNR14 := 0;

  FNR21 := 0;
  FNR22 := 0;
  FNR23 := 0;
  FNR24 := 0;

  FNR30 := 0;
  FNR31 := 0;
  FNR32 := 0;
  FNR33 := 0;
  FNR34 := 0;

  FNR41 := 0;
  FNR42 := 0;
  FNR43 := 0;
  FNR44 := 0;

  FillChar(FCh1, SizeOf(FCh1), 0);
  FillChar(FCh2, SizeOf(FCh2), 0);
  FillChar(FCh3, SizeOf(FCh3), 0);
  FillChar(FCh4, SizeOf(FCh4), 0);
  FillChar(FWaveRAM, SizeOf(FWaveRAM), 0);
end;

function TAPU.ChannelEnabled(const Channel: TApuChannelState): Boolean;
begin
  Result := Channel.Enabled and Channel.DACEnabled;
end;

procedure TAPU.UpdateChannelEnable;
begin
  FNR52 := FNR52 and $F0;
  if ChannelEnabled(FCh1) then
    FNR52 := FNR52 or $01;
  if ChannelEnabled(FCh2) then
    FNR52 := FNR52 or $02;
  if ChannelEnabled(FCh3) then
    FNR52 := FNR52 or $04;
  if ChannelEnabled(FCh4) then
    FNR52 := FNR52 or $08;
end;

procedure TAPU.ClockLengthCounters;
begin
  if FCh1.LengthEnabled and (FCh1.LengthCounter > 0) then
  begin
    Dec(FCh1.LengthCounter);
    if FCh1.LengthCounter = 0 then
      FCh1.Enabled := False;
  end;
  if FCh2.LengthEnabled and (FCh2.LengthCounter > 0) then
  begin
    Dec(FCh2.LengthCounter);
    if FCh2.LengthCounter = 0 then
      FCh2.Enabled := False;
  end;
  if FCh3.LengthEnabled and (FCh3.LengthCounter > 0) then
  begin
    Dec(FCh3.LengthCounter);
    if FCh3.LengthCounter = 0 then
      FCh3.Enabled := False;
  end;
  if FCh4.LengthEnabled and (FCh4.LengthCounter > 0) then
  begin
    Dec(FCh4.LengthCounter);
    if FCh4.LengthCounter = 0 then
      FCh4.Enabled := False;
  end;
end;

procedure TAPU.StepFrameSequencer;
begin
  Inc(FSequencerStep);
  if FSequencerStep > 7 then
    FSequencerStep := 0;

  if (FSequencerStep mod 2) = 0 then
    ClockLengthCounters;

  UpdateChannelEnable;
end;

procedure TAPU.Step(Cycles: Integer);
var
  Remaining: Integer;
begin
  Inc(FCycles, Cycles);
  Remaining := Cycles;
  while Remaining > 0 do
  begin
    Inc(FFrameSequencer);
    if FFrameSequencer >= SequencerRate then
    begin
      FFrameSequencer := 0;
      StepFrameSequencer;
    end;
    Dec(Remaining);
  end;
end;

function TAPU.ReadRegister(Address: Word): Byte;
begin
  case Address of
    $FF10: Result := FNR10 or $80;
    $FF11: Result := FNR11 or $3F;
    $FF12: Result := FNR12;
    $FF13: Result := $FF;
    $FF14: Result := FNR14 or $BF;
    $FF16: Result := FNR21 or $3F;
    $FF17: Result := FNR22;
    $FF18: Result := $FF;
    $FF19: Result := FNR24 or $BF;
    $FF1A: Result := FNR30 or $7F;
    $FF1B: Result := $FF;
    $FF1C: Result := FNR32 or $9F;
    $FF1D: Result := $FF;
    $FF1E: Result := FNR34 or $BF;
    $FF20: Result := $FF;
    $FF21: Result := FNR42;
    $FF22: Result := FNR43;
    $FF23: Result := FNR44 or $BF;
    $FF24: Result := FNR50;
    $FF25: Result := FNR51;
    $FF26: Result := FNR52 or $70;
    $FF30..$FF3F: Result := FWaveRAM[Address - $FF30];
  else
    Result := $FF;
  end;
end;

procedure TAPU.WriteRegister(Address: Word; Value: Byte);
var
  ChannelIndex: Integer;
begin
  case Address of
    $FF10:
      FNR10 := Value;
    $FF11:
      begin
        FNR11 := Value;
        FCh1.LengthCounter := 64 - (Value and $3F);
      end;
    $FF12:
      begin
        FNR12 := Value;
        FCh1.DACEnabled := (Value and $F8) <> 0;
        if not FCh1.DACEnabled then
          FCh1.Enabled := False;
      end;
    $FF13:
      FNR13 := Value;
    $FF14:
      begin
        FNR14 := Value;
        FCh1.LengthEnabled := (Value and $40) <> 0;
        if (Value and $80) <> 0 then
          FCh1.Enabled := FCh1.DACEnabled;
        FCh1.Frequency := (Word(Value and $07) shl 8) or FNR13;
      end;
    $FF16:
      begin
        FNR21 := Value;
        FCh2.LengthCounter := 64 - (Value and $3F);
      end;
    $FF17:
      begin
        FNR22 := Value;
        FCh2.DACEnabled := (Value and $F8) <> 0;
        if not FCh2.DACEnabled then
          FCh2.Enabled := False;
      end;
    $FF18:
      FNR23 := Value;
    $FF19:
      begin
        FNR24 := Value;
        FCh2.LengthEnabled := (Value and $40) <> 0;
        if (Value and $80) <> 0 then
          FCh2.Enabled := FCh2.DACEnabled;
        FCh2.Frequency := (Word(Value and $07) shl 8) or FNR23;
      end;
    $FF1A:
      begin
        FNR30 := Value;
        FCh3.DACEnabled := (Value and $80) <> 0;
        if not FCh3.DACEnabled then
          FCh3.Enabled := False;
      end;
    $FF1B:
      begin
        FNR31 := Value;
        FCh3.LengthCounter := 256 - Value;
      end;
    $FF1C:
      FNR32 := Value;
    $FF1D:
      FNR33 := Value;
    $FF1E:
      begin
        FNR34 := Value;
        FCh3.LengthEnabled := (Value and $40) <> 0;
        if (Value and $80) <> 0 then
          FCh3.Enabled := FCh3.DACEnabled;
        FCh3.Frequency := (Word(Value and $07) shl 8) or FNR33;
      end;
    $FF20:
      begin
        FNR41 := Value;
        FCh4.LengthCounter := 64 - (Value and $3F);
      end;
    $FF21:
      begin
        FNR42 := Value;
        FCh4.DACEnabled := (Value and $F8) <> 0;
        if not FCh4.DACEnabled then
          FCh4.Enabled := False;
      end;
    $FF22:
      FNR43 := Value;
    $FF23:
      begin
        FNR44 := Value;
        FCh4.LengthEnabled := (Value and $40) <> 0;
        if (Value and $80) <> 0 then
          FCh4.Enabled := FCh4.DACEnabled;
      end;
    $FF24:
      FNR50 := Value;
    $FF25:
      FNR51 := Value;
    $FF26:
      begin
        FNR52 := Value and $80;
        if (Value and $80) = 0 then
        begin
          FNR10 := 0;
          FNR11 := 0;
          FNR12 := 0;
          FNR13 := 0;
          FNR14 := 0;
          FNR21 := 0;
          FNR22 := 0;
          FNR23 := 0;
          FNR24 := 0;
          FNR30 := 0;
          FNR31 := 0;
          FNR32 := 0;
          FNR33 := 0;
          FNR34 := 0;
          FNR41 := 0;
          FNR42 := 0;
          FNR43 := 0;
          FNR44 := 0;
          for ChannelIndex := 0 to High(FWaveRAM) do
            FWaveRAM[ChannelIndex] := 0;
          FillChar(FCh1, SizeOf(FCh1), 0);
          FillChar(FCh2, SizeOf(FCh2), 0);
          FillChar(FCh3, SizeOf(FCh3), 0);
          FillChar(FCh4, SizeOf(FCh4), 0);
        end;
      end;
    $FF30..$FF3F:
      FWaveRAM[Address - $FF30] := Value;
  end;
  UpdateChannelEnable;
procedure TAPU.Reset;
begin
  FCycles := 0;
end;

procedure TAPU.Step(Cycles: Integer);
begin
  Inc(FCycles, Cycles);
end;

end.
