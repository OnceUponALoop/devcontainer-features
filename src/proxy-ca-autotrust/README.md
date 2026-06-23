
# Proxy CA Auto-Trust (proxy-ca-autotrust)

Detects a corporate SSL inspection proxy and automatically trusts its root CA. Optionally installs additional CA certificates.

## Example Usage

```json
"features": {
    "ghcr.io/OnceUponALoop/devcontainer-features/proxy-ca-autotrust:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| detect_url | HTTPS URL to probe for SSL inspection. If verification fails and the chain matches issuer_pattern, the proxy root CA is trusted automatically. Set to empty to skip detection. | string | https://example.com |
| issuer_pattern | String matched (case-insensitive) against certificate issuers in the probed chain. At least one of issuer_pattern or key_fingerprint must be set when detect_url is set. | string | O=Zscaler Inc. |
| key_fingerprint | SHA-256 SPKI fingerprint (hex) of the proxy CA's public key. When set, a certificate in the chain must match both this and issuer_pattern (if also set). More secure than issuer_pattern alone and survives certificate renewals. | string | - |
| trust_chain | Trust all certificates in the detected chain except the leaf. Useful when intermediate CAs must also be explicitly trusted. | boolean | false |
| extra_certs | Comma-separated additional CA certificate sources to install. Each entry is an http/https URL or absolute path. PEM and DER formats are supported. | string | - |

SSL inspection proxies (Zscaler, Palo Alto, Cisco Umbrella, etc.) intercept HTTPS traffic by presenting their own certificates in place of the real ones. This causes SSL verification failures in devcontainers that don't carry the proxy's root CA. This feature detects the proxy by probing an HTTPS URL, inspects the certificate chain for a known issuer, and trusts the root CA automatically — no manual certificate distribution required.

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

If your organisation uses a different SSL inspection proxy, set `issuer_pattern` to a unique substring from your proxy's issuer. See [Identifying your issuer pattern](#identifying-your-issuer-pattern) below.

```json
"features": {
    "ghcr.io/onceuponaloop/devcontainer-features/proxy-ca-autotrust:1": {
        "issuer_pattern": "O=Palo Alto Networks"
    }
}
```

---

### Extra certificates only

Skip auto-detection and install known corporate CA certificates directly:

```json
"features": {
    "ghcr.io/onceuponaloop/devcontainer-features/proxy-ca-autotrust:1": {
        "detect_url": "",
        "extra_certs": "https://corp.example.com/root-ca.der,https://corp.example.com/intermediate.crt"
    }
}
```

Both PEM and DER formats are supported. `detect_url` must be explicitly set to empty to skip detection.

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

Combine `issuer_pattern` with `key_fingerprint` to pin to a specific public key. A certificate in the chain must satisfy both. See [Computing the SPKI fingerprint](#computing-the-spki-fingerprint) below.

```json
"features": {
    "ghcr.io/onceuponaloop/devcontainer-features/proxy-ca-autotrust:1": {
        "key_fingerprint": "a04303e2582c3291e4ed1e5d9f26a5eac1da43cc..."
    }
}
```

Either `issuer_pattern` or `key_fingerprint` may be used alone, or both together.

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

## Identifying your issuer pattern

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

Pick any unique substring from the `i:` lines as your `issuer_pattern`. The match is case-insensitive.

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

Run this from any machine behind your corporate network:

```bash
openssl s_client -connect example.com:443 -servername example.com -showcerts \
    </dev/null 2>/dev/null \
    | openssl x509 -noout -pubkey \
    | openssl pkey -pubin -outform DER \
    | openssl dgst -sha256 -binary \
    | base64
```

This computes the SHA-256 fingerprint of the root CA's public key. The fingerprint survives certificate renewals as long as the CA reuses the same key pair (which most corporate CAs do).


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/OnceUponALoop/devcontainer-features/blob/main/src/proxy-ca-autotrust/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
