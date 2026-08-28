# M12 Governance Foundation — OpenBao server config. TLS is mandatory on
# the listener even for this local/demo deployment (self-signed cert
# acceptable per both OpenBao's own security model and Vault's hardening
# guide — eavesdropping is explicitly in-scope of the threat model, plain
# HTTP is not an acceptable default). File storage backend is sufficient
# for this single-node local stack (no HA requirement here).
ui = true

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/openbao/certs/openbao.crt"
  tls_key_file  = "/openbao/certs/openbao.key"
}

storage "file" {
  path = "/openbao/data"
}

disable_mlock = true
