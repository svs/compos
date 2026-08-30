defmodule Compos.Ui.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router
  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_root_layout, html: {Compos.Ui.Layouts, :root})
  end

  scope "/" do
    pipe_through(:browser)
    live("/", Compos.Ui.EditorLive)
    live("/operad", Compos.Ui.HomepageLive, :operad)
    live("/emma", Compos.Ui.HomepageLive, :emma)
    live("/compos", Compos.Ui.HomepageLive, :compos)

    # a buffer link: the tab's own frame shows BUFFER, at LINE when the
    # query gives one. The name is one percent-encoded segment, so a file
    # buffer (named after its path) keeps its slashes.
    live("/b/:buffer", Compos.Ui.EditorLive)

    # the BEAM, graphically: processes by reductions, memory, and message
    # queue; request and VM charts. The dashboard brings its own layout.
    live_dashboard("/dashboard", metrics: Compos.Ui.Telemetry)
  end

  # the same buffer as plain text, for a terminal or an agent that holds a
  # link. Loopback only, and the answer carries no CORS header: a page you
  # visit can send this request but cannot read the reply.
  forward("/raw", Compos.Ui.Raw)

  # Markdown keeps absolute filesystem paths. The preview signs each local
  # image path before the browser requests it, so this route exposes only a
  # path the editor rendered and never accepts an arbitrary filename.
  forward("/local-image", Compos.Ui.LocalImage)

  # A browser-file buffer gets the same signed-path protection. This route
  # serves only image, audio, and video MIME types.
  forward("/local-file", Compos.Ui.LocalFile)
end
