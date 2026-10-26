# Compatibilidade: use gitlab.ps1 para a interface documentada.
& (Join-Path $PSScriptRoot 'gitlab.ps1') @args
exit $LASTEXITCODE
