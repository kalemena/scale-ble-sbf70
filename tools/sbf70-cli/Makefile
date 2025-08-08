.PHONY: help setup install scan status users history measure unknown delete-saved delete-unknown delete-user

PYTHON ?= python3
CLI = $(PYTHON) sbf70.py

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

setup: ## Create venv and install requirements
	$(PYTHON) -m venv .venv
	.venv/bin/pip3 install -r requirements.txt
	@echo "Run: source .venv/bin/activate"

install: ## Install dependencies in current environment
	pip3 install -r requirements.txt

scan: ## Scan for nearby scales
	$(CLI) scan $(ARGS)

status: ## Get scale status (battery, unit, firmware)
	$(CLI) status $(ARGS)

users: ## List user profiles on the scale
	$(CLI) users $(ARGS)

history: ## Download saved measurements
	$(CLI) history $(ARGS)

measure: ## Trigger a live weigh-in
	$(CLI) measure $(ARGS)

unknown: ## List guest/unassigned measurements
	$(CLI) unknown $(ARGS)

delete-saved: ## Delete saved measurements for a user
	$(CLI) delete-saved $(ARGS)

delete-unknown: ## Delete guest measurements by slot
	$(CLI) delete-unknown $(ARGS)

delete-user: ## Remove a user profile from the scale
	$(CLI) delete-user $(ARGS)
