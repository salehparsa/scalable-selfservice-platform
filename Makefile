SHELL := /bin/bash
MODULE := modules/team_infrastructure
BASE ?= origin/main
HEAD ?= HEAD

.PHONY: help teams check-teams fmt validate test test-module test-ci plan changed-teams lint

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

test: test-module test-ci ## Run all tests (no AWS)

test-module: ## Module unit tests: terraform test, offline plans with fake credentials
	terraform -chdir=$(MODULE) init -backend=false -input=false >/dev/null
	terraform -chdir=$(MODULE) test

test-ci: ## Change-detection tests for the CI pipeline (no AWS)
	@tests/ci/test-changed-teams.sh

plan: ## Plan one team: make plan TEAM=alpha  (LOCAL=1 uses the working-tree module instead of the released one)
	@[[ "$(TEAM)" =~ ^[a-z0-9-]+$$ ]] || { echo "usage: make plan TEAM=<name> [LOCAL=1]"; exit 1; }
	cd live/team-$(TEAM) && $(if $(LOCAL),TG_SOURCE=$(CURDIR)/$(MODULE) )terragrunt plan

changed-teams: ## Show what CI would run: make changed-teams BASE=origin/main HEAD=HEAD
	@scripts/changed-teams.sh "$(BASE)" "$(HEAD)"

lint: ## shellcheck + actionlint (brew install shellcheck actionlint)
	shellcheck scripts/*.sh tests/ci/*.sh
	actionlint
