SHELL := /bin/bash

COMPOSE := docker compose

# Optional corporate/TLS-intercepting-proxy CA bundle (Milestone M3). Leave
# unset on unrestricted networks; the coder-workspace build step is then a
# no-op. Example: make coder-workspace-build CACERT=/path/to/ca-bundle.pem
CACERT ?=

.PHONY: doctor up down status logs coder-workspace-build

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
	@if [ -n "$(CACERT)" ]; then \
		docker buildx build -f coder/Dockerfile --secret id=cacert,src=$(CACERT) \
			-t devenv-cloud/coder-workspace:latest --load coder; \
	else \
		docker buildx build -f coder/Dockerfile \
			-t devenv-cloud/coder-workspace:latest --load coder; \
	fi

