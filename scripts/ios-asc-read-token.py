#!/usr/bin/env python3
"""Return an encrypted, ten-minute, read-only App Store Connect capability.

The existing protected workflow owns authorization. The long-lived signing key
stays in CI; only the supplied recipient can decrypt the scoped token. This
script does not fetch or publish diagnostic data.
"""
import base64
import json
import os
from pathlib import Path
import re
import sys
import time
from urllib.parse import urlencode

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, x25519
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

CONTEXT = b'aies.asc.read-token.v1'
LIFETIME_SECONDS = 600


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode('ascii')


def scopes(app_id):
    if not re.fullmatch(r'[0-9]{6,12}', app_id):
        raise ValueError('Invalid configured app identity')
    feedback = '/v1/apps/' + app_id + '/betaFeedbackCrashSubmissions?'
    feedback += urlencode({'include': 'build', 'fields[betaFeedbackCrashSubmissions]':
                           'createdDate,deviceModel,osVersion,appUptimeInMilliseconds,build,crashLog'})
    builds = '/v1/builds?' + urlencode({'filter[app]': app_id,
                                      'fields[builds]': 'version,processingState,uploadedDate,buildAudienceType'})
    return ['GET ' + builds, 'GET ' + feedback]


def mint(private_pem, issuer, key_id, app_id, recipient_b64, *, now=None):
    if not re.fullmatch(r'[A-Z0-9]{10}', key_id) or not re.fullmatch(r'[0-9a-fA-F-]{36}', issuer):
        raise ValueError('Invalid configured key identity')
    recipient = x25519.X25519PublicKey.from_public_bytes(base64.b64decode(recipient_b64, validate=True))
    private_key = serialization.load_pem_private_key(private_pem, password=None)
    if not isinstance(private_key, ec.EllipticCurvePrivateKey) or private_key.curve.name != 'secp256r1':
        raise ValueError('App Store Connect requires an ES256 key')
    issued = int(time.time() if now is None else now)
    header = {'alg': 'ES256', 'kid': key_id, 'typ': 'JWT'}
    payload = {'iss': issuer, 'iat': issued, 'exp': issued + LIFETIME_SECONDS,
               'aud': 'appstoreconnect-v1', 'scope': scopes(app_id)}
    message = (b64(json.dumps(header, separators=(',', ':')).encode()) + '.' +
               b64(json.dumps(payload, separators=(',', ':')).encode())).encode()
    r, s = decode_dss_signature(private_key.sign(message, ec.ECDSA(hashes.SHA256())))
    token = message + b'.' + b64(r.to_bytes(32, 'big') + s.to_bytes(32, 'big')).encode()
    ephemeral = x25519.X25519PrivateKey.generate()
    nonce = os.urandom(12)
    secret = ephemeral.exchange(recipient)
    key = HKDF(algorithm=hashes.SHA256(), length=32, salt=None, info=CONTEXT).derive(secret)
    ciphertext = AESGCM(key).encrypt(nonce, token, CONTEXT)
    return {'schema': CONTEXT.decode(), 'ephemeral_public': base64.b64encode(ephemeral.public_key().public_bytes(
                serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode(),
            'nonce': base64.b64encode(nonce).decode(), 'ciphertext': base64.b64encode(ciphertext).decode()}


def main():
    try:
        result = mint(os.environ.pop('ASC_PRIVATE_KEY_P8').encode(), os.environ['ASC_ISSUER_ID'],
                      os.environ['ASC_KEY_ID'], os.environ['APP_STORE_CONNECT_APP_ID'],
                      os.environ['ASC_READ_RECIPIENT_PUBLIC'])
        destination = Path(os.environ['RUNNER_TEMP']) / 'asc-read-capability.json'
        with destination.open('x', encoding='utf-8') as stream:
            json.dump(result, stream)
    except Exception:
        # Never echo exception inputs, key material, plaintext token or provider bodies.
        print('Read-only capability preparation failed.', file=sys.stderr)
        return 1
    print('Encrypted read-only capability prepared; expires ten minutes after issuance.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
