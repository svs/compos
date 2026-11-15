# Stale checkpoints in the shared test home slow every catalog read; see
# apps/compos_core/test/test_helper.exs. Each app runs in its own VM, so each
# one clears the directory it would otherwise leave behind.
File.rm_rf!(Compos.Core.BufferStore.dir())

# This run's home, socket and desktop file go when the VM exits.
if Code.ensure_loaded?(Compos.TestRun), do: Compos.TestRun.clean_at_exit()

ExUnit.start()
