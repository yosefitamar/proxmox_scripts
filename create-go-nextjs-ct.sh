#!/usr/bin/env bash

# =============================================================================
# create-belia-mishpat-ct.sh
# Cria a CT 201 (belia-mishpat) no Proxmox.
# Essa CT é o HOST de provisionamento dos containers dos clientes.
#
# O que é instalado:
#   - Docker Engine + Docker Compose v2
#   - Git + SSH server
#   - jq, curl, wget, make, ufw
#   - Script de provisionamento de clientes (/opt/belia/provision-client.sh)
#   - Script de desprovisionamento         (/opt/belia/deprovision-client.sh)
#   - API HTTP de provisionamento          (/opt/belia/api/server.py)
#     (Python 3 + Flask — recebe chamadas do belia-admin)
#
# Uso (no host Proxmox como root):
#   bash create-belia-mishpat-ct.sh
#
# Requisitos: rodar no HOST Proxmox como root
# =============================================================================

set -euo pipefail

# ── Rede (defaults) ───────────────────────────────────────────────────────────
CT_BRIDGE="vmbr0"
CT_DNS="8.8.8.8"
CT_ARCH="amd64"
CT_SWAP=512

# ── Cores ANSI ────────────────────────────────────────────────────────────────
R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
B='\033[0;34m'
C='\033[0;36m'
W='\033[1;37m'
D='\033[2;37m'
N='\033[0m'

# ── Box helpers ───────────────────────────────────────────────────────────────
BOX_W=58
_strip() { printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g'; }
box_top()   { printf " +"; printf '%0.s-' $(seq 1 $BOX_W); printf '+\n'; }
box_mid()   { printf " +"; printf '%0.s-' $(seq 1 $BOX_W); printf '+\n'; }
box_bot()   { printf " +"; printf '%0.s-' $(seq 1 $BOX_W); printf '+\n'; }
box_blank() { printf " |%${BOX_W}s|\n" ""; }
box_line()  {
  local text="$1"
  local clean; clean=$(_strip "$text")
  local len=${#clean}
  local lpad=$(( (BOX_W - len) / 2 ))
  local rpad=$(( BOX_W - len - lpad ))
  printf " |%*s%b%*s|\n" "$lpad" "" "$text" "$rpad" ""
}
box_row() {
  local label="$1" value="$2"
  local label_w=14
  local val_w=$(( BOX_W - label_w - 4 ))
  local cv; cv=$(_strip "$value")
  if (( ${#cv} > val_w )); then value="${cv:0:$((val_w-3))}..."; fi
  printf " | ${W}%-${label_w}s${N}: ${Y}%-${val_w}s${N} |\n" "$label" "$value"
}
sep() { echo -e " ${D}$(printf '%0.s-' $(seq 1 $((BOX_W+4))))${N}"; }

# ── Mensagens ─────────────────────────────────────────────────────────────────
info() { echo -e " ${B}[i]${N} $*"; }
ok()   { echo -e " ${G}[+]${N} $*"; }
warn() { echo -e " ${Y}[!]${N} $*"; }
erro() { echo -e " ${R}[x]${N} $*" >&2; }
die()  { erro "$*"; exit 1; }
ask()  { printf " ${W}[?]${N} %s " "$*"; }

# ── Header ────────────────────────────────────────────────────────────────────
header() {
  clear
  echo ""
  echo -e "${C}"
  box_top
  box_blank
  box_line "Belia Mishpat — CT 201"
  box_line "Host de Provisionamento de Clientes"
  box_blank
  box_line "Docker | Git | SSH | API de Provisionamento"
  box_blank
  box_bot
  echo -e "${N}"
  echo ""
}

# ── Verificacoes ──────────────────────────────────────────────────────────────
check_root()    { [[ $EUID -eq 0 ]] || die "Execute como root no host Proxmox."; }
check_proxmox() {
  command -v pvesh &>/dev/null || die "pvesh nao encontrado. Execute no host Proxmox."
  command -v pct   &>/dev/null || die "pct nao encontrado. Execute no host Proxmox."
}

# ── Descoberta ────────────────────────────────────────────────────────────────
get_node()       { pvesh get /nodes --output-format json 2>/dev/null \
                   | grep -o '"node":"[^"]*"' | head -1 | cut -d'"' -f4; }
get_next_vmid()  { pvesh get /cluster/nextid 2>/dev/null || echo "201"; }
list_used_vmids() {
  local node; node=$(get_node)
  pvesh get /nodes/"$node"/lxc  --output-format json 2>/dev/null | grep -o '"vmid":[0-9]*' | grep -o '[0-9]*'
  pvesh get /nodes/"$node"/qemu --output-format json 2>/dev/null | grep -o '"vmid":[0-9]*' | grep -o '[0-9]*'
}
is_vmid_free() { list_used_vmids | grep -qx "$1" && return 1 || return 0; }
list_templates() {
  # Usa `pveam list <storage>` que funciona apenas em storages que suportam
  # o content type vztmpl (ex: local). Ignora storages como local-lvm.
  local node; node=$(get_node)
  pvesh get /nodes/"$node"/storage --output-format json 2>/dev/null \
    | grep -o '"storage":"[^"]*"' | cut -d'"' -f4 \
    | while read -r s; do
        # Verifica se o storage suporta vztmpl antes de listar
        local content
        content=$(pvesh get /nodes/"$node"/storage/"$s" \
          --output-format json 2>/dev/null | grep -o '"content":"[^"]*"' | cut -d'"' -f4)
        [[ "$content" != *"vztmpl"* ]] && continue
        pveam list "$s" 2>/dev/null \
          | awk 'NR>1 {print $1}' \
          | grep -v '^$'
      done
}
list_storages() {
  # Retorna apenas storages que suportam rootdir/images (para criar CTs)
  local node; node=$(get_node)
  pvesh get /nodes/"$node"/storage --output-format json 2>/dev/null \
    | grep -o '"storage":"[^"]*"' | cut -d'"' -f4 \
    | while read -r s; do
        local content
        content=$(pvesh get /nodes/"$node"/storage/"$s" \
          --output-format json 2>/dev/null | grep -o '"content":"[^"]*"' | cut -d'"' -f4)
        [[ "$content" == *"rootdir"* ]] && echo "$s"
      done
}

# ── Selecao: VMID ─────────────────────────────────────────────────────────────
select_vmid() {
  local suggestion used
  suggestion=$(get_next_vmid)
  used=$(list_used_vmids | sort -n | tr '\n' ' ')
  sep
  info "IDs em uso  : ${used:-nenhum}"
  info "Sugestao    : ${Y}${suggestion}${N} (recomendado: 201)"
  echo ""
  while true; do
    ask "VMID da CT [${suggestion}]:"; read -r input
    local vmid="${input:-$suggestion}"
    [[ "$vmid" =~ ^[0-9]+$ ]]       || { warn "Apenas numeros."; continue; }
    (( vmid >= 100 ))                || { warn "VMID minimo: 100."; continue; }
    is_vmid_free "$vmid"             || { warn "VMID $vmid ja em uso."; continue; }
    ok "VMID $vmid disponivel."
    CT_VMID="$vmid"
    break
  done
}

# ── Selecao: Hostname ─────────────────────────────────────────────────────────
select_name() {
  echo ""
  info "Hostname sugerido: belia-mishpat"
  while true; do
    ask "Hostname da CT [belia-mishpat]:"; read -r nome
    nome="${nome:-belia-mishpat}"
    [[ -n "$nome" ]]                                                                 || { warn "Nome vazio."; continue; }
    (( ${#nome} <= 63 ))                                                             || { warn "Maximo 63 caracteres."; continue; }
    [[ "$nome" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]                      || { warn "Apenas letras, numeros e hifen."; continue; }
    CT_HOSTNAME="$nome"
    ok "Hostname: ${CT_HOSTNAME}"
    break
  done
}

# ── Selecao: Postgres (CT 102) ────────────────────────────────────────────────
select_postgres() {
  sep
  info "Configuracao do banco de dados central (CT 102)"
  echo ""
  ask "IP do CT 102 - PostgreSQL [192.168.1.102]:"; read -r pg_ip
  PG_HOST="${pg_ip:-192.168.1.102}"

  ask "Porta do PostgreSQL [5432]:"; read -r pg_port
  PG_PORT="${pg_port:-5432}"

  ask "Usuario admin do PostgreSQL [postgres]:"; read -r pg_user
  PG_USER="${pg_user:-postgres}"

  while true; do
    ask "Senha do PostgreSQL:"; read -rs PG_PASSWORD; echo ""
    [[ -n "$PG_PASSWORD" ]] && break
    warn "Senha nao pode ser vazia."
  done

  ok "Postgres: ${PG_USER}@${PG_HOST}:${PG_PORT}"
}

# ── Selecao: API Key ──────────────────────────────────────────────────────────
select_api_key() {
  sep
  info "Chave de autenticacao da API de provisionamento"
  info "Sera exigida pelo belia-admin em cada requisicao."
  echo ""
  local suggested
  suggested=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 48 2>/dev/null || echo "mude-esta-chave-$(date +%s)")
  ask "API Key [${suggested}]:"; read -r key
  PROVISION_API_KEY="${key:-$suggested}"
  ok "API Key definida."
}

# ── Selecao: Template ─────────────────────────────────────────────────────────
select_template() {
  sep
  info "Buscando templates disponiveis..."
  local templates=()
  while IFS= read -r t; do
    [[ -n "$t" ]] && templates+=("$t")
  done < <(list_templates)

  if (( ${#templates[@]} == 0 )); then
    warn "Nenhum template encontrado. Buscando Debian 12 no repositorio..."
    # Usa o primeiro storage que suporte vztmpl
    local tmpl_storage
    tmpl_storage=$(
      local node; node=$(get_node)
      pvesh get /nodes/"$node"/storage --output-format json 2>/dev/null \
        | grep -o '"storage":"[^"]*"' | cut -d'"' -f4 \
        | while read -r s; do
            local c
            c=$(pvesh get /nodes/"$node"/storage/"$s" \
              --output-format json 2>/dev/null | grep -o '"content":"[^"]*"' | cut -d'"' -f4)
            if [[ "$c" == *"vztmpl"* ]]; then echo "$s"; break; fi
          done
    )
    [[ -z "$tmpl_storage" ]] && die "Nenhum storage com suporte a templates (vztmpl) encontrado."

    pveam update &>/dev/null

    # Pega o nome exato do template Debian 12 mais recente disponivel no repo
    local tmpl_name
    tmpl_name=$(pveam available --section system 2>/dev/null \
      | awk '{print $2}' \
      | grep '^debian-12' \
      | sort -V | tail -1)
    [[ -z "$tmpl_name" ]] && die "Nao foi possivel encontrar template Debian 12 no repositorio."

    info "Baixando ${tmpl_name} em ${tmpl_storage}..."
    pveam download "$tmpl_storage" "$tmpl_name" \
      || die "Falha ao baixar template."
    templates=("${tmpl_storage}:vztmpl/${tmpl_name}")
  fi

  if (( ${#templates[@]} == 1 )); then
    CT_TEMPLATE="${templates[0]}"
    ok "Template: $(basename "$CT_TEMPLATE")"
    return
  fi

  info "Templates disponiveis:"
  echo ""
  local i=1
  for t in "${templates[@]}"; do
    printf " ${Y}%d)${N} %s\n" "$i" "$(basename "$t")"
    (( i++ ))
  done
  echo ""
  while true; do
    ask "Escolha o template [1]:"; read -r choice
    choice="${choice:-1}"
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#templates[@]} )) \
      || { warn "Opcao invalida."; continue; }
    CT_TEMPLATE="${templates[$((choice-1))]}"
    ok "Template: $(basename "$CT_TEMPLATE")"
    break
  done
}

# ── Selecao: Storage ──────────────────────────────────────────────────────────
select_storage() {
  sep
  local storages=()
  while IFS= read -r s; do
    [[ -n "$s" ]] && storages+=("$s")
  done < <(list_storages)

  if (( ${#storages[@]} == 1 )); then
    CT_STORAGE="${storages[0]}"
    ok "Storage: ${CT_STORAGE}"
    return
  fi

  info "Storages disponiveis:"
  echo ""
  local i=1
  for s in "${storages[@]}"; do
    printf " ${Y}%d)${N} %s\n" "$i" "$s"
    (( i++ ))
  done
  echo ""
  while true; do
    ask "Escolha o storage [1]:"; read -r choice
    choice="${choice:-1}"
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#storages[@]} )) \
      || { warn "Opcao invalida."; continue; }
    CT_STORAGE="${storages[$((choice-1))]}"
    ok "Storage: ${CT_STORAGE}"
    break
  done
}

# ── Selecao: Perfil ───────────────────────────────────────────────────────────
select_profile() {
  sep
  echo ""
  info "Perfil de recursos da CT 201 (host de containers dos clientes):"
  echo ""
  printf " ${Y}1)${N} ${W}Basico      ${N}  4 cores / 4 GB RAM / 40 GB disco  (ate ~10 clientes)\n"
  printf " ${Y}2)${N} ${W}Intermediario${N} 8 cores / 8 GB RAM / 80 GB disco  (ate ~30 clientes)\n"
  printf " ${Y}3)${N} ${W}Avancado    ${N}  8 cores / 16 GB RAM / 150 GB disco (30+ clientes)\n"
  echo ""
  while true; do
    ask "Escolha o perfil [1]:"; read -r choice
    choice="${choice:-1}"
    case "$choice" in
      1) CT_PROFILE="Basico";        CT_CORES=4; CT_MEMORY=4096;  CT_DISK=40  ;;
      2) CT_PROFILE="Intermediario"; CT_CORES=8; CT_MEMORY=8192;  CT_DISK=80  ;;
      3) CT_PROFILE="Avancado";      CT_CORES=8; CT_MEMORY=16384; CT_DISK=150 ;;
      *) warn "Opcao invalida."; continue ;;
    esac
    ok "Perfil: ${CT_PROFILE} — ${CT_CORES} cores / $((CT_MEMORY/1024)) GB RAM / ${CT_DISK} GB disco"
    break
  done
}

# ── Selecao: Rede ─────────────────────────────────────────────────────────────
select_network() {
  sep
  info "Configuracao de rede (bridge: ${CT_BRIDGE})"
  echo ""
  printf " ${Y}1)${N} DHCP (automatico)\n"
  printf " ${Y}2)${N} IP fixo (recomendado para CT 201)\n"
  echo ""
  ask "Tipo de rede [2]:"; read -r tipo
  tipo="${tipo:-2}"

  if [[ "$tipo" == "2" ]]; then
    while true; do
      ask "IP/CIDR [192.168.1.201/24]:"; read -r CT_IP
      CT_IP="${CT_IP:-192.168.1.201/24}"
      [[ "$CT_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] && break
      warn "Formato invalido. Ex: 192.168.1.201/24"
    done
    ask "Gateway [192.168.1.1]:"; read -r CT_GW
    CT_GW="${CT_GW:-192.168.1.1}"
    NET_CONFIG="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},gw=${CT_GW}"
  else
    CT_IP="dhcp"; CT_GW=""
    NET_CONFIG="name=eth0,bridge=${CT_BRIDGE},ip=dhcp"
  fi
  ok "Rede: ${CT_IP}"
}

# ── Selecao: Porta da API ─────────────────────────────────────────────────────
select_api_port() {
  sep
  info "Porta da API HTTP de provisionamento (chamada pelo belia-admin)"
  ask "Porta da API [8900]:"; read -r port
  API_PORT="${port:-8900}"
  ok "API de provisionamento: porta ${API_PORT}"
}

# ── Selecao: Senha root ───────────────────────────────────────────────────────
select_password() {
  sep
  echo ""
  while true; do
    ask "Senha root da CT:"; read -rs CT_PASSWORD; echo ""
    ask "Confirme a senha:";  read -rs CT_PASSWORD2; echo ""
    [[ "$CT_PASSWORD" == "$CT_PASSWORD2" ]] && break
    warn "Senhas nao coincidem."
    echo ""
  done
  ok "Senha definida."
}

# ── Resumo ────────────────────────────────────────────────────────────────────
confirm() {
  echo ""
  sep
  echo ""
  echo -e " ${W}Resumo da CT 201 a ser criada:${N}"
  echo ""
  echo -e "${C}"
  box_top
  box_blank
  box_row "VMID"       "${CT_VMID}"
  box_row "Hostname"   "${CT_HOSTNAME}"
  box_row "Template"   "$(basename "$CT_TEMPLATE")"
  box_row "Storage"    "${CT_STORAGE}"
  box_row "Perfil"     "${CT_PROFILE}"
  box_row "CPU"        "${CT_CORES} cores"
  box_row "RAM"        "$((CT_MEMORY/1024)) GB"
  box_row "Disco"      "${CT_DISK} GB"
  box_row "Rede"       "${CT_IP}"
  box_row "PostgreSQL" "${PG_USER}@${PG_HOST}:${PG_PORT}"
  box_row "API porta"  "${API_PORT}"
  box_blank
  box_line "Stack: Docker + Git + SSH + API Flask"
  box_blank
  box_bot
  echo -e "${N}"
  echo ""
  ask "Confirmar criacao? [s/N]:"; read -r resp
  [[ "$resp" =~ ^[sS]$ ]] || { info "Cancelado."; exit 0; }
}

# ── Criacao da CT ─────────────────────────────────────────────────────────────
create_ct() {
  sep
  info "Criando CT ${CT_VMID} (${CT_HOSTNAME})..."

  local ostype="debian"
  [[ "$(basename "$CT_TEMPLATE")" == ubuntu* ]] && ostype="ubuntu"

  pct create "${CT_VMID}" "${CT_TEMPLATE}" \
    --hostname   "${CT_HOSTNAME}"          \
    --storage    "${CT_STORAGE}"           \
    --rootfs     "${CT_STORAGE}:${CT_DISK}"\
    --cores      "${CT_CORES}"             \
    --memory     "${CT_MEMORY}"            \
    --swap       "${CT_SWAP}"              \
    --net0       "${NET_CONFIG}"           \
    --nameserver "${CT_DNS}"               \
    --arch       "${CT_ARCH}"              \
    --ostype     "$ostype"                 \
    --unprivileged 1                       \
    --features   "nesting=1,keyctl=1"      \
    --password   "${CT_PASSWORD}"          \
    --start 0

  ok "CT ${CT_VMID} criada."
}

start_ct() {
  info "Iniciando CT ${CT_VMID}..."
  pct start "${CT_VMID}"
  info "Aguardando inicializacao (20s)..."
  sleep 20
  ok "CT iniciada."
}

# ── Provisionamento interno ───────────────────────────────────────────────────
provision_ct() {
  sep
  info "Provisionando CT ${CT_VMID}..."
  info "Isso pode levar 4-6 minutos..."
  echo ""

  # Exporta variaveis para uso no heredoc
  local pg_host="$PG_HOST"
  local pg_port="$PG_PORT"
  local pg_user="$PG_USER"
  local pg_password="$PG_PASSWORD"
  local api_port="$API_PORT"
  local api_key="$PROVISION_API_KEY"

  pct exec "${CT_VMID}" -- bash -euo pipefail << PROVISION

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# ─────────────────────────────────────────────────────────────────────────────
echo "[1/7] Atualizando sistema..."
apt-get update -qq && apt-get upgrade -y -qq

# ─────────────────────────────────────────────────────────────────────────────
echo "[2/7] Instalando dependencias base..."
apt-get install -y -qq \
  curl wget git openssh-server \
  ca-certificates gnupg lsb-release \
  jq make ufw \
  python3 python3-pip python3-venv \
  postgresql-client

# ─────────────────────────────────────────────────────────────────────────────
echo "[3/7] Instalando Docker Engine..."

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/debian \
  \$(. /etc/os-release && echo \"\$VERSION_CODENAME\") stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -qq
apt-get install -y -qq \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

systemctl enable docker
systemctl start docker
docker --version
docker compose version

# ─────────────────────────────────────────────────────────────────────────────
echo "[4/7] Configurando SSH..."
sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/'  /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl enable ssh
systemctl restart ssh

# ─────────────────────────────────────────────────────────────────────────────
echo "[5/7] Configurando firewall (ufw)..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp    comment 'SSH'
ufw allow ${api_port}/tcp comment 'Belia provision API'
ufw --force enable

# ─────────────────────────────────────────────────────────────────────────────
echo "[6/7] Criando estrutura de diretorios e env..."

mkdir -p /opt/belia/{api,clients,templates,backups}

# Variaveis de ambiente compartilhadas
cat > /opt/belia/.env << 'ENV_EOF'
PG_HOST=${pg_host}
PG_PORT=${pg_port}
PG_USER=${pg_user}
PG_PASSWORD=${pg_password}
PROVISION_API_KEY=${api_key}
API_PORT=${api_port}
ENV_EOF
chmod 600 /opt/belia/.env

# ── docker-compose template por cliente ──────────────────────────────────────
cat > /opt/belia/templates/client-compose.yml << 'COMPOSE_EOF'
# Template gerado pelo provision-client.sh
# Variaveis substituidas: CLIENT_SLUG, CLIENT_PORT, PG_HOST, PG_PORT,
#                         PG_USER, PG_PASSWORD, APP_IMAGE, APP_VERSION
services:
  app:
    image: "${APP_IMAGE}:${APP_VERSION}"
    container_name: "mishpat-${CLIENT_SLUG}"
    restart: unless-stopped
    ports:
      - "${CLIENT_PORT}:3000"
    environment:
      NODE_ENV: production
      DATABASE_URL: "postgresql://${PG_USER}:${PG_PASSWORD}@${PG_HOST}:${PG_PORT}/${CLIENT_SLUG}"
      CLIENT_SLUG: "${CLIENT_SLUG}"
    labels:
      belia.client: "${CLIENT_SLUG}"
      belia.managed: "true"
COMPOSE_EOF

# ── Script: provision-client.sh ───────────────────────────────────────────────
cat > /opt/belia/provision-client.sh << 'PROV_EOF'
#!/usr/bin/env bash
# provision-client.sh — cria schema no Postgres e sobe o container do cliente
#
# Uso:
#   bash /opt/belia/provision-client.sh \
#     --slug   escritorio-silva   \
#     --port   3001               \
#     --image  belia-mishpat-app  \
#     --version latest
#
# O script e idempotente: pode ser re-executado sem duplicar recursos.

set -euo pipefail
source /opt/belia/.env

usage() {
  echo "Uso: $0 --slug <slug> --port <porta> [--image <img>] [--version <tag>]"
  exit 1
}

# ── Parse de argumentos ───────────────────────────────────────────────────────
CLIENT_SLUG=""
CLIENT_PORT=""
APP_IMAGE="belia-mishpat-app"
APP_VERSION="latest"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slug)    CLIENT_SLUG="$2";    shift 2 ;;
    --port)    CLIENT_PORT="$2";    shift 2 ;;
    --image)   APP_IMAGE="$2";      shift 2 ;;
    --version) APP_VERSION="$2";    shift 2 ;;
    *) usage ;;
  esac
done

[[ -z "$CLIENT_SLUG" || -z "$CLIENT_PORT" ]] && usage

# Valida slug: apenas letras minusculas, numeros e hifen
[[ "$CLIENT_SLUG" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]] \
  || { echo "ERRO: slug invalido. Use apenas letras minusculas, numeros e hifen."; exit 1; }

CLIENT_DIR="/opt/belia/clients/${CLIENT_SLUG}"

echo "==> [1/4] Criando schema PostgreSQL para '${CLIENT_SLUG}'..."
PGPASSWORD="$PG_PASSWORD" psql \
  -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres \
  -c "CREATE DATABASE \"${CLIENT_SLUG}\";" 2>/dev/null \
  && echo "    Database criada." \
  || echo "    Database ja existe, ignorando."

echo "==> [2/4] Preparando diretorio do cliente..."
mkdir -p "${CLIENT_DIR}"

echo "==> [3/4] Gerando docker-compose.yml..."
export CLIENT_SLUG CLIENT_PORT PG_HOST PG_PORT PG_USER PG_PASSWORD APP_IMAGE APP_VERSION
envsubst < /opt/belia/templates/client-compose.yml > "${CLIENT_DIR}/docker-compose.yml"

echo "==> [4/4] Subindo container..."
docker compose -f "${CLIENT_DIR}/docker-compose.yml" up -d --pull always

echo ""
echo "Cliente '${CLIENT_SLUG}' provisionado com sucesso."
echo "  Container : mishpat-${CLIENT_SLUG}"
echo "  Porta     : ${CLIENT_PORT}"
echo "  Database  : ${CLIENT_SLUG} em ${PG_HOST}:${PG_PORT}"
PROV_EOF
chmod +x /opt/belia/provision-client.sh

# ── Script: deprovision-client.sh ────────────────────────────────────────────
cat > /opt/belia/deprovision-client.sh << 'DEPROV_EOF'
#!/usr/bin/env bash
# deprovision-client.sh — para o container e remove recursos do cliente
#
# Uso: bash /opt/belia/deprovision-client.sh --slug <slug> [--drop-db]
#
# --drop-db  também remove o banco de dados (IRREVERSIVEL)

set -euo pipefail
source /opt/belia/.env

CLIENT_SLUG=""
DROP_DB=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slug)    CLIENT_SLUG="$2"; shift 2 ;;
    --drop-db) DROP_DB=true;     shift   ;;
    *) echo "Uso: $0 --slug <slug> [--drop-db]"; exit 1 ;;
  esac
done

[[ -z "$CLIENT_SLUG" ]] && { echo "ERRO: --slug obrigatorio."; exit 1; }

CLIENT_DIR="/opt/belia/clients/${CLIENT_SLUG}"

echo "==> [1/3] Parando e removendo container..."
if [[ -f "${CLIENT_DIR}/docker-compose.yml" ]]; then
  docker compose -f "${CLIENT_DIR}/docker-compose.yml" down --remove-orphans
  echo "    Container removido."
else
  docker rm -f "mishpat-${CLIENT_SLUG}" 2>/dev/null && echo "    Container removido." || echo "    Container nao encontrado."
fi

echo "==> [2/3] Removendo diretorio do cliente..."
rm -rf "${CLIENT_DIR}"
echo "    Diretorio removido."

if [[ "$DROP_DB" == true ]]; then
  echo "==> [3/3] Removendo banco de dados '${CLIENT_SLUG}'..."
  PGPASSWORD="$PG_PASSWORD" psql \
    -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres \
    -c "DROP DATABASE IF EXISTS \"${CLIENT_SLUG}\";"
  echo "    Banco removido."
else
  echo "==> [3/3] Banco de dados mantido (use --drop-db para remover)."
fi

echo ""
echo "Cliente '${CLIENT_SLUG}' desprovisionado."
DEPROV_EOF
chmod +x /opt/belia/deprovision-client.sh

# ── Script: list-clients.sh ───────────────────────────────────────────────────
cat > /opt/belia/list-clients.sh << 'LIST_EOF'
#!/usr/bin/env bash
# list-clients.sh — lista todos os clientes e status dos containers

source /opt/belia/.env

echo ""
echo "Clientes gerenciados pelo belia-mishpat:"
echo "----------------------------------------------------"

if [[ ! -d /opt/belia/clients ]] || [[ -z "$(ls -A /opt/belia/clients 2>/dev/null)" ]]; then
  echo "  Nenhum cliente provisionado."
  exit 0
fi

for dir in /opt/belia/clients/*/; do
  slug=$(basename "$dir")
  status=$(docker inspect --format='{{.State.Status}}' "mishpat-${slug}" 2>/dev/null || echo "nao encontrado")
  port=$(docker inspect --format='{{range $p, $conf := .NetworkSettings.Ports}}{{$p}}->{{(index $conf 0).HostPort}} {{end}}' "mishpat-${slug}" 2>/dev/null || echo "-")
  printf "  %-30s  status: %-12s  porta: %s\n" "$slug" "$status" "$port"
done
echo ""
LIST_EOF
chmod +x /opt/belia/list-clients.sh

# ─────────────────────────────────────────────────────────────────────────────
echo "[7/7] Instalando API HTTP de provisionamento..."

python3 -m venv /opt/belia/api/venv
/opt/belia/api/venv/bin/pip install --quiet flask gunicorn

cat > /opt/belia/api/server.py << 'API_EOF'
"""
Belia Mishpat — API de Provisionamento
Recebe chamadas do belia-admin para criar/remover clientes.

Endpoints:
  POST /provision   { slug, port, image?, version? }
  POST /deprovision { slug, drop_db? }
  GET  /clients
  GET  /health
"""

import subprocess, os, json
from flask import Flask, request, jsonify

app = Flask(__name__)
API_KEY = os.environ.get("PROVISION_API_KEY", "")


def require_key(f):
    from functools import wraps
    @wraps(f)
    def wrapper(*args, **kwargs):
        key = request.headers.get("X-API-Key", "")
        if not API_KEY or key != API_KEY:
            return jsonify({"error": "unauthorized"}), 401
        return f(*args, **kwargs)
    return wrapper


def run(cmd: list[str]) -> tuple[int, str, str]:
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


@app.get("/health")
def health():
    return jsonify({"status": "ok"})


@app.post("/provision")
@require_key
def provision():
    data = request.get_json(force=True) or {}
    slug    = data.get("slug", "").strip()
    port    = str(data.get("port", "")).strip()
    image   = data.get("image",   "belia-mishpat-app")
    version = data.get("version", "latest")

    if not slug or not port:
        return jsonify({"error": "slug e port sao obrigatorios"}), 400

    cmd = [
        "/opt/belia/provision-client.sh",
        "--slug",    slug,
        "--port",    port,
        "--image",   image,
        "--version", version,
    ]
    code, out, err = run(cmd)
    if code != 0:
        return jsonify({"error": err or "falha no provisionamento", "output": out}), 500

    return jsonify({"status": "provisionado", "slug": slug, "port": port, "output": out})


@app.post("/deprovision")
@require_key
def deprovision():
    data = request.get_json(force=True) or {}
    slug    = data.get("slug", "").strip()
    drop_db = data.get("drop_db", False)

    if not slug:
        return jsonify({"error": "slug e obrigatorio"}), 400

    cmd = ["/opt/belia/deprovision-client.sh", "--slug", slug]
    if drop_db:
        cmd.append("--drop-db")

    code, out, err = run(cmd)
    if code != 0:
        return jsonify({"error": err or "falha no desprovisionamento", "output": out}), 500

    return jsonify({"status": "desprovisionado", "slug": slug, "output": out})


@app.get("/clients")
@require_key
def clients():
    code, out, _ = run(["/opt/belia/list-clients.sh"])
    # Retorna lista de slugs baseado nos diretorios existentes
    clients_dir = "/opt/belia/clients"
    slugs = []
    if os.path.isdir(clients_dir):
        slugs = [d for d in os.listdir(clients_dir) if os.path.isdir(os.path.join(clients_dir, d))]
    return jsonify({"clients": sorted(slugs), "output": out})


if __name__ == "__main__":
    port = int(os.environ.get("API_PORT", 8900))
    app.run(host="0.0.0.0", port=port)
API_EOF

# Systemd service para a API
cat > /etc/systemd/system/belia-provision-api.service << 'SVC_EOF'
[Unit]
Description=Belia Mishpat Provision API
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=/opt/belia/api
EnvironmentFile=/opt/belia/.env
ExecStart=/opt/belia/api/venv/bin/gunicorn \
  --bind 0.0.0.0:${API_PORT} \
  --workers 2 \
  --timeout 120 \
  server:app
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVC_EOF

systemctl daemon-reload
systemctl enable belia-provision-api
systemctl start belia-provision-api

echo ""
echo "Provisionamento concluido."
PROVISION

  ok "Provisionamento concluido."
}

# ── Resumo final ──────────────────────────────────────────────────────────────
summary() {
  local ip
  ip=$(pct exec "${CT_VMID}" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "N/A")

  echo ""
  sep
  echo ""
  echo -e "${G}"
  box_top
  box_blank
  box_line "CT 201 criada e provisionada com sucesso!"
  box_blank
  box_mid
  box_row "VMID"      "${CT_VMID}"
  box_row "Hostname"  "${CT_HOSTNAME}"
  box_row "IP"        "${ip}"
  box_row "Perfil"    "${CT_PROFILE} — ${CT_CORES}c / $((CT_MEMORY/1024))GB / ${CT_DISK}GB"
  box_row "API porta" "${API_PORT}"
  box_blank
  box_mid
  box_blank
  box_line "Provisionar cliente (manual):"
  box_blank
  box_line "pct enter ${CT_VMID}"
  box_line "/opt/belia/provision-client.sh \\"
  box_line "  --slug meu-cliente --port 3001"
  box_blank
  box_mid
  box_blank
  box_line "API HTTP (belia-admin):"
  box_blank
  box_line "POST http://${ip}:${API_PORT}/provision"
  box_line "Header: X-API-Key: <sua-chave>"
  box_line "Body:   { slug, port, image?, version? }"
  box_blank
  box_bot
  echo -e "${N}"
  echo ""
  warn "Guarde a API Key em local seguro — ela nao e exibida novamente."
  echo ""
  echo -e " ${W}API Key:${N} ${Y}${PROVISION_API_KEY}${N}"
  echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  header
  check_root
  check_proxmox
  select_vmid
  select_name
  select_postgres
  select_api_key
  select_template
  select_storage
  select_profile
  select_network
  select_api_port
  select_password
  confirm
  create_ct
  start_ct
  provision_ct
  summary
}

main
