## Local environment testing

This docker-compose.yaml provides you a minimal environment for testing a pair of factory-edc's against each other.

This also includes an issuer service, which acts as a trusted issuer in this regard. Both edc's are also accompanied by
their respective identity hubs, which will act as their identity wallets.

In order to get access to the docker images, we are going to use here, you may need to do a docker login first. Please
use a GitHub account, that is a member of the Factory-X GitHub organisation. If you don't already have one, you will
need to create a Personal Access Token (classic) on your GitHub account. This token should minimally have the 'read:packages'
privilege.

Then please open a shell and do a docker login with that token as described [here](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry#authenticating-with-a-personal-access-token-classic).

Now we are ready to start the environment. For that, please run

```
docker compose up
```

Then please use the attached Bruno collection. ([Bruno](https://www.usebruno.com/) is a convenient http client, which
you should install, if you haven't already.) In order to this, choose the "open" (not "import") option item in the Bruno 
UI and select the respective [folder](./bruno/fx-local-test). After that, please use the icon in the upper right corner 
of the Bruno GUI to select the environment (which stores the variables, that the requests will need).

In that collection you should first run the requests of the ´identities´ folder.
After you have completed all required steps, the provider and the consumer identity are onboarded in your own dataspace
and ready to interact with each other.

Now you are ready to perform a simple contract negotiation and data transfer between these two actors.

Be sure to also read the documentation that is attached to the folders in the Bruno collection. You may also want to
check the pre- and postrequest scripts of many requests, because they may give you further insights.

In a nutshell, we are presenting the following workflows here:

### Create an issuer-participant

The issuer-participant will act as the dataspaces' trusted issuer. This issuer is mandated to sign and hand
out verifiable credentials, which the members of the dataspace can use to prove their membership (or potentially other
relevant properties of themselves) to other partners in the same dataspace. After the registration of the issuer we are
also providing the basic definition of the credential that shall be issued. And we also need register the expected (
user-) members of the dataspace at the issuer service.

### Create a consumer and a provider identity

Somewhat similar to the creation of the issuer, we will now create a consumer and a provider identity on their
respective wallets (i.e. identity hubs). After the creation, we receive an api token and a sts secret from the identity
hub. The sts secret is essential for operating the edc. So we need to store that in the hashicorp vault under a given
secret alias, so that the edc can use it later. Also, we can take a look at the DID document, that was generated on the
identity hubs. And we need to tell our identity hub, that we want to request a membership token from the trusted issuer.

When this is done, we can have a look at the credentials, that the issuer hopefully delivered to consumer and provider
respectively. And we can also do some kind of a simulated DCP flow with the just created credentials. Please see the
documentation in the Bruno collection if you are interested in learning some more details (though that is directed at
the more advanced members of the audience here, beginners can definitely skip that part).

### Do a transaction between provider and consumer

Finally, we are ready now to do a more or less 'normal' DSP/DCP protocol backed transaction between the consumer and the
provider. I.e. firstly we need the provider to prepare a data asset, which the consumer can negotiate with him for. Then
the consumer
can discover this asset via a catalog request towards the provider edc, initiate a negotiation and a transfer. If you
are interested
in a more detailed explanation of these interactions, please see
the [EDC Samples](https://github.com/eclipse-edc/Samples/tree/main/transfer).

When you're done testing and want to end your session (using 'CTRL-C' on the terminal, where you started docker
compose),
you may want to run

```
docker compose down -v
```

This will delete the data from your previous session and ensure, that the next time, you are starting this, you will
have no data remnants in your containers, which may cause confusion or conflicts, when you start the docker-compose.yaml 
and the requests of the Bruno collection later again. 

## Troubleshooting

### Transfer / GET EDR fails: `private key 'prov_priv' not found in Config`

The `vault-init` container seeds four dataplane token-signing keys
(`cons_priv`, `cons_pub`, `prov_priv`, `prov_pub`) into Vault. If a transfer
fails with `JWSSigner cannot be generated for private key 'prov_priv'` (and the
GET EDR then returns 404), those keys are missing from Vault.

Two distinct causes:

1. **`vault-init` failed silently.** On hosts whose `/etc/resolv.conf`
   advertises a search domain (e.g. systemd-resolved adds `search localdomain`
   on VMware/DHCP networks), Alpine/musl's resolver inside `vault-init` appends
   it — resolving `shared-vault.localdomain` (NXDOMAIN) and failing with
   `curl: (6) Could not resolve host: shared-vault`, while glibc-based
   containers (EDC runtimes, Postgres) retry the bare name and are unaffected.
   `vault-init.sh` now forces an absolute DNS name (trailing dot), runs with
   `set -eu`, and waits for Vault to answer — so this fails loudly instead of
   leaving Vault half-seeded.
2. **Vault was restarted.** `shared-vault` runs in `-dev` (in-memory) mode, so
   every restart wipes all secrets. The one-shot `vault-init` does **not**
   re-run automatically.

Re-seed the keys without restarting the dataplane (it reads the key from Vault
per request):

```
docker compose -f docker-compose.yaml up --force-recreate --no-deps vault-init
# or, for the monitoring superset:
docker compose -f docker-compose.monitoring.yaml up --force-recreate --no-deps vault-init
```

## Monitoring (optional)

An opt-in monitoring stack (node-exporter + OTel collector + Tempo + Prometheus
+ Grafana — host metrics plus per-API latency/throughput, JVM, and distributed
traces from the EDC runtimes) is
available as a standalone superset of `docker-compose.yaml`. Use
`docker-compose.monitoring.yaml` *instead of* `docker-compose.yaml` — it brings
up the full EDC stack plus the monitoring containers in a single invocation.
See [`monitoring/PLAN.md`](./monitoring/PLAN.md) for the staged roadmap and
[`monitoring/README.md`](./monitoring/README.md) for dashboards/usage.
Quickstart:

```
docker compose -f docker-compose.monitoring.yaml up -d
```

Don't run both compose files at the same time — they share container names,
host ports, and the `fx-test-network`, so they'll conflict.

