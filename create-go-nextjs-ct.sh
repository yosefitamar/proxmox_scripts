#!/usr/bin/env bash
# =============================================================================
#  create-go-nextjs-ct.sh
#  Cria uma LXC Container no Proxmox com Go + Node.js (Next.js) + Nginx + PM2
#
#  Uso direto (do GitHub):
#    bash -c "$(curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/create-go-nextjs-ct.sh)"
#
#  Ou localmente:
#    bash create-go-nextjs-ct.sh
#
#  Requisitos: rodar no HOST Proxmox como root
# =============================================================================

set -euo pipefail

# ── Versoes ───────────────────────────────────────────────────────────────────
GO_VERSION="1.22.5"
NODE_VERSION="20"

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

# ── Box helpers (largura fixa, sem emoji, sem unicode ambiguo) ────────────────
BOX_W=54

_strip() { printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g'; }

box_top()   { printf "  +"; printf '%0.s-' $(seq 1 $BOX_W); printf '+\n'; }
box_mid()   { printf "  +"; printf '%0.s-' $(seq 1 $BOX_W); printf '+\n'; }
box_bot()   { printf "  +"; printf '%0.s-' $(seq 1 $BOX_W); printf '+\n'; }
box_blank() { printf "  |%${BOX_W}s|\n" ""; }

box_line() {
  local text="$1"
  local clean; clean=$(_strip "$text")
  local len=${#clean}
  local lpad=$(( (BOX_W - len) / 2 ))
  local rpad=$(( BOX_W - len - lpad ))
  printf "  |%*s%b%*s|\n" "$lpad" "" "$text" "$rpad" ""
}

box_row() {
  local label="$1" value="$2"
  local label_w=11
  local val_w=$(( BOX_W - label_w - 4 ))   # 4 = "  " + ": " + " "
  local cv; cv=$(_strip "$value")
  if (( ${#cv} > val_w )); then value="${cv:0:$((val_w-3))}..."; fi
  printf "  |  ${W}%-${label_w}s${N}: ${Y}%-${val_w}s${N} |\n" "$label" "$value"
}

sep() { echo -e "  ${D}$(printf '%0.s-' $(seq 1 $((BOX_W+4))))${N}"; }

# ── Mensagens ─────────────────────────────────────────────────────────────────
info() { echo -e "  ${B}[i]${N} $*"; }
ok()   { echo -e "  ${G}[+]${N} $*"; }
warn() { echo -e "  ${Y}[!]${N} $*"; }
erro() { echo -e "  ${R}[x]${N} $*" >&2; }
die()  { erro "$*"; exit 1; }
ask()  { printf "  ${W}[?]${N} %s " "$*"; }

# ── Header ────────────────────────────────────────────────────────────────────
header() {
  clear
  echo ""
  echo -e "${C}"
  box_top
  box_blank
  box_line "Proxmox CT Creator"
  box_line "Go + Next.js Stack"
  box_blank
  box_line "Go ${GO_VERSION}  |  Node.js ${NODE_VERSION} LTS  |  Nginx  |  PM2"
  box_blank
  box_bot
  echo -e "${N}"
  echo ""
}

# ── Verificacoes ───────────────────────────────────────────────────────────────
check_root()    { [[ $EUID -eq 0 ]] || die "Execute como root no host Proxmox."; }
check_proxmox() {
  command -v pvesh &>/dev/null || die "pvesh nao encontrado. Execute no host Proxmox."
  command -v pct   &>/dev/null || die "pct nao encontrado. Execute no host Proxmox."
}

# ── Descoberta ────────────────────────────────────────────────────────────────
get_node() {
  pvesh get /nodes --output-format json 2>/dev/null \
    | grep -o '"node":"[^"]*"' | head -1 | cut -d'"' -f4
}

get_next_vmid() { pvesh get /cluster/nextid 2>/dev/null || echo "200"; }

list_used_vmids() {
  local node; node=$(get_node)
  pvesh get /nodes/"$node"/lxc  --output-format json 2>/dev/null | grep -o '"vmid":[0-9]*' | grep -o '[0-9]*'
  pvesh get /nodes/"$node"/qemu --output-format json 2>/dev/null | grep -o '"vmid":[0-9]*' | grep -o '[0-9]*'
}

is_vmid_free() { list_used_vmids | grep -qx "$1" && return 1 || return 0; }

list_templates() {
  local node; node=$(get_node)
  pvesh get /nodes/"$node"/storage --output-format json 2>/dev/null \
    | grep -o '"storage":"[^"]*"' | cut -d'"' -f4 \
    | while read -r s; do
        pvesh get /nodes/"$node"/storage/"$s"/content \
          --output-format json 2>/dev/null \
          | grep -o '"volid":"[^"]*tar[^"]*"' | cut -d'"' -f4
      done
}

list_storages() {
  pvesh get /nodes/"$(get_node)"/storage --output-format json 2>/dev/null \
    | grep -o '"storage":"[^"]*"' | cut -d'"' -f4
}

# ── Selecao: VMID ─────────────────────────────────────────────────────────────
select_vmid() {
  local suggestion used
  suggestion=$(get_next_vmid)
  used=$(list_used_vmids | sort -n | tr '\n' ' ')

  sep
  info "IDs em uso    : ${used:-nenhum}"
  info "Proximo livre : ${Y}${suggestion}${N}"
  echo ""

  while true; do
    ask "VMID da CT [${suggestion}]:"; read -r input
    local vmid="${input:-$suggestion}"
    [[ "$vmid" =~ ^[0-9]+$ ]]  || { warn "Apenas numeros."; continue; }
    (( vmid >= 100 ))           || { warn "VMID minimo: 100."; continue; }
    is_vmid_free "$vmid"        || { warn "VMID $vmid ja em uso."; continue; }
    ok "VMID $vmid disponivel."
    CT_VMID="$vmid"
    break
  done
}

# ── Selecao: Hostname ──────────────────────────────────────────────────────────
select_name() {
  echo ""
  while true; do
    ask "Hostname da CT:"; read -r nome
    [[ -n "$nome" ]]               || { warn "Nome vazio."; continue; }
    [[ ! "$nome" =~ [[:space:]] ]] || { warn "Sem espacos."; continue; }
    (( ${#nome} <= 63 ))           || { warn "Maximo 63 caracteres."; continue; }
    CT_HOSTNAME="$nome"
    ok "Hostname: ${CT_HOSTNAME}"
    break
  done
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
    warn "Nenhum template encontrado. Baixando Debian 12..."
    local storage; storage=$(list_storages | head -1)
    pveam update &>/dev/null
    pveam download "$storage" debian-12-standard_12.7-1_amd64.tar.zst \
      || die "Falha ao baixar template."
    templates=("${storage}:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst")
  fi

  if (( ${#templates[@]} == 1 )); then
    CT_TEMPLATE="${templates[0]}"
    ok "Template: $(basename "$CT_TEMPLATE")"
    return
  fi

  echo ""
  info "Templates disponiveis:"
  echo ""
  local i=1
  for t in "${templates[@]}"; do
    printf "    ${Y}%d)${N} %s\n" "$i" "$(basename "$t")"
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
    printf "    ${Y}%d)${N} %s\n" "$i" "$s"
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

# ── Selecao: Perfil de recursos ───────────────────────────────────────────────
select_profile() {
  sep
  echo ""
  info "Perfil de recursos da CT:"
  echo ""
  printf "    ${Y}1)${N} ${W}Basico       ${N}  2 cores  /  2 GB RAM  /  10 GB disco\n"
  printf "    ${Y}2)${N} ${W}Intermediario${N}  4 cores  /  4 GB RAM  /  20 GB disco\n"
  printf "    ${Y}3)${N} ${W}Avancado     ${N}  4 cores  /  8 GB RAM  /  40 GB disco\n"
  echo ""

  while true; do
    ask "Escolha o perfil [1]:"; read -r choice
    choice="${choice:-1}"
    case "$choice" in
      1) CT_PROFILE="Basico";        CT_CORES=2; CT_MEMORY=2048; CT_DISK=10 ;;
      2) CT_PROFILE="Intermediario"; CT_CORES=4; CT_MEMORY=4096; CT_DISK=20 ;;
      3) CT_PROFILE="Avancado";      CT_CORES=4; CT_MEMORY=8192; CT_DISK=40 ;;
      *) warn "Opcao invalida. Escolha 1, 2 ou 3."; continue ;;
    esac
    ok "Perfil: ${CT_PROFILE} — ${CT_CORES} cores / $((CT_MEMORY/1024)) GB RAM / ${CT_DISK} GB disco"
    break
  done
}

# ── Selecao: Rede ─────────────────────────────────────────────────────────────
select_network() {
  sep
  info "Configuracao de rede  (bridge: ${CT_BRIDGE})"
  echo ""
  printf "    ${Y}1)${N} DHCP  (automatico)\n"
  printf "    ${Y}2)${N} IP fixo\n"
  echo ""

  ask "Tipo de rede [1]:"; read -r tipo
  tipo="${tipo:-1}"

  if [[ "$tipo" == "2" ]]; then
    while true; do
      ask "IP/CIDR (ex: 192.168.1.50/24):"; read -r CT_IP
      [[ "$CT_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] && break
      warn "Formato invalido. Ex: 192.168.1.50/24"
    done
    ask "Gateway (ex: 192.168.1.1):"; read -r CT_GW
    NET_CONFIG="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},gw=${CT_GW}"
  else
    CT_IP="dhcp"; CT_GW=""
    NET_CONFIG="name=eth0,bridge=${CT_BRIDGE},ip=dhcp"
  fi
  ok "Rede: ${CT_IP}"
}

# ── Selecao: Senha ────────────────────────────────────────────────────────────
select_password() {
  sep
  echo ""
  while true; do
    ask "Senha root da CT:"; read -rs CT_PASSWORD; echo ""
    ask "Confirme a senha: "; read -rs CT_PASSWORD2; echo ""
    [[ "$CT_PASSWORD" == "$CT_PASSWORD2" ]] && break
    warn "Senhas nao coincidem. Tente novamente."
    echo ""
  done
  ok "Senha definida."
}

# ── Resumo + confirmacao ──────────────────────────────────────────────────────
confirm() {
  echo ""
  sep
  echo ""
  echo -e "  ${W}Resumo da CT a ser criada:${N}"
  echo ""
  echo -e "${C}"
  box_top
  box_blank
  box_row "VMID"      "${CT_VMID}"
  box_row "Hostname"  "${CT_HOSTNAME}"
  box_row "Template"  "$(basename "$CT_TEMPLATE")"
  box_row "Storage"   "${CT_STORAGE}"
  box_row "Perfil"    "${CT_PROFILE}"
  box_row "CPU"       "${CT_CORES} cores"
  box_row "RAM"       "$((CT_MEMORY/1024)) GB  (swap: ${CT_SWAP} MB)"
  box_row "Disco"     "${CT_DISK} GB"
  box_row "Rede"      "${CT_IP}  (${CT_BRIDGE})"
  box_row "Stack"     "Go ${GO_VERSION} + Node ${NODE_VERSION} + Nginx + PM2"
  box_blank
  box_bot
  echo -e "${N}"
  echo ""
  ask "Confirmar criacao? [s/N]:"; read -r resp
  [[ "$resp" =~ ^[sS]$ ]] || { info "Cancelado."; exit 0; }
}

# ── Criacao da CT ──────────────────────────────────────────────────────────────
create_ct() {
  sep
  info "Criando CT ${CT_VMID} (${CT_HOSTNAME})..."

  local ostype="debian"
  [[ "$(basename "$CT_TEMPLATE")" == ubuntu* ]] && ostype="ubuntu"

  pct create "${CT_VMID}" "${CT_TEMPLATE}"   \
    --hostname     "${CT_HOSTNAME}"          \
    --storage      "${CT_STORAGE}"           \
    --rootfs       "${CT_STORAGE}:${CT_DISK}" \
    --cores        "${CT_CORES}"             \
    --memory       "${CT_MEMORY}"            \
    --swap         "${CT_SWAP}"              \
    --net0         "${NET_CONFIG}"           \
    --nameserver   "${CT_DNS}"               \
    --arch         "${CT_ARCH}"              \
    --ostype       "$ostype"                 \
    --unprivileged 1                         \
    --features     "nesting=1"               \
    --password     "${CT_PASSWORD}"          \
    --start        0

  ok "CT ${CT_VMID} criada."
}

start_ct() {
  info "Iniciando CT ${CT_VMID}..."
  pct start "${CT_VMID}"
  info "Aguardando inicializacao (15s)..."
  sleep 15
  ok "CT iniciada."
}

# ── Provisionamento (executa DENTRO da CT) ────────────────────────────────────
provision_ct() {
  sep
  info "Provisionando dependencias dentro da CT..."
  info "Isso pode levar 3-5 minutos..."
  echo ""

  pct exec "${CT_VMID}" -- bash -euo pipefail << PROVISION
export DEBIAN_FRONTEND=noninteractive

echo "[1/6] Atualizando pacotes..."
apt-get update -qq && apt-get upgrade -y -qq

echo "[2/6] Instalando dependencias base..."
apt-get install -y -qq \
  curl wget git unzip ca-certificates \
  build-essential gcc g++ make \
  nginx gnupg lsb-release

echo "[3/6] Instalando Go ${GO_VERSION}..."
wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tar.gz && rm /tmp/go.tar.gz

cat > /etc/profile.d/go.sh << 'EOF'
export GOROOT=/usr/local/go
export GOPATH=\$HOME/go
export PATH=\$PATH:/usr/local/go/bin:\$HOME/go/bin
EOF
chmod +x /etc/profile.d/go.sh
source /etc/profile.d/go.sh
echo "    Go: \$(go version)"

echo "[4/6] Instalando Node.js ${NODE_VERSION} LTS + pnpm + pm2..."
curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - &>/dev/null
apt-get install -y -qq nodejs
npm install -g pnpm pm2 &>/dev/null
pm2 startup systemd -u root --hp /root 2>/dev/null | grep -v '^\[' | bash || true
echo "    Node: \$(node --version) | pnpm: \$(pnpm --version)"

echo "[5/6] Configurando Nginx..."
mkdir -p /opt/app/{backend,frontend}

cat > /etc/nginx/sites-available/app << 'NGINX'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass         http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection 'upgrade';
        proxy_set_header   Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }

    location /api/ {
        proxy_pass       http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
NGINX

ln -sf /etc/nginx/sites-available/app /etc/nginx/sites-enabled/app
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl enable nginx && systemctl restart nginx

echo "[6/6] Criando /opt/app/deploy.sh..."
cat > /opt/app/deploy.sh << 'DEPLOY'
#!/usr/bin/env bash
# Uso: bash /opt/app/deploy.sh <backend-git-url> <frontend-git-url>
set -euo pipefail
source /etc/profile.d/go.sh

BACK="\${1:-}"
FRONT="\${2:-}"
[ -z "\$BACK"  ] && { echo "Informe a URL do repositorio backend.";  exit 1; }
[ -z "\$FRONT" ] && { echo "Informe a URL do repositorio frontend."; exit 1; }

echo "==> [Backend] clone/pull..."
if [ -d /opt/app/backend/.git ]; then git -C /opt/app/backend pull
else git clone "\$BACK" /opt/app/backend; fi

echo "==> [Backend] build Go..."
cd /opt/app/backend && go mod download && go build -o server .
pm2 restart backend 2>/dev/null || pm2 start /opt/app/backend/server --name backend

echo "==> [Frontend] clone/pull..."
if [ -d /opt/app/frontend/.git ]; then git -C /opt/app/frontend pull
else git clone "\$FRONT" /opt/app/frontend; fi

echo "==> [Frontend] build Next.js..."
cd /opt/app/frontend && pnpm install --frozen-lockfile && pnpm build
pm2 restart frontend 2>/dev/null || \
  pm2 start "pnpm start" --name frontend --cwd /opt/app/frontend
pm2 save
echo "Deploy concluido."
DEPLOY

chmod +x /opt/app/deploy.sh
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
  box_line "CT criada e provisionada com sucesso!"
  box_blank
  box_mid
  box_row "VMID"     "${CT_VMID}"
  box_row "Hostname" "${CT_HOSTNAME}"
  box_row "IP"       "${ip}"
  box_row "Perfil"   "${CT_PROFILE} — ${CT_CORES}c/${CT_MEMORY}MB/${CT_DISK}GB"
  box_blank
  box_mid
  box_line "Proximo passo:"
  box_blank
  box_line "pct enter ${CT_VMID}"
  box_line "bash /opt/app/deploy.sh <back> <front>"
  box_blank
  box_bot
  echo -e "${N}"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  header
  check_root
  check_proxmox
  select_vmid
  select_name
  select_template
  select_storage
  select_profile
  select_network
  select_password
  confirm
  create_ct
  start_ct
  provision_ct
  summary
}

main
