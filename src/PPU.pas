unit PPU;

interface

type
  TPPU = class
  private
    FCycles: Integer;
  public
    procedure Reset;
    procedure Step(Cycles: Integer);
    property Cycles: Integer read FCycles;
  end;

implementation

procedure TPPU.Reset;
begin
  FCycles := 0;
end;

procedure TPPU.Step(Cycles: Integer);
begin
  Inc(FCycles, Cycles);
end;

end.
