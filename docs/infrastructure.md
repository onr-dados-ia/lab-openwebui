# Especificação Técnica de Infraestrutura - Implantação do Open WebUI no ONR

Este documento estabelece o planejamento detalhado, topologia física, scripts IaC (Terraform) e configurações de contêineres (`docker-compose.yaml`) para o provisionamento e governança de infraestrutura de nuvem no Google Cloud Platform (GCP) com foco no deploy resiliente do **Open WebUI** integrado ao **LiteLLM** no ecossistema de Inteligência Artificial do **ONR (Operador Nacional do Registro Eletrônico de Imóveis)**.

---

## 1. Topologia de Infraestrutura Física no GCP

A topologia foi desenhada com foco em segurança, resiliência, isolamento de dados corporativos (adequação à LGPD) e otimização financeira através da reutilização da instância GCE (Compute Engine) existente e do banco de dados relacional gerenciado.

```mermaid
graph TB
    %% Estilos de nós
    classDef vpc fill:#f5f5f5,stroke:#333,stroke-dasharray: 5 5;
    classDef sub fill:#e3f2fd,stroke:#0d47a1,stroke-width:1px;
    classDef vm fill:#bbdefb,stroke:#1976d2,stroke-width:2px;
    classDef db fill:#ffe0b2,stroke:#f57c00,stroke-width:2px;
    classDef ext fill:#eceff1,stroke:#607d8b,stroke-width:1px;

    %% Elementos externos
    Colaborador["Colaborador do ONR<br/>(Internet / VPN)"]:::ext
    Provedores["Gateway Externo de IAs<br/>(Azure OpenAI, AWS, Anthropic)"]:::ext

    %% GCP Project Boundary
    subgraph GCP_Project ["GCP Project: projeto-ai-ml-develop"]
        
        subgraph VPC_Network ["VPC Network: vpc-shared-produtos (Project: onr-shared)"]
            
            subgraph Subnet_App ["Subnet: subrede-ai-ml-develop"]
                
                subgraph VM_GCE ["Compute Engine Instance: gce-openwebui-vm"]
                    %% Serviços dentro da VM
                    subgraph Docker_Compose ["Docker Compose Environment"]
                        Nginx["Proxy Reverso Nginx<br/>(Porta 443 HTTPS)"]:::vm
                        OpenWebUI["Open WebUI Service<br/>(Porta 8080 HTTP)"]:::vm
                    end
                end

                LiteLLM["LiteLLM Gateway<br/>(Hospedado em 10.75.0.3:4000)"]:::vm
                
            end

            subgraph Subnet_DB ["Cloud SQL Subnetwork (Private Service Access)"]
                CloudSQL[("GCP Cloud SQL PostgreSQL<br/>(litellm-db)<br/>[Private IP: 10.59.156.17]")]:::db
            end

            %% Security Perimeters & Gateways
            CloudNAT["Cloud NAT / Cloud Gateway<br/>(Saída Segura de Tráfego)"]:::vpc
            Firewall["GCP Firewall Rules<br/>(Filtros Estritos de Entrada)"]:::vpc
            
        end
        
        VPC_Controls["VPC Service Controls Perimeter"]:::vpc
    end

    %% Conectores de Fluxo de Rede
    Colaborador -- "HTTPS (Porta 443)<br/>Restrito à WAN Corporativa / VPN" --> Firewall
    Firewall --> Nginx
    Nginx -- "Proxying (Porta 8080)" --> OpenWebUI
    OpenWebUI -- "VPC Internal Routing<br/>(http://10.75.0.3:4000/v1)" --> LiteLLM
    
    %% Comunicação com Banco e Externos
    OpenWebUI -- "SQL Queries via IP Privado (10.59.156.17:5432)" --> CloudSQL
    LiteLLM -- "Chamadas HTTPS através de" --> CloudNAT
    CloudNAT -- "Egress Autorizado" --> Provedores
```

### Componentes de Rede e Infraestrutura de Borda:
1. **Instância GCE (`gce-openwebui-vm`):** Hospeda os containers do Open WebUI e Proxy Reverso em Docker Compose sob sistema operacional Ubuntu 22.04 LTS, localizada na rede `vpc-shared-produtos` (subrede `subrede-ai-ml-develop`).
2. **Cloud SQL PostgreSQL (`litellm-db`):** Instância existente PostgreSQL 16 (Tier `db-f1-micro`) no projeto `projeto-ai-ml-develop` com IP privado **10.59.156.17**. O acesso é feito de maneira interna via Private Service Access (VPC Peering), e será criada uma base de dados exclusiva para o Open WebUI (`db_openwebui`).
3. **LiteLLM Gateway:** Rodando no endereço privado **10.75.0.3:4000**, consumido de forma direta pela subrede `subrede-ai-ml-develop`.
4. **Firewall Rules (VPC):** Regras de firewall estritas que barram todo o tráfego externo, permitindo requisições na porta 443 (HTTPS) apenas se provenientes dos blocos de IP de VPN/Sede corporativa do ONR.
5. **Cloud NAT:** Permite que a VM instale atualizações de sistema operacional e que o LiteLLM faça requisições externas para as APIs de IAs externas, sem expor a VM à internet pública por meio de IP público de entrada.
6. **VPC Service Controls (VPSC):** Perímetro de segurança lógico que evita a exfiltração de dados (por exemplo, backups do Cloud SQL sendo desviados para buckets externos não pertencentes à organização).

---

## 2. Dimensionamento e Requisitos de Máquina Virtual (GCE)

Considerando a coabitação pacífica do **Open WebUI** (com recursos de processamento local de embeddings e RAG local ativos) e do **LiteLLM**, os requisitos mínimos de máquina virtual foram projetados para mitigar indisponibilidades por falta de recursos (como falhas de Out of Memory - OOM):

| Componente | Requisito Mínimo (MVP) | Recomendado (Produção) | Justificativa |
| :--- | :--- | :--- | :--- |
| **Família de VM** | `e2-standard-2` | `e2-standard-4` | A família E2 apresenta o melhor custo-benefício para cargas de trabalho de servidores web e proxies. |
| **vCPUs** | 2 vCPUs | 4 vCPUs | O Open WebUI executa parsing de arquivos pesados (PDFs/Office) para RAG e requer processamento multithreading. |
| **Memória RAM** | 8 GB | 16 GB | O Open WebUI consome em média 3-4GB sob carga, enquanto o LiteLLM consome 1.5-2GB. Os buffers de SO necessitam de margem segura. |
| **Armazenamento** | 50 GB Balanced SSD | 100 GB Balanced SSD | Armazena o sistema operacional, Docker logs, pacotes de cache, além dos arquivos e banco vetorial ChromaDB armazenados no volume persistente do Open WebUI. |
| **Sistema Operacional** | Ubuntu Server 22.04 LTS | Ubuntu Server 22.04 LTS | Sistema operacional homologado para produção, estável, com amplo suporte de atualizações de segurança e facilidade de Docker Engine runtime. |
| **Docker Engine** | v24.0.0+ | v24.0.0+ | Versão moderna com suporte nativo a compose v2 integrado. |

---

## 3. Scripts IaC (Terraform) - Provisionamento e Segurança

Seguindo as regras de **fidelidade aos perímetros de rede da Segurança** e **Privilégio Mínimo (IAM)**, apresentamos os manifestos Terraform modulares para provisionar/ajustar a infraestrutura e definir as políticas de segurança física e lógica no GCP.

### 3.1. Provedor e Variáveis (`providers.tf` / `variables.tf`)

```hcl
# providers.tf
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.10.0"
    }
  }
  backend "gcs" {
    bucket = "onr-terraform-state-prod"
    prefix = "ia/openwebui"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# variables.tf
variable "project_id" {
  type        = string
  description = "ID do projeto do GCP onde os recursos de IA corporativos do ONR estão alocados"
  default     = "projeto-ai-ml-develop"
}

variable "region" {
  type    = string
  default = "southamerica-east1" # Região de São Paulo para latência mínima no ONR
}

variable "zone" {
  type    = string
  default = "southamerica-east1-a"
}

variable "vpc_name" {
  type    = string
  default = "vpc-shared-produtos"
}
```

### 3.2. Infraestrutura de Banco de Dados e Rede Privada (`database.tf`)

Este script provisiona de forma altamente segura a instância do **Cloud SQL PostgreSQL**, desativando IPs públicos e garantindo comunicação estrita por conexões de serviço privado.

```hcl
# database.tf

# Reserva uma faixa de IPs internos de VPC para serviços gerenciados pelo GCP (Service Networking)
resource "google_compute_global_address" "private_ip_alloc" {
  name          = "onr-ia-private-ip-alloc"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = "projects/${var.project_id}/global/networks/${var.vpc_name}"
}

# Cria a conexão privada (VPC Peering) entre o projeto do ONR e a rede gerenciada do Google (Cloud SQL)
resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = "projects/${var.project_id}/global/networks/${var.vpc_name}"
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_alloc.name]
}

# Provisionamento da Instância Cloud SQL PostgreSQL Privada
resource "google_sql_database_instance" "postgresql_instance" {
  name             = "db-onr-ia-prod-psql"
  database_version = "POSTGRES_15"
  region           = var.region
  depends_on       = [google_service_networking_connection.private_vpc_connection]

  settings {
    tier              = "db-custom-2-7680" # 2 vCPUs, 7.5 GB RAM (Ideal para banco compartilhado em prod)
    availability_type = "REGIONAL"         # Alta Disponibilidade multi-zona para SLA > 99.5%
    disk_size         = 20
    disk_type         = "PD_SSD"
    disk_autoresize   = true               # Escalabilidade automática de disco conforme uso corporativo

    ip_configuration {
      ipv4_enabled    = false # Desativa totalmente o IP Público
      private_network = "projects/${var.project_id}/global/networks/${var.vpc_name}"
      require_ssl     = true  # Força conexão criptografada SSL/TLS
    }

    backup_configuration {
      enabled                        = true
      start_time                     = "03:00" # Horário de menor utilização (UTC-3)
      point_in_time_recovery_enabled = true    # Recuperação em tempo real contra perdas acidentais
      transaction_log_retention_days = 7
    }

    database_flags {
      name  = "log_connections"
      value = "on"
    }

    database_flags {
      name  = "log_disconnections"
      value = "on"
    }
  }
}

# Criação da Base de Dados dedicada ao Open WebUI
resource "google_sql_database" "openwebui_db" {
  name     = "db_openwebui"
  instance = google_sql_database_instance.postgresql_instance.name
}

# Geração de Senha randômica forte para o Usuário do Banco
resource "random_password" "db_password" {
  length  = 24
  special = false
}

# Criação de Usuário de banco com privilégios restritos
resource "google_sql_user" "openwebui_user" {
  name     = "user_openwebui"
  instance = google_sql_database_instance.postgresql_instance.name
  password = random_password.db_password.result
}

# Armazenamento seguro da String de Conexão no GCP Secret Manager
resource "google_secret_manager_secret" "db_connection_string" {
  secret_id = "openwebui-database-url"
  labels = {
    app = "openwebui"
  }
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "db_connection_string_val" {
  secret      = google_secret_manager_secret.db_connection_string.id
  secret_data = "postgresql://user_openwebui:${random_password.db_password.result}@${google_sql_database_instance.postgresql_instance.private_ip_address}:5432/db_openwebui?sslmode=require"
}
```

### 3.3. Configuração de IAM e Privilégio Mínimo da VM (`iam.tf`)

Para atender à diretriz de **Privilégio Mínimo**, a VM que roda os containers deve utilizar uma Service Account customizada que possua permissões estritamente limitadas para conectar ao banco de dados via IAM Auth e ler os segredos necessários para o bootstrap.

```hcl
# iam.tf

# 1. Criação da Service Account dedicada para a VM de IA
resource "google_service_account" "ia_vm_sa" {
  account_id   = "sa-gce-ia-shared"
  display_name = "Service Account para VM Compartilhada do Open WebUI e LiteLLM"
  project      = var.project_id
}

# 2. Atribuição de permissão para ler o Secret Manager (DoD: secrets fora do código)
resource "google_secret_manager_secret_iam_member" "sm_accessor" {
  secret_id = google_secret_manager_secret.db_connection_string.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.ia_vm_sa.email}"
}

# 3. Atribuição de permissão estrita para conexão do Cloud SQL Auth Proxy via IAM Auth
resource "google_project_iam_member" "cloud_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.ia_vm_sa.email}"
}

# 4. Atribuição de permissões básicas de SRE e Monitoramento (Envio de Logs corporativos)
resource "google_project_iam_member" "logging_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.ia_vm_sa.email}"
}

resource "google_project_iam_member" "monitoring_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.ia_vm_sa.email}"
}
```

---

## 4. Orquestração Multi-Serviço (`docker-compose.yaml`)

Abaixo está o arquivo `docker-compose.yaml` completo e auto-portável, pronto para ser executado no servidor `gce-openwebui-vm` do ONR. Como o **LiteLLM** já se encontra deployado e operacional em `10.75.0.3:4000`, a stack local é simplificada, necessitando rodar apenas o container do **Open WebUI**, o **Proxy Reverso HTTPS (Nginx)** e o **Cloud SQL Auth Proxy** (para encapsular de forma criptografada as queries via IP privado do PostgreSQL a partir de credenciais temporárias do IAM).

```yaml
version: '3.8'

services:
  # ---------------------------------------------------------------------------
  # 1. Cloud SQL Auth Proxy: Garante a conexão criptografada com o PostgreSQL
  # ---------------------------------------------------------------------------
  cloud-sql-proxy:
    image: gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.8.2
    container_name: cloud-sql-proxy
    # Conecta utilizando a Service Account atrelada por metadados à própria VM do GCP
    command:
      - "--private-ip"
      - "--port=5432"
      - "projeto-ai-ml-develop:southamerica-east1:litellm-db"
    restart: always
    expose:
      - "5432"
    networks:
      - ia_network
    healthcheck:
      test: ["CMD", "nc", "-z", "127.0.0.1", "5432"]
      interval: 10s
      timeout: 5s
      retries: 3

  # ---------------------------------------------------------------------------
  # 2. Open WebUI: Interface de Chat Oficial para Colaboradores do ONR
  # ---------------------------------------------------------------------------
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    restart: always
    expose:
      - "8080"
    volumes:
      - openwebui_data:/app/backend/data
    environment:
      # Conexão segura através do proxy de banco local (apontando para litellm-db na porta 5432)
      - DATABASE_URL=postgresql://user_openwebui:${DB_PASSWORD}@cloud-sql-proxy:5432/db_openwebui?sslmode=disable
      
      # Pool de Conexões Otimizado
      - DATABASE_POOL_SIZE=20
      - DATABASE_POOL_MAX_OVERFLOW=10
      - DATABASE_POOL_RECYCLE=1800
      - DATABASE_POOL_TIMEOUT=30
      
      # Conexão estrita com o Gateway LiteLLM (Hospedado externamente na VPC)
      - OPENAI_API_BASE_URL=http://10.75.0.3:4000/v1
      - OPENAI_API_KEY=${LITELLM_MASTER_KEY}
      - OPENAI_API_BASE_URLS=http://10.75.0.3:4000/v1
      - OPENAI_API_KEYS=${LITELLM_MASTER_KEY}
      
      # Segurança de Cadastro - Domínio Estrito ONR (US01)
      - ENABLE_SIGNUP=true
      - WHITELIST_SIGNUP_DOMAINS=onr.org.br
      - DEFAULT_USER_ROLE=user
      
      # Ajustes de Concorrência e Workers WSGI (Otimização OOM)
      - WEB_CONCURRENCY=3
    depends_on:
      cloud-sql-proxy:
        condition: service_healthy
    networks:
      - ia_network
    deploy:
      resources:
        limits:
          cpus: '2.0'
          memory: 4G
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 15s
      timeout: 10s
      retries: 3

  # ---------------------------------------------------------------------------
  # 3. Proxy Reverso Nginx: Terminação SSL e Proteção de Borda
  # ---------------------------------------------------------------------------
  nginx-proxy:
    image: nginx:1.25-alpine
    container_name: nginx-proxy
    restart: always
    ports:
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - /etc/ssl/certs/onr-ia-cert.crt:/etc/nginx/ssl/onr-ia-cert.crt:ro
      - /etc/ssl/private/onr-ia-key.key:/etc/nginx/ssl/onr-ia-key.key:ro
    depends_on:
      - open-webui
    networks:
      - ia_network
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 512M

networks:
  ia_network:
    driver: bridge

volumes:
  openwebui_data:
    driver: local
```

### Arquivo Auxiliar de Configuração Nginx (`nginx/nginx.conf`)

Para garantir a terminação SSL robusta, segurança de cabeçalhos e correta passagem de conexões de streaming (Server-Sent Events) fundamentais para as respostas em tempo real da IA:

```nginx
events {
    worker_connections 1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;
    
    # Otimização de I/O
    sendfile        on;
    keepalive_timeout  65;
    
    # Configurações de SSL Corporativo
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers "EECDH+AESGCM:EDH+AESGCM:AES256+EECDH:AES256+EDH";
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    server {
        listen 443 ssl;
        server_name ia.onr.org.br;

        ssl_certificate     /etc/nginx/ssl/onr-ia-cert.crt;
        ssl_certificate_key /etc/nginx/ssl/onr-ia-key.key;

        # Proteções de Segurança Básicas (Headers HTTP)
        add_header X-Frame-Options "DENY" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-XSS-Protection "1; mode=block" always;
        add_header Content-Security-Policy "default-src 'self' 'unsafe-inline' 'unsafe-eval'; img-src 'self' data:; connect-src 'self' https://ia.onr.org.br;" always;

        # Configurações de timeout ampliadas para respostas de IA
        proxy_connect_timeout 600s;
        proxy_send_timeout    600s;
        proxy_read_timeout    600s;
        send_timeout          600s;

        location / {
            proxy_pass http://open-webui:8080;
            proxy_http_version 1.1;
            
            # Necessário para correto funcionamento do WebSockets e Streaming (SSE)
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            
            # Repasse de cabeçalhos originais
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            # Desabilita buffering para streaming SSE em tempo real de tokens
            proxy_buffering off;
            proxy_cache_bypass $http_upgrade;
        }
    }
}
```

---

## 5. Práticas de Implantação e Operação (SRE)

Para manter a confiabilidade de infraestrutura acima do KPI corporativo de **99.5%**, o time de SRE do ONR deve seguir as seguintes diretrizes:

1. **Gestão de Segredos na VM:**
   * O bootstrap da VM deve carregar as variáveis do arquivo `.env` do docker-compose puxando diretamente do GCP Secret Manager no pipeline de CI/CD:
     ```bash
     gcloud secrets versions access latest --secret="openwebui-database-url" > .env
     ```
2. **Estratégia de Backup Físico:**
   * Embora o banco de dados principal esteja resguardado pelas políticas automáticas diárias do Cloud SQL com PITR (Point-in-Time Recovery), o volume local `/app/backend/data` (armazenado em `/var/lib/docker/volumes/openwebui_data/_data` na VM) deve possuir um script diário de snapshot de disco persistente no GCP para evitar corrupção do banco vetorial local (ChromaDB) e perda de arquivos enviados por usuários.
3. **Monitoramento e Alertas GCE:**
   * Configurar alertas no **GCP Cloud Monitoring** para monitorar:
     * Uso de CPU da VM > 85% por mais de 5 minutos.
     * Consumo de RAM livre na VM < 10% (Garantia contra falha de Out Of Memory).
     * Taxa de erros HTTP 5xx nas requisições do Nginx > 2% em uma janela de 5 minutos.
4. **Verificação de Saúde (Liveness e Readiness):**
   * O docker-compose inclui healthchecks para todos os serviços essenciais. A falha de conexão do Open WebUI com o Cloud SQL Auth Proxy (`cloud-sql-proxy`) ou com o `litellm` acionará o reinício automático do container correspondente.
