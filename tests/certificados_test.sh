#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
export REAL_OPENSSL=$(command -v openssl)
export TEST_CERT="$tmp/cert.pem"
MSYS2_ARG_CONV_EXCL='/CN=' "$REAL_OPENSSL" req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/key.pem" \
    -out "$TEST_CERT" -days 90 -subj /CN=test.example \
    -addext subjectAltName=DNS:test.example >/dev/null 2>&1
mkdir "$tmp/bin"
cat > "$tmp/bin/openssl" <<'MOCK'
#!/usr/bin/env bash
if [[ $1 != s_client ]]; then exec "$REAL_OPENSSL" "$@"; fi
case " $* " in
    *failure.example*) exit 1 ;;
    *timeout.example*) sleep 3; exit 1 ;;
esac
cat "$TEST_CERT"
if [[ " $* " == *untrusted.example* ]]; then
    echo 'Verify return code: 18 (self-signed certificate)'
else
    echo 'Verify return code: 0 (ok)'
fi
MOCK
# Controlar o relogio permite testar expiracao sem certificado externo.
export REAL_DATE=$(command -v date)
cat > "$tmp/bin/date" <<'MOCK'
#!/usr/bin/env bash
if [[ ${TEST_EXPIRED:-0} == 1 && "$*" == '-u +%s' ]]; then
    exec "$REAL_DATE" -u -d '+100 days' +%s
fi
exec "$REAL_DATE" "$@"
MOCK
chmod +x "$tmp/bin/openssl" "$tmp/bin/date"
export PATH="$tmp/bin:$PATH"
checks=0
expect() {
    local expected=$1 actual=0; shift
    bash "$root/certificados.sh" "$@" > "$tmp/out" 2> "$tmp/err" || actual=$?
    [[ $actual == "$expected" ]] || { cat "$tmp/out" "$tmp/err"; echo "Esperado $expected, recebido $actual"; exit 1; }
    checks=$((checks + 1))
}
expect 0 --help
expect 4 verificar test.example --port 0
expect 4 verificar test.example --timeout
expect 0 verificar test.example
grep -q VALIDO "$tmp/out"
expect 1 verificar test.example --alerta-dias 100
grep -q ALERTA "$tmp/out"
export TEST_EXPIRED=1
expect 2 verificar test.example
grep -q EXPIRADO "$tmp/out"
unset TEST_EXPIRED
expect 3 verificar untrusted.example
grep -q TLS_INVALIDO "$tmp/out"
expect 3 verificar failure.example
expect 3 verificar timeout.example --timeout 1
grep -q 'Tempo limite' "$tmp/out"
printf '# teste\r\n test.example \r\nuntrusted.example:8443\r\nfailure.example\r\n' > "$tmp/list"
expect 3 verificar --lista "$tmp/list" --formato json
grep -q '"porta":8443' "$tmp/out"
grep -q '"dias_restantes":null' "$tmp/out"
expect 3 verificar --lista "$tmp/list" --formato csv
[[ $(wc -l < "$tmp/out") == 4 ]]
expect 0 baixar test.example --output "$tmp/download.pem"
"$REAL_OPENSSL" x509 -in "$tmp/download.pem" -noout >/dev/null
cp "$tmp/download.pem" "$tmp/original.pem"
expect 4 baixar test.example --output "$tmp/download.pem"
cmp "$tmp/download.pem" "$tmp/original.pem"
expect 3 baixar failure.example --output "$tmp/missing.pem"
[[ ! -e $tmp/missing.pem ]]
expect 3 baixar untrusted.example --output "$tmp/untrusted.pem"
[[ -s $tmp/untrusted.pem ]]
printf 'test.example\nbad host\n' > "$tmp/invalid-list"
expect 4 verificar --lista "$tmp/invalid-list"
printf '\n# vazio\n' > "$tmp/empty-list"
expect 4 verificar --lista "$tmp/empty-list"
bash "$root/certificado_validade.sh" test.example > "$tmp/out"
bash "$root/certificado_download.sh" test.example --output "$tmp/wrapper.pem" > "$tmp/out"
printf 'OK: %s cenarios e os dois atalhos.\n' "$checks"
