program GBCEmu;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Emulator;

var
  EmulatorInstance: TGBEmulator;
  RomPath: string;
begin
  try
    EmulatorInstance := TGBEmulator.Create;
    try
      if ParamCount > 0 then
      begin
        RomPath := ParamStr(1);
        if EmulatorInstance.LoadCartridge(RomPath) then
          Writeln('Loaded ROM: ', RomPath)
        else
          Writeln('Failed to load ROM: ', RomPath);
      end
      else
      begin
        Writeln('Usage: GBCEmu <path_to_rom>');
      end;
    finally
      EmulatorInstance.Free;
    end;
  except
    on E: Exception do
      Writeln(E.ClassName, ': ', E.Message);
  end;
end.
