#requires -Version 7.0
param([string]$Case, [string]$Folder)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if ($Case) {
    $realGit = (Get-Command git -CommandType Application | Select-Object -First 1).Source
    function global:git {
        if ($args[0] -eq 'push') {
            $global:LASTEXITCODE = if ($Case -eq 'push-failure') { 1 } else { 0 }
            return
        }
        & $realGit @args
        $global:LASTEXITCODE = $LASTEXITCODE
    }
    function global:Invoke-RestMethod {
        param($Uri, $Method, $Headers, $Body, $TimeoutSec, $MaximumRedirection, $StatusCodeVariable)
        if ($Uri -ne 'https://gitlab.example/api/v4/projects' -or $Method -ne 'Post' -or $Body.visibility -ne 'private' -or $Body.namespace_id -ne '123') {
            throw 'Requisicao incorreta.'
        }
        if ($Case -eq 'api-failure') { throw 'Simulated API failure' }
        Set-Variable -Name $StatusCodeVariable -Value 201 -Scope 1
        if ($Case -eq 'invalid-response') { return @{ http_url_to_repo = 'https://other.example/project.git' } }
        return @{ http_url_to_repo = 'https://gitlab.example/team/project.git' }
    }
    $env:GITLAB_TOKEN = 'fixture-not-a-real-token'
    & (Join-Path $root 'gitlab.ps1') publicar $Folder -GitLabUrl https://gitlab.example -Grupo 123
    exit $LASTEXITCODE
}
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('gitlab-api-tests-' + [guid]::NewGuid())
New-Item -ItemType Directory $tempRoot > $null
try {
    foreach ($scenario in @('success','api-failure','invalid-response','push-failure')) {
        $project = Join-Path $tempRoot $scenario
        & git init -b main $project > $null
        if ($LASTEXITCODE) { throw 'Falha no init.' }
        Set-Content (Join-Path $project 'README.md') 'fixture'
        & git -C $project add README.md
        & git -C $project -c user.name=Test -c user.email=test@example.com commit -m fixture > $null
        if ($LASTEXITCODE) { throw 'Falha no commit.' }
        $output = & pwsh -NoProfile -File $PSCommandPath -Case $scenario -Folder $project 2>&1
        $expected = if ($scenario -eq 'success') { 0 } else { 1 }
        if ($LASTEXITCODE -ne $expected) { throw "$scenario retornou $LASTEXITCODE : $output" }
        if ($scenario -in @('success','push-failure')) {
            $origin = & git -C $project remote get-url origin
            if ($origin -ne 'https://gitlab.example/team/project.git') { throw 'Origin nao preservado.' }
        } else {
            $remotes = & git -C $project remote
            if ($remotes) { throw 'Origin configurado apos erro da API.' }
        }
        if ($scenario -ne 'success' -and ($output -join "`n") -match 'publicada com sucesso') { throw 'Falso sucesso.' }
    }
    'OK: 4 cenarios da API PowerShell simulada (criacao, recusa, URL invalida e falha no push).'
} finally {
    $resolved = [IO.Path]::GetFullPath($tempRoot)
    $allowed = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf).StartsWith('gitlab-api-tests-')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
