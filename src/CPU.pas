unit CPU;

interface

uses
  Common, Memory;

type
  TCPU = class
  private
    FRegisters: TRegisters;
    FMemory: TMemory;
    FCycles: Integer;
  public
    constructor Create(AMemory: TMemory);
    procedure Reset;
    function Step: Integer;
    property Registers: TRegisters read FRegisters;
    property Cycles: Integer read FCycles;
  end;

implementation

constructor TCPU.Create(AMemory: TMemory);
begin
  inherited Create;
  FMemory := AMemory;
  Reset;
end;

procedure TCPU.Reset;
begin
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FRegisters.SP := $FFFE;
  FRegisters.PC := $0100;
  FCycles := 0;
end;

function TCPU.Step: Integer;
var
  OpCode: TByte;
begin
  OpCode := FMemory.ReadByte(FRegisters.PC);
  Inc(FRegisters.PC);
  Inc(FCycles, 4);
  Result := 4;
  case OpCode of
    $00: ;
  else
    ;
  end;
end;

end.
