# EAP-DID Trust Models

## 1. Scope

This document defines the trust models under which EAP-DID may be deployed and
records which security properties each model provides. It is a design-space
document: it describes what is achievable under each arrangement of
identifiers, not what the current implementation does.

The current implementation targets **Model D**. Root Issuer support is deferred
until Holder-to-Verifier authentication is complete; see Section 7.

The key words MUST, MUST NOT, SHOULD and MAY are to be interpreted as described
in [RFC2119].

## 2. Terminology

Terminology is defined in [README.md](README.md), Section 2, and is assumed
here: DID, VDR, VC, VP, DIDComm v2, the Issuer/Holder/Verifier roles, Root
Issuer, selective disclosure, zero-knowledge proof and Evil Twin. The
comparison of DID methods in Section 2.1 of that document underlies the
"Holder" and "Verifier" columns of Table 1 and should be read first.

## 3. The Three Properties This Document Separates

Earlier revisions of this document conflated three distinct properties under a
single heading. They are separated here because each is obtained by a different
mechanism and each fails independently.

1. **Verifier cryptographic authentication.** The assurance that the party
   reading the presentation holds the private key of the identifier the
   presentation was encrypted to. DIDComm v2 provides this from the identifier
   alone, including where that identifier is an ephemeral `did:peer` or
   `did:key`. It requires no VDR and no trust framework.

2. **Verifier institutional authentication.** The assurance that the party is
   entitled to request the credential — that it is, for example, an accredited
   member of an academic federation. This cannot be derived from key
   possession. It requires a chain of trust: a Trusted Verifier credential
   issued by a Root Issuer, or an equivalent externally configured trust
   anchor.

3. **Channel confidentiality.** Protection of the presentation against parties
   other than the intended recipient. DIDComm v2 provides this whenever a
   session can be established, irrespective of whether the recipient is
   trustworthy.

The consequence stated explicitly: **models C through F do not resist an Evil
Twin, yet still protect the exchange against third-party interception.** The
Evil Twin exposure follows from the absence of a trust anchor for property 2,
not from any weakness in the cryptographic channel. Confidentiality depends on
neither `did:prism` nor the VDR.

## 4. Table 1 — Trust Models

**How to read this table.** Each row is an arrangement of identifiers across
the three roles. The two "identifiers" columns are the privacy-relevant ones:
what is published to the VDR is what a third party can enumerate, and what is
resolved during authentication is what the exchange discloses to the VDR
operator.

| Model | Root Issuer | Issuer | Holder | Verifier | Published to the VDR | Resolved from the VDR during authentication | Verifier cryptographic auth. | Verifier institutional auth. | Channel confidentiality | Assumption |
|---|---|---|---|---|---|---|:---:|:---:|:---:|---|
| **A** | No | `did:prism` | `did:prism` | `did:prism` | Issuer, Holder, Verifier | Holder + Issuer + Verifier | ✓ | Out of band (3) | ✓ | All parties hold permanent published identifiers. |
| **B** | No | `did:prism` | `did:peer`/`key`/`jwk` | `did:prism` | Issuer, Verifier | Issuer + Verifier | ✓ | Out of band (3) | ✓ | The Holder uses a private or ephemeral identifier. |
| **C** | No | `did:prism` | `did:peer`/`key`/`jwk` | `did:peer`/`key` | Issuer only | Issuer only | ✓ | ✗ | ✓ | The Verifier identifier is ephemeral and serves DIDComm alone. |
| **D** | Yes | `did:prism` | `did:peer`/`key`/`jwk` | `did:peer`/`key` | Root Issuer, Issuers | Issuer + Root Issuer (1) | ✓ | ✗ | ✓ | The Root Issuer delegates authority to Issuers. |
| **E** | Yes | `did:prism` | `did:prism` | `did:peer`/`key` | Root Issuer, Issuers, Holder | Holder + Issuer + Root Issuer (1) | ✓ | ✗ | ✓ | As D, but the Holder identifier is published. |
| **F** | Yes | `did:prism` | none | `did:peer`/`key` | Root Issuer, Issuers | Issuer + Root Issuer (1) | ✓ | ✗ | ✓ | The credential is not cryptographically bound to the Holder. |
| **G** | Yes | `did:prism` | `did:peer`/`key`/`jwk` | `did:prism` + Trusted Verifier VC | Root Issuer, Issuers, Verifiers | Issuer + Root Issuer + Verifier (6) | ✓ | ✓ | ✓ | The Holder validates the Trusted Verifier credential before releasing the presentation. |

(1) The Root Issuer identifier MAY be cached or configured as a trust anchor,
in which case it is not resolved from the VDR at authentication time.

(3) In models A and B the Verifier identifier is permanent and published, so a
Holder MAY pin it or maintain a local allowlist. This is externally configured
trust, not accreditation: no in-band mechanism attests that the identifier
belongs to an entitled institution. Compare Model G, where a Trusted Verifier
credential carries that attestation.

(6) These are the *Verifier's* resolutions, made from the visited institution's
network, where connectivity is not in question. The supplicant resolves nothing
at authentication time — it cannot, since the network it is authenticating to is
the one it does not have yet. Section 8 states what that costs and what it
requires of the Trusted Verifier credential.

Two columns are constant across every model. That is the finding of Section 3
rather than an omission: **cryptographic authentication of the Verifier and
channel confidentiality are provided by DIDComm in all arrangements**, and
therefore do not discriminate between them. They are retained so that the
absence of a corresponding institutional guarantee is visible by contrast.

## 5. Table 2 — Security Properties

**How to read this table.** Rows are properties; columns are the models of
Table 1. Qualitative values (High, Medium, Low) are comparative within a row
and carry no absolute meaning.

| Property | A | B | C | D | E | F | G |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| Credential integrity | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Issuer authenticity | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Issuer institutional authorisation | — | — | — | ✓ | ✓ | ✓ | ✓ |
| Issuer non-repudiation | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Holder proof of possession | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ✓ |
| **Verifier cryptographic authentication** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Verifier institutional authentication** | Out of band (3) | Out of band (3) | ✗ | ✗ | ✗ | ✗ | ✓ |
| **Rogue verifier (Evil Twin) resistance** (4) | ✓ | ✓ | ✗ | ✗ | ✗ | ✗ | ✓ |
| **Confidentiality against third parties** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Replay resistance | ✓ | ✓ | ✓ | ✓ | ✓ | Partial | ✓ |
| Revocation | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Holder privacy | Medium | High | High | High | Low | Very high | High |
| Identifier unlinkability (5) | Low | Medium | Medium | Medium | Low | High | Medium |
| Scalability | Low | Medium | High | Very high | Medium | Very high | High |
| VDR dependency | High | Medium | Low | Medium | High | Medium | High |
| Typical deployment | Full SSI | SSI with private Holder identifier | Web login | Basic EAP-DID | National identity | Anonymous credentials | Academic SSI federation |

(3) See the note to Table 1.

(4) Evil Twin resistance tracks Verifier institutional authentication exactly:
a rogue Verifier is one that presents an identifier the Holder has no basis to
reject. **No model in this table protects the Holder against over-disclosure by
a Verifier that is legitimately accredited.** That requires selective
disclosure or zero-knowledge proofs, which appear only in the profiles of
Table 3.

(5) *Identifier* unlinkability: whether the identifiers used across two
exchanges permit those exchanges to be linked. It is distinct from
*presentation* unlinkability in Table 3, which concerns whether the credential
payload permits linking. A model MAY score well here and poorly there: an
ephemeral `did:peer` conceals the identifier while a fully disclosed JWT
credential carries constant attributes that link the exchanges regardless.

## 6. Table 3 — Technology Profiles

**How to read this table.** Where Tables 1 and 2 vary the identifier topology,
this table varies the credential technology. The legacy rows are included as a
baseline; the SSI rows extend from Model D upwards. Profiles beyond "SSI
Federated" are variants of Model G differing in credential format.

| Profile | Technology | Published to the VDR | Holder authentication | Verifier cryptographic auth. | Verifier institutional auth. | Confidentiality | Trust chain | Root Issuer | SD | ZKP | Presentation unlinkability (5) | Revocation |
|---|---|:---:|:---:|:---:|:---:|:---:|---|:---:|:---:|:---:|:---:|:---:|
| Legacy | **EAP-MD5** | ✗ | password | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| Legacy | **EAP-TLS** | ✗ | X.509 certificate | ✓ | ✓ (PKI) | ✓ | PKI | CA | ✗ | ✗ | ✗ | CRL/OCSP |
| Legacy | **EAP-PEAP-MSCHAPv2** | ✗ | password | ✓ | ✓ (PKI) | ✓ | PKI | ✗ | ✗ | ✗ | ✗ | Partial |
| Legacy | **EAP-TTLS-MSCHAPv2** | ✗ | password | ✓ | ✓ (PKI) | ✓ | PKI | ✗ | ✗ | ✗ | ✗ | Partial |
| Basic SSI | **EAP-DID + JWT VC (Model D)** | Root Issuer + Issuers | VP | ✓ (DIDComm) | ✗ | ✓ (DIDComm) | DID + Root Issuer | ✓ | ✗ | ✗ | Low | ✓ |
| Federated SSI | **EAP-DID + JWT VC + Trusted Verifier (Model G)** | Root Issuer + Issuers + Verifiers | VP | ✓ (DIDComm) | ✓ | ✓ (DIDComm) | DID + Root Issuer | ✓ | ✗ | ✗ | Low | ✓ |
| Intermediate SSI | **EAP-DID + SD-JWT VC + Trusted Verifier** | Root Issuer + Issuers + Verifiers | holder binding | ✓ (DIDComm) | ✓ | ✓ (DIDComm) | DID + Root Issuer | ✓ | ✓ | ✗ | Medium | ✓ |
| Advanced SSI | **EAP-DID + JSON-LD VC + BBS+ + Trusted Verifier** | Root Issuer + Issuers + Verifiers | BBS proof | ✓ (DIDComm) | ✓ | ✓ (DIDComm) | DID + Root Issuer | ✓ | ✓ | ✓ | High | ✓ |
| Maximum privacy | **EAP-DID + AnonCreds + Trusted Verifier** | optional | link secret | ✓ (DIDComm) | ✓ | ✓ (DIDComm) | Issuer keys + Root Issuer | ✓ | ✓ | ✓ | Very high | ✓ |

(5) *Presentation* unlinkability, as distinguished in the note to Table 2. The
Basic and Federated SSI profiles both score Low because a JWT credential is
disclosed in full on every presentation: the same signed payload is released
each time, which links the exchanges irrespective of how ephemeral the
identifiers are. This is the single largest privacy limitation of the profile
the implementation currently targets.

## 7. Implementation Status

The implementation targets **Model D** and currently diverges from it in two
respects, both accepted:

- **Root Issuer.** Not implemented. Trust in the Issuer is a locally
  configured allowlist of Issuer identifiers rather than a delegation chain.
  Consequently the "Issuer institutional authorisation" property of Table 2 is
  not yet met. This is deferred until Holder-to-Verifier authentication is
  complete.
- **VDR.** The default test deployment runs an in-memory ledger. The ledger
  profile is an opt-in override, so the deployment as shipped does not satisfy
  the "Published to the VDR" column.

All other Model D properties are met. See `model-d-architecture.md` and the
sequence diagrams for the exchange as implemented.

The target is **Model G**, and the distance to it is the two items above plus a
Verifier the supplicant can authenticate as an institution. Section 8 states
what that requires of a supplicant that has no network at the moment it has to
decide; the repository's `README.md` tracks it, and the rest of what is
outstanding, as a roadmap.

## 8. Model G with an Offline Supplicant

Model G asks the Holder to validate the Verifier before releasing the
presentation. In EAP that request lands at the worst possible moment: the
supplicant has to decide whether to trust the visited institution while it is
still on an unauthenticated link, with no address, no route and no name
resolution. Whatever it verifies, it verifies from what it already has.

**This is achievable, and the mechanism is the one the model already names: a
Trusted Verifier credential signed by the Root Issuer.** What it costs is four
constraints on how that credential is minted and presented. None of them
requires the device to reach the VDR; one of them cannot be met at all offline
and is bought off with expiry instead.

### 8.1 What the supplicant has to establish, and what it costs

| Step | Needs the VDR at authentication time? | Why not, or what replaces it |
|---|:---:|---|
| The Trusted Verifier credential was signed by the Root Issuer | No | The Root Issuer's verification key is pinned at enrolment — footnote (1) to Table 1 already permits this |
| The credential names *this* Verifier, and the supplicant has its key | No, if the credential carries the key | The subject identifier must be self-certifying, or the key material must be in the credential itself |
| The party on the other end holds that key | No | It signs a challenge the supplicant generated for this exchange |
| The credential has not expired | No | A local clock |
| The credential has not been revoked | **Yes, and it cannot** | Nothing. Status lists are fetched over a network the device does not have. Short lifetimes bound the exposure instead |

### 8.2 Requirements

R1. The Root Issuer's verification keys MUST be provisioned to the device
during enrolment and pinned there. Enrolment is a moment with connectivity by
definition, and this is what the device spends it on besides the credential:
the ledger requirement does not disappear, it moves to deployment time.

R2. The Trusted Verifier credential MUST be verifiable without resolving
anything. Its subject MUST therefore be a self-certifying identifier — a
`did:key`, a `did:jwk`, or a long-form `did:prism`, whose create operation is
carried in the identifier itself — or the subject's public key MUST appear in
the credential. A bare short-form `did:prism` subject MUST NOT be used for this
purpose: resolving it is exactly the ledger access the supplicant does not
have. Note that this constrains the *Trusted Verifier* credential only; the
Verifier's published `did:prism` of Table 1 remains what everyone else
resolves it by.

R3. The Verifier MUST prove possession of the subject key over a nonce the
supplicant chose for this exchange. A credential presented without proof of
possession is a bearer token, and one captured from a legitimate exchange
would let any rogue authenticator wear the institution's name.

R4. The Verifier's presentation MUST precede the Holder's. This is what Model G
means by validating before releasing, and it makes the EAP-DID exchange
mutual: the invitation, or the message that follows it, has to carry the
Trusted Verifier credential and the signature over the supplicant's nonce
before the supplicant discloses anything of its own.

R5. Because the device cannot check a status list, the Trusted Verifier
credential SHOULD be short-lived, re-issued by the Root Issuer on a period no
longer than the exposure the federation is willing to accept from an expelled
member, and the device MUST have a clock accurate enough to enforce the
validity window. A long-lived Trusted Verifier credential and no revocation
check together mean an institution that has been expelled keeps authenticating
users until its credential expires.

R6. The proof of R3 SHOULD be bound to the EAP session — through the EAP
Session-Id, or a key derived from the MSK. A nonce defeats replay but not
relay: an Evil Twin that forwards the exchange to a genuine Verifier in real
time satisfies every check above. Channel binding is what makes the proof a
statement about *this* link rather than about some link.

### 8.3 What this amounts to

Offline validation of a Trusted Verifier credential is, mechanically, a
certificate chain: a pinned root key, an offline-verifiable assertion binding a
key to an institution, proof of possession of that key, and expiry standing in
for revocation. That is what EAP-TLS does with the server certificate, and
claiming otherwise would be dishonest — including about the weakness, since
supplicants generally do not fetch revocation for a server certificate either.
Model G reaches parity there, not past it.

What differs is above the mechanics. The root is an NREN issuing to
institutions under a federation policy rather than a commercial CA; the
assertion can carry roles and entitlements rather than only a name, so a Holder
can require attributes of the Verifier before disclosing its own; and the
machinery is the one already carrying the user's credential in the other
direction, rather than a second trust infrastructure maintained alongside it.

Two things are unchanged by any of this. The VDR keeps its role — the Issuer
stays published, and the Verifier still resolves it at authentication, from a
network it has. And no arrangement in this document protects the Holder against
over-disclosure by a Verifier that is legitimately accredited; see footnote (4)
to Table 2.

## 9. References

- [RFC2119] Bradner, S., "Key words for use in RFCs to Indicate Requirement
  Levels", BCP 14, RFC 2119.
- [DID-CORE] W3C, "Decentralized Identifiers (DIDs)".
- [VC-DATA-MODEL] W3C, "Verifiable Credentials Data Model".
- [DIDCOMM] DIF, "DIDComm Messaging v2".
- [SD-JWT-VC] IETF, "SD-JWT-based Verifiable Credentials".
- [BBS] IRTF CFRG, "The BBS Signature Scheme".
- [ANONCREDS] Hyperledger, "AnonCreds Specification".

Related documents in this directory: `model-d-architecture.md`,
`model-d-sequence-short.puml`, `model-d-sequence-complete.puml`,
`model-d-sequence-provision.puml`, `security-analisys.md`, `ban-logic.md`.
