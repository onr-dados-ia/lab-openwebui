# PRD - Implantação e Disponibilização do Open WebUI no ONR

Este documento consolida a Visão de Produto, Requisitos Funcionais/Não Funcionais, Casos de Uso/User Stories, e Mapeamento de Lacunas para a disponibilização do **Open WebUI** como interface oficial de Chat de IA no ecossistema do **ONR (Operador Nacional do Registro Eletrônico de Imóveis)**.

---

## 1. Visão do Produto

### Objetivo Estratégico
Disponibilizar uma interface de chat web amigável, intuitiva, rica em recursos (como upload de arquivos, RAG, histórico e compartilhamento de chats) e centralizada para o ecossistema de Inteligência Artificial do ONR. A plataforma consumirá exclusivamente os modelos expostos pelo gateway de IA corporativo (**LiteLLM**) e persistirá todos os dados no **Cloud SQL PostgreSQL (GCP)** de maneira segura, auditável e altamente escalável.

### KPIs de Sucesso do Produto
*   **Adoção Interna (Active Users):** Atingir no mínimo 80% dos colaboradores-alvo ativos na plataforma nas primeiras 4 semanas de pós-lançamento.
*   **Confiabilidade de Infraestrutura (Uptime):** Manter disponibilidade (Uptime) do Open WebUI acima de **99.5%**.
*   **Performance da Interface (Response Time):** Tempo de renderização inicial da UI e transições de tela inferior a **200ms** (excluindo o tempo de inferência do LLM que é gerenciado pelo LiteLLM).
*   **Retenção e Histórico:** Zero incidente de perda de histórico de conversas causados por falhas de infraestrutura através da sincronização contínua com o PostgreSQL.

---

## 2. Visão de Arquitetura & Infraestrutura (Referência Inicial)

```
+--------------------------------------------------------------------------+
|                              GCP VM Instance                             |
|                                                                          |
|  +---------------------------+              +-------------------------+  |
|  |       Open WebUI          |              |         LiteLLM         |  |
|  |  (Web Chat Interface)     |              |  (OpenAI-Compatible GW) |  |
|  |                           |              |                         |  |
|  |   Exposé: Port 8080       |  localhost   |    Exposé: Port 4000    |  |
|  |   (ou Reverse Proxy NGINX)| <==========> |                         |  |
|  +---------------------------+              +-------------------------+  |
+--------------|-------------------------------------------|---------------+
               |                                           |
               | VPC Network / Cloud SQL Proxy             | External Providers
               v                                           v
  +---------------------------+               +-------------------------+
  |    GCP Cloud SQL          |               | Azure OpenAI / AWS      |
  |  (PostgreSQL Database)    |               | Anthropic / etc.        |
  +---------------------------+               +-------------------------+
```

---

## 3. Backlog do MVP (User Stories & Critérios de Aceite)

### US01: Acesso Seguro e Autenticação Corporativa via Google SSO (OIDC) no ONR
**Como** colaborador do ONR  
**Eu quero** autenticar-me de forma simples e segura utilizando minha conta de login institucional do Google (Google Workspace)  
**Para que** eu possa acessar meu painel de chat pessoal do Open WebUI sem criar novas senhas, garantindo que apenas usuários corporativos ativos tenham acesso ao sistema.

*   **Padrão INVEST:**
    *   **I**ndependent: Pode ser implementada ativando os parâmetros OAuth2 nativos do Open WebUI.
    *   

---

### US02: Integração do Open WebUI com Gateway LiteLLM
**Como** usuário do Open WebUI no ONR  
**Eu quero** que a interface se conecte de forma transparente ao gateway LiteLLM  
**Para que** eu possa consumir os modelos autorizados (ex: GPT-4o, Claude 3.5 Sonnet) de maneira performática e segura.

*   **Padrão INVEST:**
    *   **I**ndependent: Depende apenas da conectividade de rede com o LiteLLM.
    *   **N**egotiable: Pode ser configurado usando endpoint de rede interna (`http://localhost:4000/v1`) se estiverem na mesma VM.
    *   **V**aluable: Essencial para centralização de chaves de API, custos e governança (LGPD).
    *   **E**stimable: Baixa complexidade (2 Story Points).
    *   **S**mall: Foca exclusivamente na parametrização de conexão.
    *   **T**estable: Confirmável listando e usando os modelos no seletor do Open WebUI.

*   **Critérios de Aceite (BDD - Gherkin):**
    *   **Cenário 1: Sincronização automática de modelos do LiteLLM**
        *   **Dado que** o LiteLLM possui 3 modelos ativos configurados e autorizados
        *   **Quando** o Open WebUI inicializa conectado ao LiteLLM via variáveis de ambiente
        *   **Então** esses 3 modelos aparecem automaticamente no dropdown de seleção de modelos na interface de chat do usuário.
    *   **Cenário 2: Envio de prompt e streaming de resposta**
        *   **Dado que** o usuário selecionou o modelo "gpt-4o" na interface
        *   **Quando** ele digita um prompt e clica em enviar
        *   **Então** a chamada é roteada via LiteLLM e o chat renderiza a resposta em tempo real (streaming de texto).

*   **Definition of Ready (DoR):**
    *   Endpoint interno ou externo do LiteLLM ativo e chave de acesso (se aplicável) definida.
    *   Portas de conexão liberadas no Firewall (se as instâncias precisarem conversar via rede privada).
*   **Definition of Done (DoD):**
    *   Streaming de tokens funcionando sem travamentos.
    *   Variáveis `OPENAI_API_BASE_URL` e `OPENAI_API_KEY` injetadas de forma segura.
    *   Tratamento de erro amigável para indisponibilidade do gateway LiteLLM (ex: exibir toast informativo ao usuário em vez de travar a tela).

---

### US03: Persistência Robusta no GCP Cloud SQL PostgreSQL
**Como** administrador do ecossistema de IA do ONR  
**Eu quero** que todo o histórico de conversas, feedback, e configurações de sistema sejam armazenados no Cloud SQL PostgreSQL  
**Para que** não haja perda de dados em caso de reinicialização ou deleção do container do Open WebUI.

*   **Padrão INVEST:**
    *   **I**ndependent: É a camada de persistência. Pode ser configurada na inicialização do container.
    *   **N**egotiable: O uso de SSL e proxies de conexão de banco pode variar dependendo das políticas de rede corporativa.
    *   **V**aluable: Garante a resiliência e a conformidade corporativa para backup de chats.
    *   **E**stimable: Média complexidade (3 Story Points).
    *   **S**mall: Focado em substituir o SQLite interno pelo driver PostgreSQL via connection string.
    *   **T**estable: Verificável via conexões persistidas e consultas SQL pós-deleção do container.

*   **Critérios de Aceite (BDD - Gherkin):**
    *   **Cenário 1: Persistência após reinicialização do container**
        *   **Dado que** o Open WebUI está configurado para apontar para o Cloud SQL PostgreSQL
        *   **Quando** um usuário cria 3 chats distintos e em seguida o container do Open WebUI é reiniciado ou recriado pela esteira
        *   **Então** ao acessar novamente o sistema, os mesmos 3 chats aparecem intactos na barra lateral do usuário.
    *   **Cenário 2: Isolamento de dados entre usuários**
        *   **Dado que** o Banco de Dados PostgreSQL está em execução
        *   **Quando** o Usuário A e o Usuário B interagem com a IA ao mesmo tempo
        *   **Então** as conversas do Usuário A são inseridas vinculadas estritamente ao seu ID no PostgreSQL, impedindo que o Usuário B as visualize no painel ou via banco sem permissão.

*   **Definition of Ready (DoR):**
    *   Instância do Cloud SQL PostgreSQL criada e acessível.
    *   Criação de credenciais de banco exclusivas para o Open WebUI (User, Password e Schema separados do LiteLLM).
*   **Definition of Done (DoD):**
    *   Migrations automáticas rodando com sucesso no startup.
    *   Variável `DATABASE_URL` configurada de forma segura.
    *   Verificação de conexões ativas máximas e pool de conexões otimizado no banco para evitar gargalos.

---

### US04: Implantação e Provisionamento Compartilhado (VM GCP)
**Como** analista de infraestrutura do ONR  
**Eu quero** rodar o Open WebUI via Docker na mesma VM GCP do LiteLLM compartilhando as regras de rede  
**Para que** possamos otimizar custos de infraestrutura e simplificar a topologia do ecossistema de IA.

*   **Padrão INVEST:**
    *   **I**ndependent: Pode ser empacotado via Docker Compose ou script Bash de deploy.
    *   **N**egotiable: Pode-se optar por um reverse proxy local (Nginx) para gerenciar roteamento ou expor portas mapeadas diretamente na VM.
    *   **V**aluable: Altamente valioso por reaproveitar custos de VM e segurança pré-existente.
    *   **E**stimable: Média complexidade (3 Story Points).
    *   **S**mall: Focado no mapeamento Docker e Firewall da VM.
    *   **T**estable: Verificação de acesso à porta mapeada externamente via HTTPS.

*   **Critérios de Aceite (BDD - Gherkin):**
    *   **Cenário 1: Mapeamento de portas na VM**
        *   **Dado que** o Open WebUI foi provisionado como container na porta `8080` interna da VM
        *   **Quando** um usuário acessa o IP/Domínio correspondente à VM do LiteLLM na porta pública autorizada (ex: `8080` ou proxy reverso na `443`)
        *   **Então** a interface de login do Open WebUI é apresentada de forma instantânea.
    *   **Cenário 2: Coexistência sem colisão de recursos**
        *   **Dado que** o LiteLLM roda na porta `4000` e o Open WebUI na porta `8080` da mesma VM
        *   **Quando** ambos os containers são iniciados
        *   **Então** ambos rodam simultaneamente sem colisão de portas e sem indisponibilizar um ao outro.

*   **Definition of Ready (DoR):**
    *   Acesso SSH e Docker instalados na VM GCP de destino.
    *   Identificação das regras de Firewall atuais do GCP para liberação da porta HTTP/HTTPS do Open WebUI.
*   **Definition of Done (DoD):**
    *   Uso de volumes Docker mapeados (se aplicável para arquivos locais/RAG, ex: `/app/backend/data`).
    *   Reinicialização automática do container (`restart: always` ou similar).
    *   Monitoramento básico de consumo de memória RAM na VM para garantir que a coabitação com o LiteLLM não causará OOM (Out Of Memory).

---

## 4. Lacunas de Informação & Dúvidas de Negócio

Para que o desenvolvimento possa prosseguir com a máxima fluidez e segurança, mapeamos as seguintes lacunas de informação que precisam ser alinhadas:

1.  **Estratégia de SSO / IdP Corporativo:**  
    *O ONR utilizará um provedor de identidade existente (como o Microsoft Entra ID / Azure AD ou Google Workspace) via OAuth/OIDC, ou iniciaremos o MVP com cadastro local estrito por whitelist de e-mail institucional?*
2.  **Configuração de Rede e Exposição:**  
    *A interface do Open WebUI será acessada via VPN corporativa ou será exposta na internet pública? Se pública, precisaremos configurar um DNS próprio (ex: `ia.onr.org.br`) associado a um certificado SSL no GCP, ou utilizaremos IP público temporário para validação inicial?*
3.  **Dimensionamento da VM GCP Existente:**  
    *Quais as especificações atuais de CPU/RAM da VM que já roda o LiteLLM? O Open WebUI por padrão possui rotinas de processamento de embeddings e RAG local que podem exigir mais hardware. Se o hardware for limitado, precisaremos otimizar o Dockerfile ou alocar recursos adicionais.*
4.  **Recurso de RAG (Retrieval-Augmented Generation):**  
    *Os usuários precisarão de upload de documentos (PDF, TXT, DOCX) diretamente no chat para análise inteligente no MVP? Se sim, isso exige a habilitação de recursos internos de extração de texto (ex: NLTK/PyPDF) que aumentam o footprint de CPU e memória do container.*
5.  **Políticas de Auditoria de Prompts (LGPD):**  
    *Toda conversa deve ser retida por questões de auditoria do ONR ou os usuários terão direito de apagar/limpar o seu próprio histórico permanentemente?*

---

## 5. Payloads REST API (JSON Patch) para o Azure DevOps

Para automatizar o provisionamento do backlog diretamente nas esteiras ou ferramentas de gestão do ONR, utilize os payloads PATCH abaixo para criação das User Stories no **Azure DevOps Services**.

### Sintaxe da API do Azure DevOps:
```http
PATCH https://dev.azure.com/{organization}/{project}/_apis/wit/workitems/$User%20Story?api-version=7.0
Content-Type: application/json-patch+json
```

### JSON Patch payloads para cada User Story:

#### 1. Payload para US01 (Acesso Seguro e Autenticação)
```json
[
  {
    "op": "add",
    "path": "/fields/System.Title",
    "value": "[Open WebUI] US01 - Acesso Seguro e Autenticação de Usuários no ONR"
  },
  {
    "op": "add",
    "path": "/fields/System.Description",
    "value": "<h2>Descrição</h2><p>Como colaborador do ONR, eu quero autenticar-me de forma segura na interface do Open WebUI para que eu possa acessar meu ambiente de chat pessoal e manter meu histórico e configurações privados.</p><h2>Critérios de Aceite</h2><ul><li><b>Cadastro institucional:</b> Permitir criação de conta para domínios @onr.org.br.</li><li><b>Bloqueio:</b> Impedir domínios públicos (ex: @gmail.com).</li><li><b>Primeiro admin:</b> Primeiro cadastro promovido automaticamente a Admin.</li></ul>"
  },
  {
    "op": "add",
    "path": "/fields/Microsoft.VSTS.Scheduling.StoryPoints",
    "value": 3
  },
  {
    "op": "add",
    "path": "/fields/System.AreaPath",
    "value": "ONR-IA"
  },
  {
    "op": "add",
    "path": "/fields/System.Tags",
    "value": "OpenWebUI; Security; Auth; MVP"
  }
]
```

#### 2. Payload para US02 (Integração LiteLLM)
```json
[
  {
    "op": "add",
    "path": "/fields/System.Title",
    "value": "[Open WebUI] US02 - Integração do Open WebUI com Gateway LiteLLM"
  },
  {
    "op": "add",
    "path": "/fields/System.Description",
    "value": "<h2>Descrição</h2><p>Como usuário do Open WebUI no ONR, eu quero que a interface se conecte de forma transparente ao gateway LiteLLM para que eu possa consumir os modelos autorizados (ex: GPT-4o, Claude 3.5 Sonnet) de maneira performática e segura.</p><h2>Critérios de Aceite</h2><ul><li><b>Sincronização de Modelos:</b> Listar no seletor do chat todos os modelos configurados e expostos no LiteLLM automaticamente.</li><li><b>Streaming:</b> Retornar respostas geradas de forma progressiva (streaming) sem atrasos visíveis na UI.</li></ul>"
  },
  {
    "op": "add",
    "path": "/fields/Microsoft.VSTS.Scheduling.StoryPoints",
    "value": 2
  },
  {
    "op": "add",
    "path": "/fields/System.AreaPath",
    "value": "ONR-IA"
  },
  {
    "op": "add",
    "path": "/fields/System.Tags",
    "value": "OpenWebUI; Integration; LiteLLM; MVP"
  }
]
```

#### 3. Payload para US03 (Persistência PostgreSQL)
```json
[
  {
    "op": "add",
    "path": "/fields/System.Title",
    "value": "[Open WebUI] US03 - Persistência Robusta no GCP Cloud SQL PostgreSQL"
  },
  {
    "op": "add",
    "path": "/fields/System.Description",
    "value": "<h2>Descrição</h2><p>Como administrador do ecossistema de IA do ONR, eu quero que todo o histórico de conversas, feedback, e configurações de sistema sejam armazenados no Cloud SQL PostgreSQL para que não haja perda de dados em caso de reinicialização ou deleção do container do Open WebUI.</p><h2>Critérios de Aceite</h2><ul><li><b>Migração:</b> O container realiza as migrações automáticas de tabelas no startup no PostgreSQL.</li><li><b>Persistência de Sessões:</b> Reiniciar o container não deve limpar os chats ou preferências dos usuários.</li></ul>"
  },
  {
    "op": "add",
    "path": "/fields/Microsoft.VSTS.Scheduling.StoryPoints",
    "value": 3
  },
  {
    "op": "add",
    "path": "/fields/System.AreaPath",
    "value": "ONR-IA"
  },
  {
    "op": "add",
    "path": "/fields/System.Tags",
    "value": "OpenWebUI; Database; PostgreSQL; CloudSQL; MVP"
  }
]
```

#### 4. Payload para US04 (VM GCP & Docker)
```json
[
  {
    "op": "add",
    "path": "/fields/System.Title",
    "value": "[Open WebUI] US04 - Implantação e Provisionamento Compartilhado (VM GCP)"
  },
  {
    "op": "add",
    "path": "/fields/System.Description",
    "value": "<h2>Descrição</h2><p>Como analista de infraestrutura do ONR, eu quero rodar o Open WebUI via Docker na mesma VM GCP do LiteLLM compartilhando as regras de rede para que possamos otimizar custos de infraestrutura e simplificar a topologia do ecossistema de IA.</p><h2>Critérios de Aceite</h2><ul><li><b>Mapeamento de Portas:</b> Exposição segura do Open WebUI (ex: porta 8080 ou via proxy na 443) sem colidir com a porta do LiteLLM (4000).</li><li><b>Políticas de Restart:</b> Garantir reinicialização automática em caso de queda do container ou da VM.</li></ul>"
  },
  {
    "op": "add",
    "path": "/fields/Microsoft.VSTS.Scheduling.StoryPoints",
    "value": 3
  },
  {
    "op": "add",
    "path": "/fields/System.AreaPath",
    "value": "ONR-IA"
  },
  {
    "op": "add",
    "path": "/fields/System.Tags",
    "value": "OpenWebUI; DevOps; GCP; Docker; MVP"
  }
]
```
