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
  end
end
