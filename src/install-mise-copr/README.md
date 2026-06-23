
# mise (native-tls) (install-mise-copr)

Installs mise from the jdxcode/mise COPR repository to get a native-tls mise build.

## Example Usage

```json
"features": {
    "ghcr.io/OnceUponALoop/devcontainer-features/install-mise-copr:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| version | mise version to install (e.g. "2024.12.19") or "latest" for the most recent release. | string | latest |
| fedora_release | Fedora release to use for COPR build artifacts. | string | 44 |
| arch | CPU architecture. Auto-detected from uname -m when empty. | string | - |

## Usage

### Default — latest release

```json
"features": {
    "ghcr.io/onceuponaloop/devcontainer-features/install-mise-copr:1": {}
}
```

Installs the latest mise release to `/usr/local/bin/mise`. Architecture is detected automatically from `uname -m`.

---

### Pin a specific version

```json
"features": {
    "ghcr.io/onceuponaloop/devcontainer-features/install-mise-copr:1": {
        "version": "2024.12.19"
    }
}
```

The version string must match a published COPR package version exactly.

---

### Override architecture

```json
"features": {
    "ghcr.io/onceuponaloop/devcontainer-features/install-mise-copr:1": {
        "arch": "aarch64"
    }
}
```

---

## Updating mise

mise is installed via the COPR RPM and cannot self-update in the usual way. Use the bundled `mise-update` script instead:

```bash
sudo mise-update              # latest release
sudo mise-update 2024.12.19  # specific version
```

## OS Support

Debian and Ubuntu with `apt` available. `bash` is required to execute the `install.sh` script.


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/OnceUponALoop/devcontainer-features/blob/main/src/install-mise-copr/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
