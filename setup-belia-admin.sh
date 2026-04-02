#!/bin/bash
# =============================================================================
# Belia Admin — Setup Script
# Configura um CT/servidor do zero para rodar o Belia Admin
#
# Uso:
#   curl -fsSL https://raw.githubusercontent.com/yosefitamar/proxmox_scripts/main/setup-belia-admin.sh | bash
# =============================================================================

# Se o script esta sendo lido de um pipe (curl | bash), salva em arquivo
# temporario e re-executa. Isso evita conflitos de stdin com read/heredocs.
if [ ! -t 0 ]; then
    TMPSCRIPT=$(mktemp /tmp/belia-admin-setup.XXXXXX.sh)
    cat > "$TMPSCRIPT"
    chmod +x "$TMPSCRIPT"
    exec bash "$TMPSCRIPT"
fi

set -euo pipefail

# --- Configuracoes -----------------------------------------------------------

REPO_URL="https://github.com/yosefitamar/belia_admin.git"
INSTALL_DIR="/opt/belia-admin"
LOG_FILE="/var/log/belia-admin-setup.log"
COMPOSE_FILE="docker-compose.prod.yml"
SERVICE_NAME="belia-admin"

# --- Cores e formatacao ------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Funcoes utilitarias -----------------------------------------------------

log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${BLUE}[${timestamp}]${NC} $1" > /dev/tty
    echo "[${timestamp}] $(echo "$1" | sed 's/\x1b\[[0-9;]*m//g')" >> "$LOG_FILE"
}

log_ok() {
    log "${GREEN}[OK]${NC} $1"
}

log_warn() {
    log "${YELLOW}[AVISO]${NC} $1"
}

log_err() {
    log "${RED}[ERRO]${NC} $1"
}

log_step() {
    echo "" > /dev/tty
    log "${CYAN}${BOLD}>>> $1${NC}"
}

ask() {
    local prompt="$1"
    local var_name="$2"
    local default="${3:-}"

    if [ -n "$default" ]; then
        echo -en "${YELLOW}${prompt} [${default}]: ${NC}" > /dev/tty
    else
        echo -en "${YELLOW}${prompt}: ${NC}" > /dev/tty
    fi

    read -r input < /dev/tty
    printf -v "$var_name" '%s' "${input:-$default}"
}

ask_password() {
    local prompt="$1"
    local var_name="$2"

    echo -en "${YELLOW}${prompt}: ${NC}" > /dev/tty
    read -rs input < /dev/tty
    echo "" > /dev/tty
    printf -v "$var_name" '%s' "$input"
}

ask_yesno() {
    local prompt="$1"
    local default="${2:-s}"

    if [ "$default" = "s" ]; then
        echo -en "${YELLOW}${prompt} [S/n]: ${NC}" > /dev/tty
    else
        echo -en "${YELLOW}${prompt} [s/N]: ${NC}" > /dev/tty
    fi

    read -r input < /dev/tty
    input="${input:-$default}"
    [[ "$input" =~ ^[sS]$ ]]
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_err "Este script precisa ser executado como root."
        exit 1
    fi
}

# --- Inicio ------------------------------------------------------------------

clear > /dev/tty
cat <<BANNER > /dev/tty
$(echo -e "${BOLD}")
  ============================================
    Belia Admin — Setup de Producao
    Belia Software
  ============================================
$(echo -e "${NC}")
BANNER

# Inicia log
mkdir -p "$(dirname "$LOG_FILE")"
echo "=== Belia Admin Setup — $(date) ===" > "$LOG_FILE"

check_root

# --- ETAPA 1: Verificar/instalar dependencias --------------------------------

log_step "Etapa 1/5 — Verificando dependencias"

install_if_missing() {
    local cmd="$1"
    local pkg="${2:-$1}"

    if command -v "$cmd" &>/dev/null; then
        log_ok "$cmd ja instalado ($(command -v "$cmd"))"
        return 0
    fi

    log_warn "$cmd nao encontrado. Instalando..."

    if command -v apt-get &>/dev/null; then
        apt-get update -qq >> "$LOG_FILE" 2>&1
        apt-get install -y -qq "$pkg" >> "$LOG_FILE" 2>&1
    elif command -v apk &>/dev/null; then
        apk add --no-cache "$pkg" >> "$LOG_FILE" 2>&1
    elif command -v dnf &>/dev/null; then
        dnf install -y -q "$pkg" >> "$LOG_FILE" 2>&1
    else
        log_err "Gerenciador de pacotes nao suportado. Instale '$pkg' manualmente."
        return 1
    fi

    if command -v "$cmd" &>/dev/null; then
        log_ok "$cmd instalado com sucesso"
    else
        log_err "Falha ao instalar $cmd"
        return 1
    fi
}

# Dependencias basicas
install_if_missing "curl"
install_if_missing "wget"
install_if_missing "git"

# Docker
if command -v docker &>/dev/null; then
    log_ok "Docker ja instalado ($(docker --version 2>/dev/null | head -1))"
else
    log_warn "Docker nao encontrado. Instalando via script oficial..."

    if curl -fsSL https://get.docker.com | sh >> "$LOG_FILE" 2>&1; then
        log_ok "Docker instalado com sucesso"
    else
        log_err "Falha ao instalar Docker. Verifique $LOG_FILE"
        exit 1
    fi
fi

# Garantir que Docker esta rodando
if ! systemctl is-active --quiet docker 2>/dev/null; then
    log_warn "Docker nao esta rodando. Iniciando..."
    systemctl start docker >> "$LOG_FILE" 2>&1
    systemctl enable docker >> "$LOG_FILE" 2>&1
    log_ok "Docker iniciado e habilitado no boot"
else
    log_ok "Docker esta rodando"
fi

# Docker Compose (verificar se v2 esta disponivel)
if docker compose version &>/dev/null; then
    log_ok "Docker Compose v2 disponivel ($(docker compose version --short 2>/dev/null))"
else
    log_err "Docker Compose v2 nao disponivel. Verifique a instalacao do Docker."
    exit 1
fi

# --- ETAPA 2: Configurar projeto --------------------------------------------

log_step "Etapa 2/5 — Configurando projeto"

ask "Diretorio de instalacao" INSTALL_DIR "$INSTALL_DIR"
ask "URL do repositorio Git" REPO_URL "$REPO_URL"
ask "Branch para deploy" GIT_BRANCH "main"

# Clonar ou atualizar repositorio
if [ -d "$INSTALL_DIR/.git" ]; then
    log_warn "Projeto ja existe em $INSTALL_DIR"

    if ask_yesno "Deseja atualizar (git pull)?"; then
        cd "$INSTALL_DIR"
        git fetch origin >> "$LOG_FILE" 2>&1
        git checkout "$GIT_BRANCH" >> "$LOG_FILE" 2>&1
        git pull origin "$GIT_BRANCH" >> "$LOG_FILE" 2>&1
        log_ok "Repositorio atualizado"
    fi
else
    log "Clonando repositorio..."

    if git clone -b "$GIT_BRANCH" "$REPO_URL" "$INSTALL_DIR" >> "$LOG_FILE" 2>&1; then
        log_ok "Repositorio clonado em $INSTALL_DIR"
    else
        log_err "Falha ao clonar repositorio. Verifique a URL e permissoes."
        log_err "Detalhes em $LOG_FILE"
        exit 1
    fi
fi

cd "$INSTALL_DIR"

# --- ETAPA 3: Configurar .env ------------------------------------------------

log_step "Etapa 3/5 — Configurando variaveis de ambiente"

if [ -f "$INSTALL_DIR/.env" ]; then
    log_warn "Arquivo .env ja existe."

    if ask_yesno "Deseja reconfigurar?" "n"; then
        CONFIGURE_ENV=true
    else
        CONFIGURE_ENV=false
        log_ok "Mantendo .env existente"
    fi
else
    CONFIGURE_ENV=true
fi

if [ "$CONFIGURE_ENV" = true ]; then
    echo "" > /dev/tty
    echo -e "${BOLD}  Configuracao do banco de dados (PostgreSQL)${NC}" > /dev/tty
    ask "  Host do PostgreSQL" DB_HOST "192.168.100.41"
    ask "  Porta" DB_PORT "5432"
    ask "  Nome do banco" DB_NAME "belia_admin"
    ask "  Usuario" DB_USER "postgres"
    ask_password "  Senha do banco" DB_PASSWORD

    echo "" > /dev/tty
    echo -e "${BOLD}  Configuracao da aplicacao${NC}" > /dev/tty
    ask "  Porta da API (backend)" APP_PORT "3010"
    ask_password "  JWT Secret (minimo 32 caracteres)" JWT_SECRET
    ask "  URL do Redis" REDIS_URL "redis://redis:6379"
    ask "  CORS Origins (URL do frontend)" CORS_ORIGINS "https://admin.beliasoftware.com"
    ask "  URL publica da API (para o frontend)" NEXT_PUBLIC_API_URL "https://api-admin.beliasoftware.com"

    echo "" > /dev/tty
    echo -e "${BOLD}  Configuracao de integracao (deixe vazio para desabilitar)${NC}" > /dev/tty
    ask "  CT201 Host (Mishpat tenant host)" CT201_HOST ""
    ask "  CT201 SSH User" CT201_SSH_USER "root"
    ask "  CT201 SSH Key path" CT201_SSH_KEY "/root/.ssh/id_ed25519"
    ask "  NPM Base URL (Nginx Proxy Manager)" NPM_BASE_URL ""
    ask "  NPM Email" NPM_EMAIL "admin@beliasoftware.com"
    ask_password "  NPM Password" NPM_PASSWORD
    ask "  Dominio dos tenants" TENANT_DOMAIN "mishpat.beliasoftware.com"
    ask "  Nome da rede Docker dos tenants" TENANT_NETWORK "belia_tenants"
    ask "  Imagem Docker da API Mishpat" MISHPAT_API_IMAGE "belia-mishpat-app:latest"
    ask "  Imagem Docker do Frontend Mishpat" MISHPAT_FE_IMAGE "belia-mishpat-frontend:latest"

    # Gerar .env
    cat > "$INSTALL_DIR/.env" <<ENVFILE
APP_ENV=production
APP_PORT=${APP_PORT}

# PostgreSQL
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_SSLMODE=disable

# Auth
JWT_SECRET=${JWT_SECRET}

# Redis
REDIS_URL=${REDIS_URL}

# CORS
CORS_ORIGINS=${CORS_ORIGINS}

# Frontend build arg
NEXT_PUBLIC_API_URL=${NEXT_PUBLIC_API_URL}

# CT 201 — Mishpat host
CT201_HOST=${CT201_HOST}
CT201_SSH_USER=${CT201_SSH_USER}
CT201_SSH_KEY=${CT201_SSH_KEY}

# CT 104 — Nginx Proxy Manager
NPM_BASE_URL=${NPM_BASE_URL}
NPM_EMAIL=${NPM_EMAIL}
NPM_PASSWORD=${NPM_PASSWORD}

# Tenant networking
TENANT_DOMAIN=${TENANT_DOMAIN}
TENANT_NETWORK=${TENANT_NETWORK}
MISHPAT_API_IMAGE=${MISHPAT_API_IMAGE}
MISHPAT_FE_IMAGE=${MISHPAT_FE_IMAGE}
ENVFILE

    chmod 600 "$INSTALL_DIR/.env"
    log_ok "Arquivo .env criado com permissoes restritas (600)"
fi

# --- ETAPA 4: Build e start --------------------------------------------------

log_step "Etapa 4/5 — Build e inicializacao"

log "Construindo imagens Docker (isso pode levar alguns minutos)..."

if docker compose -f "$COMPOSE_FILE" build >> "$LOG_FILE" 2>&1; then
    log_ok "Imagens construidas com sucesso"
else
    log_err "Falha no build. Verifique $LOG_FILE"
    exit 1
fi

log "Iniciando containers..."

if docker compose -f "$COMPOSE_FILE" up -d >> "$LOG_FILE" 2>&1; then
    log_ok "Containers iniciados"
else
    log_err "Falha ao iniciar containers. Verifique $LOG_FILE"
    exit 1
fi

# Aguardar e verificar saude dos containers
log "Verificando saude dos containers..."
sleep 5

HEALTHY=true
for container in belia_admin_app belia_admin_frontend belia_admin_redis; do
    status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "not_found")
    if [ "$status" = "running" ]; then
        log_ok "$container: rodando"
    else
        log_err "$container: $status"
        HEALTHY=false
    fi
done

if [ "$HEALTHY" = false ]; then
    log_err "Alguns containers nao estao saudaveis. Verifique com: docker compose -f $COMPOSE_FILE logs"
fi

# --- ETAPA 5: Auto-start no boot ---------------------------------------------

log_step "Etapa 5/5 — Configurando auto-start no boot"

# Criar systemd service
cat > /etc/systemd/system/${SERVICE_NAME}.service <<UNIT
[Unit]
Description=Belia Admin — Painel Administrativo
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/docker compose -f ${COMPOSE_FILE} up -d
ExecStop=/usr/bin/docker compose -f ${COMPOSE_FILE} down
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload >> "$LOG_FILE" 2>&1
systemctl enable ${SERVICE_NAME}.service >> "$LOG_FILE" 2>&1
log_ok "Servico systemd '${SERVICE_NAME}' criado e habilitado no boot"

# --- Criar script de atualizacao --------------------------------------------

cat > "$INSTALL_DIR/update.sh" <<'UPDATEEOF'
#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

COMPOSE_FILE="docker-compose.prod.yml"
LOG_FILE="/var/log/belia-admin-update.log"

echo "=== Belia Admin Update — $(date) ===" >> "$LOG_FILE"

echo "[*] Baixando atualizacoes..."
git pull >> "$LOG_FILE" 2>&1

echo "[*] Reconstruindo imagens..."
docker compose -f "$COMPOSE_FILE" build >> "$LOG_FILE" 2>&1

echo "[*] Reiniciando containers..."
docker compose -f "$COMPOSE_FILE" up -d >> "$LOG_FILE" 2>&1

echo "[*] Verificando containers..."
sleep 5
docker compose -f "$COMPOSE_FILE" ps

echo ""
echo "[OK] Atualizacao concluida. Log: $LOG_FILE"
UPDATEEOF

chmod +x "$INSTALL_DIR/update.sh"
log_ok "Script de atualizacao criado: $INSTALL_DIR/update.sh"

# --- Resumo final ------------------------------------------------------------

APP_PORT="${APP_PORT:-3010}"
FE_PORT="3011"
HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")

cat <<SUMMARY > /dev/tty

$(echo -e "${BOLD}")  ============================================
    Setup concluido!
  ============================================$(echo -e "${NC}")

  $(echo -e "${CYAN}")Backend API:$(echo -e "${NC}")   http://${HOST_IP}:${APP_PORT}
  $(echo -e "${CYAN}")Frontend:$(echo -e "${NC}")      http://${HOST_IP}:${FE_PORT}
  $(echo -e "${CYAN}")Diretorio:$(echo -e "${NC}")     ${INSTALL_DIR}
  $(echo -e "${CYAN}")Log do setup:$(echo -e "${NC}")  ${LOG_FILE}

  $(echo -e "${BOLD}")Comandos uteis:$(echo -e "${NC}")
  $(echo -e "${GREEN}")$INSTALL_DIR/update.sh$(echo -e "${NC}")             — Atualizar (git pull + rebuild)
  $(echo -e "${GREEN}")systemctl status ${SERVICE_NAME}$(echo -e "${NC}")     — Ver status do servico
  $(echo -e "${GREEN}")docker compose -f $COMPOSE_FILE logs -f$(echo -e "${NC}") — Ver logs
  $(echo -e "${GREEN}")docker compose -f $COMPOSE_FILE ps$(echo -e "${NC}")     — Ver containers

SUMMARY
log_ok "Setup finalizado com sucesso!"
