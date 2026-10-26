#!/usr/bin/env bash
set -euo pipefail
usage() {
    cat <<'EOF'
Uso: bash gitlab.sh diagnostico|publicar|conectar PASTA [opcoes]
  --url URL             Remoto HTTPS/SSH existente (obrigatorio para conectar)
  --nome NOME           Nome do projeto a criar (padrao: nome da pasta)
  --gitlab-url URL      Instancia HTTPS (ou GITLAB_URL; padrao https://gitlab.com)
  --grupo ID            ID numerico do namespace/grupo
  --visibilidade VALOR  private (padrao), internal ou public
  --branch NOME         Branch inicial em pasta sem repositorio (padrao main)
  --dry-run             Exibe o plano sem rede ou alteracoes
  --help                Ajuda
Publicar exige commits existentes e arvore limpa. Prepare git add/commit manualmente.
Conectar somente adiciona origin; nao cria projeto, commit ou push.
Token de criacao: GITLAB_TOKEN. Push usa a autenticacao do proprio Git.
Saida: 0 sucesso; 1 falha de operacao; 4 uso/configuracao invalida.
EOF
}
die() { printf 'Erro: %s\n' "$*" >&2; exit 4; }
trap 'printf "Falha na operacao. Nenhum rollback automatico foi realizado.\n" >&2; exit 1' ERR
[[ $# -gt 0 ]] || { usage; exit 4; }
[[ $1 != --help && $1 != -h ]] || { usage; exit 0; }
action=$1; shift
[[ $action == diagnostico || $action == publicar || $action == conectar ]] || die 'Comando invalido.'
[[ $# -gt 0 && $1 != -* ]] || die 'Informe a pasta do projeto.'
folder=$1; shift
url= name= group= visibility=private branch=main dry=0
base=${GITLAB_URL:-https://gitlab.com}
while (($#)); do
    case "$1" in
        --help) usage; exit 0 ;;
        --dry-run) dry=1; shift ;;
        --url|--nome|--grupo|--visibilidade|--branch|--gitlab-url)
            (($# >= 2)) || die "Falta valor para $1"
            case "$1" in
                --url) url=$2 ;; --nome) name=$2 ;; --grupo) group=$2 ;;
                --visibilidade) visibility=$2 ;; --branch) branch=$2 ;; --gitlab-url) base=$2 ;;
            esac; shift 2 ;;
        *) die "Opcao desconhecida: $1" ;;
    esac
done
command -v git >/dev/null || die 'Git nao encontrado.'
[[ -d $folder ]] || die 'Pasta inexistente.'
cd -- "$folder" || die 'Nao foi possivel acessar a pasta.'
folder=$(pwd -P)
[[ -n $name ]] || name=${folder##*/}
[[ $visibility == private || $visibility == internal || $visibility == public ]] || die 'Visibilidade invalida.'
[[ -z $group || $group =~ ^[1-9][0-9]*$ ]] || die 'Grupo deve ser ID numerico positivo.'
git check-ref-format --branch "$branch" >/dev/null 2>&1 || die 'Nome de branch invalido.'
[[ $base =~ ^https://[^/@[:space:]?#]+(/[^[:space:]?#]*)?$ ]] || die 'Instancia deve ser HTTPS e nao conter credenciais.'
base=${base%/}
valid_remote() { [[ $1 =~ ^https://[^/@[:space:]]+/[^[:space:]]+$ || $1 =~ ^git@[^:[:space:]]+:[^[:space:]]+$ || $1 =~ ^ssh://git@[^/[:space:]]+/[^[:space:]]+$ ]]; }
[[ -z $url ]] || valid_remote "$url" || die 'Remoto deve ser HTTPS sem credenciais ou SSH (git@host:caminho).'
repo=0; origin=
if git rev-parse --git-dir >/dev/null 2>&1; then
    [[ $(git rev-parse --is-bare-repository) == false ]] || die 'Repositorio bare nao suportado.'
    top=$(git rev-parse --show-toplevel)
    [[ $(cd -- "$top" && pwd -P) == "$folder" ]] || die 'Informe a raiz do repositorio, nao uma subpasta.'
    repo=1
    branch=$(git symbolic-ref --quiet --short HEAD) || die 'HEAD destacado: selecione uma branch.'
    origin=$(git remote get-url origin 2>/dev/null || true)
    if [[ -n $origin && $action == publicar ]]; then
        [[ $(git remote get-url --push --all origin) == "$origin" ]] || die 'Origin tem destinos de push diferentes ou multiplos. Revise a configuracao.'
    fi
fi
printf 'Pasta: %s\nBranch: %s\nRepositorio Git: %s\nOrigin configurado: %s\n' "$folder" "$branch" "$repo" "$([[ -n $origin ]] && echo sim || echo nao)"
if ((repo)); then
    git status --short
else
    printf 'Sem repositorio. Conectar pode inicializa-lo; publicar exige commits preparados.\n'
fi
if [[ $action == diagnostico ]]; then
    printf 'Token API configurado: %s\n' "$([[ -n ${GITLAB_TOKEN:-} ]] && echo sim || echo nao)"
    printf 'Diagnostico local; autenticacao remota nao foi testada.\n'
    exit 0
fi
if [[ $action == conectar ]]; then
    [[ -n $url ]] || die 'Conectar exige --url.'
    [[ -z $origin || $origin == "$url" ]] || die 'Origin ja existe e e diferente. Nenhuma substituicao automatica.'
    printf 'Plano: inicializar se necessario e configurar origin. Sem push.\n'
    ((dry == 0)) || exit 0
    ((repo)) || git init -b "$branch"
    [[ -n $origin ]] || git remote add origin "$url"
    printf 'Repositorio conectado.\n'
    exit 0
fi
((repo)) || die 'Prepare o repositorio com git init, git add e git commit antes de publicar.'
git rev-parse --verify HEAD >/dev/null 2>&1 || die 'Repositorio sem commits.'
[[ -z $(git status --porcelain --untracked-files=all) ]] || die 'Arvore suja: revise e faca commit dos arquivos antes de publicar.'
# Bloqueio preventivo por nome nos arquivos presentes no commit atual.
while IFS= read -r -d '' file; do
    leaf=${file##*/}
    case "${leaf,,}" in
        .env.example|.env.sample|.env.template) continue ;;
        .env|.env.*|*.key|*.p12|*.pfx|id_rsa|id_ed25519|credentials.json)
            die "Arquivo potencialmente sensivel no commit: $file. Remova-o do historico antes de publicar." ;;
    esac
done < <(git ls-tree -r --name-only -z HEAD)
if [[ -n $origin && -n $url && $origin != "$url" ]]; then die 'Origin difere de --url.'; fi
target=${origin:-$url}
if [[ -n $target ]]; then
    valid_remote "$target" || die 'Origin usa formato nao suportado ou contem credenciais.'
    printf 'Plano: publicar a branch %s no remoto existente, sem force.\n' "$branch"
else
    printf 'Plano: criar projeto %s (%s) em %s e publicar a branch %s.\n' "$name" "$visibility" "$base" "$branch"
    for dependency in curl jq; do command -v "$dependency" >/dev/null || die "Dependencia ausente: $dependency"; done
    [[ -n ${GITLAB_TOKEN:-} ]] || ((dry)) || die 'Configure GITLAB_TOKEN para criar o projeto.'
fi
((dry == 0)) || { printf 'Simulacao concluida; nenhuma alteracao ou chamada de rede.\n'; exit 0; }
if [[ -z $target ]]; then
    [[ $GITLAB_TOKEN != *$'\n'* && $GITLAB_TOKEN != *$'\r'* ]] || die 'Token invalido.'
    tmp=$(mktemp -d)
    trap 'rm -rf -- "$tmp"' EXIT
    # Header em stdin evita colocar o token nos argumentos do processo curl.
    args=(--silent --show-error --connect-timeout 10 --max-time 30 --max-redirs 0
        --header @- --request POST --data-urlencode "name=$name" --data-urlencode "visibility=$visibility")
    [[ -z $group ]] || args+=(--data-urlencode "namespace_id=$group")
    http=$(printf 'PRIVATE-TOKEN: %s\n' "$GITLAB_TOKEN" | curl "${args[@]}" --output "$tmp/response" --write-out '%{http_code}' "$base/api/v4/projects") || { printf 'Falha de rede ao criar projeto. Verifique o GitLab antes de tentar novamente.\n' >&2; exit 1; }
    [[ $http == 201 ]] || { printf 'Criacao recusada: HTTP %s. Verifique token, permissoes, nome e grupo.\n' "$http" >&2; exit 1; }
    target=$(jq -er '.http_url_to_repo | select(type == "string" and length > 0)' "$tmp/response") || { printf 'Projeto pode ter sido criado, mas a resposta e invalida. Confira o GitLab.\n' >&2; exit 1; }
    valid_remote "$target" && [[ $target == "$base/"* ]] || { printf 'Projeto criado; URL retornada inesperada. Configure o remoto manualmente.\n' >&2; exit 1; }
    printf 'Projeto remoto criado. Em caso de falha no push, reutilize origin na proxima tentativa.\n'
fi
[[ -n $origin ]] || git remote add origin "$target"
if ! git push -u origin "$branch"; then
    printf 'Push falhou. Commits e origin foram preservados; corrija a autenticacao/conflito e tente novamente.\n' >&2
    exit 1
fi
printf 'Branch publicada com sucesso.\n'
