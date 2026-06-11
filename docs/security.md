# Diretrizes de Segurança Cibernética, AppSec e LGPD - Open WebUI no ONR

Este documento define os padrões mandatórios de segurança, privacidade (LGPD) e governança de dados para a implantação e operação do **Open WebUI** integrado ao gateway **LiteLLM** no ecossistema de Inteligência Artificial do **ONR**.

---

## 1. Controle de Acesso e Segurança de APIs

Para garantir a rastreabilidade e evitar o uso indevido ou não autorizado dos modelos de IA, todas as conexões lógicas devem respeitar as diretrizes de autenticação em dois níveis estabelecidas pelo ONR:

1.  **Autenticação em Dois Níveis:**
    *   **X-API-Key:** Chave de API rotativa do projeto, que valida se a requisição originou-se de uma aplicação homologada (o container do Open WebUI).
    *   **X-Product-Token:** Token do cliente ou identificador do produto que está realizando a requisição, utilizado para rastreamento de uso, auditoria de consumo e bilhetagem interna (billing).
    *   Toda requisição enviada do Open WebUI para o LiteLLM deve portar ambos os cabeçalhos em suas requisições HTTP internas.

2.  **Caching Seguro de Segredos (Thread-Safe):**
    *   Para mitigar latência, custos e excesso de chamadas de rede à API do **GCP Secret Manager**, a leitura de chaves de autenticação e segredos deve obrigatoriamente utilizar um mecanismo de cache em memória.
    *   O cache deve ser implementado de forma thread-safe (usando bibliotecas como `cachetools` com `Lock`) com um **TTL (Time-To-Live) máximo de 1 hora**.

---

## 2. Proteção de Credenciais e Gestão de Segredos

*   **Abolição Absoluta de Hardcode:** Nenhuma chave de API, credencial de banco de dados, token ou segredo de serviço (como as credenciais do GCP Secret Manager, chaves OpenRouter, ou credenciais do Postgres) pode ser exposta no código-fonte ou em arquivos commitados.
*   **Armazenamento de Segredos:** Todos os segredos de produção devem ser extraídos sob demanda do GCP Secret Manager ou injetados exclusivamente no momento do runtime via variáveis de ambiente protegidas (`.env` local, não versionado).
*   **Isolamento de Ambientes:** As variáveis de ambiente devem possuir isolamento total por escopo de execução (`ENV=dev` ou `ENV=prod`), garantindo que o ambiente de desenvolvimento não tenha acesso físico ou lógico às chaves e dados de produção.

---

## 3. Prevenção de Exposição no Git (.gitignore)

O arquivo [`.gitignore`](file:///c:/Users/ricardo.paula/OneDrive%20-%20ONR/Documentos/ONR/ONR-LAB/1.AgentCoding/lab-openwebui/.gitignore) foi configurado para barrar estritamente arquivos confidenciais em pipelines de integração e entrega contínua (CI/CD):
*   Bloqueio sistemático de arquivos de Service Account (`service_account.json`, `credentials.json`).
*   Bloqueio de arquivos de variáveis de ambiente (`.env`, `.env.local`, `.env.production`).
*   Bloqueio de segredos de infraestrutura e chaves privadas (`*.pem`, `*.key`, `id_rsa`).

---

## 4. Modelagem de Ameaças em IA (Threat Modeling / AppSec)

Para blindar o ecossistema do ONR contra os riscos emergentes descritos no **OWASP Top 10 para LLMs**, as seguintes defesas lógicas são obrigatórias:

### 4.1. Prevenção de Prompt Injection e Vazamento de System Prompt
*   **Filtro de Entrada (Input Filtering):** As requisições de chat dos usuários devem ser monitoradas quanto a padrões conhecidos de engenharia social de prompt (ex: "ignore as instruções anteriores", "aja como um administrador do sistema").
*   **Proteção do System Prompt:** Configurar instruções de sistema rígidas nos modelos corporativos do LiteLLM, instruindo o modelo a nunca revelar seu prompt original, independentemente das técnicas de persuasão empregadas pelo usuário.

### 4.2. Mascaramento de PII (Privacidade e LGPD)
*   **Anonimização de Dados Pessoais:** Antes de salvar históricos de conversas em bancos de dados ou expô-los em logs de auditoria e ferramentas de tracing (como o Langfuse), dados pessoais identificáveis (PII) — tais como CPF, CNPJ, e-mails, endereços, nomes completos e telefones — devem passar por um processo de mascaramento ou tokenização (ex: substituição por tokens como `[REDACTED_CPF]`).
*   **Rastreabilidade Imutável:** Todas as transações e interações lógicas de alta sensibilidade (ex: exclusão de histórico por parte de usuários, criação de credenciais, promoção de usuários para administradores) devem gerar logs de auditoria imutáveis no **Cloud Logging** do GCP, impedindo adulterações.

### 4.3. Prevenção contra DoS Lógico de LLMs
*   **Limitação de Contexto (Context Window Limits):** Restringir o número máximo de tokens de entrada (`max_input_tokens`) e tamanho de arquivos de upload para RAG, evitando o esgotamento dos recursos da VM ou estouro de custos por ataques de injeção de textos volumosos.
*   **Rate-Limiting por Usuário:** Definir limites de requisições por minuto (RPM) e tokens por minuto (TPM) no gateway LiteLLM, mitigando riscos de abusos que degradem o serviço para os demais usuários do ONR.

---

## 5. Perímetro de Redes e Controle de Acesso IAM

*   **Rede Privada Estrita:** A VM que executa o Open WebUI e o Cloud SQL PostgreSQL devem residir na mesma rede VPC privada. Toda comunicação leste-oeste (entre a VM e o Banco) deve usar IPs privados sem transitar pela internet pública.
*   **Firewall Restritivo:** Apenas tráfego HTTP/HTTPS direcionado ao proxy reverso é permitido externamente pelas regras de firewall do GCP. Portas administrativas (como SSH/22, Postgres/5432) são bloqueadas para acesso direto de fora da rede corporativa do ONR.
*   **IAM com Privilégio Mínimo:** A Service Account associada à VM do Open WebUI possui permissões de leitura estritamente limitadas ao seu próprio escopo do projeto, usando a role `roles/cloudsql.client` para conexões criptografadas do Postgres e `roles/secretmanager.secretAccessor` restrita às chaves específicas do Open WebUI.
