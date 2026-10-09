#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# VibOps — Cold Install Script
#
# Installs VibOps on a fresh Linux VM (Ubuntu 22.04+ / Debian 12+).
# Requires: root or sudo, internet access, 4GB+ RAM, 20GB+ disk.
#
# Usage:
#   curl -fsSL https://vibops.ai/install.sh | bash
#
# Or with options:
#   bash install.sh --version 0.41.0 --llm-key sk-ant-xxx --admin-email admin@company.com
#
# HTTPS automatique (recommande en production) :
#   bash install.sh --domain vibops.exemple.com
#   Caddy obtient alors un certificat Let's Encrypt et redirige HTTP vers HTTPS.
#   Sans --domain, l'installation reste en HTTP simple sur le port 80.
# ─────────────────────────────────────────────────────────────────────────────

VIBOPS_DIR="/opt/vibops"
VIBOPS_VERSION="${VIBOPS_VERSION:-v0.54.2}"
LLM_API_KEY="${LLM_API_KEY:-}"
LLM_MODEL="${LLM_MODEL:-claude-sonnet-5}"
LLM_PROVIDER="${LLM_PROVIDER:-claude}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@vibops.local}"
ADMIN_ORG="${ADMIN_ORG:-My Organisation}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
# Nom de domaine du reverse proxy. Vide → Caddy ecoute en HTTP simple sur :80.
# Renseigne → Caddy obtient un certificat Let's Encrypt et redirige HTTP vers HTTPS.
VIBOPS_DOMAIN="${VIBOPS_DOMAIN:-}"
# The compose file served here is pinned to this release by image digest, so it
# belongs to this version and no other. Asking for a different --version means
# taking that release's own file, which the install repository keeps under its
# tag. Keeping one file and swapping a tag would have been the easy option and
# the wrong one: Docker resolves the digest and ignores the tag, so --version
# would have appeared to work while deploying this release's images.
DEFAULT_VERSION="$VIBOPS_VERSION"
COMPOSE_URL="https://vibops.ai/docker-compose.yml"

# ── Parse args ───────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case $1 in
    --version)      VIBOPS_VERSION="$2"; shift 2 ;;
    --llm-key)      LLM_API_KEY="$2"; shift 2 ;;
    --llm-model)    LLM_MODEL="$2"; shift 2 ;;
    --llm-provider) LLM_PROVIDER="$2"; shift 2 ;;
    --admin-email)  ADMIN_EMAIL="$2"; shift 2 ;;
    --admin-org)    ADMIN_ORG="$2"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
    --domain)       VIBOPS_DOMAIN="$2"; shift 2 ;;
    --dir)          VIBOPS_DIR="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Colours ──────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
err()   { echo -e "${RED}✗${NC} $1" >&2; exit 1; }
fail()  { echo -e "${RED}✗${NC} $1"; exit 1; }

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║           VibOps — Installation ${VIBOPS_VERSION}            ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── 1. Check prerequisites ──────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
  fail "This script must be run as root (use: sudo bash install.sh)"
fi

# ── 2. Install Docker if missing ─────────────────────────────────────────────

# Docker's own documentation says the get.docker.com convenience script is not
# for production — and this script configures Let's Encrypt and calls itself the
# production path, so it has no business using it. What follows is Docker's
# documented production install: their signed apt repository, the key verified
# by apt, packages pinned to a channel. It downloads data, not code to execute.
#
# Only Debian and Ubuntu, which are the only distributions this script claims to
# support. Anything else stops with the command to run rather than guessing.
install_docker() {
  local os_id codename
  . /etc/os-release
  os_id="$ID"
  codename="${VERSION_CODENAME:-}"

  case "$os_id" in
    ubuntu|debian) ;;
    *)
      fail "Docker is missing and this script installs it only on Ubuntu and Debian.
      Install Docker Engine and the Compose plugin with your distribution's
      documented procedure (https://docs.docker.com/engine/install/), then run
      this script again."
      ;;
  esac

  [[ -n "$codename" ]] || fail "Cannot read VERSION_CODENAME from /etc/os-release — install Docker manually."

  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${os_id}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${os_id} ${codename} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

if ! command -v docker &>/dev/null; then
  warn "Docker not found — installing from Docker's signed repository..."
  install_docker
  systemctl enable --now docker
  info "Docker installed"
else
  info "Docker already installed ($(docker --version | cut -d' ' -f3 | tr -d ','))"
fi

if ! docker compose version &>/dev/null; then
  fail "Docker Compose v2 not found. Update Docker or install docker-compose-plugin."
fi
info "Docker Compose $(docker compose version --short)"

# ── 3. Create install directory ──────────────────────────────────────────────

mkdir -p "$VIBOPS_DIR"
cd "$VIBOPS_DIR"
info "Install directory: $VIBOPS_DIR"

# Deux installations VibOps ne peuvent pas coexister sur un hote, et le
# decouvrir en route coute l'installation en place.
#
# Le compose publie fixe les noms de conteneurs (`container_name: vibops_core`),
# et Compose derive le nom de projet du nom du repertoire. Un `--dir` qui finit
# par « vibops » retombe donc sur le meme projet : Compose fusionne les deux
# fichiers de configuration et **recree les conteneurs de l'installation
# existante** avec la configuration de la nouvelle. Un `--dir` different ne sauve
# rien non plus — les noms de conteneurs, eux, sont les memes.
#
# Constate le 02/10/2026 sur l'hote de la demo : `--dir /root/essai/vibops` a
# adopte la pile de /opt/vibops, recree son Caddy, et l'installation s'est
# arretee sur « Bind for 127.0.0.1:8000 failed: port is already allocated ». Le
# depot avait anticipe la reprise — le Caddyfile et le compose existants sont
# conserves — mais pas l'adoption d'une installation voisine.
#
# Relancer le script dans le MEME repertoire reste permis : c'est la facon
# documentee de reparer ou de completer une installation.
if command -v docker &>/dev/null; then
  _ailleurs=$(docker inspect vibops_core \
    --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null || true)
  if [[ -n "$_ailleurs" && "$_ailleurs" != "$VIBOPS_DIR" ]]; then
    err "Une installation VibOps existe deja sur cet hote, dans ${_ailleurs}.
  Les deux partageraient les memes noms de conteneurs : continuer recreerait
  cette installation-la avec la configuration de celle-ci.

  Pour la mettre a jour :      bash install.sh --dir ${_ailleurs} …
  Pour la remplacer :          (cd ${_ailleurs} && docker compose down) puis relancez
  Pour l'inspecter d'abord :   (cd ${_ailleurs} && docker compose ps)"
  fi
fi

# ── 4. Download docker-compose.yml ───────────────────────────────────────────

if [[ ! -f docker-compose.yml ]]; then
  if [[ "$VIBOPS_VERSION" != "$DEFAULT_VERSION" ]]; then
    COMPOSE_URL="https://raw.githubusercontent.com/VibOpsai/vibops-install/${VIBOPS_VERSION}/docker-compose.yml"
    info "Version ${VIBOPS_VERSION} requested — taking its own compose file"
  fi
  curl -fsSL "$COMPOSE_URL" -o docker-compose.yml \
    || fail "Could not download ${COMPOSE_URL} — check that ${VIBOPS_VERSION} is a published release."
  info "Downloaded docker-compose.yml"
else
  warn "docker-compose.yml already exists — keeping existing file"
fi

# Le Makefile, parce que le manuel y renvoie hors de la section Docker Compose :
# `make hash`, `make check`, `make pilot-create-client`, `make backup-now`,
# `make update`. Une installation option A n'en posait aucun — elle laissait
# trois fichiers — donc toutes ces commandes repondaient
# « make: *** No rule to make target ». Non bloquant : le script fonctionne sans.
if [[ ! -f Makefile ]]; then
  # `vibops-Makefile`, pas `Makefile` : vibops.ai est servi par GitHub Pages, et
  # Jekyll exclut par defaut les fichiers nommes `Makefile`. L'adresse rendait
  # donc 404 — verifie le 02/10/2026 — pendant que `SHA256SUMS`, sans extension
  # lui aussi, etait bien servi. Le nom publie differe, le fichier pose garde le
  # sien.
  if curl -fsSL "${COMPOSE_URL%/docker-compose.yml}/vibops-Makefile" -o Makefile 2>/dev/null; then
    info "Downloaded Makefile (make check, make hash, make update…)"
  else
    warn "Makefile indisponible — les commandes \`make\` du manuel ne fonctionneront pas ici."
    rm -f Makefile
  fi
fi

# ── 4b. Generate Caddyfile ────────────────────────────────────────────────────

if [[ ! -f Caddyfile ]]; then
  # Sans domaine, Caddy ne peut obtenir aucun certificat : Let's Encrypt ne
  # certifie pas les adresses IP. On le demande donc, quitte a retomber sur :80.
  if [[ -z "$VIBOPS_DOMAIN" || "$VIBOPS_DOMAIN" == ":80" ]] && [[ -t 0 ]]; then
    echo
    echo "  Domaine pointant vers cette machine (ex. vibops.exemple.com)."
    echo "  Laisser vide pour rester en HTTP simple sur le port 80."
    read -r -p "  Domaine [aucun] : " _d || true
    VIBOPS_DOMAIN="${_d:-}"
  fi

  if [[ -n "$VIBOPS_DOMAIN" && "$VIBOPS_DOMAIN" != ":80" ]]; then
    SITE_ADDRESS="$VIBOPS_DOMAIN"
  else
    SITE_ADDRESS=":80"
    VIBOPS_DOMAIN=":80"
  fi

  cat > Caddyfile <<CADDYEOF
${SITE_ADDRESS} {
  # Connect parle a core, pas a la console. Sans cette regle, le relais final
  # envoie tout vers console:8003, dont chaque route exige une session
  # utilisateur — et un gateway presente un jeton de passerelle, pas un JWT.
  # Il recoit alors 401, ce qui ressemble a un jeton invalide et n'en est pas
  # un : le meme jeton fonctionne contre l'adresse interne. Mesure le
  # 26/09/2026 ; sans cette route, aucune installation par defaut ne peut
  # accueillir un site distant, ce qui est pourtant tout l'objet de Connect.
  #
  # Les quatre chemins ci-dessous sont exactement ceux que connect appelle
  # (worker.py : ping, jobs, jobs/{id}/claim, jobs/{id}/result), et tous
  # s'authentifient par jeton de passerelle.
  #
  # Le motif etait `/api/v1/gateways/*`, et le commentaire affirmait que ces
  # endpoints etaient « les seuls de core exposes ici ». C'etait faux : le
  # prefixe couvre aussi GET /gateways/{id}, POST /{id}/scan et
  # /gateways/gpu-utilization/live, qui s'authentifient par session
  # utilisateur. Le navigateur n'envoie pas de JWT core sur ces appels — la
  # console les relaie normalement — donc ils arrivaient a core sans identite.
  # En APP_ENV=development, ou l'acces anonyme est actif, cela vaut la portee
  # systeme : la colonne « GPU % » de la flotte lisait l'organisation systeme
  # et non celle de l'operateur, et affichait « — » sur le seul cluster qui a
  # un GPU. Constate sur la demo le 30/09/2026, depuis l'internet public et
  # sans aucune authentification.
  @connect path_regexp ^/api/v1/gateways/[^/]+/(ping|jobs)(/.*)?$
  handle @connect {
    reverse_proxy core:8000
  }
  reverse_proxy console:8003
}
CADDYEOF

  if [[ "$SITE_ADDRESS" == ":80" ]]; then
    warn "Caddyfile genere sans domaine — HTTP SIMPLE, AUCUN CHIFFREMENT."
    warn "  Mots de passe et jetons de session circuleront en clair."
    warn "  Acceptable uniquement derriere un proxy TLS (Cloudflare) ou sur reseau prive."
    warn "  Pour activer HTTPS : relancer avec --domain votre-domaine.com,"
    warn "  ou remplacer ':80' par le domaine dans ${VIBOPS_DIR}/Caddyfile puis"
    warn "  redemarrer Caddy (docker compose restart caddy)."
  else
    info "Caddyfile genere pour ${SITE_ADDRESS} — Caddy obtiendra un certificat"
    info "  Let's Encrypt au demarrage et redirigera HTTP vers HTTPS."
    info "  Prerequis : l'enregistrement DNS de ${SITE_ADDRESS} doit pointer vers"
    info "  cette machine, et les ports 80 et 443 doivent etre joignables."
  fi
fi

# ── 4c. Static files ─────────────────────────────────────────────────────────
#
# Plus de `mkdir -p static` : il n'existait que parce que le compose montait
# ./static dans Caddy, et ce montage ne servait plus rien depuis le retrait de
# l'experimentation whisper le 26/09/2026 — aucune directive du Caddyfile ne
# lit /static, la console servant ses propres fichiers depuis son conteneur.
# Le montage restait, donc Docker creait un repertoire vide chez chaque client.

# ── 5. Generate .env ─────────────────────────────────────────────────────────

if [[ ! -f .env ]]; then
  POSTGRES_PASSWORD=$(openssl rand -hex 24)
  REDIS_PASSWORD=$(openssl rand -hex 24)
  # Le mot de passe du role `vibops_app`, celui sous lequel les politiques de
  # l'ADR 0047 mordent reellement. Sans lui, core se connecte en
  # superutilisateur et la base n'isole aucun locataire — voir le compose.
  APP_ROLE_PASSWORD=$(openssl rand -hex 24)
  SECRET_KEY=$(openssl rand -hex 32)
  JWT_SECRET_KEY=$(openssl rand -base64 32)
  VAULT_KEY=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())" 2>/dev/null \
    || openssl rand -base64 32)
  INTERNAL_API_KEY=$(openssl rand -hex 32)
  GRAFANA_PASSWORD=$(openssl rand -base64 16)
  # Chiffre les archives de sauvegarde. Elle n'existe que dans ce .env : le
  # recapitulatif de fin le dit, parce qu'une clef perdue rend trente jours
  # d'archives — et toutes les copies hors machine — inouvrables.
  BACKUP_PASSPHRASE=$(openssl rand -hex 32)

  if [[ -z "$ADMIN_PASSWORD" ]]; then
    ADMIN_PASSWORD=$(openssl rand -base64 12)
    warn "Generated admin password: $ADMIN_PASSWORD (save this!)"
  fi

  # Le hash est calcule par le produit lui-meme, pas reimplemente ici.
  #
  # Cette commande faisait un PBKDF2-SHA512 en python3 local, quand
  # `verify_password` du produit fait un scrypt : deux algorithmes, donc un
  # hash que rien ne pouvait verifier. Le format `salt:hash` identique rendait
  # les deux indistinguables a l'oeil. Constate le 01/10/2026.
  AUTH_PASSWORD_HASH=$(docker run --rm --entrypoint python \
    "ghcr.io/davidmacamara-boop/vibops-core:${VIBOPS_VERSION}" -c \
    "from app.auth import hash_password; print(hash_password('${ADMIN_PASSWORD}'))" 2>/dev/null | tail -1)
  if [[ -z "$AUTH_PASSWORD_HASH" ]]; then
    err "Impossible de calculer le hash du mot de passe administrateur."
  fi

  cat > .env <<ENVEOF
# VibOps — generated by install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)

# ─── Version ────────────────────────────────────────────────
VIBOPS_VERSION=${VIBOPS_VERSION}

# ─── Database ───────────────────────────────────────────────
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
DATABASE_URL=postgresql+asyncpg://vibops:${POSTGRES_PASSWORD}@postgres:5432/vibops_db

# ─── Isolation des locataires par la base (ADR 0047) ────────
# Le role applicatif, sans superutilisateur ni BYPASSRLS. Videz cette variable
# pour remettre l'application sur le proprietaire : la base cesse alors
# d'isoler les locataires, et l'entrypoint le dit dans ses journaux.
APP_ROLE_PASSWORD=${APP_ROLE_PASSWORD}

# ─── Redis ──────────────────────────────────────────────────
REDIS_PASSWORD=${REDIS_PASSWORD}

# ─── Backups ────────────────────────────────────────────────
# Chiffre les archives nocturnes (AES-256-CBC).
#
# ⚠ CETTE CLEF EST LA SEULE. Perdue, les trente jours d'archives et toutes
# leurs copies hors machine ne s'ouvrent plus. Gardez une copie de ce fichier
# ailleurs que sur cette machine.
BACKUP_PASSPHRASE=${BACKUP_PASSPHRASE}
BACKUP_ITER=600000

# ─── Security ───────────────────────────────────────────────
SECRET_KEY=${SECRET_KEY}
VAULT_KEY=${VAULT_KEY}
INTERNAL_API_KEY=${INTERNAL_API_KEY}

# ─── Auth ───────────────────────────────────────────────────
ADMIN_EMAIL=${ADMIN_EMAIL}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
AUTH_PASSWORD_HASH=${AUTH_PASSWORD_HASH}
JWT_SECRET_KEY=${JWT_SECRET_KEY}
JWT_EXPIRE_HOURS=24

# ─── LLM ────────────────────────────────────────────────────
LLM_PROVIDER=${LLM_PROVIDER}
LLM_MODEL=${LLM_MODEL}
LLM_API_KEY=${LLM_API_KEY}
LLM_BASE_URL=

# ─── App ────────────────────────────────────────────────────
APP_ENV=production

# ─── Webhooks (generated, override if needed) ───────────
GITHUB_WEBHOOK_SECRET=$(openssl rand -hex 32)
GRAFANA_WEBHOOK_SECRET=$(openssl rand -hex 32)

# ─── Grafana ────────────────────────────────────────────────
GRAFANA_PUBLIC_URL=http://localhost:3000
GRAFANA_PASSWORD=${GRAFANA_PASSWORD}

# ─── SMTP (optional) ────────────────────────────────────────
SMTP_HOST=
SMTP_PORT=587
SMTP_USER=
SMTP_PASSWORD=
SMTP_FROM=noreply@yourcompany.com

# ─── Reverse proxy ──────────────────────────────────────────
VIBOPS_DOMAIN=${VIBOPS_DOMAIN:-:80}

# ─── Internal URLs ──────────────────────────────────────────
CORE_API_URL=http://core:8000
AGENT_API_URL=http://agent:8001
ENVEOF

  chmod 600 .env
  info "Generated .env with secure random secrets"
else
  warn ".env already exists — keeping existing configuration"
fi

# ── 6. Pull images ───────────────────────────────────────────────────────────

info "Pulling VibOps images (v${VIBOPS_VERSION})..."
docker compose pull --quiet 2>/dev/null || docker compose pull
info "All images pulled"

# ── 7. Start services ───────────────────────────────────────────────────────

info "Starting VibOps..."
# --wait : rendre la main quand les services repondent, pas quand leurs
# processus existent. Sans lui, l'installateur affichait « Console:
# http://IP:8003 » alors que la console pouvait encore repondre par une reponse
# vide — le port est ouvert avant qu'uvicorn serve.
#
# `|| true` parce que le script tourne sous `set -e` : un depassement de delai
# doit laisser la boucle ci-dessous diagnostiquer et afficher un message utile,
# pas interrompre l'installation sur un code de retour nu.
docker compose up -d --wait --wait-timeout 300 || true

# ── 8. Wait for healthy ─────────────────────────────────────────────────────

echo -n "Waiting for Core API to be healthy"
for i in $(seq 1 60); do
  if docker compose exec -T core python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/api/v1/health')" &>/dev/null; then
    echo ""
    info "Core API is healthy"
    break
  fi
  echo -n "."
  sleep 2
done

# ── 9. Run migrations ───────────────────────────────────────────────────────

info "Running database migrations..."
docker compose exec -T core alembic upgrade head
info "Migrations complete"

# ── 9bis. Creer le compte administrateur ────────────────────────────
#
# Sans ce pas, l'installation se terminait sur « Installation complete » en
# annoncant « Admin: admin@vibops.local » — et la table `users` etait vide.
# `POST /api/v1/auth/login` n'authentifie que contre la base ; AUTH_PASSWORD_HASH
# n'active l'authentification, il ne cree aucun compte, et `create_legacy_token`
# qui lui servait de recours n'est plus appele par personne. Donc personne ne
# pouvait se connecter a une installation option A, et la page de connexion
# s'affichait quand meme. Verifie le 01/10/2026 : 0 ligne dans `users`, login en
# 401 pour l'administrateur annonce.
#
# Le provisionnement du produit fait foi, plutot qu'un INSERT ecrit ici : il
# cree l'organisation, l'utilisateur, l'appartenance et le budget d'un seul
# geste, et il est idempotent.
ADMIN_SLUG=$(echo "${ADMIN_EMAIL%%@*}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
[[ -n "$ADMIN_SLUG" ]] || ADMIN_SLUG="admin"

info "Creating the administrator account..."
if docker compose exec -T core python -m scripts.pilot_provision \
     --org "${ADMIN_ORG}" --slug "${ADMIN_SLUG}" \
     --email "${ADMIN_EMAIL}" --password "${ADMIN_PASSWORD}" >/tmp/vibops-provision.log 2>&1; then
  info "Account ${ADMIN_EMAIL} created in organisation \"${ADMIN_ORG}\""
else
  warn "La creation du compte administrateur a echoue :"
  tail -5 /tmp/vibops-provision.log >&2
  warn "  Personne ne pourra se connecter tant qu'un compte n'existe pas. Relancez :"
  echo "  docker compose exec core python -m scripts.pilot_provision \\"
  echo "    --org \"${ADMIN_ORG}\" --slug ${ADMIN_SLUG} --email ${ADMIN_EMAIL} --password '<mot de passe>'"
fi

# ── 10. Summary ──────────────────────────────────────────────────────────────

SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║              VibOps is running!                     ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║                                                      ║"
# Caddy est le seul service publie sur le reseau. Ce bandeau annoncait trois
# URL — :8003, :8000 et :3000 — et les trois repondaient 000 : 8003 est le port
# que la console ecoute DANS son conteneur, core et grafana ne sont publies que
# sur la boucle locale. C'est le dernier texte que lit celui qui vient de lancer
# un script en root. Mesure le 01/10/2026 sur un hote amd64.
if [[ "$SITE_ADDRESS" == ":80" ]]; then
  CONSOLE_URL="http://${SERVER_IP}"
else
  CONSOLE_URL="https://${SITE_ADDRESS}"
fi
echo "║  Console:    ${CONSOLE_URL}                          ║"
echo "║  Core API:   via la console, ou 127.0.0.1:8000 sur l'hote ║"
echo "║  Grafana:    127.0.0.1:3000 sur l'hote (tunnel SSH)   ║"
echo "║                                                      ║"
echo "║  Admin:      ${ADMIN_EMAIL}                          ║"
echo "║  Config:     ${VIBOPS_DIR}/.env                      ║"
echo "║  Logs:       docker compose -f ${VIBOPS_DIR}/docker-compose.yml logs -f ║"
echo "║                                                      ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# La clef de sauvegarde n'existe que dans ce .env. Le dire ici, au moment ou
# elle vient d'etre creee, est le seul instant ou l'exploitant est en train de
# regarder : une clef perdue rend trente jours d'archives — et toutes leurs
# copies hors machine — inouvrables, et rien ne le signalera avant le jour de
# la restauration.
if grep -q '^BACKUP_PASSPHRASE=.' "${VIBOPS_DIR}/.env" 2>/dev/null; then
  warn "Vos sauvegardes sont chiffrees, et la clef est dans ${VIBOPS_DIR}/.env uniquement."
  warn "  Copiez ce fichier ailleurs que sur cette machine des maintenant."
  echo "  grep BACKUP_PASSPHRASE ${VIBOPS_DIR}/.env"
  echo ""
fi

if [[ -z "$LLM_API_KEY" ]]; then
  # « ne fonctionnera pas » etait trop doux : le script pose APP_ENV=production,
  # et en production l'agent sort en code 1 quand le fournisseur est claude sans
  # cle. Le conteneur boucle donc en redemarrage indefiniment, ce que `up --wait`
  # avait deja signale par « container vibops_agent is unhealthy » quelques
  # lignes plus haut, avant que le script n'annonce « Installation complete ».
  warn "LLM_API_KEY est vide : l'agent REDEMARRE EN BOUCLE et le restera."
  warn "  C'est attendu — en production il refuse de demarrer sans cle."
  warn "  Pour le reparer, posez la cle dans ${VIBOPS_DIR}/.env puis :"
  echo "  docker compose -f ${VIBOPS_DIR}/docker-compose.yml up -d agent"
  # Des guillemets simples, pas des accents graves : dans une chaine entre
  # guillemets doubles, bash prend les accents graves pour une substitution de
  # commande. Ce message imprimait donc « up: command not found », deux fois
  # « restart: command not found », et sortait ampute de ses trois mots :
  #
  #     install.sh: line 450: up: command not found
  #     ⚠   , pas  :  relance le conteneur existant avec
  #
  # Dans un script qu'on fait executer en root, et dans la ligne meme qui
  # explique comment reparer l'agent. Constate le 02/10/2026 en rejouant
  # l'option A apres l'avoir corrigee.
  warn "  'up -d', pas 'restart' : 'restart' relance le conteneur existant avec"
  warn "  ses anciennes variables et ne relit pas .env."
fi

info "Installation complete"
