unit Common;

interface

type
  TByte = System.Byte;
  TWord = System.Word;
  TLongWord = System.LongWord;

  TRegisters = record
    A: TByte;
    F: TByte;
    B: TByte;
    C: TByte;
    D: TByte;
    E: TByte;
    H: TByte;
    L: TByte;
    SP: TWord;
    PC: TWord;
  end;

const
  MemorySize = 65536;
  FrameCycles = 70224;

implementation

end.
