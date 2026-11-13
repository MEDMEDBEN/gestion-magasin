; Installateur Windows de Shino Lighting (Inno Setup 6).
;
; Le plus simple : lancer installer\build-installer.ps1 (build Flutter,
; téléchargement du runtime Visual C++, compilation de ce fichier).
; À la main : ISCC.exe /DAppVersion=1.0.0 installer\gestion_magasin.iss
;
; Le PC cible n'a besoin de RIEN : le runtime Visual C++ 2015-2022 x64
; (vcruntime140.dll, msvcp140.dll — exigé par flutter_windows.dll) est
; embarqué et installé en silence s'il manque. Les autres DLL (pdfium, sqlite3,
; plugins) sont dans le dossier Release.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define AppName "Shino Lighting"
#define AppExe "gestion_magasin.exe"
#define Release "..\app\build\windows\x64\runner\Release"

[Setup]
; Identifiant FIXE : une nouvelle version remplace l'ancienne, sans doublon.
AppId={{6F3C2A91-7B4E-4D2C-9E15-3A8B6C0D4F27}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppName}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; Administrateur : installer dans Program Files et le runtime Visual C++.
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir=Output
OutputBaseFilename=ShinoLighting-Setup-{#AppVersion}
SetupIconFile=..\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Mise à jour : l'application ouverte est fermée puis relancée.
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "fr"; MessagesFile: "compiler:Languages\French.isl"

[Tasks]
Name: "desktopicon"; Description: "Créer une icône sur le Bureau"; GroupDescription: "Raccourcis :"

[Files]
; Toute l'application (exe, DLL, dossier data) — rien d'autre n'est requis.
Source: "{#Release}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Runtime Visual C++, installé seulement s'il manque (voir [Code]).
Source: "redist\vc_redist.x64.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall; Check: VCRedistNeeded

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{group}\Désinstaller {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; \
  StatusMsg: "Installation du runtime Visual C++ (composant Windows requis)…"; \
  Flags: waituntilterminated; Check: VCRedistNeeded
Filename: "{app}\{#AppExe}"; Description: "Lancer {#AppName}"; \
  Flags: nowait postinstall skipifsilent

[Code]
// Runtime Visual C++ 2015-2022 x64 présent ? (clé posée par vc_redist).
// Version 14.30 minimum : celle des outils qui compilent l'application.
function VCRedistNeeded: Boolean;
var
  Installed, Major, Minor: Cardinal;
begin
  Result := True;
  if RegQueryDWordValue(HKLM64, 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'Installed', Installed) and (Installed = 1) and
     RegQueryDWordValue(HKLM64, 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'Major', Major) and
     RegQueryDWordValue(HKLM64, 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'Minor', Minor) then
    Result := (Major < 14) or ((Major = 14) and (Minor < 30));
end;
