# EAP-DID BAN Logic Analysis

Scope: the authentication goals of the EAP-DID exchange as implemented on
branch `did5`, under Trust Model D, and which of them the exchange
establishes.

Notation. `P |≡ X` P believes X; `P ◁ X` P sees X; `P |~ X`
P once said X; `P ⇒ X` P has jurisdiction over X; `#(X)` X is fresh;
`P ↔K Q` K is a good key for P and Q; `↦K P` K is P's public key; `{X}K`
encrypted; `{X}K⁻¹` signed.

## 1. Principals

| | Role |
|---|---|
| P | The supplicant, holding a credential |
| S | The authenticator and EAP server |
| V | The Verifier Cloud Agent |
| I | The Issuer |
| X | Whoever holds the sender static key the JWE names in `skid` |

X is a principal of the logic like any other. Nothing in the protocol identifies
it with P, and that is not a modelling convenience — it is the finding that
sections 4 and 5 turn on.

## 2. The idealised protocol

```
1.  S → P :  Vdid, Nv, Dom, T                                (the invitation)
2.  P → V :  { {Nv, Dom, T, {Attrs}Ki⁻¹}Kp⁻¹ }Kjwe          (the presentation)
3.  V → S :  { T, P |~ (Nv, Dom) }Khttp                           (the verdict)
4.  S → P :  EAP-Success
```

Message 1 is plaintext. In the logic a plaintext message supports no belief
about where it came from, so it contributes one seeing fact and no belief
whatever. That is not an artefact of the idealisation: the EAP channel has no
integrity protection, and under Model D the supplicant holds nothing against
which `Vdid` could be evaluated. Message 4 likewise carries nothing.

`Kjwe` is the ECDH-1PU channel between the sender static key and the Verifier
key agreement key. `Kp` is the credential subject's secp256k1 key, which is
obtained from the long form `did:prism` without touching the registry. `Khttp` is
the authenticator-to-Verifier channel.

## 3. Premises

| | Premise | Justification |
|---|---|---|
| A1 | S \|≡ #(Nv) | The authenticator draws the challenge itself, in `eap_did_new_challenge()` |
| A2 | V \|≡ #(Nv) | It reaches the Verifier in the invitation request |
| A3 | V \|≡ ↦Kp P | A long form `did:prism` carries its own create operation, so the key comes from the identifier |
| A4 | V \|≡ ↦Ki I | The Issuer DID document is resolved from the registry |
| A5 | V \|≡ (I ⇒ Attrs) | The Issuer is authoritative about its own subjects |
| A6 | V \|≡ #(Attrs) | Validity window and status list checked at validation |
| A7 | V \|≡ X ↔Kjwe V | Authcrypt binds the channel to the holder of the sender key |
| A8 | S \|≡ X ↔Kjwe S | The authenticator reads the Verifier key from the key service and unwraps the recipient entry itself |
| **A9** | S \|≡ S ↔Khttp V | **CONDITIONAL** — the verdict channel is authentic |
| **A10** | S \|≡ #(T) | **CONDITIONAL** — the thread identifier is fresh |
| A11 | S \|≡ (V ⇒ P \|~ (Nv, Dom)) | The authenticator defers to the Verifier on presentation verdicts |

A7 and A8 are the honest statement of what ECDH-1PU gives. The Verifier learns
the sender's static key from `skid`, which is self-asserted; nothing resolves it
against the credential. The channel is with the holder of that key, whoever that
is. And A8 rather than a second two-party premise, because the authenticator
holds the Verifier's private key: the content encryption key is not a two-party
secret.

The two conditional premises are the ones the code does not establish. They are
not in the same position as each other.

**A9.** `did_http_set_tls_opts()` disables peer and host verification unless
`DID_TLS_VERIFY` is set, and the default URL is plain `http://`. Finding D-03.
It is discharged by the deployment premise in `docs/security-analysis.md`
section 2: the authenticator, the Verifier and the key service share `auth-net`,
one administrative domain, and an intruder on that path is outside the attacker
model. So G1 is derivable, on a warrant that comes from where the Verifier is
deployed rather than from anything the method does — and it lapses the moment
the Verifier is reached over a path the visited institution does not own.

**A10.** The authenticator receives the thread identifier from the Verifier and
verifies nothing about it, and the verdict is matched to it by textual proximity
in a JSON list rather than by record structure. Finding D-07. Nothing discharges
this one; it is a defect, and it is scheduled.

Both appear in the proof tree of every positive goal. Peer authentication rests
on them.

## 4. Goals and results

| | Goal | Status |
|---|---|---|
| G1 | S \|≡ P \|~ (Nv, Dom) | derived, on A9 and A10 |
| G1b | S \|≡ P \|≡ (Nv, Dom) | derived, same premises |
| G2 | P \|≡ V \|~ (anything) | **not derivable** |
| G3 | S \|≡ S ↔Kjwe P | **not derivable** |
| G3b | S \|≡ S ↔Kmsk P | **not derivable** |
| G4 | S \|≡ P \|≡ (S ↔Kmsk P) | **not derivable** |
| G6 | V \|≡ Attrs(P) | derived |
| G7 | S \|≡ P \|~ (the presentation), without the Verifier | **not derivable** |
| G8 | V \|≡ P ↔Kjwe V | **not derivable** |
| G9 | S \|≡ P \|~ (the link it is on) | not derivable; derivable with channel bindings |

Both tools agree on every positive goal. `make ban` prints the derivations; the
one for G1 is nine steps and the one for G6 is thirteen.

## 5. What the results mean

**G2 is not derivable because there is nothing to derive it from.** Message 1
contributes no belief, and P holds no premise about V — no public key belief, no
jurisdiction. This is Model D exactly as documented, and the earlier revision of
this document was wrong to conclude Verifier authentication from the presentation
being encrypted to the Verifier's key. Encrypting to an identifier received in
band demonstrates nothing about the recipient.

**G3 and G8 are the relay.** The channel key is shared with X, and no premise
identifies X with P. Concretely: the authenticator recovers the content
encryption key from the recipient entry using `skid` to find the sender's static
key, and never asks whether that key has anything to do with the subject of the
credential the Verifier validated. So the party that holds the session keys and
the party the credential is about are two different principals, and the logic
will not conflate them.

SPIN reaches the same place from the other direction:
`formal/eap_did_relay.pml` exhibits an intruder with no credential that obtains
EAP-Success by forwarding a victim's presentation. See finding D-02.

**G4 is not derivable because no message is protected under the MSK.** There is
no key confirmation inside the method. On 802.11 the 4-Way Handshake supplies it
after the fact, which is why the relay does not yield network access there; on
the wired testbed there is no EAPOL-Key exchange and nothing supplies it.

**G1 is derived, and it is worth being precise about what through.** Not through
anything the authenticator checks about the presentation — G7 is not derivable,
and the authenticator never verifies a signature. It is derived through the
Verifier's verdict plus jurisdiction: A9 gives the authenticator a belief about
what V said, A10 promotes it to what V believes, A11 transfers it. Remove either
conditional premise and G1 goes with it. The authenticator's belief in the
supplicant is exactly as strong as its channel to the Verifier, which is
currently a plaintext HTTP request with certificate verification switched off.

**G6 is derived, but through a premise that stands in for something the logic
cannot express.** The credential is a long-lived signed object; `V |≡ I |~ Attrs`
follows from the Issuer's key, but promoting it to `V |≡ I |≡ Attrs` needs
freshness, and a credential is not fresh. A6 is where the status list check and
the validity window enter. This is the well known limitation of BAN with
certificates rather than a defect of EAP-DID, and it is why revocation has to be
argued outside the logic.

**G9 is the fix.** With the presentation naming the link it was produced for, and
the Verifier checking it, G9 becomes derivable and G1 strengthens to a statement
about *this* exchange rather than about some exchange. `eap_did_ban.py` runs both
scenarios; the second is that one. Note what the binding cannot be: the current
Session-Id is `SHA256(thid)`, and a relay forwards the thread untouched, so both
links compute the same value. It has to be something the endpoints know
independently of the message — the lower layer identifiers of [RFC6677].

## 6. On non-derivability

A goal the engine does not produce is not one it failed to find. The postulates
are definite Horn clauses, so the fact set has a least model, and forward
chaining to a fixpoint computes exactly that model; a goal outside the fixpoint
is outside every model, which is what not derivable means. The one rule that
could generate terms without bound — freshness of a conjunction — is restricted
to conjunctions already present, so the term universe is finite.

Z3 is used only on the positive goals, where `premises ∧ ¬goal` unsatisfiable is
a proof. A saturating prover left on the negative goals reports satisfiability
rather than a proof, and a timeout reports neither.

## 8. Comparison with EAP-TLS

EAP-TLS reaches G1 through G5 through the handshake and the certificate chain,
G2 included, because the server certificate chains to an anchor the peer holds in
advance, and G3 and G4 because the client's key is used in the handshake that
establishes the channel being authenticated.

EAP-DID under Model D reaches G1 conditionally and G6, does not reach G2, and
does not reach G3 or G4. The G2 difference is not cryptographic: it is that
Model D provides no trust anchor for the Verifier. The G3 and G4 difference is
not about Model D at all. It is that the presentation and the channel are
separate objects and the method never joins them.

## 9. References

- [BAN] Burrows, M., Abadi, M. and R. Needham, "A Logic of Authentication", ACM
  TOCS 8(1), 1990.
- [RFC5247] Aboba, B. et al., "Extensible Authentication Protocol (EAP) Key
  Management Framework".
- [RFC5869] Krawczyk, H. and P. Eronen, "HMAC-based Extract-and-Expand Key
  Derivation Function (HKDF)".
- [RFC6677] Hartman, S. et al., "Channel-Binding Support for Extensible
  Authentication Protocol (EAP) Methods".
