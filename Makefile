# =============================================================================
# aws-network-architecture -- developer entry points
#
#   make check     Everything CI runs. Run this before opening a pull request.
#   make help      List every target.
#
# NOTHING in this Makefile applies or destroys AWS infrastructure. Deployment is
# always an explicit, per-lab action you take by hand -- see each lab's README.
# =============================================================================

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# Every directory containing Terraform configuration, discovered rather than
# listed, so new labs are picked up automatically.
TF_DIRS := $(shell find bootstrap modules labs -name '*.tf' -not -path '*/.terraform/*' -exec dirname {} \; 2>/dev/null | sort -u)

# Directories that ship `terraform test` files.
TEST_DIRS := $(shell find modules -name '*.tftest.hcl' -not -path '*/.terraform/*' -exec dirname {} \; 2>/dev/null | sed 's|/tests$$||' | sort -u)

TERRAFORM ?= terraform
TFLINT    ?= tflint
CHECKOV   ?= checkov

CYAN  := \033[36m
BOLD  := \033[1m
RESET := \033[0m

.PHONY: help
help: ## Show this help
	@echo ""
	@printf "$(BOLD)aws-network-architecture$(RESET)\n"
	@echo ""
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  $(CYAN)%-18s$(RESET) %s\n", $$1, $$2}'
	@echo ""

# -----------------------------------------------------------------------------
# Formatting
# -----------------------------------------------------------------------------
.PHONY: fmt
fmt: ## Rewrite all Terraform files into canonical format
	$(TERRAFORM) fmt -recursive .

.PHONY: fmt-check
fmt-check: ## Fail if any Terraform file is not canonically formatted
	@echo "==> terraform fmt -check -recursive"
	@$(TERRAFORM) fmt -check -recursive .

# -----------------------------------------------------------------------------
# Validation
#
# `-backend=false` is what makes this work without AWS credentials or an
# existing state bucket: Terraform loads providers and checks the configuration
# without ever contacting S3.
# -----------------------------------------------------------------------------
.PHONY: init
init: ## terraform init -backend=false in every module
	@for d in $(TF_DIRS); do \
		echo "==> init $$d"; \
		$(TERRAFORM) -chdir=$$d init -backend=false -input=false -no-color > /dev/null; \
	done

.PHONY: validate
validate: init ## terraform validate in every module
	@rc=0; \
	for d in $(TF_DIRS); do \
		echo "==> validate $$d"; \
		$(TERRAFORM) -chdir=$$d validate -no-color || rc=1; \
	done; \
	exit $$rc

# -----------------------------------------------------------------------------
# Linting and security scanning
# -----------------------------------------------------------------------------
.PHONY: lint
lint: ## Run TFLint across the repository
	@echo "==> tflint --init"
	@$(TFLINT) --init > /dev/null
	@echo "==> tflint --recursive"
	@$(TFLINT) --recursive --config="$(CURDIR)/.tflint.hcl" --minimum-failure-severity=error

.PHONY: security
security: ## Run Checkov static security analysis
	@echo "==> checkov"
	@$(CHECKOV) --config-file .checkov.yaml

# -----------------------------------------------------------------------------
# Tests
#
# Module tests use `mock_provider`, so they need no AWS credentials and create
# nothing. They run `terraform plan` against mocked provider responses.
# -----------------------------------------------------------------------------
.PHONY: test
test: ## Run terraform test for every module that has tests
	@rc=0; \
	for d in $(TEST_DIRS); do \
		echo "==> test $$d"; \
		$(TERRAFORM) -chdir=$$d init -backend=false -input=false -no-color > /dev/null; \
		$(TERRAFORM) -chdir=$$d test -no-color || rc=1; \
	done; \
	exit $$rc

# -----------------------------------------------------------------------------
# Aggregate
# -----------------------------------------------------------------------------
.PHONY: check
check: fmt-check validate lint security test ## Run every static check (what CI runs)
	@echo ""
	@printf "$(BOLD)All checks passed.$(RESET)\n"

# -----------------------------------------------------------------------------
# Housekeeping
# -----------------------------------------------------------------------------
.PHONY: clean
clean: ## Remove .terraform directories and local plan files
	@find . -type d -name '.terraform' -prune -exec rm -rf {} + 2>/dev/null || true
	@find . -type f \( -name '*.tfplan' -o -name 'tfplan' \) -delete 2>/dev/null || true
	@echo "Cleaned. Committed .terraform.lock.hcl files were left in place."

.PHONY: list-labs
list-labs: ## List every deployable lab and its backend state key
	@for d in $$(find labs -maxdepth 1 -mindepth 1 -type d | sort); do \
		key=$$(grep -h 'key ' $$d/backend.tf 2>/dev/null | head -1 | sed 's/.*= *//;s/"//g' || echo '-'); \
		printf "  %-42s %s\n" "$$d" "$$key"; \
	done

.PHONY: precommit-install
precommit-install: ## Install the pre-commit hooks defined in .pre-commit-config.yaml
	pre-commit install
	pre-commit install --hook-type commit-msg

# -----------------------------------------------------------------------------
# Convenience wrappers for working in a single lab.
#
#   make lab-init LAB=01-vpc-fundamentals
#   make lab-plan LAB=01-vpc-fundamentals
#
# `lab-apply` and `lab-destroy` are intentionally absent. Applying infrastructure
# that costs money should be a command you type deliberately, in the lab
# directory, having read that lab's README.
# -----------------------------------------------------------------------------
.PHONY: lab-init
lab-init: ## Init a lab against the S3 backend (LAB=01-vpc-fundamentals)
	@test -n "$(LAB)" || { echo "usage: make lab-init LAB=01-vpc-fundamentals"; exit 1; }
	@test -f labs/$(LAB)/backend.hcl || { \
		echo "labs/$(LAB)/backend.hcl not found."; \
		echo "Copy backend.hcl.example and fill in the bucket from 'terraform -chdir=bootstrap output'."; \
		exit 1; }
	$(TERRAFORM) -chdir=labs/$(LAB) init -backend-config=backend.hcl

.PHONY: lab-plan
lab-plan: ## Plan a lab (LAB=01-vpc-fundamentals)
	@test -n "$(LAB)" || { echo "usage: make lab-plan LAB=01-vpc-fundamentals"; exit 1; }
	$(TERRAFORM) -chdir=labs/$(LAB) plan
