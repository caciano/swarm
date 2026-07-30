# EAP-DID Testbed

A Docker Compose deployment of everything Model D needs: three Identus Cloud
Agents, a ledger, and the two hostap processes that carry the EAP exchange.
The protocol itself is documented in [`../doc/`](../doc/README.md); this file
covers running it.

## The two moments

The distinction that organises everything here is
[`../doc/model-d-architecture.md`](../doc/model-d-architecture.md) §2:

**Provisioning happens once.** The user obtains a credential from their
institution. It uses the network, contacts the Issuer, and takes as long as it
takes. `./provision.sh` does all of it — brings the agents up, creates the DIDs,
defines the schema, issues the credential, and lifts the resulting keys out of
the wallet so the supplicant can work standalone.

**Authentication happens every time.** It uses only the EAP channel and the
credential already on the device. `./auth.sh` does that, against whatever
provisioning left behind.

```sh
./provision.sh          # enrolment, once
./isolation.sh          # assert the boundaries still hold
./auth.sh --method did  # an authentication
./clean.sh              # take it all down
```

Or, from the repository root, `make test`: build, provision, prove the
isolation, authenticate, clean. A failure leaves the deployment running,
because the logs are only readable while the containers exist.

## Scripts

| Script | What it does |
|---|---|
| `provision.sh` | Enrolment. Agents up, DIDs, schema, credential, keys, `env.test`. |
| `auth.sh` | One authentication, or `--benchmark N` repeats and reports timings. |
| `isolation.sh` | Asserts the boundaries: the device reaches the authenticator and nothing else. |
| `logs.sh` | Reads the log of any component. |
| `clean.sh` | Containers, networks, volumes, generated files. |
| `smoke-test.sh` | Validates the environment and all three EAP methods. |
| `benchmark.sh` | Compares ledger backends. |
| `scripts/eapol-guard.sh` | Makes the EAP segment a wire: EAPoL forwarding, and an ACL that carries nothing else. `apply`, `check`, `counters`, `clear`. |
| `scripts/extract-did5-keys.sh` | Lifts the Holder's keys out of the agent database. |
| `scripts/verifier-key-service.py` | Hands the authenticator the Verifier's key. Both are the visited institution; see `../doc/model-d-architecture.md` §9. |

`provision.sh` is idempotent: run it again and it confirms what is already
provisioned rather than doing it twice. `--force` provisions from scratch;
`--no-agents` leaves compose alone.

It leaves two things behind, and both are read by the compose file:

- `env.test` — the DIDs, the schema and the credential id
- `did-keys/` — the credential and the private keys, mounted into the supplicant

## Reading the logs

Six processes matter and none is reachable the same way: two hostapd instances
share one container, the agents have generated container names. `logs.sh` puts
them behind one interface.

```sh
./logs.sh                            # what is running
./logs.sh authenticator              # the process that decides
./logs.sh eap -f                     # follow supplicant + both hostapd
./logs.sh verifier -g Presentation   # only presentation lines
./logs.sh all -o /tmp/run            # one file per component, plus env.test
```

| Target | Process |
|---|---|
| `supplicant` | `wpa_supplicant`, the EAP-DID peer |
| `authenticator` | `hostapd` as 802.1X authenticator |
| `radius` | `hostapd` as RADIUS/EAP server |
| `verifier`, `issuer`, `holder` | the Cloud Agents |
| `keys` | `verifier-keys`, the key service |
| `node` | PRISM Node, the ledger |
| `eap`, `agents`, `all` | groups of the above |

The two hostapd instances are read from their log files inside the container
rather than from `docker logs`, which returns them interleaved and, because that
stdout is block buffered, usually truncated before the end of a run.

`auth.sh` writes a full bundle to `benchmark-results/failure-<method>-<ts>/`
whenever an authentication fails, since the containers are recreated for the
next round.

## Compose profiles

| Profile | Services |
|---|---|
| `identus` | The three Cloud Agents, their databases, Caddy, PRISM Node, `verifier-keys` |
| `eap` | `init-bridge`, `authradius`, `supplicant` |

The EAP layer is started per authentication by `auth.sh`, which selects the
supplicant configuration for the method under test.

## Networks

The networks are the administrative domains, not the roles. The Issuer belongs
to the home institution, the Verifier and the authenticator to the visited one,
and the two share nothing but the ledger and the Issuer's public documents.

| Network | Members | What it stands for |
|---|---|---|
| `eapol-net` | `supplicant`, `authradius` | 802.1X. While a device authenticates, its only path off itself — and not a network: see below |
| `device-net` | `supplicant`, `agent-holder`, `caddy-holder`, `db-holder` | the user's device and the wallet holding its credential |
| `auth-net` | `authradius`, `agent-verifier`, `caddy-verifier`, `db-verifier`, `verifier-keys` | the visited institution, assumed trusted between its own processes |
| `issuer-net` | `agent-issuer`, `caddy-issuer`, `db-issuer` | the home institution |
| `internet` | `caddy-issuer`, `agent-issuer`, `agent-verifier`, `node` | what anyone may read: schema, status list, ledger |
| `ledger-net` | `node`, `node-db` | the ledger's storage, and the Cardano stack when that override is used |

`device-net` touches nothing else. The supplicant needs nothing else: the
EAP-DID peer method makes no network call, takes the Verifier's `did:peer`
inline from the invitation, and reads the credential from a file.

The Issuer is on `internet` permanently, because the ledger is not an
enrolment-only need and because the schema and status list URLs inside the
credential are fetched by the Verifier at every authentication.

Two networks are not declared here, and both exist only for the length of the
operation that needs them:

- **`provision-net`** attaches the device to the home institution while it
  enrols: the DIDComm exchange in both directions, plus the ledger the wallet
  needs to resolve the Issuer's DID. `provision.sh` removes it before
  returning, since Model D has the device isolated from the home institution
  once the deployment is running.
- **`vp-relay`** is used by some authentication paths for the same reason.

`clean.sh` removes either if a script was interrupted before it could.

## The EAP segment

`eapol-net` is the one network here that is not a network. It stands for the
uncontrolled port of an 802.1X authenticator: no address on either end, no
router, and nothing on it but EAPoL. A segment that quietly carried IP would
make every isolation claim in this deployment rest on the device choosing not
to use a stack sitting right there.

Docker's bridge driver refuses to create a network without an IPAM pool, so the
subnet stays declared and three separate things take its meaning away:

| | What it does |
|---|---|
| `com.docker.network.bridge.inhibit_ipv4` | Keeps the address off `swarm-br0` itself: the host is not on the segment, and there is no gateway on it |
| The entrypoints | Flush the address Docker assigns, and refuse to start hostapd or wpa_supplicant if one survives |
| `scripts/eapol-guard.sh` | Installs an nftables bridge-family ACL on `swarm-br0`: ethertype `0x888e` accepted, everything else dropped and counted |

Only the third is enforcement. The first two describe a segment nobody has
configured an address on; the ACL is what answers a device that configures one
anyway, which is the case that matters. `internal: true` closes the remaining
route off the segment, and `group_fwd_mask=0x8` is what makes the bridge
forward the PAE group address `01:80:C2:00:00:03` at all — it is in the
reserved range a bridge drops by default.

The `init-bridge` service applies all of it before the other two start, from
the host's network namespace, and verifies its own work; `auth.sh` and
`isolation.sh` both refuse to continue without the line it prints when that
succeeds. `clean.sh` removes the ACL, which `docker compose down` would not,
since it belongs to the host's nftables rather than to any container.

```sh
sudo nft list table bridge swarm_eapol            # the ACL, with its counters
./scripts/eapol-guard.sh check                    # as root on the host
./scripts/eapol-guard.sh counters                 # eapol=<n> blocked=<n>
```

`isolation.sh` section 2 asserts every claim above, and asserts it against a
device that does not cooperate: it puts the addresses back on both ports and
pings across, which must fail and must show up on the ACL's drop counter, then
sends a raw EAPoL frame, which must be answered. The positive half matters as
much as the negative — a segment that blocked everything would pass a
one-sided test and break the authentication.

**What is missing is everything after EAP-Success.** A real authenticator moves
the port from unauthorized to authorized and the device then configures an
address, by DHCP, on the network it has just been granted. Here the ACL is
static: the segment carries EAPoL before, during and after authentication, and
there is no DHCP server on it. The deployment demonstrates the authentication
and says nothing about what follows it; see the roadmap in the repository
`README.md`.

## Cardano

The default deployment runs an in-memory ledger. `docker-compose.cardano.yml`
is an opt-in override that replaces it with a Cardano preprod node — around
14 GB of RAM, 35 GB of disk, and 15–30 minutes of Mithril sync.

```sh
./cardano/scripts/mithril-bootstrap.sh
docker compose -f docker-compose.yml -f docker-compose.cardano.yml --profile identus up -d
./cardano/scripts/wait-for-sync.sh 3600
./benchmark.sh --ledger cardano --rounds 30
```
