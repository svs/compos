defmodule Aimax.Ui.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_root_layout, html: {Aimax.Ui.Layouts, :root}
  end

  scope "/" do
    pipe_through :browser
    live "/", Aimax.Ui.EditorLive

    # a buffer link: the tab's own frame shows BUFFER, at LINE when the
    # query gives one. The name is one percent-encoded segment, so a file
    # buffer (named after its path) keeps its slashes.
    live "/b/:buffer", Aimax.Ui.EditorLive
  end

  # the same buffer as plain text, for a terminal or an agent that holds a
  # link. Loopback only, and the answer carries no CORS header: a page you
  # visit can send this request but cannot read the reply.
  forward "/raw", Aimax.Ui.Raw
end
