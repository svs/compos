defmodule Compos.Ui.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_root_layout, html: {Compos.Ui.Layouts, :root})
  end

  pipeline :handheld do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_root_layout, html: {Compos.Ui.MobileLayouts, :root})
  end

  # the handheld client: the same frame payload, drawn for one thumb.
  # /m/b/NAME is the buffer link for a phone.
  scope "/m" do
    pipe_through(:handheld)
    live("/", Compos.Ui.MobileLive)
    live("/b/:buffer", Compos.Ui.MobileLive)
  end

  scope "/" do
    pipe_through(:browser)
    live("/", Compos.Ui.EditorLive)
    live("/compos", Compos.Ui.HomepageLive, :compos)

    # a buffer link: the tab's own frame shows BUFFER, at LINE when the
    # query gives one. The name is one percent-encoded segment, so a file
    # buffer (named after its path) keeps its slashes.
    live("/b/:buffer", Compos.Ui.EditorLive)
  end

  # The VM as Phoenix LiveDashboard shows it: processes by memory, ETS
  # tables, allocators, ports. Compos.Ui.Reach guards the route as it
  # guards the editor.
  import Phoenix.LiveDashboard.Router

  scope "/" do
    pipe_through(:browser)
    live_dashboard("/dashboard")
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
