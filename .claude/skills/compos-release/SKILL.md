---
name: compos-release
description: Cut a new release build of compos from the checkout and put it in service on the stable daemon (port 4004, home ~/.compos). Use when the user asks to cut, build, ship, or install a release for the 4004 daemon, or to get committed work into the stable compos. Also covers the tagged GitHub release.
---

# Cutting a release for the 4004 daemon

The daemon on port 4004 is the stable compos. It is a Burrito executable, not a checkout, so it has no hot reload. Committed work reaches it only through a new build and a restart.

`scheme/packages/release.scm` owns the mechanism. This skill runs its three steps from a shell: build, install, restart. `M-x release-build-and-install` does the same steps from inside the editor.

## 1. Check the tree

```sh
cd ~/src/compos
git status --short            # must print nothing
git rev-parse --short HEAD    # the commit the build carries
bin/compos --home ~/.compos eval '(build-info)'   # the build that runs now
```

The build takes the files in the working tree, but it stamps the commit of `HEAD`. A dirty tree gives a build whose stamp is false. Commit or set aside the changes first; do not build a dirty tree.

If `HEAD` equals the commit in `(build-info)`, the stable daemon already runs this build. Tell the user and stop.

The code-change skill gates each commit on `bin/test-fast`. Do not run the suite again for a release of commits that passed that gate.

## 2. Build

Run this from the checkout, in the background. It is the command `release-build!` runs. A build takes some minutes.

```sh
rm -rf _build/prod/rel && MIX_ENV=prod BURRITO_TARGET=macos_arm mix release --overwrite > /tmp/compos-release-build.log 2>&1; echo "rc=$?"
```

- `rc=0`: the executable is `burrito_out/compos_macos_arm`.
- Any other code: read the error with `grep -m3 -B2 -A8 -E '^\*\* \(|^error' /tmp/compos-release-build.log`. Fix the cause and build again. Do not install.

A failed build changes nothing in service. The stable daemon continues on the old build.

## 3. Install and restart

The restart stops each terminal and each agent turn that runs in the 4004 daemon. Buffers, windows, and groups come back from `~/.local/state/compos/desktop.etf`. Tell the user that the restart comes next, then run it. If this session runs in a terminal of the 4004 daemon, the restart ends this session too: say so first, and name the check in step 4.

```sh
bin/compos --home ~/.compos eval '(release-install!)'
```

`release-install!` copies the build to `release-bin-path` (`~/.local/bin/compos-stable`), prunes the unpacked directories of other builds, and restarts the stable daemon. The eval can end with a closed socket, because the daemon stops while it answers. That is not a failure; step 4 decides.

Never `kill` or `pkill` the daemon. Never start a second daemon on `~/.compos`.

## 4. Verify

```sh
until bin/compos --home ~/.compos eval '(build-info)' 2>/dev/null; do sleep 2; done
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4004/
```

The release passes when the `commit` in `(build-info)` equals `git rev-parse --short HEAD` and the curl prints `200`. Report the old commit and the new commit.

If the daemon does not answer after 60 seconds, read `tail -40 ~/.local/state/compos/daemon.log`. The RPC socket opens last, after the Scheme corpus loads.

If the commit is still the old one, the daemon started again from a different executable. A release respawns the path in `__BURRITO_BIN_PATH`, which is the file it first started from:

```sh
bin/compos --home ~/.compos eval '(getenv "__BURRITO_BIN_PATH")'
```

Compare that file with `burrito_out/compos_macos_arm` (`shasum`). Report the difference to the user; do not copy files by hand.

## Going back

An install keeps no copy of the old executable. To go back, check out the old commit in a clean tree and run steps 2 to 4 again. `M-x compos-update` installs the newest GitHub release instead.

## The tagged GitHub release

A tagged release is a different job: it publishes executables for other people. Do it only when the user asks for a version number or a public release.

1. Set the new version in six files: `@version` in `mix.exs`, `version:` in the `mix.exs` of each of the four apps, and `version` in `desktop/src-tauri/tauri.conf.json`.
2. Commit with the subject `release: compos X.Y.Z`. Follow `docs/FURTHER READING/COMMITS.md`; `git show v0.9.2` is the pattern.
3. Tag the commit `vX.Y.Z` and push the commit and the tag. Ask the user before the push.
4. `.github/workflows/release.yml` builds `macos_arm`, `linux`, and `linux_arm`, then attaches the executables to the GitHub release. Watch it with `gh run watch`.

The stable daemon shows a notice when the release is out, and `compos-update` installs it. To put the same commit in service at once, run steps 2 to 4 above.
