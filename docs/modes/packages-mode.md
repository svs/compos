# packages-mode and app-registry-mode

compos ships core features in `priv/` and `scheme/stdlib/`, and community or personal packages as Git repositories from `compos-dev` or your own sources.

## `packages-mode` (`M-x packages`)

Lists every package across four tabs (`all`, `packages`, `stdlib`, `core`; `<left>` and `<right>` switch tabs), plus available packages from `packages-sources` below.

| Key | What it does |
| --- | --- |
| `l` | Load an unloaded package, or install an available package (clones, loads, adds `use-package` to `~/.compos/init.scm`) |
| `k` | Unload a loaded package cleanly (runs its unload hook; core cannot unload) |
| `d` | Uninstall an installed clone and remove it from `init.scm` |
| `u` / `U` | Update package at point to the release pin / update all packages |
| `h` / `r` | Hold package at its current commit / roll back to previous commit and hold |
| `RET` or `v` | Visit the package's source file |
| `o` / `P` | Open GitHub repo / send local clone changes upstream as a PR |
| `a` / `R` | Add or remove a package source (GitHub org, user, or `OWNER/REPO`) |
| `/` | Narrow (supports `state:loaded`, `state:update`, `state:held`, `tier:core`) |
| `g` / `q` | Re-scan and fetch clones / quit |

When an update drops a public name used by your own code, compos files a todo with a fix plan and starts a review chat instead of failing silently.

## `app-registry-mode` (`M-x app-registry`)

Lists every app registered in the live editor under `user` (`~/.compos/packages`), `package`, and `core`. Moving shows the app's modes, commands, and open buffers beside the list. Press `RET` or `o` to open the app, `v` to visit its source, `/` to narrow, `g` to refresh, and `q` to quit.

See also: [10. APPS](../10.%20APPS.md), [13. EXTEND](../13.%20EXTEND.md).
