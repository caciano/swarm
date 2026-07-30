# EAP-DID Model D: Implemented Design

This document describes the exchange as implemented: the messages, the framing,
the cryptography and the key derivation. It is the reference for implementing,
reviewing and debugging.

The problem being solved and the terminology used throughout are in
[README.md](README.md); this document assumes both. The trust model this design
targets, and what it deliberately does not provide, are in
[eap-did-models.md](eap-did-models.md).

---

## 1. The cast

| Party | What it is | Its DID | On the ledger? |
|---|---|---|---|
| **Issuer** | The institution that signs credentials | `did:prism`, published | **Yes** |
| **Holder** | The user's wallet, holding the credential | `did:prism` long form, plus a `did:peer` for messaging | **No** |
| **Supplicant** | `wpa_supplicant` with the EAP-DID peer method | uses the Holder's keys | — |
| **Authenticator** | `hostapd` with the EAP-DID server method | none of its own | — |
| **Verifier** | The Identus agent that checks presentations | `did:peer`, fresh per authentication | **No** |

Three DID methods appear, and the difference matters:

- **`did:prism`, published.** Anchored on the blockchain. Anyone can resolve it
  without asking its owner. Only the **Issuer** needs this: the whole point is
  that a verifier who has never met the issuer can still check its signature.

- **`did:prism`, long form.** The identifier *embeds* the document that
  defines it. It resolves offline, from the identifier alone, with no ledger
  lookup. The **Holder** uses this. Nothing about the user is published, so
  nothing about the user can be looked up, correlated, or counted by a third
  party — and the credential still verifies, because the subject's key comes
  out of the identifier itself.

- **`did:peer`.** A throwaway identifier for one conversation, carrying its
  keys inline. The **Verifier** mints a new one for every invitation, and the
  Holder has one for the messaging layer. Nothing is published; nothing
  persists; two authentications cannot be linked by it.

The design principle: **only the Issuer belongs on the ledger.** Everything
about the user is ephemeral or self-contained.

---

## 2. Two moments

The most common confusion about this system is collapsing two things that
happen at very different times.

**Provisioning happens once**, well before any Wi-Fi is involved. The user
obtains a credential from their institution. This uses the network, contacts
the Issuer, and can take as long as it takes. Think of it as enrolment.

**Authentication happens every time** you associate. It uses only the EAP
channel and the credential already on the device. The Issuer is not contacted
and does not know it happened.

Everything from Section 4 onward concerns the second.

### Where each party runs

The other thing worth stating outright, because every claim below rests on it:
the parties are in **different administrative domains**, and the design assumes
no more of them than that.

- The **Issuer** belongs to the home institution.
- The **Verifier and the authenticator** belong to the visited institution.
  They are two processes of one security domain, on a network assumed trusted
  between them — the assumption eduroam already makes between an access point
  and its authentication server.
- The **device** — supplicant and wallet — belongs to the user, and during
  authentication its only path off itself is the EAP channel. It reaches
  neither institution, and not the ledger.

The two institutions share **the ledger, and the Issuer's public documents**:
the credential schema and the revocation status list, fetched over a public
path by anyone who holds a credential naming them. Nothing else. No database,
no queue, no secret, no private channel, no prior contact of any kind. A
verifier that has never heard of an issuer can still check its signature, which
is the entire point.

What the visited institution *does* have is a **trust policy it configured for
itself**: which issuers it accepts and which credential it asks for. In the
testbed those are the `ISSUER_DID` and `SCHEMA_ID` given to the authenticator.
That is configuration — the direct analogue of eduroam federation config — and
not shared state.

In the testbed each of these is a network, and `isolation.sh` asserts the
boundaries rather than assuming them; `testbed/README.md` has the map.

---

## 3. Provisioning, once

```
1. Issuer creates a did:prism and publishes it on the ledger.
2. Holder creates a did:prism and does NOT publish it.
3. Issuer and Holder establish a DIDComm connection.
4. Issuer defines a credential schema (which attributes, what types).
5. Issuer offers a credential; Holder accepts, naming its DID as subject.
6. Issuer signs the JWT VC and sends it over DIDComm.
```

The connection in step 3 is between the **Holder and the Issuer**, and it
belongs to enrolment alone: it carries the credential and then it is gone. No
connection to a verifier is ever pre-established. The visited institution mints
a fresh invitation, and a fresh `did:peer`, for every authentication — a device
arriving at an institution it has never seen has nothing there to resume.

The supplicant ends up with:

- the **credential** (a JWT),
- the **subject's authentication key** (secp256k1), to sign presentations,
- a **`did:peer` and its X25519 key**, for the messaging layer.

In the testbed this is `provision.sh` plus `scripts/extract-did5-keys.sh`,
which lifts the keys out of the Identus wallet so the supplicant can work
standalone. On a real device the wallet would hold them and no extraction
would happen.

See `model-d-sequence-provision.puml` for the message-level diagram.

---

## 4. Authentication, every time

Here is the whole exchange. The numbers are referenced in the rest of the
document.

```
supplicant                    authenticator                     verifier
    |                               |                               |
    |<--------- (1) Start ----------|                               |
    |---------- (2) Ack ----------->|                               |
    |                               |--- (3) mint invitation ------>|
    |                               |<-- invitation + verifier DID --|
    |                               |                               |
    |                               |--- (4) fetch verifier key --->| (key service)
    |                               |<-- X25519 private key --------|
    |                               |                               |
    |<--- (5) invitation, fragmented|                               |
    |                               |                               |
    | (6) build VP, sign, encrypt   |                               |
    |                               |                               |
    |--- (7) presentation, gzipped, |                               |
    |         fragmented ---------->|                               |
    |                               | (8) unwrap CEK locally        |
    |                               |--- (9) relay presentation --->|
    |                               |<-- (10) verdict --------------|
    |<------- (11) EAP-Success -----|                               |
    |                               |                               |
    | MSK = HKDF(CEK, thid)         | MSK = HKDF(CEK, thid)         |
```

**(1–2) Start.** The authenticator opens with an EAP-DID Start packet carrying
the protocol version. The supplicant acknowledges, confirming it speaks the
same version. Nothing else happens yet — this is the handshake that lets both
sides fail fast on a mismatch.

**(3) The invitation.** The authenticator asks the verifier to mint an
out-of-band presentation request. That request names the schema it wants, the
issuers it trusts, and — importantly — a **challenge** and a **domain**. The
challenge is 24 random octets, drawn fresh for this authentication and never
reused. The verifier answers with the invitation and with the `did:peer` it
just created for this exchange.

**(4) The verifier's key.** The authenticator obtains the private key behind
that `did:peer`. Why it needs this is Section 7; that it is a temporary
arrangement is Section 9.

**(5) Downlink.** The invitation is about 2300 octets and an EAP frame holds
around 1300, so it is split. Each fragment must be acknowledged before the next
is sent.

**(6) The presentation.** The supplicant now does the real work, entirely
offline:

- builds a **VP JWT** containing the credential, addressed to the requested
  domain (`aud`), signing the requested challenge (`nonce`), with a unique
  `jti` and a five-minute validity window (`iat`, `exp`);
- signs it **ES256K** with the authentication key of the DID the credential
  names as its subject — that DID is read out of the credential, not out of
  configuration, so `iss` of the VP equals `sub` of the VC by construction;
- wraps it in a DIDComm presentation message;
- **encrypts** that message for the verifier's `did:peer` (Section 6);
- **gzips** the result, because 9.4 KB of JWE becomes about 7 KB and every
  kilobyte is five more round trips.

**(7) Uplink.** The compressed envelope goes back, fragmented the same way.

**(8) The key.** Before relaying anything, the authenticator opens the envelope
far enough to recover the content encryption key. Section 7.

**(9–10) The verdict.** The authenticator hands the envelope to the verifier
and polls until the verifier reaches a terminal state. The authenticator does
not judge the presentation — it relays it and acts on the answer.

**(11) Done.** `PresentationVerified` becomes EAP-Success, anything else
becomes EAP-Failure.

### There is no way back to the device

Read the diagram again and notice what is missing: no arrow from the verifier
to the supplicant. The presentation reaches the verifier because the
**authenticator relays it**, not because the device delivered it. The device
speaks DIDComm over no transport at all.

The Holder's `did:peer` does carry a service endpoint — the wallet minted it
and had to put something there — and the verifier may well try to use it, to
acknowledge a presentation or to report a problem with one. It will not arrive.
Nothing routes from the visited institution to a device that is only reachable
over 802.1X, which is the topology working as intended and not a fault to be
repaired. **Opening that path would put the device back in touch with the
visited institution outside the EAP channel and undo the property this design
exists to establish.**

The verdict travels over EAP, which is the only channel there is, and EAP
carries enough to decide network access: Success or Failure.

What is genuinely lost is **diagnosis**. The authenticator polls the verifier
and learns a status and no reason; the supplicant learns only that it failed. A
user is told "authentication failed" when the system knows perfectly well that
the credential expired last Tuesday. Carrying a small, closed set of reason
codes over EAP-DID — rather than relaying a DIDComm problem-report, which would
mean parsing attacker-chosen text in the peer before anything has been verified
— is tracked in hostap#71.

---

## 5. Carrying it over EAP

EAP frames are small and EAP is strictly lockstep: one request, one response,
no pipelining. Every EAP-DID payload begins with a flags octet:

```
 7   6   5   4   3   2   1   0
+---+---+---+---+---+---+---+---+
| L | M | S | K | - | V | V | V |
+---+---+---+---+---+---+---+---+

L  Length included — this is the first fragment; the next 4 octets
   are the total message length, so the receiver can allocate once
M  More fragments — another one follows
S  Start — the opening packet
K  Reserved (key confirmation)
V  Version (currently 1)
```

A fragmented message is `L|M`, then `M`, then a final fragment with neither.
The receiver answers each intermediate fragment with a bare flags octet, and
the sender will not advance until it arrives. That ordering is deliberate: a
reflected or replayed response cannot make the sender run ahead.

While the authenticator is waiting on the verifier it sends **keepalives** —
one-octet requests that keep the EAP state machine from timing out without
carrying data. The retransmission timeout is advertised as 5 seconds.

State machines:

```
authenticator:  START -> DOWNLINK -> UPLINK -> SUCCESS
                                           \-> FAILURE

supplicant:     START -> DOWNLINK -> UPLINK -> (WAIT_ACK -> UPLINK)* -> DONE
                                  \-> FAILURE
```

---

## 6. The envelope

The presentation travels over an unencrypted Wi-Fi link. Anyone within radio
range hears it. So it is encrypted — not by the transport, but by DIDComm
itself, which is why EAP-DID needs no TLS tunnel the way PEAP and TTLS do.

The scheme is **ECDH-1PU** with **A256KW** key wrapping and **A256CBC-HS512**
content encryption. Unpacked:

- **ECDH-1PU** is an authenticated key agreement. An ordinary ECDH between two
  ephemeral keys gives you secrecy but no idea who you are talking to. 1PU
  mixes in the *sender's long-term key* as well, so the recipient learns not
  only a shared secret but that it was produced by the holder of that key. Two
  Diffie-Hellman results, `Ze` (ephemeral↔recipient) and `Zs`
  (sender↔recipient), are concatenated in that order and run through ConcatKDF
  to give the key encryption key.

- **A256KW** wraps the content encryption key under that derived key. In key
  wrapping mode the content authentication tag is fed into the derivation, so
  the wrapping is bound to this exact ciphertext.

- **A256CBC-HS512** encrypts the message. Its key is 64 octets: the first 32
  are the HMAC key, the last 32 the AES key.

The protected header carries the ephemeral public key (`epk`), the sender's key
identifier (`skid`), and the agreement party fields — `apu` is the sender key
id, `apv` a hash over the recipient key ids. All of it is authenticated.

Two consequences worth naming:

- **The sender is authenticated to the recipient.** Only the holder of the
  supplicant's X25519 key could have produced this envelope.
- **The `skid` names the sender's key.** So a recipient can resolve the
  sender's public key from the message itself. Nothing about the supplicant has
  to be configured anywhere in advance.

---

## 7. Where the session keys come from

802.1X does not end at "yes". The EAP method must produce a **MSK** (Master
Session Key) which becomes the Wi-Fi session keys. Without one, the
authentication succeeded and the link is still unprotected.

EAP-TLS gets its MSK from the TLS handshake. EAP-DID has no handshake to take
one from — so where?

**From the envelope.** Encrypting the presentation already required generating
a fresh symmetric key, the **CEK** (Content Encryption Key). The supplicant
generated it. If the authenticator can recover the same value, both sides hold
a shared secret that never crossed the EAP channel:

```
MSK  = HKDF-SHA256(IKM = CEK, salt = thid, info = "EAP-DID-MSK",  64 octets)
EMSK = HKDF-SHA256(IKM = CEK, salt = thid, info = "EAP-DID-EMSK", 64 octets)
```

The `thid` — the DIDComm thread identifier, unique per authentication — is the
salt, so the same credential presented twice yields different session keys. The
EAP Session-Id is the method type octet followed by `SHA-256(thid)`.

So how does the authenticator get the CEK? The envelope is encrypted for the
verifier, and the verifier's `did:peer` is fresh for this exchange. The
authenticator obtains the private key behind it (step 4) and unwraps that
recipient entry. It reads the sender's static public key from the `skid`, does
the ECDH-1PU derivation, and unwraps the key.

The important part is that **this cannot silently go wrong**. AES key
unwrapping is authenticated: if the derived key encryption key were off by a
bit, the unwrap fails outright. A successful unwrap is proof that the
authenticator recovered *the same* CEK the supplicant generated, not merely
*a* value. The log lines to look for are:

```
EAP-DID JWE: authdecrypt done (cek=64B)
EAP-DID: Recovered the content encryption key
```

---

## 8. What the verifier checks

The authenticator relays; the verifier decides. It checks:

| Check | What it establishes |
|---|---|
| VP signature | The presentation was signed by the key it names |
| **Holder binding** | `iss` of the VP equals `sub` of the VC — the presenter *is* the subject, not someone who intercepted the credential |
| **Dates** | The presentation is inside its validity window |
| Challenge and domain | It answers *this* request, not a recorded one |
| VC signature | The credential was signed by its issuer |
| Trusted issuers | That issuer is one the request named |
| Schema | The credential has the shape that was asked for |
| Revocation | The credential is not listed as revoked |

Holder binding and date verification are **off by default** in the agent and
are switched on explicitly (`PRESENTATION_VERIFY_HOLDER_BINDING`,
`PRESENTATION_VERIFY_DATES`). Without holder binding, a credential intercepted
in transit could be presented by whoever holds it, which defeats the point of
proof of possession. Without date verification, the `exp` the supplicant sets
is decorative.

---

## 9. What this protects, and what it does not

Being clear about the second half is more useful than the first.

**Protected:**

- **Confidentiality against third parties.** Everything on the air is inside
  the DIDComm envelope. No TLS tunnel needed.
- **Proof of possession.** The presentation is signed by the credential
  subject's own key, and holder binding enforces that.
- **Replay.** A fresh challenge per authentication, a `jti`, and a validity
  window. A recorded presentation is worth nothing afterwards.
- **Issuer authenticity.** Checked against the ledger, with no contact with
  the issuer.
- **Revocation.** Checked against the issuer's status list.
- **Holder privacy.** Nothing about the user is on the ledger. The `did:peer`
  is per-conversation; the `did:prism` long form is never published.

**Not protected — by design, at this stage:**

- **The verifier is not authenticated to the supplicant.** Its `did:peer`
  arrives in-band, inside the invitation, with nothing vouching for it. The
  supplicant encrypts to whatever DID it is handed.
- **Therefore: no Evil Twin protection.** A rogue access point can substitute
  its own DID in the invitation and read the presentation. It cannot *use* the
  credential elsewhere — the challenge and `aud` bind the presentation to that
  exchange — but it does learn the attributes.
- **No institutional authority over the verifier.** Nothing says a verifier is
  entitled to ask. Closing this is what a Root Issuer and a Trusted Verifier
  credential are for; see `eap-did-models.md`, Model G.
- **No selective disclosure, no zero-knowledge proofs.** A JWT VC is shown
  whole.

This is deliberately **Model D** of `eap-did-models.md`, the "Basic SSI"
profile. Two divergences from that model remain open and are tracked there in
Section 7: the Root Issuer is not implemented, and the default test deployment
runs an in-memory ledger rather than a live one.

A word on `verifier-keys`, which looks worse than it is. The authenticator
obtains the verifier's key agreement key from a small service that reads it out
of the verifier's database, and read cold that is a key server handing out
private keys.

What it actually is: two processes of **one administrative domain** sharing a
key that belongs to that domain (Section 2). The authenticator and the verifier
are both the visited institution, on a network the model already assumes
trusted between them — the same assumption that lets RADIUS carry key material
between an access point and its authentication server. No key crosses a trust
boundary, and none crosses the EAP channel.

The key is fetched **per authentication** because Identus mints a new `did:peer`
for every invitation, so there is nothing long-lived to share even if one wanted
to. What is a testbed expedient is the *route*: reading the key out of the
database is standing in for an internal API a real deployment would expose.

The arrangement exists because the authenticator does not verify presentations
itself. When it does, the key never leaves it and the service disappears; that
is hostap#72, and it is a large piece of work, not a pending fix.

---

## 10. Compared with the alternatives

| | EAP-TLS | EAP-TTLS/PEAP | EAP-DID |
|---|---|---|---|
| Holder proves identity with | X.509 certificate | password | Verifiable Presentation |
| Trust anchor | CA hierarchy | CA hierarchy | Blockchain (issuer DID) |
| Server authenticated | Yes, X.509 | Yes, X.509 | **No** (Model D) |
| Channel protected by | TLS | outer TLS | DIDComm envelope |
| Session keys from | TLS handshake | TLS handshake | DIDComm CEK |
| Revocation | CRL / OCSP | CRL / OCSP | status list |
| Home institution contacted | no | **yes**, via RADIUS | no |
| Selective disclosure | no | no | not yet |

EAP-DID is not strictly better than EAP-TLS today — it is weaker on server
authentication and comparable elsewhere. What it buys is that the home
institution is never contacted and never learns where you connect, and that
trust is a signature on a ledger rather than a chain of operator agreements.

---
