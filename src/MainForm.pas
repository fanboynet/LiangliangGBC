unit MainForm;

interface

uses
  System.Classes,
  System.SysUtils,
  Vcl.ExtCtrls,
  Vcl.Forms,
  Vcl.Graphics,
  Emulator,
  PPU;

type
  TMainForm = class(TForm)
  private
    FEmulator: TGBEmulator;
    FImage: TImage;
    FTimer: TTimer;
    FBitmap: TBitmap;
    procedure OnTimer(Sender: TObject);
    procedure RenderFrame;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

implementation

type
  PByteArray = ^TByteArray;
  TByteArray = array[0..0] of Byte;

constructor TMainForm.Create(AOwner: TComponent);
var
  RomPath: string;
begin
  inherited Create(AOwner);
  Caption := 'LiangliangGBC';
  ClientWidth := 160 * 2;
  ClientHeight := 144 * 2;

  FImage := TImage.Create(Self);
  FImage.Parent := Self;
  FImage.Align := alClient;
  FImage.Stretch := True;

  FBitmap := TBitmap.Create;
  FBitmap.PixelFormat := pf24bit;
  FBitmap.SetSize(160, 144);
  FImage.Picture.Bitmap := FBitmap;

  FEmulator := TGBEmulator.Create;
  if ParamCount > 0 then
  begin
    RomPath := ParamStr(1);
    if not FEmulator.LoadCartridge(RomPath) then
      Caption := Caption + ' - Failed to load ROM';
  end
  else
  begin
    Caption := Caption + ' - No ROM path provided';
  end;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 16;
  FTimer.OnTimer := OnTimer;
  FTimer.Enabled := True;
end;

destructor TMainForm.Destroy;
begin
  FTimer.Free;
  FBitmap.Free;
  FEmulator.Free;
  inherited Destroy;
end;

procedure TMainForm.OnTimer(Sender: TObject);
begin
  FEmulator.RunFrame;
  RenderFrame;
end;

procedure TMainForm.RenderFrame;
var
  Frame: TFrameBuffer;
  X: Integer;
  Y: Integer;
  Row: PByteArray;
  Color: TRGBColor;
  R, G, B: Byte;
  Index: Integer;
begin
  Frame := FEmulator.PPU.FrameBuffer;
  for Y := 0 to 143 do
  begin
    Row := PByteArray(FBitmap.ScanLine[Y]);
    for X := 0 to 159 do
    begin
      Color := Frame[Y, X];
      R := Byte((Color shr 10) and $1F);
      G := Byte((Color shr 5) and $1F);
      B := Byte(Color and $1F);
      R := Byte((Integer(R) * 255) div 31);
      G := Byte((Integer(G) * 255) div 31);
      B := Byte((Integer(B) * 255) div 31);
      Index := X * 3;
      Row[Index] := B;
      Row[Index + 1] := G;
      Row[Index + 2] := R;
    end;
  end;
  FImage.Invalidate;
end;

end.
