# Portal de IA do ONR — Open WebUI

Portal de chat de IA para colaboradores do ONR, baseado no **Open WebUI**, integrado ao
gateway **LiteLLM** e persistindo dados em **Cloud SQL (PostgreSQL)** no GCP.

O acesso é feito por **IP interno via VPN**, no mesmo padrão do portal do LiteLLM.

---

## 1. Acesso

| Item | Valor |
| --- | --- |
| URL do portal | `http://10.75.0.3:8080` |
| Rede | VPC interna do GCP (somente via **VPN**) |
| Autenticação | Login **nativo** do Open WebUI (e-mail/senha) |
| Cadastro público | **Desativado** (`ENABLE_SIGNUP=false`) — apenas o admin cria usuários |

> O **primeiro usuário** cadastrado torna-se **admin** automaticamente. A partir daí, novos
> usuários são criados pelo painel administrativo do Open WebUI (Admin Panel → Users).

---

## 2. Arquitetura

```
                 VPN
 Colaborador  ─────────►  http://10.75.0.3:8080
                                   │
                                   ▼
                          ┌──────────────────┐
                          │   open-webui     │  (container, porta 8080 publicada no host)
                          │  (login nativo)  │
                          └───────┬──────────┘
                                  │
              ┌───────────────────┼─────────────────────┐
              ▼                                          ▼
   ┌────────────────────┐                   ┌──────────────────────────┐
   │  litellm-gateway   │                   │   Cloud SQL (PostgreSQL) │
   │  :4000 (rede       │                   │   db_openwebui           │
   │  docker compart.)  │                   │   (usuários, chats, etc) │
   └────────────────────┘                   └──────────────────────────┘
```

- **Open WebUI** é publicado **diretamente na porta `8080`** do host (sem proxy reverso),
  servindo a aplicação na **raiz `/`**. Isso evita o bug de _subpath_ que quebrava os
  assets da SPA (tela preta com ícone quebrado) quando servido sob `/chat/`.
- A comunicação com o **LiteLLM** ocorre pela rede Docker compartilhada
  (`litellm-gateway_default`), resolvendo o host `litellm-gateway:4000` por nome.
- Os dados (usuários, conversas, configurações) são persistidos no **Cloud SQL**.

### Componentes

| Componente | Imagem / Recurso | Porta | Observação |
| --- | --- | --- | --- |
| `open-webui` | `ghcr.io/open-webui/open-webui:main` | `8080:8080` | Interface do portal |
| `litellm-gateway` | `ghcr.io/berriai/litellm:latest` | `4000` | Gateway de LLMs (stack pré-existente) |
| Cloud SQL | PostgreSQL (GCP) | `5432` | Banco `db_openwebui` (IP privado) |

---

## 3. Infraestrutura (GCP)

| Item | Valor |
| --- | --- |
| VM | `vm-ia-temp` |
| Zona | `southamerica-east1-a` |
| IP interno | `10.75.0.3` |
| Projeto | `projeto-ai-ml-develop` |
| Acesso admin à VM | `gcloud compute ssh` via **IAP Tunneling** |
| Firewall | `allow-hf-8080` libera `tcp:8080` (ingress) |

O Terraform em [`deploy/terraform/`](deploy/terraform/) provisiona os recursos de banco
(`database.tf`) e IAM (`iam.tf`).

---

## 4. Configuração do Open WebUI

Variáveis principais (definidas em [`deploy/docker-compose.yaml`](deploy/docker-compose.yaml)):

| Variável | Valor | Função |
| --- | --- | --- |
| `WEBUI_AUTH` | `true` | Habilita autenticação nativa |
| `ENABLE_SIGNUP` | `false` | Bloqueia auto-cadastro (admin gerencia) |
| `ENABLE_OAUTH_SIGNUP` | `false` | Desativa SSO/OIDC externo |
| `DEFAULT_USER_ROLE` | `user` | Papel padrão de novos perfis |
| `WEBUI_URL` | `http://10.75.0.3:8080` | URL base do portal |
| `DATABASE_URL` | `postgresql://...@${DB_HOST}:5432/db_openwebui` | Conexão Cloud SQL (SSL) |
| `OPENAI_API_BASE_URL` | `http://litellm-gateway:4000/v1` | Integração com o LiteLLM |
| `OPENAI_API_KEY` | _(vazio)_ | Cada usuário define a própria chave `sk-...` |
| `WEB_CONCURRENCY` | `3` | Workers (mitiga OOM na VM) |

### Variáveis sensíveis (`.env`)

O arquivo `.env` **não é versionado** (ver [`.gitignore`](.gitignore)). Ele reside na VM em
`/home/ricardo_paula/lab-openwebui/deploy/.env` e contém:

```env
DB_HOST=<ip-privado-cloud-sql>
DB_PASSWORD=<senha-do-banco>
```

Os valores de produção vêm do **GCP Secret Manager**.

---

## 5. Deploy / Operação

Todos os comandos rodam na VM `vm-ia-temp`, acessada via IAP:

```bash
gcloud compute ssh vm-ia-temp \
  --zone=southamerica-east1-a \
  --tunnel-through-iap
```

Na VM, dentro de `/home/ricardo_paula/lab-openwebui/deploy`:

```bash
# Subir / atualizar o portal
sudo docker compose --env-file .env up -d --force-recreate open-webui

# Status
sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

# Logs
sudo docker logs open-webui --tail 50

# Health check
curl -s -o /dev/null -w '%{http_code}\n' http://10.75.0.3:8080/
```

---

## 6. Gestão de usuários

1. Acesse `http://10.75.0.3:8080` (VPN).
2. O **primeiro cadastro** vira **admin**.
3. Novos usuários: **Admin Panel → Users → Add User** (signup público está desativado).

---

## 7. Histórico técnico

A solução original previa **Trusted Header Authentication** com uma *Auth Bridge* (FastAPI)
validando credenciais do LiteLLM e um **Nginx** de borda injetando os headers
`X-User-Email`/`X-User-Name`. Essa abordagem foi **descontinuada** por instabilidade
(loop de Basic Auth, vazamento de header `Authorization` para o LiteLLM e fragilidade no
fluxo de _trusted header_).

**Decisão atual:** usar o **login nativo do Open WebUI**, publicando o container
diretamente na porta `8080` (raiz), sem proxy reverso. Mais simples, estável e alinhado ao
padrão do portal do LiteLLM.

### Roadmap

- [ ] Publicar em `https://dados-ia.onr.org.br` via DNS/Load Balancer (servindo a **raiz**, não subpath).
- [ ] Avaliar autenticação corporativa via **OIDC/OAuth nativo** do Open WebUI.
- [ ] Configurar rotação de logs do Docker (`log-opt: max-size/max-file`) no `daemon.json`.

---

## 8. Estrutura do repositório

```
.
├── README.md                  # Este documento
├── deploy/
│   ├── docker-compose.yaml    # Stack do Open WebUI
│   └── terraform/             # IaC: Cloud SQL + IAM
└── docs/                      # Documentação de arquitetura, segurança, infra e QA
```
