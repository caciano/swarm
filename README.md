# SWARM — Self-Sovereign Authentication Roaming

EAP-DID: an EAP method that authenticates IEEE 802.1X supplicants with
Verifiable Credentials rather than with passwords or X.509 certificates. The
supplicant presents a credential its institution signed earlier; the network
validates it against a distributed ledger and decides locally, without
contacting that institution.

Reference implementation and test deployment. **Not for production use.**

## Repository Layout

| Path | Contents |
|---|---|
| `doc/` | Protocol and trust-model documentation. Start at [`doc/README.md`](doc/README.md). |
| `testbed/` | Docker Compose deployment, provisioning and test drivers |
| `third_party/hostap/` | Submodule: hostapd and wpa_supplicant carrying the EAP-DID method |
| `make/` | Shared Makefile definitions |

## Quickstart

```sh
git clone https://github.com/caciano/swarm.git
cd swarm
make test
```

`make test` starts the Cloud Agents, provisions a credential, runs an EAP-DID
authentication and tears the deployment down. Dependencies are listed in
[`doc/prerequisites.md`](doc/prerequisites.md).

## Make Targets

```
make submodules   # init/update git submodules
make build        # compile hostap locally (development; the image builds independently)
make provision    # enrolment: agents up, DIDs, schema, credential, keys
make auth         # authenticate; METHOD=did|tls|md5 ROUNDS=N
make test         # provision, authenticate, clean up
make logs         # read logs; TARGETS="supplicant verifier" OUT=dir
make identus-up   # start the Cloud Agents alone (compose profile: identus)
make eap-up       # start the EAP layer (compose profile: eap)
make down         # stop the deployment, keep the provisioning
make clean        # remove containers, volumes, generated files and build stamps
make distclean    # clean, then deinitialise submodules
make help         # list targets
```

`provision` and `auth` are the two that matter, and they are separate because
the protocol separates them: enrolment happens once and contacts the Issuer,
authentication happens every time and does not. See
[`doc/model-d-architecture.md`](doc/model-d-architecture.md), Section 2.
`provision` is idempotent — run it again and it confirms rather than repeats.

A failing `make test` leaves the deployment up, because the logs are only
readable while the containers exist:

```sh
cd testbed
./logs.sh                                # what is running
./logs.sh authenticator                  # the process that decides
./logs.sh eap -f                         # follow the EAP layer
./logs.sh all -o /tmp/run                # one file per component
./auth.sh --method did --benchmark 5 # repeat and report timings
./auth.sh --method tls               # EAP-TLS, for comparison
```

## Components

| Component | Source | Built from source | Role |
|---|---|:---:|---|
| hostap | fork of [w1.fi](https://w1.fi/cgit/hostap/), branch `did5` | yes | EAP-DID method, server and peer |
| Identus Cloud Agent | `hyperledgeridentus/identus-cloud-agent` | no | Issuer, Holder and Verifier agents |
| PRISM Node | `ghcr.io/input-output-hk/prism-node` | no | Verifiable Data Registry |
| Caddy, PostgreSQL | stock images | no | Reverse proxy, agent storage |

Only hostap is compiled; the agents run as published images.

## Status

The implementation targets **Model D** of
[`doc/eap-did-models.md`](doc/eap-did-models.md): the Issuer identifier is
published to the ledger, the subject identifier is not, and the Verifier is not
authenticated to the supplicant. What that does and does not protect is stated
in [`doc/README.md`](doc/README.md), Section 4.

Two features not yet implemented, both tracked in `doc/eap-did-models.md`, Section 7:

- Root Issuer delegation is not implemented; trust in the Issuer is a locally
  configured allowlist.
- The default deployment runs an in-memory ledger. The Cardano profile is an
  opt-in override (`testbed/docker-compose.cardano.yml`).

The test deployment also includes `verifier-keys`, a service that discloses
private key material to the authenticator. It exists because the authenticator
and the Verifier are separate processes here and has no place in a real
deployment; see `doc/model-d-architecture.md`, Section 9.

Protocol documentation is under `doc/`.

## Roadmap

**The target is Model G** of [`doc/eap-did-models.md`](doc/eap-did-models.md):
what is implemented today, plus a Verifier the supplicant can authenticate as
an institution rather than merely as a key holder. That is the property that
turns the Evil Twin from an accepted exposure into a rejected one, and it is
the one line of Table 2 the current deployment has no path to. Section 8 of
that document states what it requires of a supplicant that has no network at
the moment it has to decide — the answer being a Trusted Verifier credential
that is verifiable offline, against a Root Issuer key pinned during enrolment.

What stands between here and there, and what else is outstanding:

- **Root Issuer delegation.** Trust in the Issuer is a locally configured
  allowlist rather than a delegation chain, so the "Issuer institutional
  authorisation" property of Table 2 is not met. It is also the prerequisite
  for everything else in this list: the Trusted Verifier credential is signed
  by the same Root Issuer.
- **Trusted Verifier credential.** The Verifier presents nothing about itself
  today. Model G makes the exchange mutual — the Verifier presents first, the
  supplicant validates, and only then is the credential released. See
  `doc/eap-did-models.md`, Section 8, requirements R1 to R6.
- **Provisioning the Holder's keys.** `provision.sh` lifts private keys out of
  the agent's database into files the supplicant reads. On a real device the
  wallet holds them and nothing is extracted; the supplicant would ask the
  wallet to sign. Doing this properly is wallet management — key storage,
  rotation, backup, and the Root Issuer anchor that R1 above requires the
  device to carry — and is deliberately out of scope for now.
- **`verifier-keys`.** A service that hands the authenticator the Verifier's
  private key, because the two are separate processes in the testbed. It goes
  when the authenticator verifies presentations itself; see
  `doc/model-d-architecture.md`, Section 9.
- **Opening the network after authentication.** The EAP segment carries EAPoL
  and nothing else, permanently and by construction: `eapol-net` has no address
  on either end and a bridge ACL drops every other ethertype
  (`testbed/scripts/eapol-guard.sh`). What a real 802.1X deployment does next —
  move the port from unauthorized to authorized on EAP-Success, and let the
  device configure an address by DHCP on the network it has just gained — has
  no counterpart here. There is no port transition and no DHCP server on the
  segment. The deployment therefore demonstrates the authentication and says
  nothing about what follows it. Implementing it means a per-port, dynamic ACL
  driven by the authenticator's decision, and it raises the question that
  decision alone cannot answer: on a shared medium an authorized *port* is not
  an authorized *peer*, and EAP-DID derives an MSK precisely so that the
  traffic after it can be keyed rather than merely permitted.
- **Ledger.** The in-memory ledger is the default; Cardano is an opt-in
  override. The deployment as shipped therefore does not satisfy the "Published
  to the VDR" column of Table 1.

## License

BSD 2-Clause. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
