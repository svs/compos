import Config

# Runtime knobs so one machine can run several daemons at once — work,
# personal, a scratch instance — each with its own port, home, socket, and
# desktop file. The Chrome extension finds them all (see extension/sw.js).
#
#   AIMAX_HOME=~/.aimax-work AIMAX_PORT=4014 AIMAX_APP_PORT=4015 \
#     AIMAX_NAME=work mix run --no-halt
#
# Setting AIMAX_HOME alone is enough: the socket and desktop file follow it,
# so two daemons can't fight over ~/.aimax/sock.
#
# The same knobs also read from a config file, one `key = value` per line,
# `#` comments. An environment variable wins over the file.
#
#   home = ~/.aimax-work
#   port = 4004
#   app_port = 4005
#   name = work
#   registry = ~/.aimax/daemons.json
#   secret_key_base = ...
#   buffer_idle_hours = 24
#
# AIMAX_CONF names the file: `AIMAX_CONF=/etc/aimax.conf bin/aimax daemon`.
# Without AIMAX_CONF the daemon reads $AIMAX_HOME/daemon.conf. The file can
# set `home`; AIMAX_HOME wins over it.

if config_env() != :test do
  parse_conf = fn text ->
    for line <- String.split(text, "\n"),
        line = String.trim(line),
        line != "" and not String.starts_with?(line, "#"),
        [k, v] <- [String.split(line, "=", parts: 2)],
        into: %{} do
      {String.trim(k), String.trim(v)}
    end
  end

  conf =
    if conf_path = System.get_env("AIMAX_CONF") do
      case File.read(Path.expand(conf_path)) do
        {:ok, text} -> parse_conf.(text)
        {:error, reason} -> raise "cannot read AIMAX_CONF=#{conf_path}: #{reason}"
      end
    end

  home = System.get_env("AIMAX_HOME") || (conf && conf["home"])

  if home do
    home = Path.expand(home)
    config :aimax_core, home: home, desktop_path: Path.join(home, "desktop.etf")
    config :aimax_rpc, socket_path: Path.join(home, "sock")
  end

  # config apart from state: a test daemon points AIMAX_CONFIG at the real
  # ~/.aimax and keeps desktop/buffers/socket in its own AIMAX_HOME
  if config_dir = System.get_env("AIMAX_CONFIG") do
    config :aimax_core, config_dir: Path.expand(config_dir)
  end

  home_dir = if home, do: Path.expand(home), else: Path.expand("~/.aimax")

  conf =
    conf ||
      case File.read(Path.join(home_dir, "daemon.conf")) do
        {:ok, text} -> parse_conf.(text)
        _ -> %{}
      end

  # an environment variable wins over the conf file
  get = fn env_key, conf_key -> System.get_env(env_key) || conf[conf_key] end

  if execution = get.("AIMAX_SCHEME_EXECUTION", "scheme_execution") do
    mode =
      case execution do
        "lanes" -> :lanes
        "single_actor" -> :single_actor
        other -> raise "scheme_execution must be lanes or single_actor, got: #{other}"
      end

    config :aimax_core, scheme_execution: mode
  end

  if registry = get.("AIMAX_DAEMON_REGISTRY", "registry") do
    config :aimax_core, daemon_registry_path: Path.expand(registry)
  end

  if workspace = get.("AIMAX_WORKSPACE_ROOT", "workspace") do
    config :aimax_core, workspace_root: Path.expand(workspace)
  end

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

  if hours = get.("AIMAX_BUFFER_IDLE_HOURS", "buffer_idle_hours") do
    {hours, ""} = Float.parse(hours)
    config :aimax_core, buffer_idle_timeout_ms: round(hours * 60 * 60 * 1_000)
  end

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
