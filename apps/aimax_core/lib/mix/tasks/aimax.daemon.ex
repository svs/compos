defmodule Aimax.Mix.Daemon do
  @moduledoc false

  def home(opts), do: Path.expand(opts[:home] || System.get_env("AIMAX_HOME") || "~/.aimax")
  def socket(home), do: Path.join(home, "sock")

  def rpc(home, method, params \\ %{}, timeout \\ 30_000) do
    request = %{
      jsonrpc: "2.0",
      id: System.unique_integer([:positive]),
      method: method,
      params: params
    }

    with {:ok, sock} <-
           :gen_tcp.connect(
             {:local, socket(home)},
             0,
             [:binary, active: false, packet: :line]
           ),
         :ok <- :gen_tcp.send(sock, [Jason.encode!(request), "\n"]),
         {:ok, line} <- :gen_tcp.recv(sock, 0, timeout),
         :ok <- :gen_tcp.close(sock),
         {:ok, response} <- Jason.decode(line) do
      case response do
        %{"result" => result} -> {:ok, result}
        %{"error" => error} -> {:error, error["message"] || inspect(error)}
      end
    end
  end

  def wait_until(home, wanted, tries \\ 100)
  def wait_until(_home, _wanted, 0), do: {:error, :timeout}

  def wait_until(home, wanted, tries) do
    up? = match?({:ok, "pong"}, rpc(home, "ping", %{}, 250))

    if up? == wanted do
      :ok
    else
      Process.sleep(100)
      wait_until(home, wanted, tries - 1)
    end
  end

  def project_root do
    __DIR__
    |> Path.join("../../../../..")
    |> Path.expand()
  end

  def package_paths(root) do
    package_dir = Path.join(root, "apps/aimax_core/priv/packages")

    package_dir
    |> Path.join("*.scm")
    |> Path.wildcard()
    |> Enum.sort_by(fn path ->
      case Path.basename(path) do
        "custom.scm" -> {0, path}
        "tools.scm" -> {1, path}
        "recipes.scm" -> {2, path}
        "components.scm" -> {3, path}
        "preview.scm" -> {4, path}
        _ -> {5, path}
      end
    end)
  end
end

defmodule Mix.Tasks.Aimax.Reload do
  use Mix.Task

  @shortdoc "Hot-reload Scheme modules in a running ai-max daemon"
  @requirements ["app.config"]

  @impl true
  def run(args) do
    {opts, files, _} = OptionParser.parse(args, strict: [home: :string, all: :boolean])
    home = Aimax.Mix.Daemon.home(opts)
    root = Aimax.Mix.Daemon.project_root()

    paths =
      cond do
        opts[:all] -> all_paths(root, home)
        files != [] -> Enum.map(files, &Path.expand(&1, File.cwd!()))
        true -> Mix.raise("name one or more .scm files, or pass --all")
      end

    if Enum.any?(paths, &(Path.basename(&1) == "editor.scm")) do
      Mix.raise("editor.scm is core bootstrap policy; use mix aimax.restart")
    end

    case Aimax.Mix.Daemon.rpc(home, "reload", %{"paths" => paths}) do
      {:ok, %{"reloaded" => count}} -> Mix.shell().info("reloaded #{count} Scheme files")
      {:error, reason} -> Mix.raise("reload failed: #{inspect(reason)}")
    end
  end

  defp all_paths(root, home) do
    priv = Path.join(root, "apps/aimax_core/priv")
    core = Enum.map(~w(dired.scm themes.scm chrome.scm), &Path.join(priv, &1))
    init = Path.join(home, "init.scm")
    core ++ Aimax.Mix.Daemon.package_paths(root) ++ if(File.exists?(init), do: [init], else: [])
  end
end

