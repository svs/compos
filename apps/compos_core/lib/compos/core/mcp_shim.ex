defmodule Compos.Core.McpShim do
  @moduledoc """
  The stdio shim every ACP agent starts for the compos MCP server. The
  crate is `native/compos_mcp_shim`: std only, about 1 MB per agent.

  Compiling this module builds the crate with cargo, as Rustler builds a
  NIF, and puts the binary in `priv/native`. mcp.scm names that path.
  """

  @crate Path.expand("../../../native/compos_mcp_shim", __DIR__)
  @priv_native Path.expand("../../../priv/native", __DIR__)
  @bin "compos-mcp-shim"

  @external_resource Path.join(@crate, "Cargo.toml")
  @external_resource Path.join(@crate, "src/main.rs")

  case System.cmd("cargo", ["build", "--release", "--quiet"],
         cd: @crate,
         stderr_to_stdout: true
       ) do
    {_, 0} ->
      :ok

    {out, status} ->
      raise "cargo build of #{@crate} failed (exit #{status}):\n#{out}"
  end

  # Copy, then rename over the old binary. An in-place write changes a
  # binary that running agents execute, and macOS kills them for it.
  File.mkdir_p!(@priv_native)
  tmp = Path.join(@priv_native, ".#{@bin}.tmp")
  File.cp!(Path.join([@crate, "target/release", @bin]), tmp)
  File.rename!(tmp, Path.join(@priv_native, @bin))

  @doc "The absolute path of the built shim."
  def path, do: Application.app_dir(:compos_core, Path.join("priv/native", @bin))
end
