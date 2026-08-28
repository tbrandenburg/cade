SHELL := /bin/bash

COMPOSE := docker compose

# Optional corporate/TLS-intercepting-proxy CA bundle (Milestone M3). Leave
# unset on unrestricted networks; the coder-workspace build step is then a
# no-op. Example: make coder-workspace-build CACERT=/path/to/ca-bundle.pem
CACERT ?=

.PHONY: doctor up down status logs coder-workspace-build embedded-workspace-build runner-build runner-run temporal-worker-build temporal-demo-start governance-bootstrap governance-verify

## doctor: Verify the host meets the baseline requirements (Milestone M0).
doctor:
	@bash scripts/doctor.sh

## up: Start the platform stack in the background (Milestone M1).
up:
	@$(COMPOSE) up -d

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
			-t devenv-cloud/coder-workspace:latest --load coder; \
	else \
		docker buildx build -f coder/Dockerfile \
			-t devenv-cloud/coder-workspace:latest --load coder; \
	fi

## embedded-workspace-build: Build the embedded-linux workspace image (Milestone M6).
embedded-workspace-build: coder-workspace-build
	@if [ -n "$(CACERT)" ]; then \
		docker buildx build -f coder/embedded-linux/Dockerfile --secret id=cacert,src=$(CACERT) \
			-t devenv-cloud/embedded-linux-workspace:latest --load coder/embedded-linux; \
	else \
		docker buildx build -f coder/embedded-linux/Dockerfile \
			-t devenv-cloud/embedded-linux-workspace:latest --load coder/embedded-linux; \
	fi

## runner-build: Build the self-hosted GitHub Actions runner image (Milestone M2).
runner-build:
	@if [ -n "$(CACERT)" ]; then \
		docker buildx build -f runner/Dockerfile --secret id=cacert,src=$(CACERT) \
			-t devenv-cloud/runner:latest --load runner; \
	else \
		docker buildx build -f runner/Dockerfile \
			-t devenv-cloud/runner:latest --load runner; \
	fi

## runner-run: Request a JIT config and run one ephemeral self-hosted runner (Milestone M2).
runner-run:
	@bash scripts/runner-jit-start.sh

## temporal-worker-build: Build the M8 demo durable-workflow worker image.
temporal-worker-build:
	@docker buildx build -f temporal/Dockerfile -t devenv-cloud/temporal-worker:latest --load temporal

## temporal-demo-start: Start one execution of the M8 demo durable workflow.
temporal-demo-start:
	@docker run --rm --network platform-control \
		-e TEMPORAL_ADDRESS=temporal:7233 \
		-e DEMO_TASK_QUEUE=demo-durable-workflow \
		--entrypoint python \
		devenv-cloud/temporal-worker:latest -m demo.starter

## governance-bootstrap: Init/unseal OpenBao, rotate Phase 1-3 credentials, revoke root token (Milestone M12).
governance-bootstrap:
	@bash scripts/openbao-init.sh

## governance-verify: Run opa test plus a live OPA/MCP ALLOW-run_test / DENY-flash_device round trip (Milestone M12).
governance-verify:
	@bash scripts/verify-governance.sh

