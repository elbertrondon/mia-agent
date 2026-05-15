#define MyAppName      "MIA Connector Agent"
#define MyAppVersion   "1.0.0"
#define MyAppPublisher "MIA Platform"
#define MyAppExeName   "mia-agent.exe"
#define MyServiceName  "MIAAgent"

[Setup]
AppId={{B7E3A1F2-4C8D-4E9B-A0D1-F2E3B4C5D6E7}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL=https://miaplatform.com
DefaultDirName={autopf}\MIA Agent
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputBaseFilename=mia-agent-setup
OutputDir=Output
Compression=lzma2/ultra64
SolidCompression=yes
PrivilegesRequired=admin
WizardStyle=modern
WizardSizePercent=120
SetupLogging=yes
UninstallDisplayName={#MyAppName}
MinVersion=10.0
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Files]
Source: "mia-agent.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"

[UninstallRun]
Filename: "{app}\{#MyAppExeName}"; Parameters: "-service stop";      Flags: runhidden waituntilterminated; RunOnceId: "StopService"
Filename: "{app}\{#MyAppExeName}"; Parameters: "-service uninstall"; Flags: runhidden waituntilterminated; RunOnceId: "UninstallService"

; ─────────────────────────────────────────────────────────────────────────────
; Pascal Script
; ─────────────────────────────────────────────────────────────────────────────
[Code]

const
  DriverNames:  array[0..3] of String = ('MySQL',    'PostgreSQL', 'SQL Server', 'SQLite');
  DriverValues: array[0..3] of String = ('mysql',    'pgsql',      'sqlsrv',     'sqlite');
  DefaultPorts: array[0..3] of String = ('3306',     '5432',       '1433',       '0');

var
  PageMIA:   TInputQueryWizardPage;   { URL + Token                   }
  PageType:  TInputOptionWizardPage;  { Driver radio list             }
  PageConn:  TInputQueryWizardPage;   { Host / Port / Database name   }
  PageCreds: TInputQueryWizardPage;   { Username / Password           }

{ ── Page setup ──────────────────────────────────────────────────────────── }

procedure InitializeWizard;
begin
  { 1. MIA platform }
  PageMIA := CreateInputQueryPage(wpWelcome,
    'MIA Platform',
    'Connect this agent to your MIA instance',
    'Copy these values from your MIA dashboard (Connection → Agent Token).');
  PageMIA.Add('MIA URL:', False);
  PageMIA.Add('Agent Token:', False);
  PageMIA.Values[0] := 'https://';

  { 2. Database type }
  PageType := CreateInputOptionPage(PageMIA.ID,
    'Database Type',
    'Select the engine of your database',
    '',
    True,   { exclusive }
    False); { list style }
  PageType.Add(DriverNames[0]);
  PageType.Add(DriverNames[1]);
  PageType.Add(DriverNames[2]);
  PageType.Add(DriverNames[3]);
  PageType.SelectedValueIndex := 0;

  { 3. Connection details }
  PageConn := CreateInputQueryPage(PageType.ID,
    'Database Connection',
    'Enter the connection details for your database',
    '');
  PageConn.Add('Host / IP address:', False);
  PageConn.Add('Port:', False);
  PageConn.Add('Database name:', False);
  PageConn.Values[0] := 'localhost';
  PageConn.Values[1] := '3306';

  { 4. Credentials }
  PageCreds := CreateInputQueryPage(PageConn.ID,
    'Database Credentials',
    'Enter the login credentials',
    '');
  PageCreds.Add('Username:', False);
  PageCreds.Add('Password:', True);  { masked }
end;

{ ── Dynamic page behaviour ───────────────────────────────────────────────── }

procedure CurPageChanged(CurPageID: Integer);
var
  Idx: Integer;
  IsSQLite: Boolean;
begin
  if CurPageID = PageConn.ID then begin
    Idx      := PageType.SelectedValueIndex;
    IsSQLite := (Idx = 3);

    { Update default port }
    if PageConn.Values[1] = '' then
      PageConn.Values[1] := DefaultPorts[Idx]
    else
      PageConn.Values[1] := DefaultPorts[Idx];

    if IsSQLite then begin
      { For SQLite, "host" is the .sqlite file path }
      PageConn.PromptLabels[0].Caption := 'SQLite file path:';
      PageConn.Values[0]               := 'C:\data\database.sqlite';
      PageConn.Edits[1].Enabled        := False;
      PageConn.Edits[2].Enabled        := False;
      PageConn.Values[1]               := '0';
      PageConn.Values[2]               := '';
    end else begin
      PageConn.PromptLabels[0].Caption := 'Host / IP address:';
      if PageConn.Values[0] = 'C:\data\database.sqlite' then
        PageConn.Values[0] := 'localhost';
      PageConn.Edits[1].Enabled := True;
      PageConn.Edits[2].Enabled := True;
    end;
  end;
end;

{ ── Skip credentials page for SQLite ────────────────────────────────────── }

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := (PageID = PageCreds.ID) and (PageType.SelectedValueIndex = 3);
end;

{ ── Field validation ─────────────────────────────────────────────────────── }

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;

  if CurPageID = PageMIA.ID then begin
    if Length(Trim(PageMIA.Values[0])) < 8 then begin
      MsgBox('Please enter a valid MIA URL (e.g. https://app.miaplatform.com).', mbError, MB_OK);
      Result := False; Exit;
    end;
    if Length(Trim(PageMIA.Values[1])) < 32 then begin
      MsgBox('Please enter your Agent Token (at least 32 characters).', mbError, MB_OK);
      Result := False; Exit;
    end;
  end;

  if CurPageID = PageConn.ID then begin
    if Trim(PageConn.Values[0]) = '' then begin
      MsgBox('Please enter the host / file path.', mbError, MB_OK);
      Result := False; Exit;
    end;
    if (PageType.SelectedValueIndex <> 3) and (Trim(PageConn.Values[2]) = '') then begin
      MsgBox('Please enter the database name.', mbError, MB_OK);
      Result := False; Exit;
    end;
  end;

  if CurPageID = PageCreds.ID then begin
    if Trim(PageCreds.Values[0]) = '' then begin
      MsgBox('Please enter the database username.', mbError, MB_OK);
      Result := False; Exit;
    end;
  end;
end;

{ ── JSON helpers ─────────────────────────────────────────────────────────── }

function JsonEscape(S: String): String;
begin
  Result := S;
  StringChangeEx(Result, '\', '\\', True);
  StringChangeEx(Result, '"', '\"', True);
  StringChangeEx(Result, #13, '\r', True);
  StringChangeEx(Result, #10, '\n', True);
end;

{ ── Write config.json ────────────────────────────────────────────────────── }

procedure WriteConfig;
var
  Lines: TStringList;
  Path:  String;
  Idx:   Integer;
  IsSQLite: Boolean;
begin
  Idx      := PageType.SelectedValueIndex;
  IsSQLite := (Idx = 3);

  Lines := TStringList.Create;
  try
    Lines.Add('{');
    Lines.Add('  "mia_url": "'     + JsonEscape(Trim(PageMIA.Values[0]))  + '",');
    Lines.Add('  "agent_token": "' + JsonEscape(Trim(PageMIA.Values[1]))  + '",');
    Lines.Add('  "poll_interval_seconds": 3,');
    Lines.Add('  "database": {');
    Lines.Add('    "driver": "'    + DriverValues[Idx]                     + '",');
    Lines.Add('    "host": "'      + JsonEscape(Trim(PageConn.Values[0]))  + '",');
    Lines.Add('    "port": '       + Trim(PageConn.Values[1])              + ',');
    if IsSQLite then begin
      Lines.Add('    "name": "",');
      Lines.Add('    "username": "",');
      Lines.Add('    "password": ""');
    end else begin
      Lines.Add('    "name": "'     + JsonEscape(Trim(PageConn.Values[2]))   + '",');
      Lines.Add('    "username": "' + JsonEscape(Trim(PageCreds.Values[0]))  + '",');
      Lines.Add('    "password": "' + JsonEscape(Trim(PageCreds.Values[1]))  + '"');
    end;
    Lines.Add('  }');
    Lines.Add('}');

    Path := ExpandConstant('{app}\config.json');
    Lines.SaveToFile(Path);
  finally
    Lines.Free;
  end;
end;

{ ── Post-install: register and start the Windows Service ────────────────── }

procedure CurStepChanged(CurStep: TSetupStep);
var
  ExePath:    String;
  ConfigPath: String;
  ResultCode: Integer;
begin
  if CurStep <> ssPostInstall then Exit;

  ExePath    := ExpandConstant('{app}\{#MyAppExeName}');
  ConfigPath := ExpandConstant('{app}\config.json');

  { Write config before anything else }
  WriteConfig;

  { Stop + uninstall any existing service (ignore errors on first install) }
  Exec(ExePath, '-service stop',      '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec(ExePath, '-service uninstall', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  { Install and start the service }
  if not Exec(ExePath,
    '-config "' + ConfigPath + '" -service install',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then begin
    MsgBox('The Windows Service could not be installed (code ' + IntToStr(ResultCode) + ').'
      + #13#10 + 'You can install it manually by running:'
      + #13#10 + ExePath + ' -service install',
      mbError, MB_OK);
    Exit;
  end;

  if not Exec(ExePath, '-service start', '', SW_HIDE, ewWaitUntilTerminated, ResultCode)
    or (ResultCode <> 0) then begin
    MsgBox('The service was installed but could not be started (code ' + IntToStr(ResultCode) + ').'
      + #13#10 + 'Check that the database credentials are correct and try starting the service from'
      + #13#10 + 'Windows Services (services.msc).',
      mbInformation, MB_OK);
  end;
end;
