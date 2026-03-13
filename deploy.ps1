param(
  [Parameter(Position = 0)]
  [string]$Mode = '',

  [string]$HostName = $(if ($env:HOST) { $env:HOST } else { '10.0.0.81' }),
  [string]$SshUser = $(if ($env:SSH_USER) { $env:SSH_USER } else { 'dozzka' }),
  [int]$SshPort = $(if ($env:SSH_PORT) { [int]$env:SSH_PORT } else { 22 }),
  [string]$RemoteDir = $(if ($env:REMOTE_DIR) { $env:REMOTE_DIR } else { '/home/dozzka/client' }),
  [string]$RemoteFlutter = $(if ($env:REMOTE_FLUTTER) { $env:REMOTE_FLUTTER } else { '/home/dozzka/flutter/bin/flutter' }),
  [string]$AppName = $(if ($env:APP_NAME) { $env:APP_NAME } else { 'panel' }),
  [string]$SshKeyPath = $(if ($env:SSH_KEY_PATH) { $env:SSH_KEY_PATH } else { "$env:USERPROFILE\.ssh\id_ed25519" }),
  [string]$RemoteAppDataDir = $(if ($env:REMOTE_APP_DATA_DIR) { $env:REMOTE_APP_DATA_DIR } else { '' })
)

$ErrorActionPreference = 'Stop'

if ($Mode -and $Mode -ne 'new') {
  throw "Unsupported mode '$Mode'. Use 'new' or leave it empty."
}

$isFreshStart = $Mode -eq 'new'

function Require-Command {
  param([string]$Name)

  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command not found: $Name"
  }
}

function Quote-ForSh {
  param([string]$Value)

  return "'" + ($Value -replace "'", "'""'""'") + "'"
}

function Invoke-Ssh {
  param(
    [string[]]$CommonArgs,
    [string]$Target,
    [string]$Command,
    [string]$ErrorMessage
  )

  & ssh @CommonArgs $Target $Command
  if ($LASTEXITCODE -ne 0) {
    throw $ErrorMessage
  }
}

function Get-RequiredFile {
  param(
    [string]$Url,
    [string]$DestinationPath,
    [string]$ExpectedMd5
  )

  $needsDownload = $true
  if (Test-Path -LiteralPath $DestinationPath) {
    $actualMd5 = (Get-FileHash -LiteralPath $DestinationPath -Algorithm MD5).Hash.ToLowerInvariant()
    if ($actualMd5 -eq $ExpectedMd5.ToLowerInvariant()) {
      $needsDownload = $false
    } else {
      Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
    }
  }

  if ($needsDownload) {
    Invoke-WebRequest -Uri $Url -OutFile $DestinationPath
    $downloadedMd5 = (Get-FileHash -LiteralPath $DestinationPath -Algorithm MD5).Hash.ToLowerInvariant()
    if ($downloadedMd5 -ne $ExpectedMd5.ToLowerInvariant()) {
      throw "Downloaded file hash mismatch for $Url"
    }
  }
}

Require-Command ssh
Require-Command scp
Require-Command tar

if (-not (Test-Path -LiteralPath $SshKeyPath)) {
  throw "SSH key not found: $SshKeyPath"
}

$target = "$SshUser@$HostName"
$sshCommon = @(
  '-p', "$SshPort",
  '-o', 'BatchMode=yes',
  '-o', 'PreferredAuthentications=publickey',
  '-o', 'PasswordAuthentication=no',
  '-o', 'IdentitiesOnly=yes',
  '-i', $SshKeyPath
)
$scpCommon = @(
  '-P', "$SshPort",
  '-o', 'BatchMode=yes',
  '-o', 'PreferredAuthentications=publickey',
  '-o', 'PasswordAuthentication=no',
  '-o', 'IdentitiesOnly=yes',
  '-i', $SshKeyPath
)

$remoteArchivePath = "/tmp/$AppName-src.tar.gz"
$archivePath = Join-Path $env:TEMP "$AppName-src-$PID.tar.gz"
$mimallocArchivePath = Join-Path $env:TEMP 'mimalloc-2.1.2.tar.gz'
$mimallocUrl = 'https://github.com/microsoft/mimalloc/archive/refs/tags/v2.1.2.tar.gz'
$mimallocMd5 = '5179c8f5cf1237d2300e2d8559a7bc55'
$remoteDirQuoted = Quote-ForSh $RemoteDir
$remoteFlutterQuoted = Quote-ForSh $RemoteFlutter
$appNameQuoted = Quote-ForSh $AppName
$bundleDirQuoted = Quote-ForSh "$RemoteDir/build/linux/x64/release/bundle"
$runLogQuoted = Quote-ForSh "$RemoteDir/$AppName.log"
$remoteReleaseDirQuoted = Quote-ForSh "$RemoteDir/build/linux/x64/release"
$remoteMimallocArchivePath = "$RemoteDir/build/linux/x64/release/mimalloc-2.1.2.tar.gz"

try {
  Write-Host "==> Packing project for deploy"
  & tar `
    '--format' 'ustar' `
    '-czf' $archivePath `
    '--exclude=build' `
    '--exclude=.dart_tool' `
    '--exclude=.git' `
    '--exclude=.idea' `
    '.'
  if ($LASTEXITCODE -ne 0) {
    throw 'Failed to create project archive'
  }

  Write-Host "==> Preparing remote directory: $RemoteDir"
  $prepareRemoteCmd = "mkdir -p $remoteDirQuoted && find $remoteDirQuoted -mindepth 1 -maxdepth 1 -exec rm -rf {} +"
  Invoke-Ssh -CommonArgs $sshCommon -Target $target -Command $prepareRemoteCmd -ErrorMessage 'Failed to prepare remote directory'

  Write-Host "==> Uploading project archive to $target"
  & scp @scpCommon $archivePath "${target}:$remoteArchivePath"
  if ($LASTEXITCODE -ne 0) {
    throw 'Failed to upload project archive'
  }

  Write-Host "==> Extracting project on remote host"
  $extractRemoteCmd = "tar -xzf $(Quote-ForSh $remoteArchivePath) -C $remoteDirQuoted && rm -f $(Quote-ForSh $remoteArchivePath)"
  Invoke-Ssh -CommonArgs $sshCommon -Target $target -Command $extractRemoteCmd -ErrorMessage 'Failed to extract project archive on remote host'

  Write-Host '==> Preloading media_kit native archive'
  Get-RequiredFile -Url $mimallocUrl -DestinationPath $mimallocArchivePath -ExpectedMd5 $mimallocMd5
  $prepareBuildDepsCmd = "mkdir -p $remoteReleaseDirQuoted"
  Invoke-Ssh -CommonArgs $sshCommon -Target $target -Command $prepareBuildDepsCmd -ErrorMessage 'Failed to prepare remote build dependency directory'
  & scp @scpCommon $mimallocArchivePath "${target}:$remoteMimallocArchivePath"
  if ($LASTEXITCODE -ne 0) {
    throw 'Failed to upload media_kit native archive'
  }

  if ($isFreshStart) {
    Write-Host '==> Fresh start requested, clearing panel data directories'
    if ($RemoteAppDataDir) {
      $quotedDataDirs = (,@($RemoteAppDataDir) | ForEach-Object { Quote-ForSh $_ }) -join ' '
      $clearDataCmd = "rm -rf $quotedDataDirs"
    } else {
      $clearDataCmd = @"
docs_dir=`$(xdg-user-dir DOCUMENTS 2>/dev/null || true)
if [ -z "`$docs_dir" ]; then
  docs_dir="`$HOME/Documents"
fi
rm -rf "`$docs_dir/$AppName" "`$HOME/.local/share/$AppName"
"@
    }
    Invoke-Ssh -CommonArgs $sshCommon -Target $target -Command $clearDataCmd -ErrorMessage 'Failed to clear remote panel data directories'
  }

  Write-Host "==> Building Flutter app on remote host"
  $buildRemoteCmd = "cd $remoteDirQuoted && $remoteFlutterQuoted pub get --offline && $remoteFlutterQuoted build linux --no-pub"
  Invoke-Ssh -CommonArgs $sshCommon -Target $target -Command $buildRemoteCmd -ErrorMessage 'Remote Flutter build failed'

  Write-Host "==> Restarting application: $AppName"
  $restartRemoteCmd = "pkill -x $appNameQuoted || true && cd $bundleDirQuoted && DISPLAY=:0 nohup ./$AppName > $runLogQuoted 2>&1 < /dev/null &"
  Invoke-Ssh -CommonArgs $sshCommon -Target $target -Command $restartRemoteCmd -ErrorMessage 'Failed to restart remote application'

  Write-Host '==> Deploy finished'
}
finally {
  if (Test-Path -LiteralPath $archivePath) {
    Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
  }
}
