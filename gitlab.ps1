#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Position=0)][ValidateSet('diagnostico','publicar','conectar')][string]$Acao = 'diagnostico',
    [Parameter(Position=1)][string]$Pasta = '.',
    [string]$Url,
    [string]$Nome,
    [string]$GitLabUrl = $(if ($env:GITLAB_URL) { $env:GITLAB_URL } else { 'https://gitlab.com' }),
    [ValidatePattern('^[1-9][0-9]*$')][string]$Grupo,
    [ValidateSet('private','internal','public')][string]$Visibilidade = 'private',
    [string]$Branch = 'main',
    [switch]$DryRun,
    [switch]$Help
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Os codigos dos executaveis nativos sao verificados explicitamente.
$PSNativeCommandUseErrorActionPreference = $false
function Invoke-GitChecked {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$GitArgs)
    $result = & git @GitArgs
    if ($LASTEXITCODE -ne 0) { throw "Git falhou: $($GitArgs[0]) (codigo $LASTEXITCODE)." }
    return $result
}
function ValidRemote([string]$Value) {
    return $Value -cmatch '^https://[^/@\s]+/[^\s]+$|^git@[^:\s]+:[^\s]+$|^ssh://git@[^/\s]+/[^\s]+$'
}
if ($Help) {
    @'
Uso: ./gitlab.ps1 diagnostico|publicar|conectar PASTA [opcoes]
  -Url URL                 Remoto existente HTTPS sem credenciais ou SSH
  -Nome NOME               Nome do projeto a criar (padrao: nome da pasta)
  -GitLabUrl URL           Instancia HTTPS (ou GITLAB_URL)
  -Grupo ID                ID numerico do namespace
  -Visibilidade private|internal|public (padrao private)
  -Branch main             Branch inicial para conectar pasta sem repositorio
  -DryRun                  Plano sem alteracoes ou rede
Publicar exige commits e arvore limpa. Prepare git add/commit manualmente.
GITLAB_TOKEN autentica a criacao; o push usa a autenticacao do Git.
Saida: 0 sucesso, 1 falha de operacao, 4 configuracao/uso invalido.
'@
    exit 0
}
$exitCode = 4
$pushed = $false
try {
    if (!(Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git nao encontrado.' }
    $directory = Get-Item -LiteralPath $Pasta
    if (!$directory.PSIsContainer) { throw 'Informe uma pasta.' }
    Push-Location -LiteralPath $directory.FullName
    $pushed = $true
    if (!$Nome) { $Nome = $directory.Name }
    $instance = [uri]$GitLabUrl
    if (!$instance.IsAbsoluteUri -or $instance.Scheme -ne 'https' -or $instance.UserInfo -or $instance.Query -or $instance.Fragment) {
        throw 'Instancia deve ser HTTPS sem credenciais, query ou fragmento.'
    }
    $GitLabUrl = $GitLabUrl.TrimEnd('/')
    if ($Url -and !(ValidRemote $Url)) { throw 'Remoto invalido ou com credenciais embutidas.' }
    & git check-ref-format --branch $Branch *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Branch invalida.' }
    & git rev-parse --git-dir *> $null
    $repo = $LASTEXITCODE -eq 0
    $origin = ''
    if ($repo) {
        if ((Invoke-GitChecked rev-parse --is-bare-repository) -ne 'false') { throw 'Repositorio bare nao suportado.' }
        $top = Get-Item -LiteralPath (Invoke-GitChecked rev-parse --show-toplevel)
        if ($top.FullName.TrimEnd('/','\') -ne $directory.FullName.TrimEnd('/','\')) { throw 'Informe a raiz do repositorio.' }
        $Branch = Invoke-GitChecked symbolic-ref --quiet --short HEAD
        $origin = & git remote get-url origin 2>$null
        if ($LASTEXITCODE -ne 0) { $origin = '' }
        if ($origin -and $Acao -eq 'publicar') {
            $pushUrls = @(Invoke-GitChecked remote get-url --push --all origin)
            if ($pushUrls.Count -ne 1 -or $pushUrls[0] -cne $origin) {
                throw 'Origin tem destinos de push diferentes ou multiplos. Revise a configuracao.'
            }
        }
    }
    Write-Output "Pasta: $($directory.FullName)"
    Write-Output "Branch: $Branch; repositorio: $repo; origin configurado: $([bool]$origin)"
    if ($repo) { Invoke-GitChecked status --short }
    if ($Acao -eq 'diagnostico') {
        Write-Output "Token API configurado: $([bool]$env:GITLAB_TOKEN)"
        Write-Output 'Diagnostico local; autenticacao remota nao foi testada.'
        exit 0
    }
    if ($Acao -eq 'conectar') {
        if (!$Url) { throw 'Conectar exige -Url.' }
        if ($origin -and $origin -cne $Url) { throw 'Origin ja existe e difere da URL. Nenhuma substituicao automatica.' }
        Write-Output 'Plano: inicializar se necessario e configurar origin. Sem push.'
        if ($DryRun) { exit 0 }
        $exitCode = 1
        if (!$repo) { Invoke-GitChecked init -b $Branch }
        if (!$origin) { Invoke-GitChecked remote add origin $Url }
        Write-Output 'Repositorio conectado.'
        exit 0
    }
    if (!$repo) { throw 'Prepare git init, git add e git commit antes de publicar.' }
    Invoke-GitChecked rev-parse --verify HEAD > $null
    if (Invoke-GitChecked status --porcelain --untracked-files=all) { throw 'Arvore suja: revise e faca commit antes de publicar.' }
    $files = Invoke-GitChecked -c core.quotePath=false ls-tree -r --name-only HEAD
    foreach ($file in $files) {
        $leaf = ($file -split '/')[-1]
        if ($leaf -in @('.env.example','.env.sample','.env.template')) { continue }
        if ($leaf -match '^(\.env(\..*)?|id_rsa|id_ed25519|credentials\.json)$|\.(key|p12|pfx)$') {
            throw "Arquivo potencialmente sensivel no commit: $file. Remova-o do historico antes de publicar."
        }
    }
    if ($origin -and $Url -and $origin -cne $Url) { throw 'Origin difere de -Url.' }
    $target = if ($origin) { $origin } else { $Url }
    if ($target) {
        if (!(ValidRemote $target)) { throw 'Origin invalido ou com credenciais embutidas.' }
        Write-Output "Plano: publicar branch $Branch no remoto existente, sem force."
    } else {
        Write-Output "Plano: criar $Nome ($Visibilidade) em $GitLabUrl e publicar $Branch."
        if (!$env:GITLAB_TOKEN -and !$DryRun) { throw 'Configure GITLAB_TOKEN para criar o projeto.' }
    }
    if ($DryRun) { Write-Output 'Simulacao concluida; nenhuma alteracao ou chamada de rede.'; exit 0 }
    $exitCode = 1
    if (!$target) {
        if ($env:GITLAB_TOKEN -match '[\r\n]') { throw 'Token invalido.' }
        $body = @{ name = $Nome; visibility = $Visibilidade }
        if ($Grupo) { $body.namespace_id = $Grupo }
        try {
            $response = Invoke-RestMethod -Uri "$GitLabUrl/api/v4/projects" -Method Post `
                -Headers @{ 'PRIVATE-TOKEN' = $env:GITLAB_TOKEN } -Body $body `
                -TimeoutSec 30 -MaximumRedirection 0 -StatusCodeVariable httpStatus
        } catch {
            # Nao reproduzir corpo/resposta que possa conter dados sensiveis.
            throw 'Falha na API. Verifique token, permissoes, nome e grupo; confira se o projeto foi criado antes de repetir.'
        }
        if ($httpStatus -ne 201) { throw "Resposta inesperada da API: HTTP $httpStatus. Confira o GitLab." }
        $target = [string]$response.http_url_to_repo
        if (!(ValidRemote $target) -or !$target.StartsWith("$GitLabUrl/", [StringComparison]::Ordinal)) {
            throw 'Projeto pode ter sido criado; URL retornada inesperada. Configure origin manualmente.'
        }
        Write-Output 'Projeto criado. Em caso de falha no push, reutilize origin na proxima tentativa.'
    }
    if (!$origin) { Invoke-GitChecked remote add origin $target }
    try { Invoke-GitChecked push -u origin $Branch }
    catch { throw 'Push falhou. Commits e origin preservados; corrija autenticacao/conflito e tente novamente.' }
    Write-Output 'Branch publicada com sucesso.'
    exit 0
} catch {
    [Console]::Error.WriteLine("Erro: $($_.Exception.Message)")
    exit $exitCode
} finally {
    if ($pushed) { Pop-Location }
}
