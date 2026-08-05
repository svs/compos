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

config :phoenix, :json_library, Jason

if config_env() == :test do
  config :aimax_rpc, socket_path: "/tmp/aimax-rpc-test.sock"
  config :logger, level: :warning

  config :aimax_ui, Aimax.Ui.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: 4046],
    server: false
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
