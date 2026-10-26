#!/usr/bin/env bash
# Compatibilidade: use gitlab.sh para a interface documentada.
exec bash "$(dirname -- "${BASH_SOURCE[0]}")/gitlab.sh" "$@"
