#!/usr/bin/env bash
# Fail loudly: previously a silent curl failure left Vault half-seeded and the
# container still exited 0, which surfaced much later as a dataplane
# "private key 'prov_priv' not found" error during transfer.
set -eu

VAULT="${VAULT_ADDR:-http://shared-vault:8200}"
TOKEN="${VAULT_TOKEN:?missing VAULT_TOKEN}"

# Force the Vault hostname to an absolute DNS name (trailing dot). On hosts
# whose resolv.conf advertises a search domain (e.g. systemd-resolved adds
# 'search localdomain'), Alpine/musl's resolver appends it -> queries
# 'shared-vault.localdomain' -> NXDOMAIN -> curl fails with "Could not resolve
# host", while glibc containers retry the bare name. The trailing dot stops the
# search-domain append so resolution works regardless of host config.
VAULT=$(echo "$VAULT" | sed -E 's#(://[^/:]+)#\1.#')

# Wait until Vault actually answers before seeding. depends_on healthcheck
# covers the daemon, but this also guards against transient DNS/startup races.
echo "Waiting for Vault at $VAULT ..."
until curl -fsS -o /dev/null "$VAULT/v1/sys/health"; do
  sleep 1
done
echo "Vault reachable; seeding dataplane keypairs."

# function that creates and deploys a rsa keypair:

create_and_store_keypair() {
  local prefix=$1

  # create rsa keypair
  openssl genrsa -out /tmp/${prefix}_priv_pkcs1.pem 2048
  openssl pkcs8 -topk8 -nocrypt -in /tmp/${prefix}_priv_pkcs1.pem -out /tmp/${prefix}_priv.pem
  openssl rsa -in /tmp/${prefix}_priv_pkcs1.pem -pubout -out /tmp/${prefix}_pub.pem

  # deploy secrets to vault
  jq -n --rawfile content /tmp/${prefix}_priv.pem '{data:{content:$content}}' | \
    curl -fsS -H "X-Vault-Token: $TOKEN" -H "Content-Type: application/json" \
      -X POST --data-binary @- "$VAULT/v1/secret/data/${prefix}_priv"

  jq -n --rawfile content /tmp/${prefix}_pub.pem '{data:{content:$content}}' | \
    curl -fsS -H "X-Vault-Token: $TOKEN" -H "Content-Type: application/json" \
      -X POST --data-binary @- "$VAULT/v1/secret/data/${prefix}_pub"

  # cleanup temp files
  rm -f /tmp/${prefix}_priv_pkcs1.pem /tmp/${prefix}_priv.pem /tmp/${prefix}_pub.pem
}

# create keypair for consumer and provider dataplane:

create_and_store_keypair "cons"
create_and_store_keypair "prov"