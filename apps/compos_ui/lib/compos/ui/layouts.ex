defmodule Compos.Ui.Layouts do
  use Phoenix.Component
  import Compos.Ui.ComposML, only: [sigil_M: 2]

  def root(assigns) do
    assigns =
      assigns
      |> assign_new(:page_title, fn -> "compos.el" end)
      # the stylesheet and the script are static files (priv/static); the
      # boot id in their URLs makes a new boot load them again
      |> assign(:boot_id, :persistent_term.get(:compos_boot_id, "dev"))

    ~M"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <link rel="stylesheet" href="/composml.css?v=semantic-grid-6" />
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <meta name="boot-id" content={@boot_id} />
        <title>{@page_title}</title>
        <link rel="manifest" href="/manifest.webmanifest" />
        <link rel="icon" type="image/png" href="/images/compos-logo.png" />
        <link rel="apple-touch-icon" href="/images/compos-logo.png" />
        <link
          rel="stylesheet"
          href="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/css/xterm.min.css"
        />
        <meta name="theme-color" content="#e6e0d2" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
        <link
          href="https://fonts.googleapis.com/css2?family=Spectral:ital,wght@0,300;0,400;0,500;0,600;0,700;1,400&family=IBM+Plex+Sans:wght@400;500;600&family=IBM+Plex+Mono:ital,wght@0,300;0,400;0,500;0,600;1,400&display=swap"
          rel="stylesheet"
        />
        <link rel="stylesheet" href={"/editor.css?v=" <> @boot_id} />
      </head>
      <body>
        {@inner_content}
        <script src="/phx/phoenix.min.js"></script>
        <script src="/lv/phoenix_live_view.min.js"></script>
        <script src="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/lib/xterm.min.js"></script>
        <script src="https://cdn.jsdelivr.net/npm/@xterm/addon-fit@0.10.0/lib/addon-fit.min.js"></script>
        <script src="https://cdn.jsdelivr.net/npm/@xterm/addon-webgl@0.18.0/lib/addon-webgl.min.js"></script>
        <script src={"/strip-slide.js?v=" <> @boot_id}></script>
        <script src={"/rope.js?v=" <> @boot_id}></script>
        <script src={"/predict.js?v=" <> @boot_id}></script>
        <script src={"/app.js?v=" <> @boot_id}></script>
      </body>
    </html>
    """
  end
end
