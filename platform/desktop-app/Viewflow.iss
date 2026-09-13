#ifndef Payload
  #error Payload is required
#endif
#ifndef Output
  #define Output "."
#endif
[Setup]
AppId=org.viewflow.app
AppName=Viewflow
AppVersion=0.1.0
DefaultDirName={localappdata}\Programs\Viewflow
DefaultGroupName=Viewflow
OutputDir={#Output}
OutputBaseFilename=Viewflow-Setup-x64
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
UninstallDisplayIcon={app}\Viewflow.exe
CloseApplications=yes
RestartApplications=no
[Files]
Source: "{#Payload}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Icons]
Name: "{autoprograms}\Viewflow"; Filename: "{app}\Viewflow.exe"
Name: "{autodesktop}\Viewflow"; Filename: "{app}\Viewflow.exe"; Tasks: desktopicon
[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked
[Run]
Filename: "{app}\Viewflow.exe"; Description: "Open Viewflow"; Flags: nowait postinstall skipifsilent unchecked
