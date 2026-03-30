#!/usr/bin/env bash
# ==============================================================================
#  setup-docker-ct.sh
#  Prepara um Container (CT) Debian 13 (Trixie) no Proxmox para deploy Docker.
#
#  Uso direto do GitHub:
#    curl -fsSL https://raw.githubusercontent.com/SEU_USER/SEU_REPO/main/setup-docker-ct.sh | bash
#
#  Ou com wget:
#    wget -qO- https://raw.githubusercontent.com/SEU_USER/SEU_REPO/main/setup-docker-ct.sh | bash
#
#  O que este script faz:
#    1. Corrige locale (pt_BR.UTF-8) — elimina os erros de localization
#    2. Atualiza pacotes do sistema
#    3. Instala ferramentas básicas (git, curl, wget, ca-certificates, gnupg)
#    4. Instala Docker Engine + Docker Compose plugin (repositório oficial)
#    5. Configura Docker daemon com boas práticas (log rotation, live-restore)
#    6. Configura UFW com portas 22, 80 e 443 abertas
#    7. Cria alias úteis para Docker
#    8. Smoke test — valida tudo no final
# ==============================================================================

set -euo pipefail

# ─── Cores e helpers ─────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()   { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

step() {
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  $*${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ─── Checagens iniciais ──────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    fail "Este script deve ser executado como root."
fi

if ! grep -qi 'debian\|trixie' /etc/os-release 2>/dev/null; then
    warn "Sistema não parece ser Debian 13 (Trixie). Continuando mesmo assim..."
fi

step "1/7  Corrigindo locale (pt_BR.UTF-8)"

# Instala locales se não estiver presente
apt-get update -qq
apt-get install -y -qq locales > /dev/null 2>&1

# Gera os locales necessários
sed -i 's/^# *pt_BR.UTF-8/pt_BR.UTF-8/' /etc/locale.gen 2>/dev/null || true
sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen 2>/dev/null || true

# Garante que as linhas existam mesmo que não estivessem comentadas
grep -q '^pt_BR.UTF-8' /etc/locale.gen || echo 'pt_BR.UTF-8 UTF-8' >> /etc/locale.gen
grep -q '^en_US.UTF-8' /etc/locale.gen || echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen

locale-gen > /dev/null 2>&1

# Seta o locale padrão do sistema
cat > /etc/default/locale <<'EOF'
LANG=pt_BR.UTF-8
LANGUAGE=pt_BR:pt:en
LC_ALL=pt_BR.UTF-8
EOF

export LANG=pt_BR.UTF-8
export LC_ALL=pt_BR.UTF-8

ok "Locale configurado: pt_BR.UTF-8"

# ─── 2. Atualização do sistema ──────────────────────────────────────────────

step "2/7  Atualizando pacotes do sistema"

apt-get update -qq
apt-get upgrade -y -qq > /dev/null 2>&1
apt-get dist-upgrade -y -qq > /dev/null 2>&1

ok "Sistema atualizado"

# ─── 3. Ferramentas básicas ─────────────────────────────────────────────────

step "3/7  Instalando ferramentas básicas"

BASIC_PKGS=(
    git
    curl
    wget
    ca-certificates
    gnupg
    lsb-release
    apt-transport-https
    software-properties-common
    jq
    unzip
    bash-completion
)

apt-get install -y -qq "${BASIC_PKGS[@]}" > /dev/null 2>&1

ok "Ferramentas instaladas: ${BASIC_PKGS[*]}"

# ─── 4. Docker Engine + Compose ─────────────────────────────────────────────

step "4/7  Instalando Docker Engine + Docker Compose"

# Remove versões antigas/conflitantes
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
    apt-get remove -y -qq "$pkg" > /dev/null 2>&1 || true
done

# Adiciona chave GPG oficial do Docker
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | \
    gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Adiciona o repositório
# Trixie pode não ter repo oficial ainda — fallback para bookworm se necessário
DEBIAN_CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-trixie}")

# Docker pode não ter repo para trixie ainda, usa bookworm como fallback
DOCKER_CODENAME="$DEBIAN_CODENAME"
if ! curl -fsSL "https://download.docker.com/linux/debian/dists/${DOCKER_CODENAME}/Release" > /dev/null 2>&1; then
    warn "Repositório Docker não disponível para '${DOCKER_CODENAME}', usando 'bookworm' como fallback."
    DOCKER_CODENAME="bookworm"
fi

cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${DOCKER_CODENAME} stable
EOF

apt-get update -qq

DOCKER_PKGS=(
    docker-ce
    docker-ce-cli
    containerd.io
    docker-buildx-plugin
    docker-compose-plugin
)

apt-get install -y -qq "${DOCKER_PKGS[@]}" > /dev/null 2>&1

# Habilita e inicia o Docker
systemctl enable docker --now > /dev/null 2>&1 || true
systemctl enable containerd --now > /dev/null 2>&1 || true

ok "Docker Engine instalado"
ok "Docker Compose plugin instalado"

# ─── 5. Configuração do Docker daemon ───────────────────────────────────────

step "5/7  Configurando Docker daemon (log rotation, live-restore)"

mkdir -p /etc/docker

cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true,
  "default-address-pools": [
    {
      "base": "172.20.0.0/16",
      "size": 24
    }
  ],
  "storage-driver": "overlay2"
}
EOF

# Reinicia para aplicar configurações
systemctl restart docker > /dev/null 2>&1 || warn "Não foi possível reiniciar o Docker (pode ser normal em CT sem systemd completo)"

ok "daemon.json configurado com log rotation e live-restore"

# ─── 6. Firewall (UFW) ─────────────────────────────────────────────────────

step "6/7  Configurando UFW (portas 22, 80, 443)"

apt-get install -y -qq ufw > /dev/null 2>&1

# Reset silencioso para garantir estado limpo
ufw --force reset > /dev/null 2>&1

# Políticas padrão
ufw default deny incoming > /dev/null 2>&1
ufw default allow outgoing > /dev/null 2>&1

# Portas essenciais
ufw allow 22/tcp comment 'SSH' > /dev/null 2>&1
ufw allow 80/tcp comment 'HTTP' > /dev/null 2>&1
ufw allow 443/tcp comment 'HTTPS' > /dev/null 2>&1

# Ativa o UFW
ufw --force enable > /dev/null 2>&1

ok "UFW ativo — portas abertas: 22 (SSH), 80 (HTTP), 443 (HTTPS)"

# ─── 7. Aliases e qualidade de vida ─────────────────────────────────────────

step "7/7  Configurando aliases e bash"

ALIAS_BLOCK='
# ── Docker aliases (adicionado por setup-docker-ct.sh) ──
alias d="docker"
alias dc="docker compose"
alias dps="docker ps --format \"table {{.Names}}\t{{.Status}}\t{{.Ports}}\""
alias dlogs="docker compose logs -f"
alias ddown="docker compose down"
alias dup="docker compose up -d"
alias dpull="docker compose pull"
alias dprune="docker system prune -af --volumes"
alias drestart="docker compose down && docker compose up -d"
'

# Adiciona no .bashrc do root se ainda não existir
if ! grep -q 'setup-docker-ct.sh' /root/.bashrc 2>/dev/null; then
    echo "$ALIAS_BLOCK" >> /root/.bashrc
fi

ok "Aliases Docker configurados no .bashrc"

# ─── Smoke test ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  SMOKE TEST${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

TESTS_PASSED=0
TESTS_TOTAL=0

check() {
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if eval "$2" > /dev/null 2>&1; then
        ok "$1"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        warn "FALHOU: $1"
    fi
}

check "Locale pt_BR.UTF-8"          "locale | grep -q 'pt_BR.UTF-8'"
check "Git instalado"               "command -v git"
check "curl instalado"              "command -v curl"
check "wget instalado"              "command -v wget"
check "Docker Engine"               "docker --version"
check "Docker Compose"              "docker compose version"
check "Docker daemon rodando"       "docker info"
check "UFW ativo"                   "ufw status | grep -q 'Status: active'"
check "daemon.json válido"          "jq . /etc/docker/daemon.json"

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [[ $TESTS_PASSED -eq $TESTS_TOTAL ]]; then
    echo -e "${GREEN}${BOLD}  ✓ TODOS OS TESTES PASSARAM (${TESTS_PASSED}/${TESTS_TOTAL})${NC}"
else
    echo -e "${YELLOW}${BOLD}  ⚠ ${TESTS_PASSED}/${TESTS_TOTAL} testes passaram${NC}"
fi

echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ─── Resumo final ────────────────────────────────────────────────────────────

DOCKER_V=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
COMPOSE_V=$(docker compose version 2>/dev/null | awk '{print $NF}')

echo -e "${GREEN}${BOLD}  ✓ CT PRONTO PARA DEPLOY!${NC}"
echo ""
echo -e "  Docker:   ${CYAN}${DOCKER_V}${NC}"
echo -e "  Compose:  ${CYAN}${COMPOSE_V}${NC}"
echo -e "  Locale:   ${CYAN}pt_BR.UTF-8${NC}"
echo -e "  Firewall: ${CYAN}UFW ativo (22, 80, 443)${NC}"
echo ""
echo -e "  ${BOLD}Próximos passos:${NC}"
echo -e "  ${CYAN}1.${NC} git clone https://github.com/seu-user/seu-projeto.git"
echo -e "  ${CYAN}2.${NC} cd seu-projeto"
echo -e "  ${CYAN}3.${NC} docker compose up -d"
echo ""
echo -e "  ${BOLD}Aliases disponíveis (abra novo terminal ou rode: source ~/.bashrc):${NC}"
echo -e "  ${CYAN}dc${NC}        → docker compose"
echo -e "  ${CYAN}dup${NC}       → docker compose up -d"
echo -e "  ${CYAN}ddown${NC}     → docker compose down"
echo -e "  ${CYAN}dlogs${NC}     → docker compose logs -f"
echo -e "  ${CYAN}dpull${NC}     → docker compose pull"
echo -e "  ${CYAN}dps${NC}       → docker ps (formatado)"
echo -e "  ${CYAN}dprune${NC}    → limpa tudo (imagens, volumes, containers)"
echo -e "  ${CYAN}drestart${NC}  → down + up"
echo ""
