import Config

# Runtime knobs so one machine can run several daemons at once — work,
# personal, a scratch instance — each with its own port, home, socket, and
# desktop file. The Chrome extension finds them all (see extension/sw.js).
#
#   COMPOS_HOME=~/.compos-work COMPOS_PORT=4014 COMPOS_APP_PORT=4015 \
#     COMPOS_NAME=work mix run --no-halt
#
# Setting COMPOS_HOME alone is enough: the socket and desktop file follow it,
# so two daemons can't fight over ~/.compos/sock.
#
# The same knobs also read from a config file, one `key = value` per line,
# `#` comments. An environment variable wins over the file.
#
#   home = ~/.compos-work
#   port = 4004
#   app_port = 4005
#   name = work
#   registry = ~/.compos/daemons.json
#   secret_key_base = ...
#   buffer_idle_hours = 24
#   trusted_networks = 10.10.69.0/24, 10.10.67.4
#   bind = 10.10.69.1
#
# COMPOS_CONF names the file: `COMPOS_CONF=/etc/compos.conf bin/compos daemon`.
# Without COMPOS_CONF the daemon reads $COMPOS_HOME/daemon.conf. The file can
# set `home`; COMPOS_HOME wins over it.

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
    if conf_path = System.get_env("COMPOS_CONF") do
      case File.read(Path.expand(conf_path)) do
        {:ok, text} -> parse_conf.(text)
        {:error, reason} -> raise "cannot read COMPOS_CONF=#{conf_path}: #{reason}"
      end
    end

  home = System.get_env("COMPOS_HOME") || (conf && conf["home"])

  if home do
    home = Path.expand(home)
    config :compos_core, home: home, desktop_path: Path.join(home, "desktop.etf")
    config :compos_rpc, socket_path: Path.join(home, "sock")
  end

  # config apart from state: a test daemon points COMPOS_CONFIG at the real
  # ~/.compos and keeps desktop/buffers/socket in its own COMPOS_HOME
  if config_dir = System.get_env("COMPOS_CONFIG") do
    config :compos_core, config_dir: Path.expand(config_dir)
  end

  home_dir = if home, do: Path.expand(home), else: Path.expand("~/.compos")

  conf =
    conf ||
      case File.read(Path.join(home_dir, "daemon.conf")) do
        {:ok, text} -> parse_conf.(text)
        _ -> %{}
      end

  # an environment variable wins over the conf file
  get = fn env_key, conf_key -> System.get_env(env_key) || conf[conf_key] end

  if registry = get.("COMPOS_DAEMON_REGISTRY", "registry") do
    config :compos_core, daemon_registry_path: Path.expand(registry)
  end

  if workspace = get.("COMPOS_WORKSPACE_ROOT", "workspace") do
    config :compos_core, workspace_root: Path.expand(workspace)
  end

  if port = get.("COMPOS_PORT", "port") do
    config :compos_ui, Compos.Ui.Endpoint, http: [ip: {0, 0, 0, 0}, port: String.to_integer(port)]
  end

  # one interface instead of every interface: the address of a WireGuard
  # interface keeps the port off the LAN, and loopback keeps it on this machine
  if bind = get.("COMPOS_BIND", "bind") do
    case :inet.parse_address(String.to_charlist(String.trim(bind))) do
      {:ok, ip} -> config :compos_ui, Compos.Ui.Endpoint, http: [ip: ip]
      _ -> raise "COMPOS_BIND=#{bind} is not an IP address"
    end
  end

  # the networks besides loopback that may reach the port (Compos.Ui.Reach),
  # comma or space separated CIDRs. They replace the Tailscale default.
  if networks = get.("COMPOS_TRUSTED_NETWORKS", "trusted_networks") do
    config :compos_ui, trusted_networks: String.split(networks, [",", " "], trim: true)
  end

  # the preview-app origin; a second daemon must move this port too
  if app_port = get.("COMPOS_APP_PORT", "app_port") do
    config :compos_ui, app_port: String.to_integer(app_port)
  end

  # explicit overrides win over the ones derived from home
  if sock = get.("COMPOS_SOCK", "sock"), do: config(:compos_rpc, socket_path: Path.expand(sock))

  if desktop = get.("COMPOS_DESKTOP", "desktop"),
    do: config(:compos_core, desktop_path: Path.expand(desktop))

  if hours = get.("COMPOS_BUFFER_IDLE_HOURS", "buffer_idle_hours") do
    {hours, ""} = Float.parse(hours)
    config :compos_core, buffer_idle_timeout_ms: round(hours * 60 * 60 * 1_000)
  end

  # the session-cookie key. In prod a per-install key is generated once and
  # kept in $home/secret_key_base (mode 0600); dev keeps the fixed key from
  # config.exs so browser sessions survive daemon restarts.
  secret = get.("COMPOS_SECRET_KEY_BASE", "secret_key_base")

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

  if secret, do: config(:compos_ui, Compos.Ui.Endpoint, secret_key_base: secret)

  # what this daemon calls itself — shown in the extension's options page so
  # you can tell which tabs belong to which life
  derived_name = if home, do: Path.basename(home), else: "compos"
  config :compos_core, name: get.("COMPOS_NAME", "name") || derived_name

  # an optional frame accent identifies this daemon at a glance. The view
  # validates the value before it places the color in CSS.
  if accent = get.("COMPOS_ACCENT", "accent") do
    config :compos_core, accent: accent
  end
end

# The model catalog the editor refreshed, when it has one. llm_db packages a
# catalog inside deps/, which ages from the day the lock was written and which
# mix deps.get throws away. M-x llm-catalog-refresh writes a fresh one here,
# outside the build, and this points llm_db at it for every boot after.
llm_db_snapshot = Path.expand("~/.compos/llm_db/snapshot.json")

if File.exists?(llm_db_snapshot) do
  config :llm_db, snapshot_path: llm_db_snapshot
end

# Models newer than the newest published catalog. llm_db merges these over
# the snapshot, so a refresh keeps them; drop an entry once the catalog has it.
config :llm_db,
  custom: %{
    openrouter: [
      models: %{
        "moonshotai/kimi-k3.1-pro" => %{
          name: "MoonshotAI: Kimi K3.1 Pro",
          capabilities: %{chat: true, tools: %{enabled: true}, streaming: %{tool_calls: true}},
          limits: %{context: 1_048_576},
          cost: %{input: 2.0, output: 10.0, cache_read: 0.2},
          modalities: %{input: [:text], output: [:text]}
        }
      }
    ]
  }
