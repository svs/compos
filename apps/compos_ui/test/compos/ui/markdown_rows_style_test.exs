defmodule Compos.Ui.MarkdownRowsStyleTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  test "preview never reveals Markdown source markers on the active line" do
    html = render_component(&Compos.Ui.Layouts.root/1, %{inner_content: ""})

    assert html =~ ".f-md-marker { display: none; }"
    refute html =~ ".line.hl-line .f-md-marker"
    assert html =~ ".line.row-li .line-content::before"
    assert html =~ ".line.row-hr .line-content::after"
  end
end
