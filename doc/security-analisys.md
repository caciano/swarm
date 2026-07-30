# Security Analysis

Scope: the EAP-DID exchange as implemented, under Trust Model D. Terminology is
defined in [README.md](README.md); the exchange itself is described in
[model-d-architecture.md](model-d-architecture.md).

> **Status.** The per-finding analysis originally carried out against the
> hostap repository has not been fully migrated. The threat model and the
> posture table below reflect the current design and are accurate; the
> historical finding identifiers are reconciled in Section 5.

## 1. Assets

| Asset | Exposure if compromised |
|---|---|
| MSK, EMSK | Session keys for the 802.11 link; disclosure breaks link confidentiality |
| Verifiable Credential | The subject's attested attributes |
| CEK | The presentation plaintext, and by derivation the session keys |
| Subject signing key (secp256k1) | Impersonation of the subject in future exchanges |

## 2. Trust Anchors

| Anchor | Established by | Assumption |
|---|---|---|
| Issuer identifier | Verifiable Data Registry | The ledger provides integrity and availability for the Issuer DID document |
| Accepted issuer set | Local configuration on the EAP server | Under Model D this is an allowlist; a Root Issuer would replace it with a delegation chain |
| Credential status | Status list published by the Issuer | Reachable at validation time |

Note that the subject identifier is **not** anchored in the registry. It is a
`did:prism` long form and is verified from the identifier itself.

## 3. Attacker Model

| Capability | In scope |
|---|:---:|
| Passive observation of the link | yes |
| Message injection, modification, replay | yes |
| Rogue access point (Evil Twin) | yes |
| Compromise of the Verifier | yes |
| Compromise of the subject's key store | out of scope |
| Compromise of the Issuer | out of scope |
| Compromise of the ledger | out of scope |

## 4. Posture

| Property | Status | Mechanism |
|---|---|---|
| Link confidentiality | Provided | DIDComm JWE, ECDH-1PU with A256CBC-HS512. No TLS tunnel is used |
| Sender authentication | Provided | ECDH-1PU incorporates the subject's static key; only its holder can produce the envelope |
| Holder proof of possession | Provided | Presentation signed ES256K by the credential subject; holder binding enforced at the Verifier |
| Replay resistance | Provided | Per-exchange challenge as `nonce`, `jti`, and a 300 second validity window, all checked |
| Key agreement | Provided | MSK derived by both parties from the JWE CEK, HKDF-SHA256 per [RFC5869] with the thread identifier as salt |
| Key confirmation | Provided on 802.11 only | The 4-Way Handshake confirms agreement on the MSK. The wired test deployment performs no EAPOL-Key exchange, so agreement is not confirmed there |
| Issuer authenticity | Provided | Signature verified against the DID document resolved from the registry |
| Revocation | Provided | Credential status list checked at validation |
| **Verifier authentication** | **Not provided** | The Verifier identifier is conveyed in band inside the invitation with nothing attesting it |
| **Evil Twin resistance** | **Not provided** | Follows from the above. See Section 4.1 |
| Selective disclosure | Not provided | The credential is disclosed in full on every presentation |

### 4.1 Rogue Authenticator

An adversarial Authenticator can substitute its own identifier for the
Verifier's in the invitation. The supplicant has no basis on which to reject
it, encrypts the presentation to the substituted identifier, and the adversary
reads the attributes.

The adversary cannot reuse the presentation against a genuine Verifier: the
`nonce` and `aud` claims bind it to that exchange and `exp` bounds its
lifetime. The exposure is disclosure of the attributes, not impersonation.

This is a property of Model D. Closing it requires an anchor by which the
supplicant can evaluate the Verifier identifier, which is Model G.

### 4.2 Key Service

The test deployment includes a service that returns the Verifier's private key
agreement key to the EAP server, so that the server can recover the CEK. It is
an artefact of the EAP server and the Verifier being separate processes.

Within the test deployment it is reachable only on the Verifier network.
Anywhere else it is a private key disclosure interface and must not be
deployed. It is removed when the EAP server validates presentations itself.

### 4.3 Correlation

Under Model D no subject identifier reaches the registry, and the `did:peer`
used by the messaging layer is per-exchange. Identifier-level correlation is
therefore limited.

Presentation-level correlation is not. The credential is a JWT disclosed in
full, so the same signed payload is released on every authentication and links
the exchanges regardless of the identifiers. This is the principal privacy
limitation of the profile and is recorded in
[eap-did-models.md](eap-did-models.md), Table 3.

## 5. Reconciliation of Earlier Findings

Findings F-01 through F-12 were raised against earlier designs. Several
concerned mechanisms that no longer exist. Recorded here so that references to
the identifiers remain resolvable.

| ID | Original finding | Disposition |
|---|---|---|
| F-01 | MSK derivation depends on the CEK | Still the design. Both parties derive from the CEK; see Section 4 |
| F-02 | Presentation replay | Addressed, but not by the original mechanism: the thread identifier is an HKDF salt and does not bind the presentation. Binding is by `nonce`, `aud`, `jti` and `exp` |
| F-03 | Server authentication | **Withdrawn as stated.** It was recorded as mitigated by Verifier DID validation in the peer. That check exists but is disabled by default, and validating an identifier received in band establishes nothing. Verifier authentication is not provided under Model D |
| F-05 | HKDF block chaining | Resolved. The expand step now feeds T(n-1) forward as [RFC5869] requires. The original citation of NIST SP 800-56A was incorrect: that document specifies the Concat KDF, which is used for the JWE key encryption key, not for the MSK |
| F-06 | CEK extraction reliability | Obsolete. The agent-side CEK store was removed; the supplicant generates the CEK and the EAP server recovers it by key unwrap |
| F-08 | HTTP listener bind address | Obsolete. The embedded HTTP listener was removed; libmicrohttpd is no longer a dependency |
| F-09 | Key confirmation | Open. Confirmation is implicit and occurs only on 802.11 media; the wired test deployment does not exercise it |
| F-11 | AEAD associated data | Superseded. Content encryption is A256CBC-HS512, not AES-GCM. The associated data is the encoded protected header, and the resulting tag is an input to the key encryption key derivation |
| F-12 | JSON truncation in framing | Obsolete. The length-prefixed socket transport it referred to was removed |

## 6. Comparison with EAP-TLS

| Property | EAP-TLS | EAP-DID (Model D) |
|---|---|---|
| Trust anchor | Certification authority hierarchy | Ledger-resolved Issuer identifier |
| Credential | X.509 certificate | Verifiable Credential |
| Server authenticated | yes | **no** |
| Channel protection | TLS | DIDComm JWE |
| Session keys | TLS key schedule | DIDComm content encryption key |
| Revocation | CRL, OCSP | Credential status list |
| Home institution contacted | no | no |
| Selective disclosure | no | no |

EAP-DID under Model D is weaker than EAP-TLS on server authentication and
comparable elsewhere. What it provides instead is that no certification
authority hierarchy is required and that the issuing institution neither
participates in nor learns of the authentication.

## 7. References

- [RFC5869] Krawczyk, H. and P. Eronen, "HMAC-based Extract-and-Expand Key
  Derivation Function (HKDF)".
- [RFC7518] Jones, M., "JSON Web Algorithms (JWA)".
- [RFC3394] Schaad, J. and R. Housley, "Advanced Encryption Standard (AES) Key
  Wrap Algorithm".
- [ECDH-1PU] Madden, N., "Public Key Authenticated Encryption for JOSE:
  ECDH-1PU", draft-madden-jose-ecdh-1pu-04.
