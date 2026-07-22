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

; Watchdog регистрируется из [Code] (RegisterWatchdog): при тихом обновлении
; выбор берётся из прошлой установки, а не из галочки, которую некому нажать.

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
; Watchdog — не просто автозапуск: задача в планировщике поднимает клиент при
; входе в систему и перезапускает, если он упал. Для экрана в холле, к которому
; никто не подходит, это единственный способ пережить сбой. Но для машины, где
; клиент ставят посмотреть, круглосуточно висящая задача не нужна — поэтому
; спрашиваем, а не навязываем.
Name: "watchdog"; Description: "Следить за приложением и перезапускать при сбое"; \
    GroupDescription: "Автозапуск:"

; Простой автозапуск без слежения — на случай, если планировщик недоступен
; (урезанная сборка Windows, политики домена).
Name: "autorun"; Description: "Просто запускать при входе в систему"; \
    GroupDescription: "Автозапуск:"; Flags: unchecked

Name: "desktopicon"; Description: "Создать ярлык на рабочем столе"; \
    GroupDescription: "Дополнительно:"; Flags: unchecked

[Registry]
; Автозапуск через реестр — только если его выбрали явно. Раньше запись
; создавалась при `Tasks: not desktopicon`, то есть автозапуск включался
; отсутствием ярлыка на рабочем столе: связи между ними нет никакой.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
    ValueType: string; ValueName: "{#AppName}"; \
    ValueData: """{app}\{#AppExeName}"""; \
    Flags: uninsdeletevalue; Tasks: autorun

; Выбор про watchdog запоминаем: при тихом автообновлении из панели галочку
; нажать некому, и брать её надо из прошлой установки.
Root: HKCU; Subkey: "Software\{#AppName}\Setup"; \
    ValueType: dword; ValueName: "Watchdog"; ValueData: "1"; \
    Flags: uninsdeletekey; Tasks: watchdog
Root: HKCU; Subkey: "Software\{#AppName}\Setup"; \
    ValueType: dword; ValueName: "Watchdog"; ValueData: "0"; \
    Flags: uninsdeletekey; Tasks: not watchdog

[Code]
const
  WatchdogTask = 'EFIR-Watchdog';
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

// --------------------------------------------------------- прошлые установки
// Ключ деинсталляции Inno лежит либо в HKCU (установка на пользователя), либо в
// HKLM (на машину). Смотрим оба: одну и ту же программу могли поставить и так,
// и так, и «прошлой версии нет» из-за проверки только одной ветки — это
// установка второй копии рядом с работающей.
function PreviousVersion(var Location: String): String;
var
  Key, Value: String;
begin
  Result := '';
  Location := '';
  Key := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{#AppId}_is1';

  if RegQueryStringValue(HKCU, Key, 'DisplayVersion', Value) then begin
    Result := Value;
    Location := 'для текущего пользователя';
    Exit;
  end;
  if RegQueryStringValue(HKLM, Key, 'DisplayVersion', Value) then begin
    Result := Value;
    Location := 'для всех пользователей';
  end;
end;

// Запуск powershell без окна. Ошибки намеренно не фатальны: ни одна из этих
// операций не стоит того, чтобы прервать установку клиента.
function RunHiddenPS(const Command: String): Integer;
begin
  if not Exec('powershell.exe',
      '-NonInteractive -ExecutionPolicy Bypass -Command "' + Command + '"',
      '', SW_HIDE, ewWaitUntilTerminated, Result) then
    Result := -1;
end;

// Перед заменой файлов watchdog надо остановить.
//
// Иначе он делает ровно то, для чего создан: видит, что efir.exe закрылся, и
// поднимает его обратно — прямо посреди копирования. Файлы оказываются
// заняты, обновление падает на «не удалось заменить», и экран остаётся на
// старой версии без единого внятного признака почему.
procedure StopWatchdogAndApp;
var
  Code: Integer;
begin
  RunHiddenPS('Stop-ScheduledTask -TaskName ''' + WatchdogTask + ''' -ErrorAction SilentlyContinue; ' +
              'Disable-ScheduledTask -TaskName ''' + WatchdogTask + ''' -ErrorAction SilentlyContinue');
  Exec('taskkill.exe', '/F /IM {#AppExeName}', '', SW_HIDE, ewWaitUntilTerminated, Code);
end;

procedure UnregisterWatchdog;
begin
  RunHiddenPS('Unregister-ScheduledTask -TaskName ''' + WatchdogTask + ''' -Confirm:$false -ErrorAction SilentlyContinue');
end;

// Нужен ли watchdog.
//
// В обычной установке — как выбрал человек. В тихой (автообновление из панели)
// галочки нет вовсе, поэтому берём выбор прошлой установки: обновление не
// должно менять поведение экрана, о котором его никто не просил.
function WantWatchdog: Boolean;
var
  Stored: Cardinal;
begin
  if not WizardSilent then begin
    Result := WizardIsTaskSelected('watchdog');
    Exit;
  end;
  if RegQueryDWordValue(HKCU, 'Software\{#AppName}\Setup', 'Watchdog', Stored) then
    Result := (Stored <> 0)
  else
    Result := True;  // ставили до появления выбора — вели себя как с watchdog
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

// Страница «Всё готово к установке». Про найденную прошлую версию говорим
// именно здесь: страница приветствия в Inno 6 по умолчанию скрыта
// (DisableWelcomePage=yes), а эта показывается всегда.
function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo,
  MemoTypeInfo, MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
var
  Version, Location: String;
begin
  Result := '';
  Version := PreviousVersion(Location);
  if Version <> '' then begin
    if Version = '{#AppVersion}' then
      Result := 'Обновление:' + NewLine + Space +
                'Версия {#AppVersion} уже установлена (' + Location + ') — будет переустановлена.' + NewLine + NewLine
    else
      Result := 'Обновление:' + NewLine + Space +
                'Установлена версия ' + Version + ' (' + Location + ') → будет обновлена до {#AppVersion}.' + NewLine + Space +
                'Регистрация экрана, журналы и кэш контента сохранятся.' + NewLine + NewLine;
  end;

  Result := Result + MemoDirInfo + NewLine + NewLine + MemoGroupInfo;
  if MemoTasksInfo <> '' then
    Result := Result + NewLine + NewLine + MemoTasksInfo;
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

  // Первым делом убрать с дороги watchdog и работающий клиент — иначе файлы
  // будут заняты в момент замены.
  StopWatchdogAndApp;

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

// После установки: watchdog регистрируем или снимаем — по выбору.
//
// Снимать обязательно: если человек снял галочку при обновлении, задача от
// прошлой установки осталась бы в планировщике и продолжила поднимать клиент.
procedure CurStepChanged(CurStep: TSetupStep);
var
  Code: Integer;
begin
  if CurStep <> ssPostInstall then
    Exit;

  if WantWatchdog then begin
    Exec('powershell.exe',
      '-NonInteractive -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\install-watchdog.ps1') +
      '" -AppPath "' + ExpandConstant('{app}\{#AppExeName}') + '" -Silent',
      '', SW_HIDE, ewWaitUntilTerminated, Code);
    if Code <> 0 then
      Log('watchdog registration failed with code ' + IntToStr(Code));
    // Ключ реестра пишется секцией [Registry] по галочке; в тихом режиме
    // галочки нет, поэтому проставляем сохранённый выбор здесь же.
    if WizardSilent then
      RegWriteDWordValue(HKCU, 'Software\{#AppName}\Setup', 'Watchdog', 1);
  end else begin
    UnregisterWatchdog;
    if WizardSilent then
      RegWriteDWordValue(HKCU, 'Software\{#AppName}\Setup', 'Watchdog', 0);
  end;
end;

// --------------------------------------------------------------- удаление
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ResultCode: Integer;
  DataDir: String;
begin
  if CurUninstallStep = usUninstall then begin
    // Порядок важен: сначала снять watchdog, потом убивать процесс. Наоборот —
    // watchdog успеет поднять клиент заново, и файлы останутся занятыми.
    UnregisterWatchdog;
    Exec('taskkill.exe', '/F /IM {#AppExeName}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;

  if CurUninstallStep = usPostUninstall then begin
    // Данные клиента: кэш медиа, логи и — главное — device.json с токеном
    // регистрации экрана. Удалить его значит потерять регистрацию: экран
    // придётся заново одобрять в панели. Поэтому спрашиваем и по умолчанию
    // оставляем; при тихом удалении не трогаем вовсе.
    DataDir := ExpandConstant('{userdocs}\efir');
    if not DirExists(DataDir) then
      Exit;
    if UninstallSilent then
      Exit;

    if MsgBox('Удалить данные клиента?' + #13#10#13#10 +
              DataDir + #13#10#13#10 +
              'Там кэш контента, журналы и регистрация экрана в панели.' + #13#10 +
              'Если удалить — экран придётся заново одобрять в панели.' + #13#10 +
              'Если оставить — при повторной установке всё подхватится само.',
              mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
    begin
      if not DelTree(DataDir, True, True, True) then
        MsgBox('Не удалось удалить папку целиком:' + #13#10 + DataDir + #13#10#13#10 +
               'Возможно, часть файлов занята. Удалите её вручную.',
               mbInformation, MB_OK);
    end;
  end;
end;
