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

  test "a table row is a table box and every bar is one of its columns" do
    html = render_component(&Compos.Ui.Layouts.root/1, %{inner_content: ""})

    assert html =~ "display: table; width: 100%; table-layout: fixed;"
    assert html =~ ".line.row-table .f-md-table-bar"
    assert html =~ ".line.row-table-rule .line-content::after"
  end
end
