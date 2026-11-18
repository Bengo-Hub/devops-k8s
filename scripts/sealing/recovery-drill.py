"""Sealed Secrets recovery drill, fully in memory. Prints names and ok/fail only.

1. Fetches the newest age backup from R2 (SigV4 GET; creds come in via env from the caller).
2. Decrypts it with the offline age identity (X25519 recipient stanza, HKDF, ChaCha20-Poly1305 STREAM).
3. gunzips, parses the key Secrets, loads each RSA private key.
4. For each sealed file given, decrypts one encryptedData value with the backed-up keys
   (sealed-secrets format: u16 len | RSA-OAEP-SHA256(label=ns/name) session key | AES-256-GCM, zero nonce)
   and prints which key generation opened it. Values are never printed or written.
argv: identity_file bucket prefix sealed_file...
env: R2_EP, R2_AK, R2_SK
"""
import base64, datetime, gzip, hashlib, hmac, os, sys, urllib.parse, urllib.request
import yaml
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305, AESGCM

CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"


def b32dec(s):
    s = s.lower(); pos = s.rfind("1"); data = [CHARSET.find(c) for c in s[pos + 1:-6]]
    acc = bits = 0; out = []
    for v in data:
        acc = (acc << 5) | v; bits += 5
        while bits >= 8:
            bits -= 8; out.append((acc >> bits) & 255)
    return bytes(out)


def s3_get(ep, ak, sk, bucket, key=None, query=""):
    host = urllib.parse.urlparse(ep).netloc
    path = "/" + bucket + ("/" + urllib.parse.quote(key) if key else "/")
    now = datetime.datetime.now(datetime.timezone.utc)
    amz, day = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
    ph = hashlib.sha256(b"").hexdigest()
    canon = f"GET\n{path}\n{query}\nhost:{host}\nx-amz-content-sha256:{ph}\nx-amz-date:{amz}\n\nhost;x-amz-content-sha256;x-amz-date\n{ph}"
    scope = f"{day}/auto/s3/aws4_request"
    sts = f"AWS4-HMAC-SHA256\n{amz}\n{scope}\n{hashlib.sha256(canon.encode()).hexdigest()}"
    k = ("AWS4" + sk).encode()
    for part in (day, "auto", "s3", "aws4_request"):
        k = hmac.new(k, part.encode(), hashlib.sha256).digest()
    sig = hmac.new(k, sts.encode(), hashlib.sha256).hexdigest()
    req = urllib.request.Request(ep.rstrip("/") + path + (("?" + query) if query else ""), headers={
        "x-amz-date": amz, "x-amz-content-sha256": ph,
        "Authorization": f"AWS4-HMAC-SHA256 Credential={ak}/{scope}, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature={sig}"})
    return urllib.request.urlopen(req, timeout=60).read()


def age_decrypt(data, ident):
    sk = b32dec(ident)
    priv = X25519PrivateKey.from_private_bytes(sk)
    pub = priv.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    hdr_end = data.index(b"\n---")
    header = data[:hdr_end]
    mac_line_end = data.index(b"\n", hdr_end + 1)
    mac = base64.b64decode(data[hdr_end + 5:mac_line_end] + b"==")
    payload = data[mac_line_end + 1:]
    lines = header.split(b"\n")
    assert lines[0] == b"age-encryption.org/v1"
    file_key = None
    i = 1
    while i < len(lines):
        if lines[i].startswith(b"-> X25519 "):
            share = base64.b64decode(lines[i].split()[2] + b"==")
            body = base64.b64decode(lines[i + 1] + b"==")
            shared = priv.exchange(X25519PublicKey.from_public_bytes(share))
            wrap = HKDF(hashes.SHA256(), 32, share + pub, b"age-encryption.org/v1/X25519").derive(shared)
            try:
                file_key = ChaCha20Poly1305(wrap).decrypt(b"\x00" * 12, body, None)
            except Exception:
                pass
            i += 2
        else:
            i += 1
    assert file_key, "no stanza opened with this identity"
    hk = HKDF(hashes.SHA256(), 32, b"", b"header").derive(file_key)
    assert hmac.compare_digest(hmac.new(hk, header + b"\n---", hashlib.sha256).digest(), mac), "header MAC"
    nonce, rest = payload[:16], payload[16:]
    pk = HKDF(hashes.SHA256(), 32, nonce, b"payload").derive(file_key)
    aead = ChaCha20Poly1305(pk)
    out = bytearray(); ctr = 0; CH = 64 * 1024 + 16
    while rest:
        chunk, rest = rest[:CH], rest[CH:]
        n = ctr.to_bytes(11, "big") + (b"\x01" if not rest else b"\x00")
        out += aead.decrypt(n, chunk, None); ctr += 1
    return bytes(out)


ident_file, bucket, prefix, *sealed_files = sys.argv[1:]
ident = [l for l in open(ident_file).read().splitlines() if l.startswith("AGE-SECRET-KEY-")][0]
ep, ak, sk = os.environ["R2_EP"], os.environ["R2_AK"], os.environ["R2_SK"]
listing = s3_get(ep, ak, sk, bucket, query="list-type=2&prefix=" + urllib.parse.quote(prefix + "/", safe=""))
import re
keys = sorted(re.findall(rb"<Key>([^<]+)</Key>", listing))
newest = keys[-1].decode()
blob = s3_get(ep, ak, sk, bucket, newest)
print(f"backup object: {newest} ({len(blob)} bytes, {len(keys)} copies in bucket)")
doc = yaml.safe_load(gzip.decompress(age_decrypt(blob, ident)))
privs = {}
for item in doc["items"]:
    privs[item["metadata"]["name"]] = serialization.load_pem_private_key(base64.b64decode(item["data"]["tls.key"]), None)
print("age decrypt ok; sealing keys in backup:", ", ".join(sorted(privs)))
for f in sealed_files:
    ss = yaml.safe_load(open(f))
    ns, name = ss["metadata"]["namespace"], ss["metadata"]["name"]
    k0, v0 = sorted(ss["spec"]["encryptedData"].items())[0]
    raw = base64.b64decode(v0)
    n = int.from_bytes(raw[:2], "big"); enc_key, ct = raw[2:2 + n], raw[2 + n:]
    opened = None
    for kn, pk in privs.items():
        try:
            sess = pk.decrypt(enc_key, padding.OAEP(mgf=padding.MGF1(hashes.SHA256()), algorithm=hashes.SHA256(), label=f"{ns}/{name}".encode()))
            AESGCM(sess).decrypt(b"\x00" * 12, ct, None)
            opened = kn; break
        except Exception:
            continue
    print(f"{ns}/{name} key {k0}: {'opened by ' + opened if opened else 'FAILED'}")
