; Compile through tool/package_windows.ps1 so the version and runtime DLLs match the build.
#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef SourceDir
  #error SourceDir is required
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif

[Setup]
; Keep this identity unchanged so later versions upgrade the existing installation.
AppId=com.ckales.cdata
AppName=CData
AppVersion={#AppVersion}
AppPublisher=Ckales
AppPublisherURL=https://github.com/Ckales/CData
DefaultDirName={localappdata}\Programs\CData
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
DisableProgramGroupPage=yes
DisableDirPage=no
OutputDir={#OutputDir}
OutputBaseFilename=CData-{#AppVersion}-windows-x64-setup
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\CData.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
; Bundled translation: do not depend on the compiler installation's optional languages.
Name: "chinesesimplified"; MessagesFile: "Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\CData"; Filename: "{app}\CData.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\CData"; Filename: "{app}\CData.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\CData.exe"; Description: "{cm:LaunchProgram,CData}"; Flags: nowait postinstall skipifsilent
