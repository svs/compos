defmodule Compos.Mix.Daemon do
  @moduledoc false

  def home(opts), do: Path.expand(opts[:home] || System.get_env("COMPOS_HOME") || "~/.compos")
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
    package_dir = Path.join(root, "apps/compos_core/priv/packages")
    init = Path.join(root, "apps/compos_core/priv/init.scm")

    ~r/\(load-bundled-package\s+"([^"]+)"\)/
    |> Regex.scan(File.read!(init), capture: :all_but_first)
    |> Enum.map(fn [file] -> Path.join(package_dir, file) end)
  end
end

defmodule Mix.Tasks.Compos.Reload do
  use Mix.Task

  @shortdoc "Hot-reload Scheme modules in a running compos daemon"
  @requirements ["app.config"]

  @impl true
  def run(args) do
    {opts, files, _} = OptionParser.parse(args, strict: [home: :string, all: :boolean])
    home = Compos.Mix.Daemon.home(opts)
    root = Compos.Mix.Daemon.project_root()

    paths =
      cond do
        opts[:all] -> all_paths(root, home)
        files != [] -> Enum.map(files, &Path.expand(&1, File.cwd!()))
        true -> Mix.raise("name one or more .scm files, or pass --all")
      end

    case Compos.Mix.Daemon.rpc(home, "reload", %{"paths" => paths}) do
      {:ok, %{"reloaded" => count, "forms" => forms}} ->
        Mix.shell().info("reloaded #{count} Scheme files · #{forms} changed forms")

      {:ok, %{"reloaded" => count}} ->
        Mix.shell().info("reloaded #{count} Scheme files")

      {:error, reason} ->
        Mix.raise("reload failed: #{inspect(reason)}")
    end
  end

  defp all_paths(root, home) do
    priv = Path.join(root, "apps/compos_core/priv")

    core =
      Enum.map(
        ~w(editor.scm transient.scm dired.scm themes.scm chrome.scm init.scm),
        &Path.join(priv, &1)
      )

    # the user's own Scheme too: config first, then anything installed under
    # <home>/packages. `--all` must mean all, or a reload leaves half a session.
    config =
      Enum.filter(
        Enum.map(~w(ai-config.scm init.scm custom.scm), &Path.join(home, &1)),
        &File.exists?/1
      )

    user = Path.wildcard(Path.join([home, "packages", "*.scm"]))

    core ++ Compos.Mix.Daemon.package_paths(root) ++ config ++ user
  end
end
