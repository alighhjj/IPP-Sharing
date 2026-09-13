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
function IsBonjourInstalled(): Boolean;
begin
  // mDNSResponder.exe is the Bonjour service; dnssd.dll sits beside it and is
  // what the loader actually needs.
  Result := FileExists(ExpandConstant('{commonpf32}\Bonjour\dnssd.dll')) or
            FileExists(ExpandConstant('{commonpf}\Bonjour\dnssd.dll'));
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Response: Integer;
begin
  if CurStep = ssPostInstall then
  begin
    if not IsBonjourInstalled() then
    begin
      Response := MsgBox('Apple Bonjour was not detected on this system.' + #13#10 + #13#10 +
                         'IPP Sharing requires Bonjour: Windows must find dnssd.dll before the program ' + #13#10 +
                         'can start, so without it every command fails with "dnssd.dll was not found" ' + #13#10 +
                         '(error 0xC0000135) — even when DNS-SD discovery is switched off.' + #13#10 + #13#10 +
                         'Install Bonjour Print Services before using IPP Sharing.' + #13#10 + #13#10 +
                         'Continue the installation anyway?', mbConfirmation, MB_YESNO);
      if Response = IDNO then
        MsgBox('Install Bonjour Print Services (https://support.apple.com/106390), then run this setup again.', mbInformation, MB_OK);
    end;
  end;
end;
