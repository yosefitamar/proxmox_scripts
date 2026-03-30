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

# ── Versões ──────────────────────────────────────────────────────────────────
GO_VERSION="1.22.5"
NODE_VERSION="20"          # LTS

# ── Recursos da CT ───────────────────────────────────────────────────────────
CT_CORES=2
CT_MEMORY=2048             # MB
CT_SWAP=512                # MB
CT_DISK=10                 # GB
CT_ARCH="amd64"
CT_OSTYPE="debian"

# ── Rede ─────────────────────────────────────────────────────────────────────
CT_BRIDGE="vmbr0"
CT_DNS="8.8.8.8"

# ── Cores ANSI ───────────────────────────────────────────────────────────────
R='\033[0;31m'  # Red
G='\033[0;32m'  # Green
Y='\033[1;33m'  # Yellow
B='\033[0;34m'  # Blue
C='\033[0;36m'  # Cyan
W='\033[1;37m'  # White Bold
N='\033[0m'     # Reset

# ── Helpers de UI ─────────────────────────────────────────────────────────────

header() {
  clear
  echo -e "${C}"
  echo "  ╔══════════════════════════════════════════════════════╗"
  echo "  ║       Proxmox CT Creator — Go + Next.js Stack       ║"
  echo "  ║            Debian 12 · Go ${GO_VERSION} · Node ${NODE_VERSION} LTS          ║"
  echo "  ╚══════════════════════════════════════════════════════╝"
  echo -e "${N}"
}

info()    { echo -e "  ${B}[INFO]${N}  $*"; }
ok()      { echo -e "  ${G}[ OK ]${N}  $*"; }
warn()    { echo -e "  ${Y}[WARN]${N}  $*"; }
erro()    { echo -e "  ${R}[ERRO]${N}  $*" >&2; }
die()     { erro "$*"; exit 1; }
ask()     { echo -e -n "  ${W}[?]${N}  $* "; }

separador() { echo -e "  ${C}──────────────────────────────────────────────────────${N}"; }

# ── Verificações iniciais ─────────────────────────────────────────────────────

check_root() {
  [[ $EUID -eq 0 ]] || die "Execute como root no host Proxmox."
}

check_proxmox() {
  command -v pvesh &>/dev/null || die "pvesh não encontrado. Execute no host Proxmox."
  command -v pct   &>/dev/null || die "pct não encontrado. Execute no host Proxmox."
}

# ── Descoberta automática do ambiente ────────────────────────────────────────

get_node() {
  pvesh get /nodes --output-format json 2>/dev/null \
    | grep -o '"node":"[^"]*"' | head -1 | cut -d'"' -f4
}

get_next_vmid() {
  pvesh get /cluster/nextid 2>/dev/null || echo "200"
}

list_used_vmids() {
  pvesh get /nodes/"$(get_node)"/lxc   --output-format json 2>/dev/null | grep -o '"vmid":[0-9]*' | grep -o '[0-9]*'
  pvesh get /nodes/"$(get_node)"/qemu  --output-format json 2>/dev/null | grep -o '"vmid":[0-9]*' | grep -o '[0-9]*'
}

is_vmid_free() {
  local id=$1
  list_used_vmids | grep -qx "$id" && return 1 || return 0
}

list_templates() {
  # Lista templates .tar.zst / .tar.gz disponíveis em todos os storages
  pvesh get /nodes/"$(get_node)"/storage --output-format json 2>/dev/null \
    | grep -o '"storage":"[^"]*"' | cut -d'"' -f4 \
    | while read -r s; do
        pvesh get /nodes/"$(get_node)"/storage/"$s"/content \
          --output-format json 2>/dev/null \
          | grep -o '"volid":"[^"]*tar[^"]*"' | cut -d'"' -f4
      done
}

list_storages() {
  pvesh get /nodes/"$(get_node)"/storage --output-format json 2>/dev/null \
    | grep -o '"storage":"[^"]*"' | cut -d'"' -f4
}

# ── Seleção interativa ────────────────────────────────────────────────────────

select_vmid() {
  local suggestion
  suggestion=$(get_next_vmid)
  local used
  used=$(list_used_vmids | sort -n | tr '\n' ' ')

  echo ""
  info "IDs em uso: ${used:-nenhum}"
  info "Próximo ID sugerido: ${Y}${suggestion}${N}"
  echo ""

  while true; do
    ask "Número da CT (VMID) [${suggestion}]:"; read -r input
    local vmid="${input:-$suggestion}"

    if ! [[ "$vmid" =~ ^[0-9]+$ ]]; then
      warn "Digite apenas números."; continue
    fi
    if (( vmid < 100 )); then
      warn "VMID mínimo é 100."; continue
    fi
    if ! is_vmid_free "$vmid"; then
      warn "VMID ${vmid} já está em uso. Escolha outro."; continue
    fi

    ok "VMID ${vmid} disponível."
    CT_VMID="$vmid"
    break
  done
}

select_name() {
  echo ""
  while true; do
    ask "Hostname da CT:"; read -r nome
    if [[ -z "$nome" ]]; then
      warn "O nome não pode ser vazio."; continue
    fi
    if [[ "$nome" =~ [[:space:]] ]]; then
      warn "Sem espaços no hostname."; continue
    fi
    if (( ${#nome} > 63 )); then
      warn "Máximo 63 caracteres."; continue
    fi
    CT_HOSTNAME="$nome"
    ok "Hostname: ${CT_HOSTNAME}"
    break
  done
}

select_template() {
  echo ""
  info "Buscando templates disponíveis..."

  local templates=()
  while IFS= read -r t; do
    [[ -n "$t" ]] && templates+=("$t")
  done < <(list_templates)

  if (( ${#templates[@]} == 0 )); then
    warn "Nenhum template encontrado. Baixando Debian 12 automaticamente..."
    local storage
    storage=$(list_storages | head -1)
    pveam update &>/dev/null
    pveam download "$storage" debian-12-standard_12.7-1_amd64.tar.zst \
      || die "Falha ao baixar template Debian 12."
    templates=("${storage}:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst")
  fi

  if (( ${#templates[@]} == 1 )); then
    CT_TEMPLATE="${templates[0]}"
    ok "Template: ${CT_TEMPLATE}"
    return
  fi

  echo ""
  info "Templates disponíveis:"
  local i=1
  for t in "${templates[@]}"; do
    echo -e "    ${Y}${i})${N} ${t}"
    (( i++ ))
  done

  while true; do
    ask "Escolha o template [1]:"; read -r choice
    choice="${choice:-1}"
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#templates[@]} )); then
      warn "Opção inválida."; continue
    fi
    CT_TEMPLATE="${templates[$((choice-1))]}"
    ok "Template: ${CT_TEMPLATE}"
    break
  done
}

select_storage() {
  echo ""
  local storages=()
  while IFS= read -r s; do
    [[ -n "$s" ]] && storages+=("$s")
  done < <(list_storages)

  if (( ${#storages[@]} == 1 )); then
    CT_STORAGE="${storages[0]}"
    ok "Storage: ${CT_STORAGE}"
    return
  fi

  info "Storages disponíveis:"
  local i=1
  for s in "${storages[@]}"; do
    echo -e "    ${Y}${i})${N} ${s}"
    (( i++ ))
  done

  while true; do
    ask "Escolha o storage para o rootfs [1]:"; read -r choice
    choice="${choice:-1}"
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#storages[@]} )); then
      warn "Opção inválida."; continue
    fi
    CT_STORAGE="${storages[$((choice-1))]}"
    ok "Storage: ${CT_STORAGE}"
    break
  done
}

select_network() {
  echo ""
  info "Configuração de rede (bridge: ${CT_BRIDGE})"
  echo -e "    ${Y}1)${N} DHCP (automático)"
  echo -e "    ${Y}2)${N} IP fixo"

  ask "Tipo de rede [1]:"; read -r tipo
  tipo="${tipo:-1}"

  if [[ "$tipo" == "2" ]]; then
    while true; do
      ask "IP com CIDR (ex: 192.168.1.50/24):"; read -r CT_IP
      [[ "$CT_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] && break
      warn "Formato inválido. Use: 192.168.x.x/24"
    done
    ask "Gateway (ex: 192.168.1.1):"; read -r CT_GW
    NET_CONFIG="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},gw=${CT_GW}"
  else
    CT_IP="dhcp"
    CT_GW=""
    NET_CONFIG="name=eth0,bridge=${CT_BRIDGE},ip=dhcp"
  fi
  ok "Rede: ${CT_IP}"
}

select_password() {
  echo ""
  while true; do
    ask "Senha root da CT:"; read -rs CT_PASSWORD; echo ""
    ask "Confirme a senha:";  read -rs CT_PASSWORD2; echo ""
    if [[ "$CT_PASSWORD" == "$CT_PASSWORD2" ]]; then
      ok "Senha definida."
      break
    fi
    warn "As senhas não coincidem. Tente novamente."
  done
}

# ── Resumo + confirmação ──────────────────────────────────────────────────────

confirm() {
  echo ""
  separador
  echo -e "  ${W}Resumo da CT a ser criada:${N}"
  separador
  echo -e "  VMID      : ${Y}${CT_VMID}${N}"
  echo -e "  Hostname  : ${Y}${CT_HOSTNAME}${N}"
  echo -e "  Template  : ${CT_TEMPLATE}"
  echo -e "  Storage   : ${CT_STORAGE}"
  echo -e "  CPU/RAM   : ${CT_CORES} cores / ${CT_MEMORY} MB RAM / ${CT_SWAP} MB swap"
  echo -e "  Disco     : ${CT_DISK} GB"
  echo -e "  Rede      : ${CT_IP}  (bridge=${CT_BRIDGE})"
  echo -e "  Stack     : Go ${GO_VERSION}  +  Node.js ${NODE_VERSION} LTS (Next.js) + Nginx + PM2"
  separador
  echo ""
  ask "Confirmar criação? [s/N]:"; read -r resp
  [[ "$resp" =~ ^[sS]$ ]] || { info "Cancelado."; exit 0; }
}

# ── Criação da CT ─────────────────────────────────────────────────────────────

create_ct() {
  info "Criando CT ${CT_VMID} (${CT_HOSTNAME})..."

  pct create "${CT_VMID}" "${CT_TEMPLATE}" \
    --hostname    "${CT_HOSTNAME}" \
    --storage     "${CT_STORAGE}" \
    --rootfs      "${CT_STORAGE}:${CT_DISK}" \
    --cores       "${CT_CORES}" \
    --memory      "${CT_MEMORY}" \
    --swap        "${CT_SWAP}" \
    --net0        "${NET_CONFIG}" \
    --nameserver  "${CT_DNS}" \
    --arch        "${CT_ARCH}" \
    --ostype      "${CT_OSTYPE}" \
    --unprivileged 1 \
    --features    "nesting=1" \
    --password    "${CT_PASSWORD}" \
    --start       0

  ok "CT ${CT_VMID} criada."
}

start_ct() {
  info "Iniciando CT ${CT_VMID}..."
  pct start "${CT_VMID}"
  info "Aguardando inicialização (15s)..."
  sleep 15
  ok "CT iniciada."
}

# ── Script de provisionamento (roda DENTRO da CT) ─────────────────────────────

provision_ct() {
  info "Provisionando dependências (Go + Node.js + Nginx + PM2)..."
  info "Isso pode levar 3-5 minutos..."
  echo ""

  pct exec "${CT_VMID}" -- bash -euo pipefail << PROVISION
export DEBIAN_FRONTEND=noninteractive

echo "  --> Atualizando pacotes..."
apt-get update -qq && apt-get upgrade -y -qq

echo "  --> Instalando dependências base..."
apt-get install -y -qq \
  curl wget git unzip ca-certificates \
  build-essential gcc g++ make \
  nginx gnupg lsb-release

# ── Go ────────────────────────────────────────────────────────────────────────
echo "  --> Instalando Go ${GO_VERSION}..."
wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tar.gz
rm /tmp/go.tar.gz

cat > /etc/profile.d/go.sh << 'EOF'
export GOROOT=/usr/local/go
export GOPATH=\$HOME/go
export PATH=\$PATH:/usr/local/go/bin:\$HOME/go/bin
EOF
chmod +x /etc/profile.d/go.sh
source /etc/profile.d/go.sh
echo "     Go: \$(go version)"

# ── Node.js ───────────────────────────────────────────────────────────────────
echo "  --> Instalando Node.js ${NODE_VERSION} LTS..."
curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - &>/dev/null
apt-get install -y -qq nodejs
npm install -g pnpm pm2 &>/dev/null
echo "     Node: \$(node --version) | pnpm: \$(pnpm --version) | pm2: \$(pm2 --version)"

# ── PM2 startup ───────────────────────────────────────────────────────────────
pm2 startup systemd -u root --hp /root 2>/dev/null | grep -v '^\[' | bash || true

# ── Estrutura de diretórios ───────────────────────────────────────────────────
mkdir -p /opt/app/{backend,frontend}

# ── Nginx ─────────────────────────────────────────────────────────────────────
cat > /etc/nginx/sites-available/app << 'NGINX'
server {
    listen 80;
    server_name _;

    # Next.js frontend
    location / {
        proxy_pass         http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection 'upgrade';
        proxy_set_header   Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }

    # Go API
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

# ── deploy.sh ─────────────────────────────────────────────────────────────────
cat > /opt/app/deploy.sh << 'DEPLOY'
#!/usr/bin/env bash
# Uso: bash /opt/app/deploy.sh <backend-git-url> <frontend-git-url>
set -euo pipefail
source /etc/profile.d/go.sh

BACK="\${1:-}"
FRONT="\${2:-}"

[ -z "\$BACK"  ] && { echo "Informe a URL do repositório backend.";  exit 1; }
[ -z "\$FRONT" ] && { echo "Informe a URL do repositório frontend."; exit 1; }

echo "==> [Backend] clone / pull..."
if [ -d /opt/app/backend/.git ]; then
  git -C /opt/app/backend pull
else
  git clone "\$BACK" /opt/app/backend
fi

echo "==> [Backend] build Go..."
cd /opt/app/backend
go mod download
go build -o /opt/app/backend/server .
pm2 restart backend 2>/dev/null || pm2 start /opt/app/backend/server --name backend

echo "==> [Frontend] clone / pull..."
if [ -d /opt/app/frontend/.git ]; then
  git -C /opt/app/frontend pull
else
  git clone "\$FRONT" /opt/app/frontend
fi

echo "==> [Frontend] build Next.js..."
cd /opt/app/frontend
pnpm install --frozen-lockfile
pnpm build
pm2 restart frontend 2>/dev/null || pm2 start "pnpm start" --name frontend --cwd /opt/app/frontend

pm2 save
echo ""
echo "✅ Deploy concluído."
DEPLOY

chmod +x /opt/app/deploy.sh

echo ""
echo "  --> Provisionamento concluído."
PROVISION

  ok "Provisionamento concluído."
}

# ── Resultado final ───────────────────────────────────────────────────────────

summary() {
  local ip
  ip=$(pct exec "${CT_VMID}" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "verifique com: pct exec ${CT_VMID} -- hostname -I")

  echo ""
  separador
  echo -e "${G}"
  echo "  ╔══════════════════════════════════════════════════════╗"
  echo "  ║           ✅  CT criada e provisionada!             ║"
  echo "  ╠══════════════════════════════════════════════════════╣"
  printf  "  ║  VMID     : %-40s║\n" "${CT_VMID}"
  printf  "  ║  Hostname : %-40s║\n" "${CT_HOSTNAME}"
  printf  "  ║  IP       : %-40s║\n" "${ip}"
  echo "  ╠══════════════════════════════════════════════════════╣"
  echo "  ║  Stack instalada:                                    ║"
  echo "  ║    Go ${GO_VERSION}  ·  Node.js ${NODE_VERSION} LTS  ·  pnpm  ·  pm2      ║"
  echo "  ║    Nginx (reverse proxy na porta 80)                 ║"
  echo "  ╠══════════════════════════════════════════════════════╣"
  echo "  ║  Próximos passos:                                    ║"
  echo "  ║    pct enter ${CT_VMID}                                    ║"
  echo "  ║    bash /opt/app/deploy.sh <back-url> <front-url>   ║"
  echo "  ╚══════════════════════════════════════════════════════╝"
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
  select_network
  select_password
  confirm

  separador
  create_ct
  start_ct
  provision_ct
  summary
}

main
