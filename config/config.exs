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

config :aimax_ui, Aimax.Ui.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: 4004],
  server: true,
  check_origin: false,
  secret_key_base: "aimax-dev-secret-key-base-0123456789-0123456789-0123456789-0123456789",
  render_errors: [formats: [html: Aimax.Ui.ErrorHTML], layout: false],
  pubsub_server: Aimax.Ui.PubSub,
  live_view: [signing_salt: "aimax-lv-salt"]

# the origin previewed apps run in — a different port is a different origin,
# which is the whole point: an app's JavaScript can never read the editor
config :aimax_ui, app_port: 4005

# Dormant buffers remain durable and in history; only their live processes
# are released. Zero disables idle eviction.
config :aimax_core, buffer_idle_timeout_ms: 24 * 60 * 60 * 1_000
config :aimax_core, daemon_registry_path: Path.expand("~/.aimax/daemons.json")

config :phoenix, :json_library, Jason

# AIMAX_VERIFY=1 mix run --no-halt: an isolated daemon (own port, home,
# socket) for verifying changes from a worktree while the real one runs
if config_env() == :dev and System.get_env("AIMAX_VERIFY") do
  config :aimax_ui, Aimax.Ui.Endpoint, http: [ip: {127, 0, 0, 1}, port: 4104]
  config :aimax_ui, app_port: 4105

  config :aimax_core,
    home: "/tmp/aimax-verify-home",
    desktop_path: "/tmp/aimax-verify-home/desktop.etf"

  config :aimax_rpc, socket_path: "/tmp/aimax-verify.sock"
end

if config_env() == :test do
  # per-checkout suffix: concurrent test runs from different worktrees must
  # not share sockets or fixture files, or evals land in the other VM
  suffix = Integer.to_string(:erlang.phash2(Path.expand(".")), 36)

  config :aimax_rpc, socket_path: "/tmp/aimax-rpc-test-#{suffix}.sock"

  config :aimax_core,
    home: "/tmp/aimax-test-home-#{suffix}",
    desktop_path: "/tmp/aimax-desktop-test-#{suffix}.etf",
    daemon_registry_path: "/tmp/aimax-daemons-test-#{suffix}.json",
    desktop_autorestore: false,
    # no models.dev fetches from tests
    llmdb_auto: false

  config :logger, level: :warning

  config :aimax_ui, Aimax.Ui.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: 4046],
    server: false

  # no listening socket in tests: concurrent worktrees would fight for the
  # port, and the router answers a Plug.Test conn without one
  config :aimax_ui, app_port: nil

  # no oembed fetches from tests: a cache miss stays :pending
  config :aimax_ui, oembed_fetch: false
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
