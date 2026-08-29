SHELL := /bin/bash

COMPOSE := docker compose

# Optional corporate/TLS-intercepting-proxy CA bundle (Milestone M3). Leave
# unset on unrestricted networks; the coder-workspace build step is then a
# no-op. Example: make coder-workspace-build CACERT=/path/to/ca-bundle.pem
CACERT ?=

.PHONY: doctor up down status logs coder-workspace-build embedded-workspace-build devcontainer-workspace-build templates-push runner-build runner-run temporal-worker-build lab-sim-build temporal-demo-start governance-bootstrap governance-verify opa-policy-check backup restore-test

## doctor: Verify the host meets the baseline requirements (Milestone M0).
doctor:
	@bash scripts/doctor.sh

## up: Start the platform stack in the background (Milestone M1).
## Builds cade/temporal-worker and cade/lab-sim first — compose.yaml
## references them as local-only images (no `build:` stanza), so `up`
## fails on a fresh host/clone without this. Pass CACERT=... to also
## thread a corporate CA bundle through both builds.
up: temporal-worker-build lab-sim-build
	@$(COMPOSE) up -d
	@bash scripts/print-urls.sh

## down: Stop and remove the platform stack's containers.
down:
	@$(COMPOSE) down

## status: Show the status/health of the platform stack's containers.
status:
	@$(COMPOSE) ps

## logs: Follow the logs of the platform stack's containers.
logs:
	@$(COMPOSE) logs -f

## coder-workspace-build: Build the docker-standard workspace image (Milestone M3).
coder-workspace-build:
	@dirty="$$(git status --porcelain -- examples coder Makefile 2>/dev/null)"; \
	if [ -n "$$dirty" ]; then \
		echo "ERROR: uncommitted changes under examples/, coder/, or Makefile:"; \
		echo "$$dirty"; \
		echo "The workspace template clones the remote repository, not this"; \
		echo "working tree — commit and push these files first, otherwise the"; \
		echo "built image/pushed template will not match what workspaces clone."; \
		exit 1; \
	fi
	@if [ -n "$(CACERT)" ]; then \
		docker buildx build -f coder/Dockerfile --secret id=cacert,src=$(CACERT) \
			-t cade/coder-workspace:latest --load coder; \
	else \
		docker buildx build -f coder/Dockerfile \
			-t cade/coder-workspace:latest --load coder; \
	fi

## embedded-workspace-build: Build the embedded-linux workspace image (Milestone M6).
embedded-workspace-build: coder-workspace-build
	@if [ -n "$(CACERT)" ]; then \
		docker buildx build -f coder/embedded-linux/Dockerfile --secret id=cacert,src=$(CACERT) \
			-t cade/embedded-linux-workspace:latest --load coder/embedded-linux; \
	else \
		docker buildx build -f coder/embedded-linux/Dockerfile \
			-t cade/embedded-linux-workspace:latest --load coder/embedded-linux; \
	fi

## runner-build: Build the self-hosted GitHub Actions runner image (Milestone M2).
runner-build:
	@if [ -n "$(CACERT)" ]; then \
		docker buildx build -f runner/Dockerfile --secret id=cacert,src=$(CACERT) \
			-t cade/runner:latest --load runner; \
	else \
		docker buildx build -f runner/Dockerfile \
			-t cade/runner:latest --load runner; \
	fi

## runner-run: Request a JIT config and run one ephemeral self-hosted runner (Milestone M2).
runner-run:
	@bash scripts/runner-jit-start.sh

## temporal-worker-build: Build the M8 demo durable-workflow worker image.
## Pass CACERT=/path/to/ca-bundle.pem on a corporate TLS-intercepting proxy.
temporal-worker-build:
	@if [ -n "$(CACERT)" ]; then \
		docker buildx build -f temporal/Dockerfile --secret id=cacert,src=$(CACERT) \
			-t cade/temporal-worker:latest --load temporal; \
	else \
		docker buildx build -f temporal/Dockerfile \
			-t cade/temporal-worker:latest --load temporal; \
	fi

## lab-sim-build: Build the M11 lab-sim MCP service image.
## Pass CACERT=/path/to/ca-bundle.pem on a corporate TLS-intercepting proxy.
lab-sim-build:
	@if [ -n "$(CACERT)" ]; then \
		docker buildx build -f mcp/lab-sim/Dockerfile --secret id=cacert,src=$(CACERT) \
			-t cade/lab-sim:latest --load mcp/lab-sim; \
	else \
		docker buildx build -f mcp/lab-sim/Dockerfile \
			-t cade/lab-sim:latest --load mcp/lab-sim; \
	fi

## temporal-demo-start: Start one execution of the M8 demo durable workflow.
temporal-demo-start:
	@docker run --rm --network platform-control \
		-e TEMPORAL_ADDRESS=temporal:7233 \
		-e DEMO_TASK_QUEUE=demo-durable-workflow \
		--entrypoint python \
		cade/temporal-worker:latest -m demo.starter

## temporal-build-demo-start: Start one execution of the Issue #5 build-in-workspace demo workflow.
temporal-build-demo-start:
	@docker run --rm --network platform-control \
		-e TEMPORAL_ADDRESS=temporal:7233 \
		-e DEMO_TASK_QUEUE=demo-durable-workflow \
		--entrypoint python \
		cade/temporal-worker:latest -m demo.build_starter --wait

## governance-bootstrap: Init/unseal OpenBao, rotate Phase 1-3 credentials, revoke root token (Milestone M12).
governance-bootstrap:
	@bash scripts/openbao-init.sh

## governance-verify: Run opa test plus a live OPA/MCP ALLOW-run_test / DENY-flash_device round trip (Milestone M12).
governance-verify:
	@bash scripts/verify-governance.sh

## opa-policy-check: Run opa test plus an ALLOW/DENY decision smoke check against a throwaway, job-scoped opa server - no live platform stack required (Issue #9, also run in CI).
opa-policy-check:
	@bash scripts/opa-policy-check.sh

## backup: Create a timestamped backup set covering every MUST-BACK-UP category (Milestone M14).
backup:
	@bash scripts/backup.sh

## restore-test: Destroy the MUST-BACK-UP resources and restore them from the latest backup set (Milestone M14).
restore-test:
	@bash scripts/restore-test.sh


## devcontainer-workspace-build: Build the devcontainer bootstrap image (Issue #6).
devcontainer-workspace-build:
	@dirty="$$(git status --porcelain -- examples coder Makefile 2>/dev/null)"; \
	if [ -n "$$dirty" ]; then \
		echo "ERROR: uncommitted changes under examples/, coder/, or Makefile:"; \
		echo "$$dirty"; \
		echo "The devcontainer template clones the remote repository, not this"; \
		echo "working tree — commit and push these files first, otherwise the"; \
		echo "built image/pushed template will not match what workspaces clone."; \
		exit 1; \
	fi
	@if [ -n "$(CACERT)" ]; then \
		docker buildx build -f coder/devcontainer/Dockerfile --secret id=cacert,src=$(CACERT) \
			-t cade/devcontainer-bootstrap:latest --load coder/devcontainer; \
	else \
		docker buildx build -f coder/devcontainer/Dockerfile \
			-t cade/devcontainer-bootstrap:latest --load coder/devcontainer; \
	fi

## templates-push: Push every Coder workspace template (docker-standard, embedded-linux,
## devcontainer) to the running Coder server in one shot. Depends on all three
## *-workspace-build targets, so it also builds/refreshes cade/coder-workspace,
## cade/embedded-linux-workspace, and cade/devcontainer-bootstrap first (cache-hit,
## near-instant unless code changed) — and inherits their dirty-tree refusal check.
## Requires: the `coder` CLI on PATH and an authenticated session
## (`coder login`/`coder whoami`), and the Coder server itself already up (`make up`)
## and healthy (`make status`).
templates-push: embedded-workspace-build devcontainer-workspace-build
	@coder templates push docker-standard -d coder/templates/docker-workspace --yes
	@coder templates push embedded-linux -d coder/templates/embedded-linux --yes
	@coder templates push devcontainer -d coder/templates/devcontainer --yes
