SHELL := /bin/bash
MODULE := modules/team_infrastructure
BASE ?= origin/main
HEAD ?= HEAD

.PHONY: help teams check-teams fmt validate plan changed-teams test-ci lint

help: ## Show available targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

teams: ## Create/refresh live/team-* folders from teams.yaml
	@scripts/sync-teams.sh sync

check-teams: ## Fail if live/ is out of sync with teams.yaml (used by CI)
	@scripts/sync-teams.sh check

fmt: ## Format Terraform and Terragrunt files
	terraform fmt -recursive
	terragrunt hcl fmt --working-dir live

validate: check-teams ## Offline checks, no AWS credentials needed
	terraform fmt -check -recursive
	terragrunt hcl fmt --check --working-dir live
	terraform -chdir=$(MODULE) init -backend=false -input=false >/dev/null
	terraform -chdir=$(MODULE) validate

plan: ## Plan one team: make plan TEAM=alpha
	@[[ "$(TEAM)" =~ ^[a-z0-9-]+$$ ]] || { echo "usage: make plan TEAM=<name>"; exit 1; }
	cd live/team-$(TEAM) && terragrunt plan

changed-teams: ## Show what CI would run: make changed-teams BASE=origin/main HEAD=HEAD
	@scripts/changed-teams.sh "$(BASE)" "$(HEAD)"

test-ci: ## Run the CI script tests (no AWS)
	@tests/ci/run.sh

lint: ## shellcheck + actionlint (brew install shellcheck actionlint)
	shellcheck scripts/*.sh tests/ci/*.sh
	actionlint
