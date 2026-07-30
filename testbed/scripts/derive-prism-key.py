#!/usr/bin/env python3
"""Derive a prism DID key from an Identus wallet seed.

The cloud agent stores prism DID keys as HD derivations of the wallet seed
rather than as key material, so this is the only way to hand one to the
supplicant. The path is the one in
cloud-agent/service/wallet-api/.../model/KeyManagement.scala:

    m/29'/29'/<didIndex>'/<keyUsage>'/<keyIndex>'

with 29 (0x1d) for both the wallet purpose and the prism DID method, and the
key usage numbered MASTER 1, ASSERTION_METHOD 2, KEY_AGREEMENT 3,
AUTHENTICATION 4, REVOCATION 5, CAPABILITY_INVOCATION 6,
CAPABILITY_DELEGATION 7.

Usage:
    derive-prism-key.py <seed-hex> <did-index> <key-usage> <key-index>

Prints three lines: the private key base64url without padding, the compressed
public key the same way, and the compressed public key in hex, which is the
form the create operation stored in the wallet uses. The caller is expected to
check the public key against the one published in the DID.
"""

import base64
import hashlib
import hmac
import sys

# secp256k1
P = 2**256 - 2**32 - 977
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
G = (0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
     0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8)

KEY_USAGE = {
    "MASTER": 1,
    "ASSERTION_METHOD": 2,
    "KEY_AGREEMENT": 3,
    "AUTHENTICATION": 4,
    "REVOCATION": 5,
    "CAPABILITY_INVOCATION": 6,
    "CAPABILITY_DELEGATION": 7,
}

WALLET_PURPOSE = 0x1D
PRISM_DID_METHOD = 0x1D


def point_add(p, q):
    if p is None:
        return q
    if q is None:
        return p
    if p[0] == q[0] and (p[1] + q[1]) % P == 0:
        return None
    if p == q:
        lam = 3 * p[0] * p[0] * pow(2 * p[1], P - 2, P) % P
    else:
        lam = (q[1] - p[1]) * pow(q[0] - p[0], P - 2, P) % P
    x = (lam * lam - p[0] - q[0]) % P
    return (x, (lam * (p[0] - x) - p[1]) % P)


def point_mul(k, p=G):
    r = None
    while k:
        if k & 1:
            r = point_add(r, p)
        p = point_add(p, p)
        k >>= 1
    return r


def compress(point):
    return bytes([2 + (point[1] & 1)]) + point[0].to_bytes(32, "big")


def master_key(seed):
    h = hmac.new(b"Bitcoin seed", seed, hashlib.sha512).digest()
    return int.from_bytes(h[:32], "big"), h[32:]


def derive_hardened(key, chain_code, index):
    data = b"\x00" + key.to_bytes(32, "big") + (0x80000000 + index).to_bytes(4, "big")
    h = hmac.new(chain_code, data, hashlib.sha512).digest()
    return (int.from_bytes(h[:32], "big") + key) % N, h[32:]


def b64url(raw):
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def main(argv):
    if len(argv) != 5:
        print(__doc__, file=sys.stderr)
        return 2

    seed = bytes.fromhex(argv[1].removeprefix("\\x"))
    did_index = int(argv[2])
    usage = argv[3].upper()
    key_index = int(argv[4])

    if usage not in KEY_USAGE:
        print(f"unknown key usage {usage}", file=sys.stderr)
        return 2

    key, chain_code = master_key(seed)
    for index in (WALLET_PURPOSE, PRISM_DID_METHOD, did_index,
                  KEY_USAGE[usage], key_index):
        key, chain_code = derive_hardened(key, chain_code, index)

    public = compress(point_mul(key))
    print(b64url(key.to_bytes(32, "big")))
    print(b64url(public))
    print(public.hex())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
