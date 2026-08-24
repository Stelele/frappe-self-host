; BasaPOS one-click offline installer (native WSL2 appliance, no Docker)
#define MyAppName "BasaPOS"
#ifndef MyAppVersion
#define MyAppVersion "0.1.0"
#endif
#define MyAppExeName "BasaPOS.exe"

[Setup]
AppId={{8A2C9B4E-5D3F-4E7A-9C1B-4F6A2E1B5C3D}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=BasaPOS
DefaultDirName={localappdata}\Programs\BasaPOS
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
OutputBaseFilename=BasaPOS-Setup-{#MyAppVersion}
OutputDir=build\output
UninstallDisplayIcon={app}\BasaPOS.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
RestartApplications=no
CloseApplications=no

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "autostart"; Description: "Start BasaPOS when I sign in to Windows"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "build\payload\rootfs\basapos-rootfs.tar.gz"; DestDir: "{app}\rootfs"; Flags: ignoreversion nocompression
Source: "build\payload\wsl\wsl.msi"; DestDir: "{app}\wsl"; Flags: ignoreversion nocompression
Source: "build\payload\BasaPOS.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "build\payload\install\*"; DestDir: "{app}\payload\install"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "build\payload\app\*"; DestDir: "{app}\app"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon
Name: "{userstartup}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: autostart

[Run]
; Empty — setup is driven from [Code] CurStepChanged to avoid blocking on
; PowerShell process exit (child processes keep it alive indefinitely).

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File {app}\payload\install\remove-basapos.ps1"; Flags: runhidden; RunOnceId: "BasaPOSCleanup"

[Code]
function ReadStatus(): String;
var lines: TArrayOfString;
begin
  Result := '';
  if FileExists(ExpandConstant('{app}\setup-status.txt')) then
    if LoadStringsFromFile(ExpandConstant('{app}\setup-status.txt'), lines) then
      if GetArrayLength(lines) > 0 then Result := lines[0];
end;

function NeedRestart(): Boolean;
begin
  Result := Pos('NEEDS_REBOOT', ReadStatus()) > 0;
end;

function SetupSucceeded(): Boolean;
begin
  Result := Pos('SETUP_COMPLETE', ReadStatus()) > 0;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  Status: String;
  I: Integer;
  IsUpgrade: Boolean;
  PsArgs: String;
  DiagFile: String;
  Line: String;
begin
  if CurStep = ssPostInstall then
  begin
    DiagFile := ExpandConstant('{app}\setup-diag.txt');
    IsUpgrade := FileExists(ExpandConstant('{app}\installed.txt'));

    Line := 'CurStepChanged:';
    if IsUpgrade then
      Line := Line + ' IsUpgrade=TRUE'
    else
      Line := Line + ' IsUpgrade=FALSE';
    SaveStringToFile(DiagFile, Line + #13#10, True);

    SaveStringToFile(DiagFile, 'AppDir=' + ExpandConstant('{app}') + #13#10, True);

    PsArgs := '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
      ExpandConstant('{app}\payload\install\setup.ps1') + '" -AppDir "' +
      ExpandConstant('{app}') + '"';
    if IsUpgrade then
      PsArgs := PsArgs + ' -Upgrade';

    SaveStringToFile(DiagFile, 'PsArgs=' + PsArgs + #13#10, True);

    { Clear stale status file so polling loop doesn't exit on old SETUP_COMPLETE }
    DeleteFile(ExpandConstant('{app}\setup-status.txt'));

    Exec('powershell.exe', PsArgs, '', SW_HIDE, ewNoWait, ResultCode);
    SaveStringToFile(DiagFile, 'Exec returned ResultCode=' + IntToStr(ResultCode) + #13#10, True);

    { Poll status file for a terminal state (max ~17 min = 200 * 5s). }
    for I := 1 to 200 do
    begin
      Status := ReadStatus();
      if (I <= 5) or (I mod 20 = 0) or (Pos('SETUP_COMPLETE', Status) > 0) or (Pos('ERROR', Status) > 0) then
      begin
        SaveStringToFile(DiagFile, 'Poll #' + IntToStr(I) + ': ' + Status + #13#10, True);
      end;
      if Pos('SETUP_COMPLETE', Status) > 0 then
        Exit;
      if Pos('NEEDS_REBOOT', Status) > 0 then
        Exit;
      if Pos('ERROR', Status) > 0 then
      begin
        MsgBox('Setup failed: ' + Status, mbError, MB_OK);
        Exit;
      end;
      Sleep(5000);
    end;
    MsgBox('Setup timed out waiting for appliance.', mbError, MB_OK);
  end;
end;
