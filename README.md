# infra-automation-scripts

Ferramentas para consultar certificados TLS e publicar projetos no GitLab.

## Certificados TLS

Requisitos: Bash 4+, OpenSSL com `-verify_hostname`, GNU `date`, `timeout` e utilitários básicos (`sed`, `mktemp`, `cat`, `rm`). Execute em Linux, WSL ou Git Bash com essas dependências no PATH. O `date` nativo do macOS não é suportado.

```bash
# Consulta individual: vencimento UTC, dias restantes, emissor e domínios
bash certificados.sh verificar example.com

# Alerta de 15 dias; timeout por servidor de 5 segundos
bash certificados.sh verificar example.com --alerta-dias 15 --timeout 5

# Vários servidores (consulte servidores.exemplo.txt)
bash certificados.sh verificar --lista servidores.exemplo.txt

# Exportação para integrações
bash certificados.sh verificar --lista servidores.exemplo.txt --formato csv > relatorio.csv
bash certificados.sh verificar --lista servidores.exemplo.txt --formato json > relatorio.json

# Baixar o certificado apresentado pelo servidor
bash certificados.sh baixar example.com --output example.pem

bash certificados.sh --help
```

A lista aceita um host ou `host:porta` por linha, linhas vazias e comentários iniciados por `#`. IPv6 com porta deve usar `[endereco]:porta`. `--port` define a porta padrão (443). A consulta em lote é sequencial e continua quando um servidor falha. Entradas inválidas são rejeitadas antes das consultas.

### Estados e códigos de saída

| Código | Estado | Significado |
| --- | --- | --- |
| 0 | VALIDO | Certificado confiável, identidade correta e fora do período de alerta |
| 1 | ALERTA | Vence dentro do prazo configurado (padrão: 30 dias) |
| 2 | EXPIRADO | Certificado vencido |
| 3 | ERRO / TLS_INVALIDO | Timeout, falha de conexão, cadeia não confiável, identidade incorreta ou certificado ainda não válido |
| 4 | Erro de uso | Argumentos, lista, dependências ou destino inválidos |

Em lote, prevalece o maior código encontrado. Certificados vencidos recebem EXPIRADO mesmo se também houver erro de confiança; o campo `detalhe` preserva o resultado TLS. Dias restantes são dias inteiros truncados; a classificação usa os segundos restantes.

CSV e JSON vão para stdout; erros de uso vão para stderr. Falhas dos servidores ficam nos próprios relatórios. Ao agendar ou usar em CI, capture o código de saída: 1 e 2 são resultados de monitoramento, não falhas de geração do relatório.

### Download e limites

O download salva apenas o certificado do servidor, sem chave privada e sem a cadeia completa. Não sobrescreve destinos existentes. Certificados expirados ou não confiáveis também podem ser baixados para inspeção; o status e o código de saída indicam o problema. Falhas de conexão não criam o arquivo de destino.

A verificação usa as CAs do OpenSSL instalado. CAs internas precisam estar configuradas nesse ambiente (por exemplo, via `SSL_CERT_FILE`). A consulta usa TLS direto e SNI: não suporta STARTTLS, proxy HTTP ou verificação de revogação. O timeout limita a chamada ao OpenSSL por servidor.

`certificado_validade.sh` e `certificado_download.sh` continuam como atalhos. Sem argumentos, perguntam host e porta; com argumentos, encaminham para a nova ferramenta. Não aguardam tecla ao terminar.

### Testes locais

```bash
bash tests/certificados_test.sh
```

Os testes não acessam a internet: simulam respostas TLS e usam um certificado gerado localmente. Cobrem alertas, expiração, TLS inválido, falhas, timeout, relatórios, listas e download sem sobrescrita.

## GitLab

As versões `gitlab.sh` (Bash 4+) e `gitlab.ps1` (PowerShell 7+) oferecem os mesmos três comandos. Os nomes antigos `gitlab_script_v1.0.*` encaminham para essa interface; a versão Shell agora usa Bash.

Requisitos: Git no PATH. Para criar projetos pela versão Shell, também são necessários `curl` com suporte a `--header @-` e `jq`. A versão PowerShell usa `Invoke-RestMethod`.

```bash
# Diagnóstico local, sem rede ou alteração
bash gitlab.sh diagnostico ./meu-projeto

# Conectar projeto a um remoto existente (inicializa Git se necessário)
bash gitlab.sh conectar ./meu-projeto --url git@gitlab.com:time/meu-projeto.git

# Preparar os arquivos explicitamente antes da publicação
git -C ./meu-projeto add README.md src/
git -C ./meu-projeto commit -m "Preparar projeto"

# Conferir o plano e depois publicar no origin existente
bash gitlab.sh publicar ./meu-projeto --dry-run
bash gitlab.sh publicar ./meu-projeto

# Criar projeto privado e publicar quando ainda não existir origin
# Configure GITLAB_TOKEN por um mecanismo de segredos do seu ambiente.
bash gitlab.sh publicar ./meu-projeto --nome meu-projeto --grupo 123 --gitlab-url https://gitlab.com
```

```powershell
./gitlab.ps1 diagnostico ./meu-projeto
./gitlab.ps1 conectar ./meu-projeto -Url git@gitlab.com:time/meu-projeto.git
./gitlab.ps1 publicar ./meu-projeto -DryRun
./gitlab.ps1 publicar ./meu-projeto
./gitlab.ps1 publicar ./meu-projeto -Nome meu-projeto -Grupo 123 -Visibilidade private
./gitlab.ps1 -Help
```

### Comportamento

- `diagnostico`: informa branch, alterações, existência de origin e presença do token, sem exibir o token. Não verifica autenticação remota.
- `conectar`: inicializa Git com `main` (configurável por `--branch`/`-Branch`) quando necessário e adiciona origin. Um origin diferente é rejeitado; repetir a mesma conexão é permitido. Não faz commit ou push.
- `publicar`: exige repositório com commits, branch selecionada e árvore limpa, incluindo arquivos não rastreados. Preserva a branch atual e não usa force. Use a raiz do repositório, não uma subpasta.
- Com origin ou URL explícita, publica no projeto existente sem usar a API. Sem ambos, cria um projeto privado por padrão e configura origin a partir da resposta validada.
- `--dry-run`/`-DryRun`: executa as validações e mostra o plano; não chama a rede nem altera arquivos ou configuração. Não comprova permissões ou disponibilidade do remoto.

Criação usa `GITLAB_TOKEN` com permissão de API e de criação no namespace escolhido. `GITLAB_URL` pode definir a instância padrão. `--grupo`/`-Grupo` recebe o **ID numérico**, não o nome do grupo. O corpo e os campos seguem a [API oficial de projetos do GitLab](https://docs.gitlab.com/api/projects/#create-a-project).

O token da API não é salvo, impresso nem colocado na URL do remoto. O push depende da autenticação já configurada no Git (SSH ou gerenciador de credenciais). HTTPS mantém validação de certificados; instâncias internas devem configurar suas CAs no ambiente. Não são seguidos redirecionamentos na criação pela API.

O bloqueio preventivo identifica nomes como `.env`, `.env.*`, `*.key`, `*.p12`, `*.pfx`, `id_rsa`, `id_ed25519` e `credentials.json` no commit atual; `.env.example`, `.env.sample` e `.env.template` são permitidos. **Isso não é uma varredura de conteúdo nem do histórico**. Revise todos os commits que serão enviados e use um detector de segredos quando necessário.

Códigos de saída: `0` sucesso; `1` falha operacional (API/push); `4` uso ou configuração inválida. Erros de vinculação de parâmetros do PowerShell são tratados pelo próprio PowerShell e podem retornar `1`.

Não há rollback automático: se o projeto remoto for criado e o push falhar, origin e commits ficam preservados para nova tentativa. Em timeout de criação, confira o GitLab antes de repetir, pois a requisição pode ter sido processada. Projetos existentes sem origin devem usar `conectar` ou uma URL explícita para evitar tentativa de criação duplicada.

### Testes do GitLab

```powershell
pwsh -NoProfile -File tests/gitlab_test.ps1
pwsh -NoProfile -File tests/gitlab_api_test.ps1
```

Testa ambas as versões em pastas temporárias: simulação sem alteração, conexão repetida, conflitos de origin, ausência de commits, árvore suja, subpastas, arquivos sensíveis e push recusado sem rede. Requer Bash (no Windows, Git Bash no caminho padrão), Git e PowerShell 7.

O segundo teste simula a API e o push na versão PowerShell para verificar criação, recusa, resposta com URL inesperada e recuperação após falha no push. Não usa tokens reais nem cria projetos externos. A criação pela versão Shell ainda precisa de validação de integração em uma instância GitLab de testes.

### CI opcional

O modelo de GitHub Actions está em `docs/ci/checks.yml.example`, fora de `.github/workflows`, para não iniciar execuções nem consumir minutos automaticamente. Os testes podem ser executados localmente pelos comandos acima. Ative o modelo somente após revisar os limites e as condições de cobrança da sua conta.
