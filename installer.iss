[Setup]
AppName=eLGCDD Consumer Search Engine
AppVersion=1.0.0
AppPublisher=eLGCDD
DefaultDirName={autopf}\eLGCDD Consumer Search Engine
DefaultGroupName=eLGCDD Consumer Search Engine
OutputDir=installer_output
OutputBaseFilename=eLGCDD_Consumer_Search_Engine_Setup
Compression=lzma2/ultra64
SolidCompression=yes
SetupIconFile=windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\consumer_search_engine.exe
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
DisableProgramGroupPage=yes
DisableDirPage=no
LicenseFile=
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\eLGCDD Consumer Search Engine"; Filename: "{app}\consumer_search_engine.exe"; IconFilename: "{app}\consumer_search_engine.exe"
Name: "{group}\Uninstall eLGCDD Consumer Search Engine"; Filename: "{uninstallexe}"
Name: "{autodesktop}\eLGCDD Consumer Search Engine"; Filename: "{app}\consumer_search_engine.exe"; Tasks: desktopicon; IconFilename: "{app}\consumer_search_engine.exe"

[Run]
Filename: "{app}\consumer_search_engine.exe"; Description: "Launch eLGCDD Consumer Search Engine now"; Flags: nowait postinstall skipifsilent
