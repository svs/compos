import Config

# Runtime knobs so one machine can run several daemons at once — work,
# personal, a scratch instance — each with its own port, home, socket, and
# desktop file. The Chrome extension finds them all (see extension/sw.js).
#
#   AIMAX_HOME=~/.aimax-work AIMAX_PORT=4005 AIMAX_NAME=work mix run --no-halt
#
# Setting AIMAX_HOME alone is enough: the socket and desktop file follow it,
# so two daemons can't fight over ~/.aimax/sock.

if config_env() != :test do
  home = System.get_env("AIMAX_HOME")

  if home do
    home = Path.expand(home)
    config :aimax_core, home: home, desktop_path: Path.join(home, "desktop.etf")
    config :aimax_rpc, socket_path: Path.join(home, "sock")
  end

  if port = System.get_env("AIMAX_PORT") do
    config :aimax_ui, Aimax.Ui.Endpoint, http: [ip: {127, 0, 0, 1}, port: String.to_integer(port)]
  end

  # the preview-app origin; a second daemon must move this port too
  if app_port = System.get_env("AIMAX_APP_PORT") do
    config :aimax_ui, app_port: String.to_integer(app_port)
  end

  # explicit overrides win over the ones derived from home
  if sock = System.get_env("AIMAX_SOCK"), do: config(:aimax_rpc, socket_path: Path.expand(sock))

  if desktop = System.get_env("AIMAX_DESKTOP"),
    do: config(:aimax_core, desktop_path: Path.expand(desktop))

  # what this daemon calls itself — shown in the extension's options page so
  # you can tell which tabs belong to which life
  derived_name = if home, do: Path.basename(home), else: "aimax"
  config :aimax_core, name: System.get_env("AIMAX_NAME") || derived_name
end
