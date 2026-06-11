# Estrutura de DevOps e Garantia de Qualidade (QA) - Open WebUI no ONR

Este documento estabelece a especificação técnica para o pipeline de Integração e Entrega Contínua (CI/CD) no Azure DevOps e o plano estratégico de testes de Garantia de Qualidade (QA) para a implantação do Open WebUI e seus componentes no ambiente do ONR (Operador Nacional do Registro Eletrônico de Imóveis).

---

## 1. Pipeline de CI/CD (Azure Pipelines)

O pipeline de CI/CD foi desenhado de forma declarativa utilizando Azure Pipelines (YAML) estruturado em estágios sequenciais com gates de qualidade, segurança cibernética corporativa e deploy contínuo controlado por ambientes.

As definições utilizam os agentes hospedados padrão do Azure DevOps (`ubuntu-latest`) e realizam a implantação de forma segura via SSH na VM compartilhada do GCP (Google Compute Engine), utilizando chaves privadas e variáveis secretas gerenciadas na biblioteca do Azure Pipelines.

### 1.1. Arquivo de Configuração do Pipeline (`azure-pipelines.yml`)

```yaml
trigger:
  batch: true
  branches:
    include:
      - main
      - develop

pr:
  branches:
    include:
      - main
      - develop

variables:
  - name: dockerComposePath
    value: 'docker-compose.yaml'
  - name: terraformDir
    value: 'terraform'
  # Variáveis de conexão do ambiente (referenciadas nos grupos de variáveis seguros)
  - group: onr-ia-secrets-prod

stages:
  # ==========================================
  # Estágio de Integração Contínua (CI)
  # ==========================================
  - stage: CI
    displayName: 'Integração Contínua & Segurança'
    jobs:
      - job: Static_Analysis_And_Security
        displayName: 'Validação Estática e AppSec'
        pool:
          vmImage: 'ubuntu-latest'
        steps:
          # 1. Instalar dependências necessárias para as verificações
          - task: UsePythonVersion@0
            inputs:
              versionSpec: '3.x'
            displayName: 'Configurar Python'

          # 2. Varredura de credenciais com GitLeaks
          - script: |
              echo "Iniciando auditoria de credenciais expostas usando Gitleaks..."
              docker run --rm -v $(System.DefaultWorkingDirectory):/code zricethezav/gitleaks:latest detect --source="/code" -v --redact
            displayName: 'Auditoria Gitleaks (Vazamento de Chaves)'

          # 3. Linter e Validação do Terraform
          - script: |
              echo "Instalando tflint..."
              curl -s https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash
              echo "Iniciando validação estática e tflint..."
              cd $(terraformDir)
              terraform init -backend=false
              terraform validate
              tflint --init
              tflint
            displayName: 'Linter e Validação Terraform'

          # 4. Verificação de Vulnerabilidades IaC com tfsec / Checkov
          - script: |
              echo "Executando Checkov para validar segurança do Terraform e Docker Compose..."
              pip install checkov
              checkov -d $(terraformDir) --framework terraform
              checkov -f $(dockerComposePath) --framework docker_compose
            displayName: 'Análise de Conformidade de Segurança (Checkov)'

          # 5. Validação do arquivo Docker Compose (Sintaxe)
          - script: |
              docker compose -f $(dockerComposePath) config --quiet
            displayName: 'Validação de Sintaxe Docker Compose'

  # ==========================================
  # Estágio de Deploy Contínuo (CD) - Homologação
  # ==========================================
  - stage: CD_Staging
    displayName: 'Deploy Contínuo - Homologação'
    dependsOn: CI
    condition: and(succeeded(), eq(variables['Build.SourceBranch'], 'refs/heads/develop'))
    jobs:
      - deployment: Deploy_Staging
        displayName: 'Deploy para VM de Homologação GCP'
        pool:
          vmImage: 'ubuntu-latest'
        environment: 'onr-ia-staging'
        strategy:
          runOnce:
            deploy:
              steps:
                - checkout: self
                
                # 1. Configurar chave SSH Privada de Homologação de forma segura
                - task: InstallSSHKey@0
                  inputs:
                    knownHostsEntry: '$(SSH_KNOWN_HOSTS_STAGING)'
                    sshPublicKey: '$(SSH_PUBLIC_KEY_STAGING)'
                    sshKeySecureFile: 'id_rsa_staging'
                  displayName: 'Instalar Chave SSH de Homologação'

                # 2. Copiar arquivos de configuração essenciais para o host remoto da GCP via SCP
                - task: CopyFilesOverSSH@0
                  inputs:
                    sshEndpoint: 'gcp-vm-staging'
                    sourceFolder: '$(System.DefaultWorkingDirectory)'
                    contents: |
                      $(dockerComposePath)
                      nginx/nginx.conf
                      litellm/config.yaml
                    targetFolder: '/app/openwebui-deployment'
                    cleanTargetFolder: false
                    overwrite: true
                  displayName: 'Sincronizar Arquivos de Configuração via SCP'

                # 3. Executar o deploy na VM por comando SSH remoto
                - task: SSH@0
                  inputs:
                    sshEndpoint: 'gcp-vm-staging'
                    runOptions: 'commands'
                    commands: |
                      cd /app/openwebui-deployment
                      # Obter as variáveis de ambiente necessárias a partir do GCP Secret Manager
                      echo "Injetando configurações de runtime..."
                      echo "DB_PASSWORD=$(DB_PASSWORD_STAGING)" > .env
                      echo "LITELLM_MASTER_KEY=$(LITELLM_MASTER_KEY_STAGING)" >> .env
                      echo "AZURE_API_KEY=$(AZURE_API_KEY_STAGING)" >> .env
                      echo "AZURE_API_BASE=$(AZURE_API_BASE_STAGING)" >> .env
                      
                      # Reiniciar a stack com Docker Compose puxando as novas imagens
                      echo "Executando Docker Compose..."
                      docker compose down --remove-orphans
                      docker compose pull
                      docker compose up -d --wait
                      docker system prune -f --volumes
                    readyTimeout: '20000'
                  displayName: 'Reiniciar Stack Docker Compose via SSH'

  # ==========================================
  # Estágio de Deploy Contínuo (CD) - Produção
  # ==========================================
  - stage: CD_Production
    displayName: 'Deploy Contínuo - Produção'
    dependsOn: CI
    condition: and(succeeded(), eq(variables['Build.SourceBranch'], 'refs/heads/main'))
    jobs:
      - deployment: Deploy_Production
        displayName: 'Deploy para VM de Produção GCP'
        pool:
          vmImage: 'ubuntu-latest'
        # Utiliza o ambiente do Azure DevOps associado com Aprovação Manual de Gatekeepers
        environment: 'onr-ia-production'
        strategy:
          runOnce:
            deploy:
              steps:
                - checkout: self

                # 1. Configurar chave SSH Privada de Produção de forma segura
                - task: InstallSSHKey@0
                  inputs:
                    knownHostsEntry: '$(SSH_KNOWN_HOSTS_PROD)'
                    sshPublicKey: '$(SSH_PUBLIC_KEY_PROD)'
                    sshKeySecureFile: 'id_rsa_prod'
                  displayName: 'Instalar Chave SSH de Produção'

                # 2. Copiar arquivos de configuração essenciais para o host remoto da GCP via SCP
                - task: CopyFilesOverSSH@0
                  inputs:
                    sshEndpoint: 'gcp-vm-prod'
                    sourceFolder: '$(System.DefaultWorkingDirectory)'
                    contents: |
                      $(dockerComposePath)
                      nginx/nginx.conf
                      litellm/config.yaml
                    targetFolder: '/app/openwebui-deployment'
                    cleanTargetFolder: false
                    overwrite: true
                  displayName: 'Sincronizar Arquivos de Configuração via SCP'

                # 3. Executar o deploy na VM por comando SSH remoto
                - task: SSH@0
                  inputs:
                    sshEndpoint: 'gcp-vm-prod'
                    runOptions: 'commands'
                    commands: |
                      cd /app/openwebui-deployment
                      # Obter as variáveis de ambiente necessárias a partir do GCP Secret Manager
                      echo "Injetando configurações de runtime de produção..."
                      echo "DB_PASSWORD=$(DB_PASSWORD_PROD)" > .env
                      echo "LITELLM_MASTER_KEY=$(LITELLM_MASTER_KEY_PROD)" >> .env
                      echo "AZURE_API_KEY=$(AZURE_API_KEY_PROD)" >> .env
                      echo "AZURE_API_BASE=$(AZURE_API_BASE_PROD)" >> .env
                      
                      # Reiniciar a stack com Docker Compose
                      echo "Executando Docker Compose em Produção..."
                      docker compose down --remove-orphans
                      docker compose pull
                      docker compose up -d --wait
                      docker system prune -f --volumes
                    readyTimeout: '20000'
                  displayName: 'Reiniciar Stack Docker Compose via SSH'
```

---

## 2. Plano de Testes de Garantia de Qualidade (QA)

O plano de testes visa garantir a estabilidade do sistema frente ao SLA estipulado de 99.5%, o isolamento completo de dados sensíveis entre usuários e a performance da plataforma em cenários de alta concorrência interna.

### 2.1. Estratégia de Automação de Testes de UI (Cypress / Playwright)

Os testes funcionais de ponta a ponta (E2E) serão automatizados utilizando **Playwright** devido ao suporte nativo a múltiplos contextos de browser isolados paralelamente, ideal para simular interações síncronas de chats de IA.

A automação foca nas User Stories descritas em `docs/scope.md`:

#### Automação para US01 (Acesso Seguro e Autenticação de Usuários):
*   **Caso de Teste 01.1 - Registro com Domínio Corporativo:**
    *   **Ação:** Preencher formulário de cadastro com e-mail `@onr.org.br`.
    *   **Resultado Esperado:** O cadastro deve ser efetuado com sucesso e redirecionar para a tela interna do Open WebUI.
*   **Caso de Teste 01.2 - Bloqueio de Cadastro Externo:**
    *   **Ação:** Tentar realizar cadastro utilizando o e-mail `usuario@gmail.com`.
    *   **Resultado Esperado:** O sistema deve abortar o cadastro, exibindo um alerta informando que o domínio não é autorizado.
*   **Caso de Teste 01.3 - Promoção de Admin:**
    *   **Ação:** Validar se o primeiro usuário cadastrado na base PostgreSQL possui a role de administrador no painel de configurações.
    *   **Resultado Esperado:** O perfil correspondente deve carregar o painel de administração habilitado.

#### Automação para US02 (Integração do Open WebUI com Gateway LiteLLM):
*   **Caso de Teste 02.1 - Sincronização e Listagem de Modelos:**
    *   **Ação:** Abrir o dropdown de seleção de modelos do chat e validar se as opções cadastradas no `config.yaml` do LiteLLM (ex: `gpt-4o`, `claude-3-5-sonnet`) são renderizadas em tela.
    *   **Resultado Esperado:** A lista de modelos na interface deve ser idêntica aos modelos ativos retornados pelo endpoint `/v1/models` do LiteLLM.
*   **Caso de Teste 02.2 - Prompt de Chat e Verificação de Streaming:**
    *   **Ação:** Enviar um prompt de texto e aferir se a resposta é impressa via chunks síncronos (Server-Sent Events) de forma progressiva.
    *   **Resultado Esperado:** A resposta não pode aparecer de forma agrupada após longos segundos; deve haver renderização dinâmica do texto em tempo real sem travamentos visuais.

#### Automação para US03 (Persistência no GCP Cloud SQL PostgreSQL):
*   **Caso de Teste 03.1 - Persistência pós Recriação de Container:**
    *   **Ação:** Criar uma nova conversa, simular a derrubada e recriação do container do Open WebUI por meio de comandos de terminal, e recarregar a página web do usuário autenticado.
    *   **Resultado Esperado:** O histórico de conversa deve persistir intacto na barra lateral esquerda do usuário.
*   **Caso de Teste 03.2 - Isolamento de Sessões de Chat:**
    *   **Ação:** Abrir duas sessões de navegadores isoladas para `Usuário A` e `Usuário B`. Criar mensagens no `Usuário A`.
    *   **Resultado Esperado:** O histórico do `Usuário A` jamais deve aparecer visível na UI do `Usuário B`.

#### Exemplo de Script de Teste Automatizado (Playwright / TypeScript)

```typescript
import { test, expect } from '@playwright/test';

test.describe('Testes de Autenticação e Segurança (US01)', () => {
  test('Deve barrar cadastros com e-mails que não pertençam ao domínio institucional ONR', async ({ page }) => {
    await page.goto('https://ia.onr.org.br/signup');
    
    await page.fill('input[type="name"]', 'Usuario Externo');
    await page.fill('input[type="email"]', 'teste_vazamento@gmail.com');
    await page.fill('input[type="password"]', 'SenhaForte123!');
    await page.click('button[type="submit"]');

    // Valida o aparecimento de toast ou mensagem de erro de domínio bloqueado
    const errorMessage = page.locator('.error-message-selector'); // Substituir pelo seletor de erro real
    await expect(errorMessage).toBeVisible();
    await expect(errorMessage).toContainText('Domínio de e-mail não autorizado');
  });

  test('Deve permitir cadastro com e-mail institucional @onr.org.br', async ({ page }) => {
    await page.goto('https://ia.onr.org.br/signup');
    
    await page.fill('input[type="name"]', 'Colaborador ONR');
    await page.fill('input[type="email"]', 'colaborador.teste@onr.org.br');
    await page.fill('input[type="password"]', 'SenhaSegura123!');
    await page.click('button[type="submit"]');

    // Valida se redirecionou com sucesso para a UI interna de chat
    await expect(page).toHaveURL('https://ia.onr.org.br/');
    const modelSelector = page.locator('#model-selector');
    await expect(modelSelector).toBeVisible();
  });
});
```

---

## 3. Testes de Integração de API (LiteLLM Gateway)

Os testes de integração validam as transações de dados de forma headless, assegurando o cumprimento dos padrões de segurança (conforme `docs/security.md`), caching de chaves e tratamento de falhas.

### 3.1. Validação de Cabeçalhos de Segurança (X-API-Key e X-Product-Token)
As chamadas internas originadas pelo Open WebUI em direção ao LiteLLM são submetidas a testes de payload para validar as chaves rotativas do projeto.

*   **Caso de Teste API-01 - Validação com Cabeçalhos Válidos:**
    *   **Ação:** Realizar chamada HTTP `POST /v1/chat/completions` enviando as chaves corretas: `X-API-Key: $(GATEWAY_KEY)` e `X-Product-Token: openwebui-onr`.
    *   **Resultado Esperado:** Retorno HTTP `200 OK` com o payload de resposta do LLM correspondente.
*   **Caso de Teste API-02 - Chamada Sem Cabeçalhos de Auditoria:**
    *   **Ação:** Enviar requisição para o gateway omitindo o cabeçalho `X-Product-Token`.
    *   **Resultado Esperado:** Retorno HTTP `401 Unauthorized` ou `400 Bad Request` pelo gateway, impedindo o processamento anônimo e sem bilhetagem.

### 3.2. Caching de Segredos (Thread-Safe)
A segurança de chaves exige que a aplicação armazene em memória de forma temporária as permissões do Secret Manager para não sobrecarregar a API da nuvem.

*   **Teste de Integração de Cache de Segredos:**
    *   **Ação:** Executar 50 requisições consecutivas simuladas ao backend do Open WebUI exigindo a verificação de credenciais de banco e chaves. Monitorar a latência do primeiro acesso em comparação com os acessos subsequentes.
    *   **Resultado Esperado:** O primeiro acesso deve apresentar latência de ~300ms (consulta ao GCP Secret Manager). Os outros 49 acessos subsequentes devem responder em menos de 5ms devido ao cache thread-safe em memória, com o TTL configurado para expirar e renovar em exatamente 1 hora.

---

## 4. Testes de Regressão e Resiliência da Infraestrutura

Os testes de regressão automatizados serão inseridos como etapa do pipeline de deploy, rodando imediatamente após a subida dos novos containers na VM de homologação do GCP, de modo a prevenir a quebra de funcionalidades em releases subsequentes.

### 4.1. Resiliência a Desconexões do Banco de Dados
*   **Teste de Queda do PostgreSQL:**
    *   **Ação:** Durante a realização de uma requisição de geração de chat de usuário, realizar a parada temporária do container `cloud-sql-proxy` por 10 segundos, reativando-o em seguida.
    *   **Resultado Esperado:** A aplicação não deve travar por definitivo em tela branca de erro nem expor a conexão Postgres em stacktrace para o usuário final. Deve efetuar novas tentativas automáticas (retries) por meio do pool SQLAlchemy gerenciado de acordo com as variáveis `DATABASE_POOL_RECYCLE` e `DATABASE_POOL_TIMEOUT`, reconectando perfeitamente após a recuperação do banco de dados.

### 4.2. Tratamento de Erros e Indisponibilidade do LiteLLM
*   **Teste de Queda do Gateway de IA:**
    *   **Ação:** Parar o container `litellm-gateway` e realizar o envio de prompt na UI do Open WebUI.
    *   **Resultado Esperado:** A interface deve interceptar o erro HTTP 503 retornado pelo backend e exibir uma mensagem amigável e acessível ao colaborador informando que "O ecossistema de modelos de IA do ONR está temporariamente inacessível, tente novamente em alguns instantes", prevenindo travamentos ou loops de processamento em tela.

---

## 5. Testes de Carga e Vazão da VM (Mitigação de Riscos de OOM)

Como o Open WebUI e o LiteLLM coabitam o mesmo host `gce-ia-shared-vm`, testes de estresse rigorosos são desenhados para validar os limites de CPU, RAM e I/O definidos no arquivo de infraestrutura (`docs/infrastructure.md`).

Os testes de estresse serão executados utilizando a ferramenta de código aberto **k6** de forma headless para simular a concorrência e carga de requisições de tokens.

### 5.1. Cenário de Teste de Estresse com k6

O arquivo Javascript abaixo simula uma carga agressiva de acessos simultâneos efetuando chamadas concorrentes para avaliar o comportamento do servidor web e a capacidade de vazão e streaming do gateway:

```javascript
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  stages: [
    { duration: '1m', target: 50 },  // Ramp-up gradual para 50 colaboradores concorrentes
    { duration: '3m', target: 100 }, // Manter pico com 100 colaboradores concorrentes gerando prompts
    { duration: '1m', target: 0 },   // Ramp-down gradual para esvaziamento de conexões
  ],
  thresholds: {
    http_req_failed: ['rate<0.01'],   // Taxa de falhas de requisições web menor que 1%
    http_req_duration: ['p(95)<2000'], // 95% das conexões web devem receber resposta inicial do streaming em menos de 2 segundos
  },
};

export default function () {
  const url = 'https://ia.onr.org.br/api/v1/chat/completions'; // Endpoint do Open WebUI mapeado
  const payload = JSON.stringify({
    model: 'gpt-4o',
    messages: [
      { role: 'user', content: 'Forneça uma análise preliminar sobre as garantias reais no registro de imóveis.' }
    ],
    stream: true, // Força testes na vazão de streaming de Server-Sent Events (SSE)
  });

  const params = {
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer sk-mock-onr-client-token-prod',
    },
  };

  const res = http.post(url, payload, params);
  
  check(res, {
    'status é 200 (Sucesso de Conexão)': (r) => r.status === 200,
    'conteúdo de streaming ativo': (r) => r.body.includes('data:'),
  });

  sleep(1); // Simular uma pausa humana de leitura de 1 segundo entre prompts de chat
}
```

### 5.2. Métricas de Monitoramento Obrigatórias Durante Testes de Carga

Durante a execução de testes de concorrência com 100 usuários simultâneos no k6, o time de engenharia DevOps monitorará o host remoto GCP com ferramentas de telemetria ou logs locais do Docker Engine, validando os seguintes thresholds contra falhas de Out of Memory (OOM):

*   **Uso de Memória RAM na VM:** O consumo consolidado total da VM do GCP (incluindo SO, Open WebUI, LiteLLM, Proxy Nginx e o Sidecar Auth Proxy) não deve ultrapassar **85% do total da máquina virtual (6.8 GB de consumo em uma máquina de 8 GB RAM)**.
*   **Estabilidade dos Limites Docker (cgroups):** Validar via `docker stats` se o container do `open-webui` respeita o teto de isolamento físico de **4GB** e o container do `litellm` respeita o teto de **2GB** sem sofrer crash ou reinicializações devido à atuação do mecanismo do kernel OOM-Killer.
*   **Limites de Conexões do Pool de Banco de Dados:** Aferir se a fila do pool do Cloud SQL no PostgreSQL não atinge timeout sob concorrência e se o número de conexões ativas simultâneas respeita o teto estabelecido nas variáveis `DATABASE_POOL_SIZE=20` e `DATABASE_POOL_MAX_OVERFLOW=10`.
