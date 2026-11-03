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
APP_VERSION ?= $(shell python3 -c "import re;print(re.search(r'\"(.+)\"',open('app/sentinel_app/__init__.py').read()).group(1))")
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
	  --build-arg APP_VERSION=$(APP_VERSION) --build-arg GIT_SHA=$(GIT_SHA) \
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

##@ Quality
.PHONY: lint
lint: venv ## Lint Python, YAML and shell
	cd app && $(PY) -m ruff check . && $(PY) -m ruff format --check .
	if [ -d tools ]; then $(PY) -m ruff check tools && $(PY) -m ruff format --check tools; fi
	$(PY) -m yamllint -s .
	@if command -v shellcheck >/dev/null; then shellcheck scripts/*.sh; else echo "shellcheck not installed - skipping (sudo apt install shellcheck)"; fi

.PHONY: secrets-scan
secrets-scan: ## gitleaks scan of the working tree
	@mkdir -p $(REPORTS)
	gitleaks detect --source . --no-banner --redact --report-format json --report-path $(REPORTS)/gitleaks.json

.PHONY: iac-scan
iac-scan: venv ## checkov over Dockerfile, Terraform and Kubernetes manifests
	@mkdir -p $(REPORTS)
	$(PY) -m checkov.main --config-file .checkov.yaml

.PHONY: verify
verify: lint test iac-scan ## Run every check that does not need a cluster or AWS
	@echo "verify: OK"
