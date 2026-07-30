#!/usr/bin/env python3
"""
issue-cred.py — Issue eduroam credential to Holder (idempotent)

Checks for existing schemas and credentials before creating new ones.
Running twice with the same state will return the existing objects.

Outputs:
    SCHEMA_URL=...
    CRED_ID=...
"""
import urllib.request, json, time, sys, uuid, os

ISSUER = os.environ.get('ISSUER_URL', 'http://agent-issuer:8085')
HOLDER = os.environ.get('HOLDER_URL', 'http://agent-holder:8085')
SCHEMA_TAG = 'eduroam-cred'

def req(method, url, data=None, timeout=15):
    r = urllib.request.Request(url, data=data, headers={'Content-Type': 'application/json'} if data else {})
    try:
        resp = urllib.request.urlopen(r, timeout=timeout)
        return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        print('ERR', e.code, body[:200], file=sys.stderr)
        sys.exit(1)

# ── 1. Resolve Issuer DID ──
resp = req('GET', ISSUER + '/did-registrar/dids')
issuer_did = resp['contents'][0]['did']

# ── 2. Find or create schema (idempotent) ──
existing = req('GET', f'{ISSUER}/schema-registry/schemas')
schema_guid = None
for s in existing.get('contents', []):
    if SCHEMA_TAG in s.get('tags', []):
        schema_guid = s['guid']
        print(f'Reusing existing schema: {schema_guid}', file=sys.stderr)
        break

if not schema_guid:
    sname = f'EduroamCredential-{uuid.uuid4()[:8]}'
    schema_obj = {
        'type': 'object',
        'properties': {'name': {'type': 'string'}, 'institution': {'type': 'string'}},
        'required': ['name'],
        'additionalProperties': False
    }
    schema_obj['$schema'] = 'https://json-schema.org/draft/2020-12/schema'

    schema = {
        'name': sname, 'version': '1.0.0',
        'tags': [SCHEMA_TAG],
        'type': 'https://w3c-ccg.github.io/vc-json-schemas/schema/2.0/schema.json',
        'schema': schema_obj,
        'author': issuer_did
    }
    result = req('POST', f'{ISSUER}/schema-registry/schemas', data=json.dumps(schema).encode())
    schema_guid = result['guid']
    print(f'Created schema: {schema_guid}', file=sys.stderr)

schema_url = f'http://caddy-issuer:8080/cloud-agent/schema-registry/schemas/{schema_guid}/schema'

# ── 3. Resolve connection ──
resp = req('GET', f'{ISSUER}/connections')
issuer_conn = resp['contents'][0]['connectionId']

# ── 4. Find or create credential offer (idempotent) ──
# Check if there's already a credential issued with this schema
existing_offers = req('GET', f'{ISSUER}/issue-credentials/records')
existing_cred_id = None
for rec in existing_offers.get('contents', []):
    if rec.get('protocolState') == 'CredentialReceived':
        existing_cred_id = rec.get('recordId')
        print(f'Reusing existing credential: {existing_cred_id}', file=sys.stderr)
        break

if existing_cred_id:
    # Verify the holder also has it
    holder_recs = req('GET', f'{HOLDER}/issue-credentials/records')
    for rec in holder_recs.get('contents', []):
        if rec.get('recordId') == existing_cred_id and rec.get('protocolState') == 'CredentialReceived':
            print(f'SCHEMA_URL={schema_url}')
            print(f'CRED_ID={existing_cred_id}')
            sys.exit(0)

# Create new offer
offer = {
    'claims': {'name': 'Test User', 'institution': 'Universidade Federal'},
    'credentialFormat': 'JWT',
    'issuingDID': issuer_did,
    'connectionId': issuer_conn,
    'schemaId': schema_url
}
result3 = req('POST', f'{ISSUER}/issue-credentials/credential-offers', data=json.dumps(offer).encode())
offer_thid = result3['thid']
print(f'Offer thid: {offer_thid}', file=sys.stderr)

# Wait for holder to receive
time.sleep(3)
holder_record_id = None
for i in range(15):
    resp4 = urllib.request.urlopen(f'{HOLDER}/issue-credentials/records?thid={offer_thid}')
    for c in json.loads(resp4.read()).get('contents', []):
        if c.get('protocolState') in ('OfferReceived', 'RequestReceived'):
            holder_record_id = c['recordId']
            break
    if holder_record_id:
        break
    time.sleep(2)

if not holder_record_id:
    print('ERR: holder never received offer', file=sys.stderr)
    sys.exit(1)

# Accept offer
resp = urllib.request.urlopen(f'{HOLDER}/did-registrar/dids')
holder_did = json.loads(resp.read())['contents'][0]['did']
accept = {'subjectId': holder_did}
req('POST', f'{HOLDER}/issue-credentials/records/{holder_record_id}/accept-offer', data=json.dumps(accept).encode())
print('Accepted', file=sys.stderr)

# Wait for credential
time.sleep(3)
for i in range(15):
    resp6 = urllib.request.urlopen(f'{HOLDER}/issue-credentials/records/{holder_record_id}')
    if json.loads(resp6.read()).get('protocolState') == 'CredentialReceived':
        break
    time.sleep(2)

print(f'SCHEMA_URL={schema_url}')
print(f'CRED_ID={holder_record_id}')
