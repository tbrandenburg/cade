# Coder AI configuration

Declarative configuration for the AI providers and models reconciled into
Coder by `make ai-bootstrap` (see `scripts/ai-bootstrap.sh`).

## Files

- `providers.yaml` — the list of upstream AI providers (OpenAI, local
  OpenAI-compatible endpoints, etc.) available to Coder.
- `models.yaml` — the list of models offered to users, each tied to a
  provider defined in `providers.yaml`.

## Adding a provider

1. Add an entry to `providers.yaml` with a unique, lowercase, hyphenated
   `name`, its `type`, `base_url`, and `api_key_env`.
2. Run `make ai-bootstrap` to reconcile the change into Coder.

## Adding a model

1. Add an entry to `models.yaml` with a `provider` matching a `name` in
   `providers.yaml`, the exact upstream `model` string, and a
   `display_name`.
2. Run `make ai-bootstrap` to reconcile the change into Coder.

## Secret indirection rule

`api_key_env` is **never** a literal secret — it is only the name of an
environment variable that holds the key (e.g. `OPENAI_API_KEY`).
`scripts/ai-bootstrap.sh` resolves the actual secret value at bootstrap
time via its `resolve_secret` function. This indirection is what allows
the secret source to move from `.env` to OpenBao later without any
change to these YAML files. Never commit a literal API key into this
directory.

## Default model

Exactly one entry in `models.yaml` must set `default: true`. This is the
model selected for users who have not explicitly chosen one. Setting more
than one (or zero) default models is a configuration error.
