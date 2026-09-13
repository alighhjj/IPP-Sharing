; Inno Setup script for IPP Sharing.
;
; This file is a template. .github/scripts/build-installer.ps1 substitutes the
; @PLACEHOLDER@ tokens before invoking ISCC.
;
; Build locally with:
;   ISCC.exe ipp-sharing.iss

#define AppName        "IPP Sharing"
#define AppPublisher   "alampy.com"
#define AppURL         "https://github.com/ArcticLampyrid/ipp-sharing"
#define AppExeName     "ipp-sharing-gui.exe"

; Apple's Bonjour download. Two distinct packages exist and they are NOT
; interchangeable:
;
;   * Bonjour Print Services (this URL, kb/DL999) — what we point users at.
;     Its payload contains both Bonjour64.msi (the service, which is what
;     provides dnssd.dll) and BonjourPS64.msi (a printer wizard). Installing
;     it therefore satisfies our hard dependency.
;   * Bundled with iTunes / Apple Software Update — also ships dnssd.dll.
;
; There is no official Apple winget package; "Apple.Bonjour" and
; "Apple.BonjourPrintServices" are community-maintained manifests. We surface
; the winget ID as a convenience but treat the vendor download as primary.
#define BonjourDownloadURL  "https://support.apple.com/kb/DL999"
; Direct link to BonjourPSSetup.exe (5.2 MiB, Bonjour 2.0.2). Kept as a
; fallback because the support article URL has changed before.
#define BonjourDirectURL    "https://download.info.apple.com/Mac_OS_X/061-8098.20100603.gthyu/BonjourPSSetup.exe"
#define BonjourWingetId     "Apple.BonjourPrintServices"

[Setup]
AppId={{8E1B6F73-1C4A-4E8B-9F2D-7A3C5D0E4B61}
AppName={#AppName}
AppVersion=@APP_VERSION@
AppVerName={#AppName} @APP_VERSION@
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}/issues
AppUpdatesURL={#AppURL}/releases
VersionInfoVersion=@APP_VERSION@
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExeName}
LicenseFile=@LICENSE_FILE@
OutputDir=@OUTPUT_DIR@
OutputBaseFilename=@OUTPUT_BASE@
ArchitecturesAllowed=@ARCH@
ArchitecturesInstallIn64BitMode=@ARCH@
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
; The optional autostart entry writes to HKCU. It is guarded by
; `Check: not IsAdminInstallMode` wherever it appears, so elevation and per-user
; state never mix. Declaring that here silences the compiler's blanket warning.
UsedUserAreasWarning=no
PrivilegesRequiredOverridesAllowed=dialog
MinVersion=10.0

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
; Vendored into the repo: Inno Setup only ships this translation as a separate
; download, so relying on "compiler:Languages\..." would break CI.
Name: "chinesesimplified"; MessagesFile: "@REPO_ROOT@\languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
; Firewall rules are machine-wide and need elevation.
Name: "firewall";    Description: "Add Windows Firewall rules (TCP 631 / UDP 5353)"; GroupDescription: "Printer sharing:"; Flags: checkedonce; Check: IsAdminInstallMode
; Autostart is per-user, so it is only offered in non-administrative mode.
Name: "autostart";   Description: "Start IPP Sharing when I log in"; GroupDescription: "Printer sharing:"; Check: not IsAdminInstallMode
; Bonjour is a hard prerequisite, so this defaults to on — but only while it is
; actually missing. InitializeSetup runs before the task list is built, so a
; machine that already has Bonjour never sees the checkbox at all.
Name: "bonjour";     Description: "Install Apple Bonjour (required — IPP Sharing cannot start without it)"; \
    GroupDescription: "Prerequisites:"; Flags: checkedonce; Check: BonjourNeeded

[Files]
Source: "@STAGE_DIR@\ipp-sharing-gui.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "@STAGE_DIR@\ipp-sharing.exe";     DestDir: "{app}"; Flags: ignoreversion
Source: "@STAGE_DIR@\README.md";           DestDir: "{app}"; Flags: ignoreversion
Source: "@STAGE_DIR@\LICENSE.md";          DestDir: "{app}"; Flags: ignoreversion
Source: "@STAGE_DIR@\BUILD-INFO.txt";      DestDir: "{app}"; Flags: ignoreversion
; PDFium is a runtime dependency of the pdfium feature; without it the
; executables fail to start. skipifsourcedoesntexist keeps this working for
; builds made with the winpdf feature instead.
Source: "@STAGE_DIR@\pdfium.dll";          DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

; Only install a config if the user does not already have one, so upgrades and
; reinstalls never clobber their settings.
Source: "@STAGE_DIR@\config.example.yaml"; DestDir: "{app}"; DestName: "config.yaml"; \
    Flags: onlyifdoesntexist uninsneveruninstall

[Icons]
Name: "{group}\{#AppName}";                  Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}";            Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
; Machine-wide firewall rules: only meaningful with elevation.
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""IPP Sharing (IPP)"" dir=in action=allow protocol=TCP localport=631"; Flags: runhidden; Tasks: firewall; Check: IsAdminInstallMode
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""IPP Sharing (Bonjour)"" dir=in action=allow protocol=UDP localport=5353"; Flags: runhidden; Tasks: firewall; Check: IsAdminInstallMode
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Removing rules that were never added is harmless, so these run unconditionally.
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""IPP Sharing (IPP)""";     Flags: runhidden; RunOnceId: "DelFwIpp"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""IPP Sharing (Bonjour)"""; Flags: runhidden; RunOnceId: "DelFwBonjour"

[Registry]
; Autostart entry, removed again on uninstall.
; This is a per-user (HKCU) change, which is only honoured when setup runs in
; non-administrative mode. See PrivilegesRequiredOverridesAllowed above.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; \
    ValueName: "IppSharing"; ValueData: """{app}\{#AppExeName}"""; \
    Flags: uninsdeletevalue; Tasks: autostart; Check: not IsAdminInstallMode

[UninstallDelete]
; Leave config.yaml behind: it holds the user's certificate paths and printer UUIDs.
Type: filesandordirs; Name: "{app}\logs"

[Code]
// Bonjour is a hard runtime requirement, not just a discovery nicety.
//
// The binaries import dnssd.dll via a `raw-dylib` link, and Windows resolves
// file-backed imports before the process entry point runs. Without Bonjour
// installed, every invocation therefore dies with 0xC0000135
// (STATUS_DLL_NOT_FOUND / "dnssd.dll was not found") before any of our code,
// config parsing or the `dnssd: false` setting can take effect. dnssd.dll
// belongs to Apple and cannot be redistributed, so the installer cannot supply
// it — the user has to install Bonjour themselves.
//
// Verified against the payload of BonjourPSSetup.exe (Bonjour 2.0.2): the
// dnssd*.dll files live in Bonjour64.msi, whose File table targets
// `SystemFolder` (System32), while mDNSResponder.exe and its DLLs land in the
// `INSTALLDIR` directory under Program Files\Bonjour. The service is
// registered under the display name "Bonjour Service".

const
  // Both keys are repository-relative to the hive, i.e. the path is appended
  // to `HKLM` verbatim. Verified with ISCC 6: `HKLM` does NOT imply a
  // `SOFTWARE` prefix, and under 64-bit install mode `HKLM` does not see keys
  // that a 32-bit Apple package wrote, hence the explicit HKLM/HKLM32 pair on
  // every lookup below.
  BonjourUninstallKey = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Bonjour';
  BonjourServiceKey   = 'SYSTEM\CurrentControlSet\Services\Bonjour Service';

var
  // Set once in InitializeSetup; the [Tasks] Check function below must not
  // re-scan the disk on every redraw of the task list.
  BonjourPresent: Boolean;
  BonjourDetectedVia: String;

// Finds dnssd.dll. The System32 copy is what the loader actually resolves, but
// older or 32-bit Bonjour installs keep it under Program Files only, so both
// are accepted. Returns the path, or '' when nothing is found.
function FindDnssdDll(): String;
var
  Candidates: array of String;
  I: Integer;
begin
  SetArrayLength(Candidates, 4);
  Candidates[0] := ExpandConstant('{sys}\dnssd.dll');          // System32 / SysWOW64
  Candidates[1] := ExpandConstant('{commonpf}\Bonjour\dnssd.dll');
  Candidates[2] := ExpandConstant('{commonpf32}\Bonjour\dnssd.dll');
  Candidates[3] := ExpandConstant('{commoncf}\Apple\dnssd.dll');

  for I := 0 to GetArrayLength(Candidates) - 1 do
  begin
    if FileExists(Candidates[I]) then
    begin
      Result := Candidates[I];
      Exit;
    end;
  end;
  Result := '';
end;

// True when Bonjour looks installed by any of the three signals we can check
// without running anything. Sets BonjourDetectedVia for diagnostics.
//
// The file check is deliberately first: dnssd.dll on disk is the one thing the
// loader strictly needs, so its absence means the program will not start even
// if the registry and service entries survive from a botched uninstall.
function DetectBonjour(): Boolean;
var
  Dll: String;
begin
  Result := False;
  BonjourDetectedVia := '';

  Dll := FindDnssdDll();
  if Dll <> '' then
  begin
    Result := True;
    BonjourDetectedVia := 'dnssd.dll at ' + Dll;
    Exit;
  end;

  // Fall back to the service registration, which survives cases where the DLL
  // sits somewhere unusual (e.g. a redirected System32 on some managed fleets).
  if RegKeyExists(HKLM, BonjourServiceKey) or
     RegKeyExists(HKLM32, BonjourServiceKey) then
  begin
    Result := True;
    BonjourDetectedVia := 'service registration (Bonjour Service)';
    Exit;
  end;

  if RegKeyExists(HKLM, BonjourUninstallKey) or
     RegKeyExists(HKLM32, BonjourUninstallKey) then
  begin
    Result := True;
    BonjourDetectedVia := 'uninstall entry for Bonjour';
  end;
end;

// Used as the [Tasks] Check: the prerequisite entry is only shown on machines
// that actually lack Bonjour.
function BonjourNeeded(): Boolean;
begin
  Result := not BonjourPresent;
end;

// --- download & silent install -----------------------------------------------

// urlmon's URLDownloadToFileW. Preferred over the WinHttp + ADODB.Stream dance
// for two reasons: it needs no COM component beyond what Windows itself ships,
// and it is a single call. Declared as String because Pascal Script has no
// PWideChar; the W entry point is what makes that work with non-ASCII paths.
function URLDownloadToFile(pCaller: Integer; szURL, szFileName: String;
  dwReserved, lpfnCB: Integer): Integer;
  external 'URLDownloadToFileW@urlmon.dll stdcall';

function BonjourNeedsInstalling(): Boolean;
begin
  Result := (not BonjourPresent) and WizardIsTaskSelected('bonjour');
end;

// True when the file starts with the DOS/PE magic that every Windows
// executable has.
//
// This check is not paranoia. Measured behaviour: when the URL 404s, Apple's
// CDN answers with an HTML error page and URLDownloadToFileW still returns
// S_OK (0). A 108 KiB text file was written in place of the installer. Running
// that would surface as a nonsensical "this app can't run on your PC" rather
// than a download error, so the payload is verified before it is executed.
//
// LoadStringFromFile into an AnsiString, not TFileStream.Read: Pascal Script's
// native String is UTF-16, so reading two bytes into it yields the pair as a
// single code unit (measured: Ord(H[1]) came back as 23117, i.e. the 16-bit
// little-endian word 0x5A4D) and the byte comparison below can never match.
function LooksLikePeFile(const Path: String): Boolean;
var
  Head: AnsiString;
begin
  Result := False;
  if not FileExists(Path) then
    Exit;
  // False for a directory, an unreadable file, or anything larger than the
  // function's size limit.
  if not LoadStringFromFile(Path, Head) then
  begin
    Log('Could not read ' + Path + ' for the PE check.');
    Exit;
  end;
  if Length(Head) < 2 then
    Exit;
  // 'MZ' — the DOS stub header every PE image begins with.
  Result := (Ord(Head[1]) = $4D) and (Ord(Head[2]) = $5A);
end;

function DownloadBonjour(const Url, DestFile: String): Boolean;
var
  R: Integer;
begin
  Result := False;
  // Delete first: URLDownloadToFileW happily overwrites, but a stale file from
  // an earlier failed run would make the PE check below pass on bad data.
  DeleteFile(DestFile);

  R := URLDownloadToFile(0, Url, DestFile, 0, 0);
  if R <> 0 then
  begin
    Log(Format('Bonjour download failed: 0x%x from %s', [R, Url]));
    Exit;
  end;

  if not LooksLikePeFile(DestFile) then
  begin
    // Reported as S_OK but the body is not an executable — almost certainly an
    // HTML error page from the CDN.
    Log('Bonjour download returned S_OK but the payload is not a PE file: ' + DestFile);
    DeleteFile(DestFile);
    Exit;
  end;

  Result := True;
end;

procedure InstallBonjour();
var
  DestFile: String;
  ResultCode: Integer;
begin
  DestFile := ExpandConstant('{tmp}\BonjourPSSetup.exe');

  // The support article is the canonical entry point, but it is an HTML page,
  // not a file — so we go straight to the pinned direct link and keep the
  // article URL only for the error messages. Both point at the same 5.2 MiB
  // Bonjour 2.0.2 build.
  if not DownloadBonjour('{#BonjourDirectURL}', DestFile) then
  begin
    MsgBox('Could not download Bonjour.' + #13#10 + #13#10 +
           'Please install it manually from:' + #13#10 +
           '{#BonjourDownloadURL}' + #13#10 + #13#10 +
           'Then run this setup again.', mbError, MB_OK);
    Exit;
  end;

  // /quiet /norestart are the documented silent switches for this package.
  // It installs both the Bonjour service and the printer wizard, and needs
  // elevation — which we already have (PrivilegesRequired=admin).
  if not Exec(DestFile, '/quiet /norestart', '', SW_SHOW, ewWaitUntilTerminated, ResultCode) then
  begin
    MsgBox('Bonjour setup could not be started.' + #13#10 + #13#10 +
           'Please install it manually from:' + #13#10 +
           '{#BonjourDownloadURL}', mbError, MB_OK);
    Exit;
  end;

  // 0 = success, 3010 = success but a reboot is pending.
  if (ResultCode <> 0) and (ResultCode <> 3010) then
  begin
    Log(Format('Bonjour setup exited with %d', [ResultCode]));
    MsgBox('Bonjour setup exited with code ' + IntToStr(ResultCode) + '.' + #13#10 + #13#10 +
           'Please install it manually from:' + #13#10 +
           '{#BonjourDownloadURL}', mbError, MB_OK);
    Exit;
  end;

  BonjourPresent := DetectBonjour();
  if not BonjourPresent then
    Log('Bonjour setup reported success but dnssd.dll is still not visible; a reboot is likely required.');
end;

// --- wizard ---------------------------------------------------------------

function InitializeSetup(): Boolean;
begin
  BonjourPresent := DetectBonjour();
  if BonjourPresent then
    Log('Bonjour detected via ' + BonjourDetectedVia)
  else
    Log('Bonjour NOT detected; IPP Sharing will not start until it is installed.');
  Result := True;
end;

// Tell the user up front rather than after the files are on disk — the choice
// materially affects whether the installed program can run at all.
function NextButtonClick(CurPageID: Integer): Boolean;
var
  Response: Integer;
begin
  Result := True;
  if (CurPageID = wpSelectTasks) and BonjourNeedsInstalling() then
  begin
    Response := MsgBox('IPP Sharing requires Apple Bonjour, which is not installed on this computer.' + #13#10 + #13#10 +
                       'The program imports dnssd.dll before it starts, so without Bonjour every ' + #13#10 +
                       'command fails with "dnssd.dll was not found" (error 0xC0000135) — even if ' + #13#10 +
                       'you never use automatic printer discovery.' + #13#10 + #13#10 +
                       'Setup can download and install Bonjour (about 5 MB) for you now.' + #13#10 + #13#10 +
                       'Install Bonjour?', mbConfirmation, MB_YESNO);
    if Response = IDNO then
      Result := False;   // keep the user on the task page
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    if BonjourNeedsInstalling() then
      InstallBonjour();

    // Last chance to warn: covers "Bonjour was already there but broken", and
    // the case where the download or silent install did not take effect.
    if not BonjourPresent then
    begin
      MsgBox('IPP Sharing is installed, but Apple Bonjour is still missing.' + #13#10 + #13#10 +
             'The program will fail to start with error 0xC0000135 until Bonjour is ' + #13#10 +
             'installed. A restart may be required if you just installed it.' + #13#10 + #13#10 +
             'Download: {#BonjourDownloadURL}' + #13#10 +
             'Or run:   winget install --id={#BonjourWingetId} -e', mbInformation, MB_OK);
    end;
  end;
end;
