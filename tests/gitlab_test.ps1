#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('gitlab-tests-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tempRoot > $null
$script:checks = 0
$previousSsh = $env:GIT_SSH_COMMAND
$bash = if ($IsWindows) { 'C:\Program Files\Git\bin\bash.exe' } else { 'bash' }
function Check([string]$Engine, [int]$Expected, [string[]]$Arguments) {
    $output = if ($Engine -eq 'bash') {
        & $bash (Join-Path $root 'gitlab.sh') @Arguments 2>&1
    } else {
        & pwsh -NoProfile -File (Join-Path $root 'gitlab.ps1') @Arguments 2>&1
    }
    $actual = $LASTEXITCODE
    if ($actual -ne $Expected) { throw "$Engine esperado $Expected, recebido $actual : $output" }
    $script:checks++
    return ($output -join "`n")
}
function RunGit([string[]]$GitArgs) {
    & git @GitArgs > $null
    if ($LASTEXITCODE -ne 0) { throw "Falha na preparacao Git: $GitArgs" }
}
try {
    foreach ($engine in @('bash','powershell')) {
        $folder = Join-Path $tempRoot "$engine project"
        New-Item -ItemType Directory $folder > $null
        $dry = if ($engine -eq 'bash') { '--dry-run' } else { '-DryRun' }
        $url = if ($engine -eq 'bash') { '--url' } else { '-Url' }
        Check $engine 0 @('diagnostico', $folder) > $null
        Check $engine 0 @('conectar', $folder, $url, 'https://gitlab.example/team/test.git', $dry) > $null
        if (Test-Path (Join-Path $folder '.git')) { throw 'Dry run criou repositorio.' }
        Check $engine 4 @('publicar', $folder, $url, 'https://gitlab.example/team/test.git', $dry) > $null
        Check $engine 0 @('conectar', $folder, $url, 'https://gitlab.example/team/test.git') > $null
        Check $engine 0 @('conectar', $folder, $url, 'https://gitlab.example/team/test.git') > $null
        Check $engine 4 @('conectar', $folder, $url, 'https://gitlab.example/team/other.git') > $null
        Check $engine 4 @('publicar', $folder, $dry) > $null
        Set-Content (Join-Path $folder 'README.md') 'fixture'
        RunGit @('-C', $folder, 'add', 'README.md')
        RunGit @('-C', $folder, '-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-m', 'fixture')
        Check $engine 0 @('publicar', $folder, $dry) > $null
        RunGit @('-C', $folder, 'remote', 'set-url', '--push', 'origin', 'https://other.example/team/test.git')
        Check $engine 4 @('publicar', $folder, $dry) > $null
        RunGit @('-C', $folder, 'config', '--unset-all', 'remote.origin.pushurl')
        Set-Content (Join-Path $folder 'pendente.txt') 'pending'
        Check $engine 4 @('publicar', $folder, $dry) > $null
        New-Item -ItemType Directory (Join-Path $folder 'subfolder') > $null
        Check $engine 4 @('diagnostico', (Join-Path $folder 'subfolder')) > $null
        RunGit @('-C', $folder, 'add', 'pendente.txt')
        Set-Content (Join-Path $folder '.env') 'FAKE_SECRET=test'
        RunGit @('-C', $folder, 'add', '.env')
        RunGit @('-C', $folder, '-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-m', 'sensitive fixture')
        Check $engine 4 @('publicar', $folder, $dry) > $null
        # Push negado localmente: um hook aborta antes de qualquer conexao de rede.
        RunGit @('-C', $folder, 'rm', '.env')
        RunGit @('-C', $folder, '-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-m', 'remove fixture')
        $hook = Join-Path $folder '.git/hooks/pre-push'
        [IO.File]::WriteAllText($hook, "#!/bin/sh`nexit 1`n")
        if (!$IsWindows) { & chmod +x $hook }
        # Um remoto local testa a falha via protocolo SSH simulado sem rede.
        $env:GIT_SSH_COMMAND = if ($IsWindows) { 'C:/Windows/System32/cmd.exe /c exit 1' } else { 'false' }
        RunGit @('-C', $folder, 'remote', 'set-url', 'origin', 'git@gitlab.example:team/test.git')
        $failed = Check $engine 1 @('publicar', $folder)
        if ($failed -match 'publicada com sucesso') { throw 'Falso sucesso no push.' }
    }
    Write-Output "OK: $script:checks cenarios Shell/PowerShell, sem acesso a API ou publicacao."
} finally {
    $env:GIT_SSH_COMMAND = $previousSsh
    # Exclusao limitada ao diretorio temporario criado neste teste.
    $resolved = [IO.Path]::GetFullPath($tempRoot)
    $allowed = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf).StartsWith('gitlab-tests-')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
