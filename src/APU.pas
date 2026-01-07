unit APU;

interface

type
  TAPU = class
  private
    FCycles: Integer;
  public
    procedure Reset;
    procedure Step(Cycles: Integer);
    property Cycles: Integer read FCycles;
  end;

implementation

procedure TAPU.Reset;
begin
  FCycles := 0;
end;

procedure TAPU.Step(Cycles: Integer);
begin
  Inc(FCycles, Cycles);
end;

end.
