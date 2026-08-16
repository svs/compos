import Config

# Runtime knobs so one machine can run several daemons at once — work,
# personal, a scratch instance — each with its own port, home, socket, and
# desktop file. The Chrome extension finds them all (see extension/sw.js).
#
#   AIMAX_HOME=~/.aimax-work AIMAX_PORT=4005 AIMAX_NAME=work mix run --no-halt
#
# Setting AIMAX_HOME alone is enough: the socket and desktop file follow it,
# so two daemons can't fight over ~/.aimax/sock.
#
# The same knobs also read from $AIMAX_HOME/daemon.conf, one `key = value`
# per line, `#` comments. An environment variable wins over the file.
#
#   port = 4004
#   app_port = 4005
#   name = work
#   secret_key_base = ...

if config_env() != :test do
  home = System.get_env("AIMAX_HOME")

  if home do
    home = Path.expand(home)
    config :aimax_core, home: home, desktop_path: Path.join(home, "desktop.etf")
    config :aimax_rpc, socket_path: Path.join(home, "sock")
  end

  home_dir = if home, do: Path.expand(home), else: Path.expand("~/.aimax")

  conf =
    case File.read(Path.join(home_dir, "daemon.conf")) do
      {:ok, text} ->
        for line <- String.split(text, "\n"),
            line = String.trim(line),
            line != "" and not String.starts_with?(line, "#"),
            [k, v] <- [String.split(line, "=", parts: 2)],
            into: %{} do
          {String.trim(k), String.trim(v)}
        end

      _ ->
        %{}
    end

  # an environment variable wins over daemon.conf
  get = fn env_key, conf_key -> System.get_env(env_key) || conf[conf_key] end

  if port = get.("AIMAX_PORT", "port") do
    config :aimax_ui, Aimax.Ui.Endpoint, http: [ip: {127, 0, 0, 1}, port: String.to_integer(port)]
  end

  # the preview-app origin; a second daemon must move this port too
  if app_port = get.("AIMAX_APP_PORT", "app_port") do
    config :aimax_ui, app_port: String.to_integer(app_port)
  end

  # explicit overrides win over the ones derived from home
  if sock = get.("AIMAX_SOCK", "sock"), do: config(:aimax_rpc, socket_path: Path.expand(sock))

  if desktop = get.("AIMAX_DESKTOP", "desktop"),
    do: config(:aimax_core, desktop_path: Path.expand(desktop))

  # the session-cookie key. In prod a per-install key is generated once and
  # kept in $home/secret_key_base (mode 0600); dev keeps the fixed key from
  # config.exs so browser sessions survive daemon restarts.
  secret = get.("AIMAX_SECRET_KEY_BASE", "secret_key_base")

  secret =
    cond do
      secret ->
        secret

      config_env() == :prod ->
        secret_path = Path.join(home_dir, "secret_key_base")

        case File.read(secret_path) do
          {:ok, s} when byte_size(s) >= 64 ->
            String.trim(s)

          _ ->
            s = 64 |> :crypto.strong_rand_bytes() |> Base.encode64()
            File.mkdir_p!(home_dir)
            File.write!(secret_path, s)
            File.chmod!(secret_path, 0o600)
            s
        end

      true ->
        nil
    end

  if secret, do: config(:aimax_ui, Aimax.Ui.Endpoint, secret_key_base: secret)

  # what this daemon calls itself — shown in the extension's options page so
  # you can tell which tabs belong to which life
  derived_name = if home, do: Path.basename(home), else: "aimax"
  config :aimax_core, name: get.("AIMAX_NAME", "name") || derived_name
end
