defmodule Compos.Mix.Daemon do
  @moduledoc false

  def home(opts), do: Path.expand(opts[:home] || System.get_env("COMPOS_HOME") || "~/.compos")
  # HOME's socket, in its state folder (Compos.Core.default_state_dir), or in
  # the home for a daemon from before the home split
  def socket(home) do
    state =
      cond do
        dir = System.get_env("COMPOS_STATE_DIR") -> Path.expand(dir)
        home != Path.expand("~/.compos") -> Path.join(home, "state")
        true -> Path.join(System.get_env("XDG_STATE_HOME") || Path.expand("~/.local/state"), "compos")
      end

    old = Path.join(home, "sock")
    if File.exists?(old) and not File.exists?(Path.join(state, "sock")), do: old, else: Path.join(state, "sock")
  end

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

  # the bundled packages: scheme/packages at the project root
  def package_dirs(root), do: [Path.join(root, "scheme/packages")]

  def package_paths(root) do
    init = Path.join(root, "apps/compos_core/priv/init.scm")

    ~r/\(load\s+"([^"]+)"\)/
    |> Regex.scan(File.read!(init), capture: :all_but_first)
    |> Enum.flat_map(fn [file] ->
      root |> package_dirs() |> Enum.map(&Path.join(&1, file)) |> Enum.filter(&File.regular?/1) |> Enum.take(1)
    end)
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
        Compos.Core.Session.bootstrap_files(),
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
