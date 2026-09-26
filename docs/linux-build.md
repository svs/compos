# Linux x86_64 build

The [Linux x86_64 workflow](../.github/workflows/linux-x86_64.yml) runs on pushes to the fork's main branch and can also be started manually from GitHub Actions. For every successful push, it publishes a GitHub release tagged `build-<full commit SHA>` with the Linux archive and its SHA-256 checksum. The new release is marked Latest so the [installation guide](../INSTALLATION.md) can use a fixed download URL. It also uploads the same files as a 30-day Actions artifact. Manual workflow runs build the artifact without publishing a release. Upstream has no tag or Release process yet.

Burrito's outer executable is statically linked and self-extracting. The bundled Erlang runtime and Rust NIFs are built against the Ubuntu 24.04 runner's glibc, so the application is intended for compatible glibc-based Linux x86_64 hosts. It is not a fully static BEAM application. The workflow runs the executable and checks the browser endpoint before uploading it.

To verify and run the downloaded release assets:

```sh
sha256sum -c compos-linux-x86_64.tar.gz.sha256
tar -xzf compos-linux-x86_64.tar.gz
sha256sum -c SHA256SUMS
COMPOS_HOME="$PWD/compos-state" ./compos-linux-x86_64
```

Open <http://localhost:4004>. Set `COMPOS_INSTALL_DIR` if the extracted runtime should live outside the default application data directory.
