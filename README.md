# devcontainer-features

A collection of [dev container Features](https://containers.dev/implementors/features/) 

## Features

| Feature | Description |
|---|---|
| [`proxy-ca-autotrust`](src/proxy-ca-autotrust/README.md) | Detects a corporate SSL inspection proxy and automatically trusts its root CA. Optionally installs additional CA certificates. |
| [`install-mise-copr`](src/install-mise-copr/README.md) | Installs [mise](https://mise.jdx.dev) from the jdxcode/mise COPR repository. |

## Usage

Add a feature to your `devcontainer.json`:

```jsonc
{
    "image": "mcr.microsoft.com/devcontainers/base:ubuntu",
    "features": {
        "ghcr.io/onceuponaloop/devcontainer-features/proxy-ca-autotrust:1": {},
        "ghcr.io/onceuponaloop/devcontainer-features/install-mise-copr:1": {}
    }
}
```

See each feature's README for the full list of options.
