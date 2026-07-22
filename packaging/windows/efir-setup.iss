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

; Установка НЕ требует администратора — и это принципиально: обновление из
; панели запускает установщик от того же пользователя, что и приложение.
; Машинная установка в Program Files потребовала бы UAC при каждом обновлении,
; а на экране, к которому никто не подходит, диалог UAC = обновления нет.
; {auto*}-константы сами разворачиваются в пользовательские пути.
; Админ всё ещё может поставить на всю машину: кнопка выбора в мастере.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

; Обновление поверх работающего клиента: закрыть приложение перед заменой файлов.
CloseApplications=yes
RestartApplications=no

; Запустить приложение после установки
[Run]
Filename: "{app}\{#AppExeName}"; Description: "Запустить {#AppName}"; \
    Flags: nowait postinstall skipifsilent

; То же, но для тихого обновления: там страницы «Готово» нет, а клиент
; обязан подняться сам — иначе экран останется чёрным до перезагрузки.
Filename: "{app}\{#AppExeName}"; \
    Flags: nowait runasoriginaluser; Check: IsSilentInstall

; Зарегистрировать watchdog в Task Scheduler после установки
Filename: "powershell.exe"; \
    Parameters: "-NonInteractive -ExecutionPolicy Bypass -File ""{app}\install-watchdog.ps1"" -AppPath ""{app}\{#AppExeName}"" -Silent"; \
    Description: "Установить автозапуск (watchdog)"; \
    Flags: runhidden runasoriginaluser; \
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
Name: "{autodesktop}\{#AppName}";  Filename: "{app}\{#AppExeName}"; \
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
const
  VCRedistUrl  = 'https://aka.ms/vs/17/release/vc_redist.x64.exe';
  { Evergreen Bootstrapper: ~2 МБ, сам скачивает и ставит актуальный рантайм. }
  WebView2Url  = 'https://go.microsoft.com/fwlink/p/?LinkId=2124703';
  { Идентификатор WebView2 Runtime в EdgeUpdate — по нему и определяем наличие. }
  WebView2Guid = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';

var
  PrereqPage: TDownloadWizardPage;

// Обёртка для Check: тихая установка — это автообновление из панели,
// там некому нажать «Запустить» на финальной странице.
function IsSilentInstall: Boolean;
begin
  Result := WizardSilent;
end;

// Проверяем наличие VC++ 2015-2022 Redistributable x64 через реестр
function VCRedistNeedsInstall: Boolean;
var
  Ver: String;
begin
  Result := not RegQueryStringValue(
    HKLM,
    'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64',
    'Version',
    Ver
  );
end;

// Установлен ли WebView2 Runtime.
//
// Рантайм регистрируется в EdgeUpdate и бывает трёх видов размещения: на 64-бит
// системе — в WOW6432Node, на 32-бит — в обычной ветке, и отдельно
// пользовательская установка в HKCU. Проверяем все три: пропустить одну значит
// поставить рантайм второй раз поверх имеющегося.
//
// `pv` = '0.0.0.0' означает «запись есть, рантайма нет» — так EdgeUpdate
// помечает удалённый компонент.
function WebView2Installed: Boolean;
var
  Ver: String;
begin
  Result := False;

  if RegQueryStringValue(HKLM32, 'SOFTWARE\Microsoft\EdgeUpdate\Clients\' + WebView2Guid, 'pv', Ver) then
    if (Ver <> '') and (Ver <> '0.0.0.0') then begin Result := True; Exit; end;

  if IsWin64 then
    if RegQueryStringValue(HKLM64, 'SOFTWARE\Microsoft\EdgeUpdate\Clients\' + WebView2Guid, 'pv', Ver) then
      if (Ver <> '') and (Ver <> '0.0.0.0') then begin Result := True; Exit; end;

  if RegQueryStringValue(HKCU, 'Software\Microsoft\EdgeUpdate\Clients\' + WebView2Guid, 'pv', Ver) then
    if (Ver <> '') and (Ver <> '0.0.0.0') then begin Result := True; Exit; end;
end;

// Создаём страницу загрузки при запуске мастера установки
procedure InitializeWizard;
begin
  PrereqPage := CreateDownloadPage(
    'Подготовка к установке',
    'Загрузка компонентов с серверов Microsoft...',
    nil
  );
end;

// Ставит WebView2 Runtime, если его нет.
//
// Ошибка здесь НЕ прерывает установку — и это осознанно. Без WebView2 клиент
// прекрасно играет видео, картинки и плейлисты; не открываются только
// HTML-страницы, и плеер честно пропускает такой слот с записью в лог.
// Ронять из-за этого установку нельзя тем более, что тот же установщик
// запускается тихо при автообновлении из панели: отказ означал бы экран,
// оставшийся на старой версии без единого признака почему.
procedure InstallWebView2;
var
  ResultCode: Integer;
begin
  if WebView2Installed then
    Exit;

  PrereqPage.Clear;
  PrereqPage.Add(WebView2Url, 'MicrosoftEdgeWebview2Setup.exe', '');
  PrereqPage.Show;
  try
    try
      PrereqPage.Download;
      // Без прав администратора bootstrapper ставит рантайм в профиль
      // пользователя — то есть UAC не появится и на автообновлении.
      Exec(
        ExpandConstant('{tmp}\MicrosoftEdgeWebview2Setup.exe'),
        '/silent /install',
        '',
        SW_HIDE,
        ewWaitUntilTerminated,
        ResultCode
      );
      if ResultCode <> 0 then
        Log('WebView2 runtime install failed with code ' + IntToStr(ResultCode) +
            '; HTML pages will not be available');
    except
      Log('WebView2 runtime download failed: ' + GetExceptionMessage +
          '; HTML pages will not be available');
    end;
  finally
    PrereqPage.Hide;
  end;
end;

// Перед установкой: доставляем недостающие компоненты.
//
// Разница между ними принципиальная: без VC++ Runtime приложение не стартует
// вообще, поэтому его отсутствие — повод прервать установку. WebView2 нужен
// одному виду контента, поэтому он ставится «по возможности».
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Result := '';

  if VCRedistNeedsInstall then begin
    // Runtime ставится только на всю машину — это единственное место, где нужен
    // администратор. При обычной пользовательской установке честно говорим, что
    // делать, вместо падения с невнятным кодом.
    if not IsAdminInstallMode then begin
      Result := 'Не установлен Visual C++ Runtime, а он ставится только с правами администратора.' + #13#10 +
                'Установите его один раз: ' + VCRedistUrl + #13#10 +
                'либо запустите этот установщик от имени администратора.';
      Exit;
    end;

    PrereqPage.Clear;
    PrereqPage.Add(VCRedistUrl, 'vc_redist.x64.exe', '');
    PrereqPage.Show;
    try
      try
        PrereqPage.Download;
        Exec(
          ExpandConstant('{tmp}\vc_redist.x64.exe'),
          '/install /quiet /norestart',
          '',
          SW_HIDE,
          ewWaitUntilTerminated,
          ResultCode
        );
        if ResultCode <> 0 then
          { строка-продолжение не должна начинаться с # — ISPP примет её за директиву }
          Result := 'Не удалось установить Visual C++ Runtime (код: ' + IntToStr(ResultCode) + ').' + #13#10 +
                    'Установите вручную: ' + VCRedistUrl;
      except
        Result := 'Ошибка загрузки Visual C++ Runtime.' + #13#10 +
                  'Проверьте интернет-соединение или установите вручную:' + #13#10 +
                  VCRedistUrl;
      end;
    finally
      PrereqPage.Hide;
    end;

    if Result <> '' then
      Exit;
  end;

  InstallWebView2;
end;

// Остановить процесс при деинсталляции
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ResultCode: Integer;
begin
  if CurUninstallStep = usUninstall then begin
    Exec('taskkill.exe', '/F /IM {#AppExeName}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;
end;
