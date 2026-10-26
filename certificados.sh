#!/usr/bin/env bash
# Consulta TLS direta (HTTPS e outros servicos sem STARTTLS).
set -uo pipefail
export LC_ALL=C

usage() {
    cat <<'EOF'
Uso:
  bash certificados.sh verificar HOST [--port 443] [--alerta-dias 30]
  bash certificados.sh verificar --lista servidores.txt [--formato tabela|csv|json]
  bash certificados.sh baixar HOST [--port 443] --output certificado.pem
Opcoes: --timeout SEGUNDOS (padrao 10), --help
Lista: um host ou host:porta por linha; linhas vazias e comentarios # ignorados.
IPv6: use [endereco]:porta na lista ou --port na consulta individual.
Saida: 0 valido; 1 proximo ao vencimento; 2 expirado; 3 falha/TLS invalido;
       4 argumentos, dependencias ou arquivos invalidos. Em lote, prevalece o maior.
EOF
}
die() { printf 'Erro: %s\n' "$*" >&2; exit 4; }
[[ $# -gt 0 ]] || { usage; exit 4; }
case "$1" in -h|--help) usage; exit 0 ;; esac
action=$1; shift
[[ $action == verificar || $action == baixar ]] || die 'Comando desconhecido.'
host= port=443 days=30 limit=10 list= format=tabela output=
while (($#)); do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --port|--alerta-dias|--timeout|--lista|--formato|--output)
            (($# >= 2)) || die "Falta valor para $1"
            case "$1" in
                --port) port=$2 ;; --alerta-dias) days=$2 ;; --timeout) limit=$2 ;;
                --lista) list=$2 ;; --formato) format=$2 ;; --output) output=$2 ;;
            esac; shift 2 ;;
        -*) die "Opcao desconhecida: $1" ;;
        *) [[ -z $host ]] || die 'Informe apenas um host.'; host=$1; shift ;;
    esac
done
valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
valid_host() { [[ -n $1 && $1 != -* && $1 =~ ^[a-zA-Z0-9._:%-]+$ ]]; }
valid_port "$port" || die 'Porta invalida.'
[[ $days =~ ^[0-9]{1,5}$ ]] || die 'Alerta deve ser de 0 a 99999 dias.'
[[ $limit =~ ^[0-9]{1,4}$ ]] && ((10#$limit > 0)) || die 'Timeout deve ser de 1 a 9999 segundos.'
days=$((10#$days)); limit=$((10#$limit))
[[ $format == tabela || $format == csv || $format == json ]] || die 'Formato invalido.'
if [[ -n $list ]]; then
    [[ -z $host && $action == verificar && -r $list ]] || die 'Lista exige verificar, arquivo legivel e nenhum host avulso.'
else
    valid_host "$host" || die 'Informe um host valido, sem protocolo ou caminho.'
fi
[[ $action != baixar || ( -n $output && -z $list ) ]] || die 'Download exige host e --output.'
[[ $action != verificar || -z $output ]] || die 'Para exportar, redirecione a saida com > arquivo.'
for dependency in openssl timeout date mktemp sed; do
    command -v "$dependency" >/dev/null || die "Dependencia ausente: $dependency"
done
date -u -d 'Jan 1 2020' +%s >/dev/null 2>&1 || die 'GNU date necessario (Linux, WSL ou Git Bash).'
tmp=$(mktemp -d) || die 'Nao foi possivel criar pasta temporaria.'
trap 'rm -rf -- "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
hosts=(); ports=()
if [[ -n $list ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z $line || $line == \#* ]] && continue
        h=$line; p=$port
        if [[ $line =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
            h=${BASH_REMATCH[1]}; p=${BASH_REMATCH[2]}
        elif [[ $line == *:* && $line != *:*:* ]]; then
            h=${line%:*}; p=${line##*:}
        fi
        valid_host "$h" && valid_port "$p" || die "Entrada invalida na lista: $line"
        hosts+=("$h"); ports+=("$p")
    done < "$list"
    ((${#hosts[@]})) || die 'Lista vazia.'
else
    hosts+=("$host"); ports+=("$port")
fi
json_string() {
    local value=$1
    value=${value//\\/\\\\}; value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}; value=${value//$'\r'/\\r}; value=${value//$'\t'/\\t}
    printf '"%s"' "$value"
}
csv_string() { local value=${1//\"/\"\"}; printf '"%s"' "$value"; }
result=0; separator=
if [[ $action == verificar ]]; then
    case "$format" in
        tabela) printf '%-35s %-6s %-18s %-8s %s\n' HOST PORTA STATUS DIAS VENCIMENTO_UTC ;;
        csv) printf 'host,porta,status,dias_restantes,vencimento_utc,emissor,dominios,detalhe\n' ;;
        json) printf '[\n' ;;
    esac
fi
for i in "${!hosts[@]}"; do
    h=${hosts[$i]}; p=${ports[$i]}; address=$h
    [[ $h != *:* ]] || address="[$h]"
    verify=(-verify_hostname "$h")
    [[ $h != *:* && ! $h =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || verify=(-verify_ip "$h")
    status=ERRO; code=3; remaining=; expiry=; issuer=; domains=; detail=
    timeout "$limit" openssl s_client -connect "$address:$p" -servername "$h" \
        "${verify[@]}" -showcerts </dev/null >"$tmp/session" 2>"$tmp/error"
    connection=$?
    if ((connection == 124)); then
        detail='Tempo limite de conexao excedido.'
    elif ! openssl x509 -in "$tmp/session" -out "$tmp/cert.pem" 2>/dev/null; then
        detail='Falha de conexao ou servidor sem certificado TLS.'
    else
        end=$(openssl x509 -in "$tmp/cert.pem" -noout -enddate)
        start=$(openssl x509 -in "$tmp/cert.pem" -noout -startdate)
        end_epoch=$(date -u -d "${end#*=}" +%s) || die 'Data de vencimento invalida.'
        start_epoch=$(date -u -d "${start#*=}" +%s) || die 'Data de inicio invalida.'
        now=$(date -u +%s); seconds=$((end_epoch - now)); remaining=$((seconds / 86400))
        expiry=$(date -u -d "@$end_epoch" '+%Y-%m-%dT%H:%M:%SZ')
        issuer=$(openssl x509 -in "$tmp/cert.pem" -noout -issuer); issuer=${issuer#issuer=}
        domains=$(openssl x509 -in "$tmp/cert.pem" -noout -ext subjectAltName 2>/dev/null | sed '1d;s/^[[:space:]]*//')
        detail=$(sed -n 's/^[[:space:]]*Verify return code: /TLS: /p' "$tmp/session")
        if ((seconds <= 0)); then status=EXPIRADO; code=2
        elif ((start_epoch > now)); then status=TLS_INVALIDO; code=3
        elif ((connection != 0)) || [[ $detail != 'TLS: 0 (ok)' ]]; then status=TLS_INVALIDO; code=3
        elif ((seconds <= days * 86400)); then status=ALERTA; code=1
        else status=VALIDO; code=0
        fi
        if [[ $action == baixar ]]; then
            [[ ! -e $output && ! -L $output ]] || die "Destino ja existe: $output"
            # noclobber evita sobrescrita inclusive se o destino surgir durante a consulta.
            (set -o noclobber; cat "$tmp/cert.pem" > "$output") || die 'Falha ao gravar certificado.'
            printf 'Certificado salvo em %s. Status: %s. %s\n' "$output" "$status" "$detail"
        fi
    fi
    ((code <= result)) || result=$code
    if [[ $action == baixar ]]; then
        [[ -z $expiry ]] && printf 'Erro: %s\n' "$detail" >&2
        continue
    fi
    case "$format" in
        tabela)
            printf '%-35s %-6s %-18s %-8s %s\n' "$h" "$p" "$status" "${remaining:--}" "${expiry:--}"
            printf '  Emissor: %s\n  Dominios: %s\n  %s\n' "${issuer:--}" "${domains:--}" "$detail" ;;
        csv)
            values=("$h" "$p" "$status" "$remaining" "$expiry" "$issuer" "$domains" "$detail")
            for j in "${!values[@]}"; do ((j == 0)) || printf ','; csv_string "${values[$j]}"; done; printf '\n' ;;
        json)
            printf '%s  {"host":' "$separator"; json_string "$h"
            printf ',"porta":%d,"status":' "$((10#$p))"; json_string "$status"
            printf ',"dias_restantes":%s,"vencimento_utc":' "${remaining:-null}"; json_string "$expiry"
            printf ',"emissor":'; json_string "$issuer"; printf ',"dominios":'; json_string "$domains"
            printf ',"detalhe":'; json_string "$detail"; printf '}'
            separator=$',\n' ;;
    esac
done
[[ $action != verificar || $format != json ]] || printf '\n]\n'
exit "$result"
