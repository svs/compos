# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

config :compos_ui, Compos.Ui.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: 4004],
  server: true,
  check_origin: false,
  secret_key_base: "compos-dev-secret-key-base-0123456789-0123456789-0123456789-0123456789",
  render_errors: [formats: [html: Compos.Ui.ErrorHTML], layout: false],
  pubsub_server: Compos.Ui.PubSub,
  live_view: [signing_salt: "compos-lv-salt"]

# the origin previewed apps run in — a different port is a different origin,
# which is the whole point: an app's JavaScript can never read the editor
config :compos_ui, app_port: 4005

# Dormant buffers remain durable and in history; only their live processes
# are released. Zero disables idle eviction.
config :compos_core, buffer_idle_timeout_ms: 24 * 60 * 60 * 1_000
config :compos_core, daemon_registry_path: Path.expand("~/.compos/daemons.json")

config :phoenix, :json_library, Jason

if config_env() == :dev do
  # A saved file reaches the running daemon with no restart: Scheme reloads
  # its changed forms, Elixir recompiles in a child process and the VM swaps
  # the changed modules in. Compos.Core.Hotload owns the watcher; the
  # compiler is named here so a test can name a stub.
  config :compos_core,
    hotload: true,
    hotload_recompile: {Compos.Core.Hotload.Compile, :compile, []}

  config :compos_ui, Compos.Ui.Endpoint,
    code_reloader: true,
    debug_errors: true,
    live_reload: [
      patterns: [
        ~r"apps/compos_ui/priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
        ~r"apps/compos_ui/(lib|priv)/.*(ex|heex)$"
      ]
    ]
end

# COMPOS_VERIFY=1 mix run --no-halt: an isolated daemon (own port, home,
# socket) for verifying changes from a worktree while the real one runs
if config_env() == :dev and System.get_env("COMPOS_VERIFY") do
  config :compos_ui, Compos.Ui.Endpoint, http: [ip: {127, 0, 0, 1}, port: 4104]
  config :compos_ui, app_port: 4105

  config :compos_core,
    home: "/tmp/compos-verify-home",
    desktop_path: "/tmp/compos-verify-home/desktop.etf"

  config :compos_rpc, socket_path: "/tmp/compos-verify.sock"
end

if config_env() == :test do
  # per-checkout suffix: concurrent test runs from different worktrees must
  # not share sockets or fixture files, or evals land in the other VM.
  # MIX_TEST_PARTITION joins the suffix, so each partition of
  # `mix test --partitions N` gets its own home, socket, and desktop file.
  suffix =
    Integer.to_string(:erlang.phash2(Path.expand(".")), 36) <>
      (System.get_env("MIX_TEST_PARTITION") || "")

  config :compos_rpc, socket_path: "/tmp/compos-rpc-test-#{suffix}.sock"

  config :compos_core,
    home: "/tmp/compos-test-home-#{suffix}",
    provenance_path: ":memory:",
    desktop_path: "/tmp/compos-desktop-test-#{suffix}.etf",
    daemon_registry_path: "/tmp/compos-daemons-test-#{suffix}.json",
    desktop_autorestore: false,
    # no models.dev fetches from tests
    llmdb_auto: false

  config :logger, level: :warning

  config :compos_ui, Compos.Ui.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: 4046],
    server: false

  # no listening socket in tests: concurrent worktrees would fight for the
  # port, and the router answers a Plug.Test conn without one
  config :compos_ui, app_port: nil

  # no oembed fetches from tests: a cache miss stays :pending
  config :compos_ui, oembed_fetch: false
end

# Sample configuration:
#
#     config :logger, :default_handler,
#       level: :info
#
#     config :logger, :default_formatter,
#       format: "$date $time [$level] $metadata$message\n",
#       metadata: [:user_id]
#
