# SentinelOps — run from WSL2/Linux/macOS. `make help` lists targets.
SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

ROOT      := $(shell pwd)
include versions.env
export
export PATH := $(ROOT)/.bin:$(ROOT)/.venv/bin:$(PATH)

MODE      ?= local
GIT_SHA   ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)
APP_VERSION ?= $(shell sed -n 's/^__version__ = "\(.*\)"/\1/p' app/sentinel_app/__init__.py)
IMAGE_LOCAL := localhost:5001/sentinelops-app:$(GIT_SHA)
PY        := $(ROOT)/.venv/bin/python
REPORTS   := $(ROOT)/reports

##@ Setup
.PHONY: help
help: ## Show this help
	@awk 'BEGIN{FS=":.*##"; printf "\nUsage: make <target>\n"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  \033[36m%-18s\033[0m %s\n",$$1,$$2} /^##@/ {printf "\n\033[1m%s\033[0m\n",substr($$0,5)}' $(MAKEFILE_LIST)

.PHONY: tools
tools: ## Install pinned CLI tools into ./.bin
	@bash scripts/install-tools.sh

.venv/.installed: app/requirements-dev.txt requirements-tools.txt
	python3 -m venv .venv
	.venv/bin/pip install -q --upgrade pip
	.venv/bin/pip install -q -r app/requirements-dev.txt -r requirements-tools.txt
	touch $@

.PHONY: venv
venv: .venv/.installed ## Create Python virtualenv with pinned deps

##@ App
.PHONY: test
test: venv ## Run app unit tests with coverage gate (>=80%)
	@mkdir -p $(REPORTS)
	cd app && $(PY) -m pytest --junitxml=$(REPORTS)/junit-app.xml

.PHONY: run
run: venv ## Run the app locally on :8000
	cd app && $(PY) -m uvicorn sentinel_app.main:app --reload --port 8000

.PHONY: build
build: ## Build the app image (BuildKit) and tag for the local registry
	DOCKER_BUILDKIT=1 docker build -f docker/Dockerfile \
	  --build-arg APP_VERSION="$(APP_VERSION)" --build-arg GIT_SHA="$(GIT_SHA)" \
	  -t sentinelops-app:$(GIT_SHA) -t $(IMAGE_LOCAL) app/

.PHONY: image-test
image-test: build ## Build, run the container, and smoke-test /health /ready /metrics
	@bash scripts/image-smoke-test.sh sentinelops-app:$(GIT_SHA)

.PHONY: registry
registry: ## Start the local registry (localhost:5001)
	@bash scripts/local-registry.sh up

.PHONY: push-local
push-local: build registry ## Push the image to the local registry
	docker push $(IMAGE_LOCAL)

##@ Local mode
COMPOSE := docker compose --env-file .env -f local/docker-compose.yml
.PHONY: init-env local-up local-down local-clean local-status jenkins-logs sonar-bootstrap cosign-keygen jenkins-image
init-env: ## Create .env from .env.example with generated strong passwords
	@python3 scripts/envfile.py init
local-up: ## LOCAL MODE: registry + SonarQube + Jenkins (+ kind cluster from phase 5)
	@bash scripts/local-up.sh
local-down: ## Stop the local stack (keeps data volumes)
	-$(COMPOSE) --profile localstack down
	-bash scripts/local-registry.sh down
	@if [ -x scripts/kind-down.sh ]; then bash scripts/kind-down.sh; fi
local-clean: local-down ## Stop everything AND delete local data volumes
	-$(COMPOSE) --profile localstack down -v
	-docker volume rm sentinelops-registry
local-status: ## Show local stack status
	@$(COMPOSE) ps
	@bash scripts/local-registry.sh status || true
jenkins-logs: ## Tail Jenkins logs
	$(COMPOSE) logs -f --tail=100 jenkins
sonar-bootstrap: ## (Re)configure SonarQube: admin password, quality gate, webhook, token
	@bash scripts/sonar-bootstrap.sh
cosign-keygen: init-env ## Generate the Cosign signing key pair
	@bash scripts/cosign-keygen.sh
jenkins-image: ## Build the Jenkins image only
	DOCKER_BUILDKIT=1 docker build -f jenkins/image/Dockerfile -t sentinelops-jenkins:local .

##@ Terraform
.PHONY: tf-fmt tf-fmt-fix tf-validate tf-lint tf-check localstack tf-local aws-bootstrap-plan aws-bootstrap aws-plan aws-apply aws-destroy
tf-fmt: ## terraform fmt -check (recursive)
	@bash scripts/terraform.sh fmt
tf-fmt-fix: ## Rewrite Terraform files to canonical format
	terraform -chdir=terraform fmt -recursive
tf-validate: ## terraform validate every root and module (no backend, no AWS creds)
	@bash scripts/terraform.sh validate
tf-lint: ## tflint every root and module
	@bash scripts/terraform.sh lint
tf-check: tf-fmt tf-validate tf-lint ## fmt + validate + tflint
localstack: init-env ## Start LocalStack (local AWS emulation)
	docker compose --env-file .env -f local/docker-compose.yml --profile localstack up -d --wait localstack
tf-local: localstack ## LOCAL MODE: apply state-backend + finops modules to LocalStack (free)
	@bash scripts/terraform.sh local
aws-bootstrap-plan: ## Plan the S3+DynamoDB state backend (needs AWS creds)
	@bash scripts/terraform.sh bootstrap-plan
aws-bootstrap: ## Create the state backend - asks you to type APPLY
	@bash scripts/terraform.sh bootstrap-apply
aws-plan: ## Plan the AWS environment (+ Infracost if INFRACOST_API_KEY). Creates nothing
	@bash scripts/terraform.sh plan
aws-apply: ## Apply the saved plan - asks you to type APPLY (billable!)
	@bash scripts/terraform.sh apply
aws-destroy: ## Destroy the AWS environment - asks you to type DESTROY
	@bash scripts/terraform.sh destroy

##@ Ansible
.PHONY: ansible-lint ansible-test ansible-inventory ansible-aws
ansible-lint: venv ## ansible-lint (production profile) + playbook syntax check
	cd ansible && $(ROOT)/.venv/bin/ansible-lint --offline
	cd ansible && $(ROOT)/.venv/bin/ansible-playbook -i "jenkins," site.yml --syntax-check
.venv/.molecule: requirements-molecule.txt venv
	.venv/bin/pip install -q -r requirements-molecule.txt
	touch $@
ansible-test: .venv/.molecule ## Molecule: converge + idempotence + verify in a systemd container (needs Docker)
	cd ansible && $(ROOT)/.venv/bin/molecule test
ansible-inventory: ## Build ansible/inventory/aws.ini from terraform outputs
	@bash scripts/ansible-inventory.sh
ansible-aws: venv ansible-inventory ## Configure the Jenkins EC2 host (needs .env secrets + labsuser.pem)
	set -a; [ -f .env ] && . ./.env; set +a; cd ansible && $(ROOT)/.venv/bin/ansible-playbook site.yml

.PHONY: jenkins-lint
jenkins-lint: ## Groovy syntax lint of Jenkinsfile + shared library (needs Node.js + Java 17+)
	npx --yes npm-groovy-lint@15.0.0 --noserver --failon error --output txt jenkins/Jenkinsfile jenkins/shared-library/vars/

##@ Quality
.PHONY: lint
lint: venv ## Lint Python, YAML and shell
	cd app && $(PY) -m ruff check . && $(PY) -m ruff format --check .
	$(PY) -m ruff check tools scripts && $(PY) -m ruff format --check tools scripts
	$(PY) -m yamllint -s .
	@if command -v shellcheck >/dev/null; then shellcheck scripts/*.sh jenkins/image/entrypoint.sh; else echo "shellcheck not installed - skipping (sudo apt install shellcheck)"; fi

.PHONY: secrets-scan
secrets-scan: ## gitleaks scan of the working tree
	@mkdir -p $(REPORTS)
	gitleaks detect --source . --no-banner --redact --report-format json --report-path $(REPORTS)/gitleaks.json

.PHONY: iac-scan
iac-scan: venv ## checkov over Dockerfile, Terraform and Kubernetes manifests
	@mkdir -p $(REPORTS)
	$(PY) -m checkov.main --config-file .checkov.yaml

.PHONY: test-tools
test-tools: venv ## Unit tests for tools/ (drs, explain, finops, chaos)
	@mkdir -p $(REPORTS)
	$(PY) -m pytest tools/tests -q -p no:cacheprovider --junitxml=$(REPORTS)/junit-tools.xml

.PHONY: verify
verify: lint ansible-lint test test-tools iac-scan ## All checks that need no cluster/AWS (+ terraform checks if terraform is installed)
	@if command -v terraform >/dev/null && command -v tflint >/dev/null; then $(MAKE) --no-print-directory tf-check; \
	  else echo "terraform/tflint not installed - run 'make tools' to include tf-check"; fi
	@echo "verify: OK"
