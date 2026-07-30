#!/bin/bash
# Generate PKI certificates for EAP-TLS benchmark
# Creates CA, server, and client certificates

set -e

CERT_DIR="${1:-./config/certs}"
mkdir -p "$CERT_DIR"

echo "=== Generating EAP-TLS PKI certificates in $CERT_DIR ==="

# 1. CA
if [ ! -f "$CERT_DIR/ca-key.pem" ]; then
    echo "→ CA key + cert"
    openssl genrsa -out "$CERT_DIR/ca-key.pem" 4096 2>/dev/null
    openssl req -new -x509 -key "$CERT_DIR/ca-key.pem" \
        -out "$CERT_DIR/ca.pem" -days 3650 \
        -subj "/C=PT/O=EAP-DID-Bench/CN=EAP-TLS-CA" 2>/dev/null
fi

# 2. Server cert
if [ ! -f "$CERT_DIR/server-key.pem" ]; then
    echo "→ Server key + cert"
    openssl genrsa -out "$CERT_DIR/server-key.pem" 2048 2>/dev/null
    openssl req -new -key "$CERT_DIR/server-key.pem" \
        -out "$CERT_DIR/server.csr" \
        -subj "/C=PT/O=EAP-DID-Bench/CN=authradius" 2>/dev/null
    openssl x509 -req -in "$CERT_DIR/server.csr" \
        -CA "$CERT_DIR/ca.pem" -CAkey "$CERT_DIR/ca-key.pem" \
        -CAcreateserial -out "$CERT_DIR/server.pem" -days 365 2>/dev/null
    rm -f "$CERT_DIR/server.csr"
fi

# 3. Client cert (for wpa_supplicant)
if [ ! -f "$CERT_DIR/client-key.pem" ]; then
    echo "→ Client key + cert"
    openssl genrsa -out "$CERT_DIR/client-key.pem" 2048 2>/dev/null
    openssl req -new -key "$CERT_DIR/client-key.pem" \
        -out "$CERT_DIR/client.csr" \
        -subj "/C=PT/O=EAP-DID-Bench/CN=supplicant" 2>/dev/null
    openssl x509 -req -in "$CERT_DIR/client.csr" \
        -CA "$CERT_DIR/ca.pem" -CAkey "$CERT_DIR/ca-key.pem" \
        -CAcreateserial -out "$CERT_DIR/client.pem" -days 365 2>/dev/null
    rm -f "$CERT_DIR/client.csr"
fi

echo "=== Done. Files in $CERT_DIR ==="
ls -la "$CERT_DIR/"
