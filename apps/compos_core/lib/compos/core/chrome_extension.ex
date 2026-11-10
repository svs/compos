defmodule Compos.Core.ChromeExtension do
  @moduledoc """
  Places the Chrome extension at a fixed path, `~/.compos/chrome-extension`,
  so Chrome's "Load unpacked" has one folder to point at whether compos runs
  from a checkout or from the release binary. Burrito unpacks every build into
  a new directory, so the folder inside the release moves with each version;
  this one does not, and Chrome's reload button picks up the new files.
  """

  require Logger

  @doc "The folder Chrome loads: ~/.compos/chrome-extension."
  def path, do: Path.join(Compos.Core.home(), "chrome-extension")

  @doc "The shipped extension: priv/extension in a release, extension/ in a checkout."
  def source do
    priv = :code.priv_dir(:compos_core) |> to_string()

    [Path.join(priv, "extension"), Path.expand("../../../extension", priv),
     Path.join(File.cwd!(), "extension")]
    |> Enum.find(&File.exists?(Path.join(&1, "manifest.json")))
  end

  @doc "Copy the shipped extension to `path/0`. Answers {:ok, path} or {:error, reason}."
  def install do
    case source() do
      nil ->
        {:error, :no_extension_source}

      src ->
        dest = path()
        File.mkdir_p!(dest)
        File.cp_r!(src, dest)
        {:ok, dest}
    end
  rescue
    e ->
      Logger.warning("chrome extension not installed: " <> Exception.message(e))
      {:error, Exception.message(e)}
  end
end
