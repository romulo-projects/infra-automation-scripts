#!/usr/bin/env bash
# Atalho compativel com o uso interativo original.
if (($#)); then
    exec bash "$(dirname -- "${BASH_SOURCE[0]}")/certificados.sh" verificar "$@"
fi
read -r -p 'Host com dominio: ' servidor || exit 4
read -r -p 'Porta [443]: ' porta || exit 4
exec bash "$(dirname -- "${BASH_SOURCE[0]}")/certificados.sh" verificar "$servidor" --port "${porta:-443}"
