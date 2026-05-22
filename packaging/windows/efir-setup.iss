; Inno Setup Script — EFIR Digital Signage Client
; Документация: https://jrsoftware.org/ishelp/
;
; Сборка:
;   iscc packaging\windows\efir-setup.iss
;
; Выходной файл: packaging\windows\Output\efir-setup-1.0.0-windows-x64.exe

#define AppName      "EFIR"
#define AppPublisher "YourCompany"
#define AppVersion   "1.0.0"
#define AppExeName   "efir.exe"
#define AppId        "{{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}"

; Путь к Flutter-сборке относительно корня репозитория.
; При сборке в CI: flutter build windows --release перед запуском iscc.
#define FlutterBuildDir "..\..\build\windows\x64\runner\Release"

; Путь к watchdog-скриптам
#define DeployWinDir "..\..\deploy\windows"

[Setup]
AppId={#AppId}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL=https://yourcompany.com
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
OutputDir=Output
OutputBaseFilename=efir-setup-{#AppVersion}-windows-x64
Compression=lzma2/ultra64
SolidCompression=yes

; Иконка приложения (замените на реальную .ico перед релизом)
; SetupIconFile=assets\efir.ico

; Минимальная версия Windows: 10 (требование Flutter + media_kit)
MinVersion=10.0.19041

; Требуем права администратора для установки watchdog в Task Scheduler
PrivilegesRequired=admin

; Запустить приложение после установки
[Run]
Filename: "{app}\{#AppExeName}"; Description: "Запустить {#AppName}"; \
    Flags: nowait postinstall skipifsilent

; Зарегистрировать watchdog в Task Scheduler после установки
Filename: "powershell.exe"; \
    Parameters: "-NonInteractive -ExecutionPolicy Bypass -File ""{app}\install-watchdog.ps1"" -AppPath ""{app}\{#AppExeName}"""; \
    Description: "Установить автозапуск (watchdog)"; \
    Flags: runhidden postinstall; \
    StatusMsg: "Настройка автозапуска..."

[UninstallRun]
; Удалить watchdog задачу при деинсталляции
Filename: "powershell.exe"; \
    Parameters: "-NonInteractive -ExecutionPolicy Bypass -Command ""Unregister-ScheduledTask -TaskName 'EFIR-Watchdog' -Confirm:$false -ErrorAction SilentlyContinue"""; \
    Flags: runhidden

[Files]
; Flutter bundle — основное приложение и все .dll
Source: "{#FlutterBuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs

; Watchdog скрипты (из deploy/windows/)
Source: "{#DeployWinDir}\watchdog.ps1";       DestDir: "{app}"; Flags: ignoreversion
Source: "{#DeployWinDir}\install-watchdog.ps1"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
; Ярлык в меню Пуск
Name: "{group}\{#AppName}";          Filename: "{app}\{#AppExeName}"
Name: "{group}\Удалить {#AppName}";  Filename: "{uninstallexe}"

; Ярлык на рабочем столе (опционально — можно убрать)
Name: "{commondesktop}\{#AppName}";  Filename: "{app}\{#AppExeName}"; \
    Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Создать ярлык на рабочем столе"; \
    GroupDescription: "Дополнительно:"; Flags: unchecked

[Registry]
; Автозапуск через реестр — резервный вариант если Task Scheduler не сработал
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
    ValueType: string; ValueName: "{#AppName}"; \
    ValueData: """{app}\{#AppExeName}"""; \
    Flags: uninsdeletevalue; Tasks: not desktopicon

[Code]
// Проверка при деинсталляции: остановить процесс если запущен
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ResultCode: Integer;
begin
  if CurUninstallStep = usUninstall then begin
    Exec('taskkill.exe', '/F /IM {#AppExeName}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;
end;
