unit SAVIUnit;
{
  Copyright (c) <2018> <Stuart "Stucuk" Carey>

  This software is provided 'as-is', without any express or implied
  warranty. In no event will the authors be held liable for any damages
  arising from the use of this software.

  Permission is granted to anyone to use this software for any purpose,
  including commercial applications, and to alter it and redistribute it
  freely, subject to the following restrictions:

  1. The origin of this software must not be misrepresented; you must not
  claim that you wrote the original software. If you use this software
  in a product, an acknowledgment in the product documentation would be
  appreciated but is not required.
  2. Altered source versions must be plainly marked as such, and must not be
  misrepresented as being the original software.
  3. This notice may not be removed or altered from any source distribution.


  // Altered by Krom for KaM Remake
}

interface
uses
  Windows, SysUtils, VFW, graphics, OALHandler;

type
  TSimpleTimer = class(TObject)
  protected
    fFrequency: Int64;
    fLastTime: Int64; // last system time
    FFrameTime: Extended;
  public
    constructor Create;
    procedure Refresh;
    property FrameTime: Extended read FFrameTime;
  end;

  TAVI_State = (aviStopped, aviPlaying, aviPaused, aviNoFile);

  TAVI_Video = record
    AFile: PAVIFile;
    Stream_Video, Stream_Audio: PAVIStream;
    Frame: PGETFRAME;
  end;

  TAVI = class(TObject)
  protected
    fFilename: AnsiString;
    fBMP: TBitmap;

    fAVI: TAVI_Video;
    fAVIState: TAVI_State;

    fFPS: Extended;

    fCurrFrame, fLastFrame, fFrameCount: Integer;
    fCurrentTime: Extended;
    fLoop: Boolean;
    fTimer: TSimpleTimer;

    fWidth, fHeight: Integer;

    fDoubleHeight: Boolean;
    fBlackLines: Boolean;
    fBrightness: ShortInt;

    fSound: TOALSound;

    fOnFinish: procedure;
    function GetFrame(aForce: Boolean): Boolean;
  public
    constructor Create;
    destructor Destroy; override;

    procedure VidInit(aFilename: AnsiString; aLoop, aDoubleHeight: Boolean; aOnFinish: Pointer);
    procedure VidFree;

    function RefreshFrame(aForce: Boolean): Boolean;

    function GetFrameRGB: Pointer;

    procedure Restart;
    procedure Play;
    procedure Pause;
    procedure Stop;

    property BMP: TBitmap read fBMP;
    property DoubleHeight: Boolean read fDoubleHeight write fDoubleHeight;
    property BlackLines: Boolean read fBlackLines write fBlackLines;

    property Width: Integer read fWidth;
    property Height: Integer read fHeight;
    property FrameCount: Integer read fFrameCount;
    property CurrentFrame: Integer read fCurrFrame;

    property AVIState: TAVI_State read fAVIState;

    property Brightness: ShortInt read fBrightness write fBrightness;
  end;

implementation
uses
   MMSystem, openal, Math;

//--------------------------------[ Utility ]---------------------------------//

procedure DrawFrameToBMP(aBMP: TBitmap; const aBitmapInfo: PBITMAPINFOHEADER);
var
  TempBMP: TBitmap;
  DC_Handle: HDC;
  DIB_Handle: HBITMAP;
begin
  TempBMP := TBitmap.Create;
  try
    DC_Handle := CreateDC('Display', nil, nil, nil);
    try
      DIB_Handle := CreateDIBitmap(DC_Handle, aBitmapInfo^, CBM_INIT,
        Pointer(Cardinal(aBitmapInfo) + aBitmapInfo.biSize + aBitmapInfo.biClrUsed * 4), PBITMAPINFO(aBitmapInfo)^,
        DIB_RGB_COLORS);
    finally
      DeleteDC(DC_Handle);
    end;

    TempBMP.Handle := DIB_Handle;

    aBMP.Height := aBitmapInfo.biHeight;
    aBMP.Width := aBitmapInfo.biWidth;
    aBMP.Canvas.Draw(0, 0, TempBMP);

    DeleteObject(DIB_Handle);
  finally
    TempBMP.Free;
  end;
end;

function BMPToRaw(aBMP: TBitmap): Pointer;
var
  Y: Integer;
  P: Pointer;
begin
  GetMem(Result, 3 * aBMP.Width * aBMP.Height);
  P := Result;
  for Y := aBMP.Height - 1 downto 0 do
  begin
    CopyMemory(P, aBMP.ScanLine[Y], aBMP.Width * 3);
    Inc(Cardinal(P), aBMP.Width * 3);
  end;
end;

function SetRGBTriple(aR, aG, aB: Byte): TRGBTriple;
begin
  Result.rgbtRed := aR;
  Result.rgbtGreen := aG;
  Result.rgbtBlue := aB;
end;

function GetVideoAverage(aBMP: TBitmap; aX: Integer; aSL1, aSL2: Pointer): TRGBTriple;
var
  A, aB: TRGBTriple;
begin
  if Assigned(aSL1) then
    A := PRGBTriple(Cardinal(aSL1) + 3 * aX)^
  else
    A := SetRGBTriple(0, 0, 0);

  if Assigned(aSL2) then
    aB := PRGBTriple(Cardinal(aSL2) + 3 * aX)^
  else
    aB := SetRGBTriple(0, 0, 0);

  Result.rgbtRed := Integer(A.rgbtRed + aB.rgbtRed) div 2;
  Result.rgbtGreen := Integer(A.rgbtGreen + aB.rgbtGreen) div 2;
  Result.rgbtBlue := Integer(A.rgbtBlue + aB.rgbtBlue) div 2;
end;

procedure DoubleVideoFrame(aBMP: TBitmap; aBlackLines: Boolean);
var
  aX, Y, OY: Integer;
  P: PRGBTriple;
  aSL1, aSL2: Pointer;
begin
  OY := aBMP.Height;
  aBMP.Height := aBMP.Height * 2;
  for Y := OY - 1 downto 0 do
    CopyMemory(aBMP.ScanLine[(Y + 1) * 2 - 1], aBMP.ScanLine[Y], aBMP.Width * 3);

  if aBlackLines then
  begin
    for Y := 0 to OY - 1 do
      ZeroMemory(aBMP.ScanLine[Y * 2], aBMP.Width * 3);
    Exit;
  end;

  for Y := 0 to OY - 1 do
  begin
    P := aBMP.ScanLine[Y * 2];

    if (Y - 1) >= 0 then
      aSL1 := aBMP.ScanLine[Y * 2 - 1]
    else
      aSL1 := Nil;

    if (Y + 1) < aBMP.Height then
      aSL2 := aBMP.ScanLine[Y * 2 + 1]
    else
      aSL2 := Nil;

    for aX := 0 to aBMP.Width - 1 do
    begin
      P^ := GetVideoAverage(aBMP, aX, aSL1, aSL2);
      Inc(Cardinal(P), 3);
    end;
  end;
end;

procedure ApplyBrightness(aBMP: TBitmap; aBrightness: ShortInt);
var
  aX, Y: Integer;
  P: PRGBTriple;
begin
  for Y := 0 to aBMP.Height - 1 do
  begin
    P := aBMP.ScanLine[Y];
    for aX := 0 to aBMP.Width - 1 do
    begin
      P^ := SetRGBTriple(
        EnsureRange(P^.rgbtRed + aBrightness, 0, 255),
        EnsureRange(P^.rgbtGreen + aBrightness, 0, 255),
        EnsureRange(P^.rgbtBlue + aBrightness, 0, 255));
      Inc(Cardinal(P), 3);
    end;
  end;
end;

{ TSimpleTimer }
constructor TSimpleTimer.Create;
begin
  QueryPerformanceFrequency(fFrequency); // get high-resolution Frequency
  QueryPerformanceCounter(fLastTime);
end;

procedure TSimpleTimer.Refresh;
var
  CurTime: Int64;
begin
  QueryPerformanceCounter(CurTime);
  FFrameTime := (CurTime - fLastTime) / fFrequency;
  fLastTime := CurTime;
end;

{ TAVI }
constructor TAVI.Create;
begin
  inherited;

  fTimer := TSimpleTimer.Create;

  fAVIState := aviNoFile;
end;

destructor TAVI.Destroy;
begin
  VidFree;

  inherited;
end;

procedure TAVI.VidFree;
begin
  if fAVIState = aviNoFile then
    Exit;

  fAVIState := aviNoFile;

  fBMP.Free;

  AVIStreamGetFrameClose(fAVI.Frame);
  AVIStreamRelease(fAVI.Stream_Video);
  AVIStreamRelease(fAVI.Stream_Audio);
  AVIFileRelease(fAVI.AFile);
  ZeroMemory(@fAVI, SizeOf(TAVI_Video));

  if Assigned(fSound) then
  begin
    fSound.Stop;
    fSound.Free;
  end;
end;

procedure TAVI.VidInit(aFilename: AnsiString; aLoop, aDoubleHeight: Boolean; aOnFinish: Pointer);
var
  WF: PPCMWaveFormat;
  WFSize: Cardinal;
  SoundFormat: Integer;
  Buffer: Pointer;
  BufferSize: Integer;
  StreamInfo_Video: TAVISTREAMINFO;
begin
  VidFree;
  fLoop := aLoop;
  fDoubleHeight := aDoubleHeight;
  fLastFrame := -1;
  @fOnFinish := aOnFinish;

  fFilename := ChangeFileExt(aFilename, '.avi');

  if not FileExists(fFilename) then
  begin
    if Assigned(fOnFinish) then
      fOnFinish;
    Exit;
  end;

  AVIFileOpen(fAVI.AFile, PAnsiChar(fFilename), OF_READ, nil);
  AVIFileGetStream(fAVI.AFile, fAVI.Stream_Video, streamtypeVIDEO, 0);
  AVIFileGetStream(fAVI.AFile, fAVI.Stream_Audio, streamtypeAUDIO, 0);
  AVIStreamInfoA(fAVI.Stream_Video, @StreamInfo_Video, SizeOf(TAVISTREAMINFO));

  fFPS := 1 / (StreamInfo_Video.dwRate / StreamInfo_Video.dwScale);
  fFrameCount := StreamInfo_Video.dwLength;

  if Assigned(fAVI.Stream_Audio) then
  begin
    WFSize := SizeOf(TPCMWaveFormat);
    GetMem(WF, WFSize);
    AVIStreamReadFormat(fAVI.Stream_Audio, 0, WF, @WFSize);

    AVIStreamRead(fAVI.Stream_Audio, 0, AVIStreamTimeToSample(fAVI.Stream_Audio, AVIStreamEndTime(fAVI.Stream_Audio)),
      nil, 0, @BufferSize, nil);
    GetMem(Buffer, BufferSize);
    ZeroMemory(Buffer, BufferSize);
    AVIStreamRead(fAVI.Stream_Audio, 0, AVIStreamTimeToSample(fAVI.Stream_Audio, AVIStreamEndTime(fAVI.Stream_Audio)),
      Buffer, BufferSize, nil, nil);

    case WF.WF.nChannels of
      1:
        SoundFormat := AL_FORMAT_MONO8;
      2:
        SoundFormat := AL_FORMAT_STEREO8;
    else
      Exit; // Error!
    end;

    if WF.wBitsPerSample = 16 then
      Inc(SoundFormat);

    fSound := TOALSound.Create(SoundFormat, WF.WF.nSamplesPerSec, BufferSize, Buffer, aLoop);

    FreeMem(Buffer);
  end
  else
    fSound := Nil;

  fAVI.Frame := AVIStreamGetFrameOpen(fAVI.Stream_Video, Nil);

  if not Assigned(fAVI.Frame) then
  begin
    fOnFinish;
    Exit;
  end;

  fBMP := TBitmap.Create;
  fBMP.PixelFormat := pf24bit;
  fCurrentTime := 0;
  fCurrFrame := 0;

  GetFrame(True);
  fLastFrame := -1;
  fWidth := fBMP.Width;
  fHeight := fBMP.Height;

  fAVIState := aviStopped;
end;

procedure TAVI.Restart;
begin
  Stop;
  Play;
end;

function TAVI.GetFrame(aForce: Boolean): Boolean;
begin
  Result := (fCurrFrame <> fLastFrame) or aForce;
  if not Result then
    Exit;

  fLastFrame := fCurrFrame;

  DrawFrameToBMP(fBMP, AVIStreamGetFrame(fAVI.Frame, fCurrFrame));

  if fDoubleHeight then
    DoubleVideoFrame(fBMP, fBlackLines);

  if fBrightness <> 0 then
    ApplyBrightness(fBMP, fBrightness);
end;

function TAVI.GetFrameRGB: Pointer;
begin
  Result := BMPToRaw(fBMP);
end;

function TAVI.RefreshFrame(aForce: Boolean): Boolean;
begin
  Result := False;

  if fAVIState in [aviNoFile, aviStopped, aviPaused] then
  begin
    if aForce then
      Result := GetFrame(aForce);
    Exit;
  end;

  fTimer.Refresh;
  fCurrentTime := fCurrentTime + fTimer.FrameTime;
  fCurrFrame := Round(fCurrentTime / fFPS);

  if (fCurrFrame >= fFrameCount) then
  begin
    if fLoop then
      Restart
    else
      Stop;
    Exit;
  end;

  Result := GetFrame(aForce);
end;

procedure TAVI.Play;
begin
  if fAVIState in [aviNoFile, aviPlaying] then
    Exit;

  fAVIState := aviPlaying;

  if Assigned(fSound) then
    fSound.Play;

  fTimer.Refresh;
end;

procedure TAVI.Pause;
begin
  if fAVIState = aviNoFile then
    Exit;

  if fAVIState = aviPaused then
  begin
    Play;
    Exit;
  end;

  fAVIState := aviPaused;
  if Assigned(fSound) then
    fSound.Pause;
end;

procedure TAVI.Stop;
begin
  if fAVIState in [aviNoFile, aviStopped] then
    Exit;

  fAVIState := aviStopped;
  fCurrentTime := 0;
  fCurrFrame := 0;
  fLastFrame := -1;

  if Assigned(fSound) then
    fSound.Stop;

  if Assigned(fOnFinish) then
    fOnFinish;
end;

begin
  AVIFileInit;

end.
