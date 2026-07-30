# EAP-DID Documentation

This directory documents EAP-DID: an EAP method that authenticates 802.1X
supplicants with Verifiable Credentials instead of passwords or X.509
certificates.

Start here. This document states the problem, defines the terminology the other
documents assume, and says which of them to read for what.

## 1. The Problem

Under eduroam, an access point at a visited institution cannot evaluate a
supplicant's credentials, so it forwards them. The exchange traverses a
hierarchy of RADIUS proxies to the institution that issued the credentials,
that institution decides, and the decision travels back.

This arrangement has four consequences:

- The home institution must be reachable for the supplicant to obtain access.
- The home institution learns the time and place of every association.
- Every proxy on the path observes the exchange.
- Trust is a set of bilateral agreements between operators.

EAP-DID moves the evidence to the supplicant. Rather than the network querying
the home institution, the supplicant presents a credential that institution
signed earlier. The verifying party checks the signature against a public
registry and decides locally. The issuing institution is neither contacted nor
informed. This is the operative meaning of Self-Sovereign Identity: the subject
holds its own credentials and presents them directly.

## 2. Terminology

Defined once here and assumed by every other document in this directory.

**DID (Decentralized Identifier)** [DID-CORE] — an identifier that resolves to
a document listing public keys and service endpoints, without recourse to a
central registry. The substring following the first colon names the *method*,
which determines how resolution is performed.

**VDR (Verifiable Data Registry)** — the registry a DID method resolves
against; here, a distributed ledger. Publishing an identifier makes it
resolvable by any party, and equally makes it enumerable and correlatable by
any party.

**VC (Verifiable Credential)** [VC-DATA-MODEL] — a statement about a subject,
signed by the issuer. In this deployment it is a JWT whose `sub` claim names
the subject.

**VP (Verifiable Presentation)** — a signed envelope produced by the holder at
presentation time. The credential asserts who the subject is; the presentation
demonstrates that the presenting party *is* that subject, because it is signed
with the subject's key and bound to a challenge the verifier has just issued.

**DIDComm v2** [DIDCOMM] — a messaging protocol between DIDs providing
confidentiality and sender authentication over an arbitrary transport,
including an unprotected link-layer channel.

**Roles.** The **Issuer** signs credentials. The **Holder** stores and presents
them. The **Verifier** validates presentations. A **Root Issuer** is an Issuer
whose credentials accredit other parties, forming a chain of trust.

**Selective disclosure (SD)** — presenting a subset of a credential's
attributes. **ZKP** — proving a statement about the attributes without
disclosing them.

**Evil Twin** — an access point impersonating a legitimate network in order to
obtain credentials or attributes from supplicants that associate with it.

### 2.1 DID Methods

The distinction between these three governs most of the design space:

| Method | Resolution | Published to the VDR | Lifetime |
|---|---|---|---|
| `did:prism` short form | VDR lookup required | yes | permanent |
| `did:prism` long form | self-contained; no VDR access | no | permanent |
| `did:peer`, `did:key`, `did:jwk` | self-contained; no VDR access | no | per-relationship or ephemeral |

A `did:prism` long form embeds the create operation that defines it and is
therefore verifiable from the identifier alone. Publication is not a
prerequisite for verification; it is a decision about visibility.

## 3. Document Map

| Document | Content | Read it when |
|---|---|---|
| `eap-did-models.md` | The eight trust models, the security properties each provides, and the technology profiles | Deciding what to build, or arguing about what a model guarantees |
| `model-d-architecture.md` | The implemented design: exchange, framing, cryptography, key derivation | Implementing, reviewing, or debugging |
| `model-d-sequence-short.puml` | Authentication exchange, overview (Figure 2) | Orientation |
| `model-d-sequence-complete.puml` | Authentication exchange with cryptographic detail (Figure 3) | Working on the cryptography |
| `model-d-sequence-provision.puml` | Enrolment and credential issuance (Figure 4) | Working on provisioning |
| `model-d-architecture.puml` | Entities and interfaces (Figure 1) | Orientation |
| `security-analisys.md` | Threat model and findings | Assessing exposure |
| `ban-logic.md` | Formal authentication goals | Reasoning about what is proved |
| `prerequisites.md` | Build and runtime dependencies | Setting up a build host |

Repository layout, build targets and how to run the testbed are in the
[top-level README](../README.md), not here.

### Suggested Order

1. This document, sections 1 and 2.
2. `eap-did-models.md`, sections 1 to 3 — what the three authentication
   properties are and why they are separated.
3. `model-d-architecture.md` — the implemented design.
4. The sequence diagrams, alongside section 6 of the architecture document.

## 4. Status

The implementation targets **Model D** of `eap-did-models.md`. It provides
confidentiality against third parties, holder proof of possession, replay
resistance, issuer authenticity and revocation.

It does **not** authenticate the Verifier to the supplicant, and therefore does
not resist an Evil Twin. This is a property of Model D, not a defect: closing
it requires a Root Issuer and a Trusted Verifier credential, which is Model G.

Two items diverge from Model D and are tracked in `eap-did-models.md`,
Section 7: the Root Issuer is not implemented, and the default test deployment
runs an in-memory ledger rather than a live one.

## 5. Diagrams

The `.puml` sources are authoritative; rendered images are not committed.

```sh
make -C doc            # render every .puml to .png
```

PlantUML and Graphviz are required; see `prerequisites.md`.

## 6. References

- [DID-CORE] W3C, "Decentralized Identifiers (DIDs)".
- [VC-DATA-MODEL] W3C, "Verifiable Credentials Data Model".
- [DIDCOMM] DIF, "DIDComm Messaging v2".
- [RFC3748] Aboba, B., et al., "Extensible Authentication Protocol (EAP)".
- [RFC5247] Aboba, B., et al., "Extensible Authentication Protocol (EAP) Key
  Management Framework".
