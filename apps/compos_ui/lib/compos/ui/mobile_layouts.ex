defmodule Compos.Ui.MobileLayouts do
  @moduledoc """
  The root layout of the handheld client. Its stylesheet and its one hook
  are static files: priv/static/mobile.css and mobile.js.

  The desktop layout is not shared. The phone has its own chrome (a
  header, a composer, a bar of four places) and its own gestures,
  and the two files stay apart so neither grows conditions for the other.
  The theme still comes from the faces: the design's tokens map onto the
  face variables the daemon sends.
  """
  use Phoenix.Component
  import Compos.Ui.ComposML, only: [sigil_M: 2]

  def root(assigns) do
    assigns =
      assigns
      |> assign_new(:page_title, fn -> "compos" end)
      # the stylesheet and the script are static files (priv/static); the
      # boot id in their URLs makes a new boot load them again
      |> assign(:boot_id, :persistent_term.get(:compos_boot_id, "dev"))
      |> then(&assign(&1, :css_v, file_version(&1.boot_id, "mobile.css")))
      |> then(&assign(&1, :js_v, file_version(&1.boot_id, "mobile.js")))

    ~M"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <link rel="stylesheet" href="/composml.css?v=semantic-grid-6" />
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, maximum-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <meta name="boot-id" content={@boot_id} />
        <meta name="apple-mobile-web-app-capable" content="yes" />
        <meta name="apple-mobile-web-app-status-bar-style" content="default" />
        <meta name="theme-color" content="#efece2" />
        <title>{@page_title}</title>
        <link rel="manifest" href="/manifest.webmanifest" />
        <link rel="icon" type="image/png" href="/images/compos-logo.png" />
        <link rel="apple-touch-icon" href="/images/compos-logo.png" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
        <link
          href="https://fonts.googleapis.com/css2?family=Spectral:ital,wght@0,300;0,400;0,500;0,600;1,400&family=IBM+Plex+Mono:wght@400;500;600&display=swap"
          rel="stylesheet"
        />
        <link rel="stylesheet" href={"/mobile.css?v=" <> @css_v} />
      </head>
      <body>
        {@inner_content}
        <script src="/phx/phoenix.min.js"></script>
        <script src="/lv/phoenix_live_view.min.js"></script>
        <script src={"/mobile.js?v=" <> @js_v}></script>
      </body>
    </html>
    """
  end

  # the boot and the file's own time: a saved change to the file reaches
  # the phone at its next load, with no restart
  defp file_version(boot, file) do
    path = Application.app_dir(:compos_ui, ["priv", "static", file])

    case File.stat(path, time: :posix) do
      {:ok, %{mtime: t}} -> boot <> "-" <> Integer.to_string(t)
      _ -> boot
    end
  end
end
