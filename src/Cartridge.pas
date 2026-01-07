unit Cartridge;

interface

uses
  System.SysUtils;

type
  TCartridge = class
  private
    FData: TBytes;
  public
    function LoadFromFile(const FileName: string): Boolean;
    function Data: TBytes;
  end;

implementation

function TCartridge.LoadFromFile(const FileName: string): Boolean;
begin
  if not FileExists(FileName) then
    Exit(False);
  FData := TFile.ReadAllBytes(FileName);
  Result := Length(FData) > 0;
end;

function TCartridge.Data: TBytes;
begin
  Result := FData;
end;

end.
