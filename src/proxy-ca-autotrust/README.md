
# Proxy CA Auto-Trust (proxy-ca-autotrust)

Detects a TLS trust gap caused by a corporate SSL inspection proxy and automatically trusts its root CA. Optionally installs additional CA certificates.

## Example Usage

```json
"features": {
    "ghcr.io/OnceUponALoop/devcontainer-features/proxy-ca-autotrust:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| tls_test_url | HTTPS URL probed to detect a TLS trust gap. If verification fails, the certificate chain is fetched and scanned for a CA matching cert_pattern and/or key_fingerprint. Set to empty to skip detection entirely. | string | https://example.com |
| cert_pattern | Case-insensitive regex matched against the full text of each certificate in the probed chain (subject, issuer, SANs, policy OIDs, etc.). At least one of cert_pattern or key_fingerprint must be set when tls_test_url is set. | string | Subject:.*O=Zscaler Inc\. |
| key_fingerprint | SHA-256 SPKI fingerprint (base64) of the proxy CA's public key. When set alone, a certificate in the chain must match this fingerprint directly. When set together with cert_pattern, the fingerprint is checked against the issuer of the pattern-matched cert (cert[i+1]), enabling two-factor pinning. Survives certificate renewals when the CA reuses its key pair. | string | - |
| trust_chain | Trust all certificates in the detected chain except the leaf. Useful when intermediate CAs must also be explicitly trusted. | boolean | false |
| extra_certs | Comma-separated additional CA certificate sources to install. Each entry is an http/https URL or absolute path. PEM and DER formats are supported. | string | - |

SSL inspection proxies (Zscaler, Palo Alto, Cisco Umbrella, etc.) intercept HTTPS traffic by presenting their own certificates in place of the real ones. This causes a TLS trust gap in devcontainers that don't carry the proxy's root CA. This feature detects the gap by probing a test URL, scans the presented certificate chain for a known CA, and trusts the root automatically — no manual certificate distribution required.

## Usage

### Default — Zscaler

```json
"features": {
    "ghcr.io/onceuponaloop/devcontainer-features/proxy-ca-autotrust:1": {}
}
```

Probes `https://example.com`. If Zscaler is intercepting traffic, its root CA is extracted from the chain and trusted automatically.

---

### Custom proxy

If your organisation uses a different SSL inspection proxy, set `cert_pattern` to a regex that matches a unique field in your proxy's certificate (subject, issuer, OID, etc.). See [Identifying your cert pattern](#identifying-your-cert-pattern) below.

```json
"features": {
    "ghcr.io/onceuponaloop/devcontainer-features/proxy-ca-autotrust:1": {
        "cert_pattern": "O=Palo Alto Networks"
    }
}
```

---

### Extra certificates only

Skip auto-detection and install known corporate CA certificates directly:

```json
"features": {
    "ghcr.io/onceuponaloop/devcontainer-features/proxy-ca-autotrust:1": {
        "tls_test_url": "",
        "extra_certs": "https://corp.example.com/root-ca.der,https://corp.example.com/intermediate.crt"
    }
}
```

Both PEM and DER formats are supported. `tls_test_url` must be explicitly set to empty to skip detection.

---

### Combined — auto-detect proxy and install extra certificates

Trust the intercepting proxy's root CA and install additional corporate CAs in one step. The proxy root is trusted first, so `extra_certs` HTTPS downloads work even through the proxy.

```json
"features": {
    "ghcr.io/onceuponaloop/devcontainer-features/proxy-ca-autotrust:1": {
        "extra_certs": "https://corp.example.com/internal-root.crt"
    }
}
```

---

### With key fingerprint for stronger verification

Combine `cert_pattern` with `key_fingerprint` to pin to a specific public key. `cert_pattern` identifies a certificate in the chain by content; `key_fingerprint` then verifies that the issuer of that certificate matches the expected key. Both must pass. See [Computing the SPKI fingerprint](#computing-the-spki-fingerprint) below.

```json
"features": {
    "ghcr.io/onceuponaloop/devcontainer-features/proxy-ca-autotrust:1": {
        "cert_pattern": "O=Zscaler Inc\\.",
        "key_fingerprint": "a04303e2582c3291e4ed1e5d9f26a5eac1da43cc..."
    }
}
```

Either `cert_pattern` or `key_fingerprint` may be used alone, or both together.

---

### Trust the full chain

When intermediate CAs must also be explicitly trusted:

```json
"features": {
    "ghcr.io/onceuponaloop/devcontainer-features/proxy-ca-autotrust:1": {
        "trust_chain": true
    }
}
```

Trusts every certificate in the detected chain except the leaf. The leaf is always the site certificate and should never be trusted as a CA.

---

## Identifying your cert pattern

Run these commands from any machine behind your corporate network. They work even when SSL verification is failing — `openssl s_client` retrieves the chain without verifying it.

**Show the issuer of every certificate in the chain:**

```bash
openssl s_client -connect example.com:443 -servername example.com -showcerts \
    </dev/null 2>/dev/null \
    | grep " i:"
```

Example output behind Zscaler:
```
   i:O=Zscaler Inc., CN=Zscaler Intermediate CA
   i:O=Zscaler Inc., CN=Zscaler Root CA
```

Example output behind Palo Alto:
```
   i:O=Palo Alto Networks, CN=Palo Alto Networks Root CA
```

Pick any unique substring from the `i:` lines as your `cert_pattern`. The match is case-insensitive and applied against the full `openssl x509 -text` output of each cert, so subject, issuer, SANs, and policy OIDs all work.

---

**Confirm which certificate is the root** (subject equals issuer — this is what gets trusted):

```bash
openssl s_client -connect example.com:443 -servername example.com -showcerts \
    </dev/null 2>/dev/null \
    | grep -E "^\s+[si]:"
```

The root appears as the entry where the `s:` (subject) and `i:` (issuer) lines are identical.

---

**Inspect the root CA's full details:**

```bash
openssl s_client -connect example.com:443 -servername example.com \
    </dev/null 2>/dev/null \
    | openssl x509 -noout -subject -issuer -dates
```

---

## Computing the SPKI fingerprint

### Browser

1. Go to any HTTPS site through your corporate proxy.
2. Click the **padlock** in the address bar, then **Connection is secure**, then the certificate icon.
3. Open the **Details** tab and select the **second-to-last** certificate in the hierarchy — this is the CA that signed the site certificate.
4. Scroll to the bottom of the **Certificate Fields** panel. The last two entries are the Certificate fingerprint and the **Public Key** fingerprint. Copy the **Public Key** fingerprint - that is the SPKI fingerprint.

> Works in Chrome, Edge, and any Chromium-based browser. Firefox shows the same fields under **Security** → **View Certificate** → **Details**.

### CLI

Run this from any machine behind your corporate network:

```bash
HOST=example.com

# Which cert in the chain to fingerprint:
#   0  = leaf (the site cert — don't use this)
#   1  = issuing / intermediate CA
#   2+ = issuing
#   N  = root CA
CHAIN_INDEX=1

openssl s_client -connect "$HOST:443" -servername "$HOST" -showcerts </dev/null 2>/dev/null \
  | awk -v n="$CHAIN_INDEX" '
      /-----BEGIN CERTIFICATE-----/ { i++; p=(i == n + 1) }
      p
    ' \
  | openssl x509 -noout -pubkey \
  | openssl pkey -pubin -outform DER \
  | openssl dgst -sha256 -r \
  | cut -d ' ' -f1
```

The output is the SHA-256 hash of that certificate's public key. It stays stable across certificate renewals as long as the CA reuses the same key pair, which corporate CAs typically do.



---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/OnceUponALoop/devcontainer-features/blob/main/src/proxy-ca-autotrust/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
