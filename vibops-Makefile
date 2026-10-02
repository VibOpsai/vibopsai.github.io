# VibOps — Makefile
# Usage:
#   make quickstart                   # first-time setup: copy .env, generate secrets, start stack
#   make up                           # start the full stack
#   make down                         # stop the stack
#   make check                        # verify the stack is healthy
#   make update                       # pull the published images and recreate
#   make debug                        # collect a support bundle (.tar.gz)
#   make logs SERVICE=core            # tail logs for a service
#   make pilot-create-client ORG=acme EMAIL=admin@acme.com PASSWORD=s3cr3t
#   make pilot-create-client ORG=acme EMAIL=admin@acme.com PASSWORD=s3cr3t BUDGET=5000

.PHONY: up down logs quickstart check update debug hash wait-healthy pilot-create-client backup-now backup-list help

# ── Stack ──────────────────────────────────────────────────────────────────────

# Le Caddyfile d'abord, et hors du garde-fou sur .env. Il y etait imbrique :
# un second `make quickstart`, ou un .env copie a la main comme le manuel le
# decrivait avant, sautait la copie entiere. Le compose monte alors un
# ./Caddyfile absent, Docker cree un REPERTOIRE a sa place et caddy meurt sur
# « Are you trying to mount a directory onto a file ». Reproduit le 01/10/2026
# sur l'hote de validation : `make: *** [quickstart] Error 1`.
quickstart:
	@if [ ! -f Caddyfile ]; then cp Caddyfile.example Caddyfile; \
		echo "→ Caddyfile created from Caddyfile.example (HTTP on :80 — set your domain for HTTPS)"; \
	fi
	@if [ -f .env ]; then \
		echo "→ .env already exists — skipping copy. Edit it manually if needed."; \
	else \
		cp .env.example .env; \
		echo "→ .env created from .env.example"; \
		SECRET=$$(openssl rand -hex 32); \
		JWT=$$(openssl rand -hex 32); \
		PGPASS=$$(openssl rand -hex 16); \
		GRAFPASS=$$(openssl rand -hex 12); \
		REDISPASS=$$(openssl rand -hex 24); \
		sed -i.bak "s/change-me-in-production/$$SECRET/" .env; \
		sed -i.bak "s/change-me-jwt-secret-in-production/$$JWT/" .env; \
		sed -i.bak "s/^POSTGRES_PASSWORD=$$/POSTGRES_PASSWORD=$$PGPASS/" .env; \
		sed -i.bak "s|\$${POSTGRES_PASSWORD}|$$PGPASS|g" .env; \
		sed -i.bak "s/^GRAFANA_PASSWORD=$$/GRAFANA_PASSWORD=$$GRAFPASS/" .env; \
		sed -i.bak "s/^REDIS_PASSWORD=$$/REDIS_PASSWORD=$$REDISPASS/" .env; \
		sed -i.bak "s|\$${REDIS_PASSWORD}|$$REDISPASS|g" .env; \
		rm -f .env.bak; \
		echo "→ SECRET_KEY, JWT_SECRET_KEY, POSTGRES_PASSWORD, REDIS_PASSWORD and GRAFANA_PASSWORD generated"; \
		echo ""; \
		echo "  Edit .env and set:"; \
		echo "    LLM_PROVIDER + LLM_API_KEY  (or set LLM_PROVIDER=ollama for local LLM)"; \
		echo "    AUTH_PASSWORD_HASH          (run: make hash PASSWORD=yourpassword)"; \
		echo ""; \
	fi
	docker compose up -d
	@echo ""
	@echo "→ Stack starting — waiting for the healthchecks to settle..."
	@$(MAKE) wait-healthy --no-print-directory
	@$(MAKE) check --no-print-directory
	@echo ""
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  Next steps — required before first use:"
	@echo ""
	@echo "  1. Set your LLM provider in .env:"
	@echo "       LLM_PROVIDER=claude   → add LLM_API_KEY=sk-ant-..."
	@echo "       LLM_PROVIDER=openai   → add LLM_API_KEY + LLM_BASE_URL"
	@echo "       LLM_PROVIDER=ollama   → no key needed"
	@echo ""
	@echo "  2. Create your admin account:"
	@echo "       make hash PASSWORD=yourpassword"
	@echo "       → paste the result into AUTH_PASSWORD_HASH in .env"
	@echo ""
	@echo "  3. Create your organisation:"
	@echo "       make pilot-create-client ORG=\"My Company\" EMAIL=you@company.com PASSWORD=yourpassword"
	@echo ""
	@echo "  4. Apply your .env changes to the agent:"
	@echo "       docker compose up -d agent"
	@echo "       (up -d, not restart: restart reuses the container's old"
	@echo "        environment and does not re-read .env)"
	@echo ""
	@HOST=$$(hostname -I 2>/dev/null | awk '{print $$1}' || echo "localhost"); \
	echo "  Console: http://$$HOST"; \
	if [ "$$HOST" != "localhost" ] && [ "$$HOST" != "127.0.0.1" ]; then \
		echo "           (or http://localhost from this machine)"; \
	fi; \
	echo ""; \
	echo "  Licence: trial mode — 14 days, 10 GPUs, 5 users, 5 clusters."; \
	echo "           Add VIBOPS_LICENCE_KEY to .env to activate your licence."; \
	echo "           Contact david@vibops.ai to obtain a key."
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Attendre que les healthchecks se soient prononces, plutot qu'un delai fixe.
#
# `make update` enchainait `up -d` et `check` sans rien attendre : sur la demo, le
# 01/10/2026, la verification a declare la console et l'agent injoignables alors
# que les deux repondaient 200 quinze secondes plus tard. Caddy et l'agent
# demarrent apres core, et `up -d` ne les attend pas. `quickstart` avait un
# `sleep 8`, qui est le meme pari sur une machine plus lente.
#
# Tous les services du compose declarent un healthcheck, donc « plus aucun
# health: starting » est une condition de repos fiable. Bornee a 90 s : au-dela,
# on verifie quand meme et `check` dira ce qu'il voit.
wait-healthy:
	@echo "→ Waiting for the healthchecks to settle..."
	@for i in $$(seq 1 45); do \
		if ! docker compose ps --format '{{.Status}}' 2>/dev/null | grep -q 'health: starting'; then break; fi; \
		sleep 2; \
	done

# Section 13 du manuel, « Upgrading / Docker Compose », qui tient en une ligne :
# `make update`. La cible n'existait pas — `No rule to make target 'update'` —
# donc le chemin de mise a jour documente echouait a sa premiere commande, de la
# meme facon que `make login` avant lui. Mesure le 01/10/2026.
#
# `up -d` et non `restart` : il faut recreer les conteneurs pour que les
# nouvelles images ET le .env courant soient pris.
update:
	@echo "→ Pulling the published images..."
	docker compose pull
	@echo "→ Recreating the services..."
	docker compose up -d
	@$(MAKE) wait-healthy --no-print-directory
	@echo ""
	@$(MAKE) check --no-print-directory

# Section 14 du manuel, « Troubleshooting », qui decrit precisement l'archive que
# cette cible produit — et qui n'existait pas non plus. Rien n'est envoye nulle
# part : l'archive reste sur la machine, a l'operateur de la transmettre.
debug:
	@BUNDLE="vibops-debug-$$(date -u +%Y-%m-%d-%H%M%S)"; \
	mkdir -p "$$BUNDLE"; \
	{ echo "# System"; uname -a; echo; \
	  echo "# CPU/RAM"; nproc 2>/dev/null; free -h 2>/dev/null || true; echo; \
	  echo "# Disk"; df -h . ; echo; \
	  echo "# Docker"; docker version --format "{{.Server.Version}}" 2>/dev/null; \
	  docker compose version 2>/dev/null; } > "$$BUNDLE/system.txt" 2>&1; \
	docker compose ps > "$$BUNDLE/containers.txt" 2>&1; \
	docker stats --no-stream > "$$BUNDLE/stats.txt" 2>&1 || true; \
	for svc in $$(docker compose config --services); do \
	  docker compose logs --tail 500 --no-color "$$svc" > "$$BUNDLE/log-$$svc.txt" 2>&1; \
	done; \
	sed -E "s/=(.+)/=<redacted>/" .env > "$$BUNDLE/env-keys.txt" 2>/dev/null || true; \
	tar czf "$$BUNDLE.tar.gz" "$$BUNDLE" && rm -rf "$$BUNDLE"; \
	echo "→ $$BUNDLE.tar.gz"; \
	echo "  Les valeurs du .env sont remplacees par <redacted> — seuls les noms"; \
	echo "  de variables partent. Relisez l'archive avant de la transmettre."

# Meme garde-fou qu'au quickstart : `make up` est le chemin de celui qui a deja
# son .env, donc precisement celui que l'imbrication laissait sans Caddyfile.
up:
	@if [ ! -f Caddyfile ] && [ -f Caddyfile.example ]; then cp Caddyfile.example Caddyfile; \
		echo "→ Caddyfile created from Caddyfile.example"; \
	fi
	docker compose up -d

down:
	docker compose down

logs:
	docker compose logs -f $(SERVICE)

check:
	@bash scripts/poc-healthcheck.sh http://localhost:8000

hash:
	@test -n "$(PASSWORD)" || (echo "Usage: make hash PASSWORD=yourpassword"; exit 1)
	@# --entrypoint python : l'entrypoint de l'image n'accepte que api, worker
	@# ou beat, et prenait « python » pour un mode inconnu — `make hash`
	@# repondait « Mode inconnu : python » et sortait en erreur. C'est l'etape 5
	@# du manuel, celle qui genere le hash sans lequel l'authentification reste
	@# desactivee. Constate le 01/10/2026 en deroulant Option B.
	@docker compose run --rm --entrypoint python core -c \
		"from app.auth import hash_password; print(hash_password('$(PASSWORD)'))"

# ── Pilot Onboarding ───────────────────────────────────────────────────────────
# Crée une organisation + admin + budget optionnel dans l'instance VibOps locale.
# Idempotent : peut être relancé sans danger (le password est mis à jour).
#
# Paramètres requis :
#   ORG      — nom de l'organisation  (ex: "Acme Corp")
#   EMAIL    — email de l'admin       (ex: admin@acme.com)
#   PASSWORD — mot de passe admin     (ex: changeme123)
#
# Paramètres optionnels :
#   SLUG     — identifiant URL        (défaut: valeur de ORG en minuscules)
#   BUDGET   — plafond mensuel USD    (ex: 5000 — aucun budget si absent)
#   SOFT_CAP — seuil d'alerte %       (défaut: 80)
#   HARD_CAP — seuil de blocage %     (défaut: 100)
#
# Exemples :
#   make pilot-create-client ORG=acme EMAIL=admin@acme.com PASSWORD=s3cr3t
#   make pilot-create-client ORG="BioTech AI" EMAIL=cto@biotech.io PASSWORD=p@ss BUDGET=12000

ORG      ?=
EMAIL    ?=
PASSWORD ?=
SLUG     ?= $(shell echo "$(ORG)" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')
BUDGET   ?=
SOFT_CAP ?= 80
HARD_CAP ?= 100

pilot-create-client:
	@test -n "$(ORG)"      || (echo "Erreur : ORG est requis.   Usage: make pilot-create-client ORG=acme EMAIL=... PASSWORD=..."; exit 1)
	@test -n "$(EMAIL)"    || (echo "Erreur : EMAIL est requis. Usage: make pilot-create-client ORG=acme EMAIL=... PASSWORD=..."; exit 1)
	@test -n "$(PASSWORD)" || (echo "Erreur : PASSWORD est requis."; exit 1)
	$(eval _BUDGET_ARG := $(if $(filter-out ,$(BUDGET)),--budget $(BUDGET),))
	@# SLUG, SOFT_CAP et HARD_CAP etaient passes vides quand l'appelant ne les
	@# donnait pas — et le manuel ne les mentionne pas. `--soft-cap ""` fait
	@# sortir argparse sur « invalid float value: '' » : la commande documentee
	@# pour creer une organisation echouait telle qu'elle est ecrite. Mesure le
	@# 01/10/2026. Le slug se derive de ORG, les caps ne sont passes que si on
	@# les fournit.
	$(eval _SLUG := $(if $(SLUG),$(SLUG),$(shell echo "$(ORG)" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$$//')))
	$(eval _SOFT_ARG := $(if $(filter-out ,$(SOFT_CAP)),--soft-cap $(SOFT_CAP),))
	$(eval _HARD_ARG := $(if $(filter-out ,$(HARD_CAP)),--hard-cap $(HARD_CAP),))
	docker compose exec core python -m scripts.pilot_provision \
		--org      "$(ORG)" \
		--slug     "$(_SLUG)" \
		--email    "$(EMAIL)" \
		--password "$(PASSWORD)" \
		$(_SOFT_ARG) $(_HARD_ARG) $(_BUDGET_ARG)

# ── Backup ─────────────────────────────────────────────────────────────────────

backup-now:
	@echo "→ Lancement d'un backup manuel..."
	docker compose exec backup sh -c \
		'DEST=/backups/vibops_$$(date -u +%Y-%m-%dT%H%M%S)_manual.sql.gz; \
		 pg_dump -h postgres -U vibops -d vibops_db | gzip > $$DEST && echo "✓ $$DEST"'

backup-list:
	@echo "Backups disponibles :"
	docker compose exec backup sh -c 'ls -lh /backups/vibops_*.sql.gz 2>/dev/null || echo "(aucun backup)"'

# ── Release ────────────────────────────────────────────────────────────────────

publish:
	@bash scripts/publish-install-repo.sh $(VERSION)

# ── Help ───────────────────────────────────────────────────────────────────────

help:
	@echo ""
	@echo "VibOps — available commands"
	@echo ""
	@echo "  make quickstart                            First-time setup + start"
	@echo "  make up                                    Start the stack"
	@echo "  make down                                  Stop the stack"
	@echo "  make check                                 Health check (all services)"
	@echo "  make logs SERVICE=core                     Tail logs for a service"
	@echo "  make hash PASSWORD=yourpassword            Generate bcrypt password hash"
	@echo ""
	@echo "  make pilot-create-client \\"
	@echo "    ORG=acme EMAIL=admin@acme.com \\"
	@echo "    PASSWORD=s3cr3t [BUDGET=5000]            Provision a client org"
	@echo ""
	@echo "  make backup-now                            Manual PostgreSQL backup"
	@echo "  make backup-list                           List available backups"
	@echo ""
	@echo "  make publish VERSION=v0.15.1               Publish to public install repo"
	@echo ""
