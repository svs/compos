# stdlib

The standard library of compos: chat, agents, todo, git, code, help and the rest of the everyday set. One directory for each package, its tests beside it.

Core loads it at boot from `priv/init.scm` with `(require 'stdlib)`. `stdlib.scm` puts every package directory on `load-path` and loads the stock set in order. `recipes.scm` has one recipe for each package.

A Scheme name is defined at one level only: core (`scheme/packages`, `priv`) or here. `apps/compos_core/test/compos/stdlib_levels_test.exs` fails when a file name or a top-level define is in both.

This directory was `compos-dev/compos-packages` from 2026-11-15 to 2026-11-18; that repo keeps the history before the move.
