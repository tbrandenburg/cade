> Gap-fill for docs/plan/steps/in-review/00100-governance-foundation.md

# Gap: OpenBao TLS private key generated world-readable (0644)

## Why this matters

`scripts/openbao-gen-cert.sh` generates the OpenBao listener's self-signed
TLS key pair and explicitly `chmod 644`s both the certificate **and** the
private key:

```bash
chmod 644 "${CERT_DIR}/openbao.crt"
chmod 644 "${CERT_DIR}/openbao.key"
```

Verified on disk: `governance/openbao/certs/openbao.key` is `-rw-r--r--`,
i.e. readable by every local user on the host, not just the owner. M12's
own stated hardening baseline is "configure TLS on the listener ... because
eavesdropping is explicitly in-scope of the threat model" — a
world-readable private key undermines that same threat model on any
multi-user host: any local account can read the key and passively decrypt
OpenBao's TLS traffic (or impersonate the listener), even though the
listener itself correctly refuses plaintext HTTP. A `0644` private key is
also flagged by essentially every TLS hardening checklist (Vault's own
production hardening guide included) as a baseline mistake to avoid.

The certificate (`openbao.crt`) being `0644` is fine — it's public material.
Only the key needs tightening.

## Fix

1. In `scripts/openbao-gen-cert.sh`, change the key's permission bits to
   `600` (owner read/write only), leaving the cert at `644`:
   ```bash
   chmod 644 "${CERT_DIR}/openbao.crt"
   chmod 600 "${CERT_DIR}/openbao.key"
   ```
2. Apply the tightened permission to the key file already generated on this
   host (`governance/openbao/certs/openbao.key`) via `chmod 600`, since the
   fix in (1) only affects future generations, not the file already on disk.
3. Re-run `docker compose up -d openbao` (or restart the container) and
   confirm the listener still serves TLS correctly afterward (`bao status
   -tls-skip-verify -address=https://127.0.0.1:8200` — mounted read-only
   into the container as `openbao`'s runtime UID, so a stricter host-side
   permission must still be readable by whatever UID the bind mount
   presents inside the container; verify with `docker exec openbao cat
   /openbao/certs/openbao.key | wc -l` or equivalent after tightening).
4. Note in `docs/security.md`'s M12 section that the key file permission
   was tightened, for audit-trail continuity.
