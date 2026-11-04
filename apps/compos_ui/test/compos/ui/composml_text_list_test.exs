defmodule Compos.Ui.ComposMLTextListTest do
  use ExUnit.Case
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Compos.Core.{Buffer, Editor, Session}
  @endpoint Compos.Ui.Endpoint

  test "ibuffer owns semantic records while retaining its text lines and navigation" do
    Editor.minibuffer_close()
    Editor.set_pending([])
    {:ok, _} = Compos.Core.Session.eval("(test-one-window!)")

    {:ok, _} =
      Session.eval(~S|(begin (buffer-create "*zz-semantic-buffer*") (run-command "ibuffer-pretty"))|)

    on_exit(fn -> Compos.Core.kill_buffer("*zz-semantic-buffer*") end)

    row_text = fn ->
      Buffer.text("*ibuffer*")
      |> String.split("\n")
      |> Enum.find(&String.contains?(&1, "zz-semantic-buffer"))
    end

    text = row_text.()
    {:ok, view, _} = live(build_conn(), "/")
    assert has_element?(view, "buffers.buf > buffer[record-id]")
    assert has_element?(view, "buffers.buf c-headline.line")
    assert has_element?(view, "buffers > buffer .ibuffer-name", "zz-semantic-buffer")
    html = view |> element(~s(buffer[record-id="*zz-semantic-buffer*"])) |> render()
    assert html =~ "ibuffer-info ibuffer-mode"
    assert html =~ "ibuffer-info ibuffer-file"
    [_, win, line] = Regex.run(~r/id="ln-(\d+)-(\d+)"/, html)
    view |> element("#editor") |> render_hook("mouse", %{"win" => String.to_integer(win), "line" => String.to_integer(line), "col" => 0})
    assert has_element?(view, ~s(buffer[record-id="*zz-semantic-buffer*"].hl-line))
    assert row_text.() == text
    view |> element("#editor") |> render_hook("key", %{"k" => "n"})
    assert row_text.() == text
    {:ok, _} = Session.eval(~S|(list-refresh! "*ibuffer*")|)
    assert has_element?(view, "buffers.buf > buffer[record-id]")
  end

  test "picker metadata exposes formatter CSS classes on the rendered elements" do
    Editor.minibuffer_close()
    Editor.set_pending([])
    {:ok, _} = Compos.Core.Session.eval("(test-one-window!)")
    Editor.set_window_buffer("*scratch*")
    {:ok, view, _} = live(build_conn(), "/")
    {:ok, _} = Session.eval(~S|(begin
      (buffer-create "*picker-css*")
      (buffer-set-local! "*picker-css*" 'mode-name "text-mode")
      (set! ibuffer-info #t) (set! ibuffer-pretty #t)
      (run-command "ibuffer-prompt-pretty")
      (list-set-query! " *buffers*" "picker-css"))|)
    on_exit(fn ->
      Session.eval("(when (minibuffer-state) (minibuffer-cancel!))")
      Compos.Core.kill_buffer("*picker-css*")
    end)
    assert has_element?(view, "buffers .ibuffer-name", "picker-css"),
      inspect({Buffer.text(" *buffers*"), Buffer.get_local(" *buffers*", "render-records"), Editor.current_buffer()})
    assert has_element?(view, "buffers .ibuffer-info.ibuffer-mode", "text-mode")
    assert has_element?(view, "buffers .ibuffer-info.ibuffer-file")
    assert has_element?(view, "buffers .ibuffer-info.ibuffer-modified")
    assert has_element?(view, "buffers[profile=pretty] .ibuffer-info.ibuffer-size")
    assert has_element?(view, "buffers .ibuffer-heading", "[ ungrouped ]")
  end

  test "plain and pretty picker rows both use the direct DOM path" do
    Editor.minibuffer_close()
    Editor.set_pending([])
    {:ok, _} = Compos.Core.Session.eval("(test-one-window!)")
    Editor.set_window_buffer("*scratch*")
    {:ok, view, _} = live(build_conn(), "/")
    {:ok, _} = Session.eval(~S|(begin
      (buffer-create "*picker-direct*")
      (buffer-set-local! "*picker-direct*" 'mode-name "text-mode")
      (run-command "ibuffer-prompt-pretty")
      (list-set-query! " *buffers*" "picker-direct"))|)
    on_exit(fn ->
      Session.eval("(when (minibuffer-state) (minibuffer-cancel!))")
      Compos.Core.kill_buffer("*picker-direct*")
    end)
    row = ~s(buffers > buffer[record-id="*picker-direct*"])
    assert has_element?(view, row <> ".semantic-direct.line")
    assert has_element?(view, row <> " > .ibuffer-mode", "text-mode")
    refute has_element?(view, row <> " c-line")
    refute has_element?(view, row <> " .ibuffer-mode c-text")
    {:ok, _} = Session.eval(~S|(run-command "ibuffer-toggle-pretty")|)
    assert has_element?(view, row <> ".semantic-direct.line")
    assert has_element?(view, row <> " > .ibuffer-mode", "text-mode")
    refute has_element?(view, row <> " c-line")
  end

  test "Dired exposes file identities without replacing its compact text renderer" do
    dir = Path.join(System.tmp_dir!(), "composml-dired-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "alpha.txt"), "alpha")
    File.write!(Path.join(dir, "beta.txt"), "beta")
    Editor.minibuffer_close()
    Editor.set_pending([])
    {:ok, _} = Compos.Core.Session.eval("(test-one-window!)")
    {:ok, _} = Session.eval("(dired-open #{inspect(dir)})")

    on_exit(fn ->
      Compos.Core.kill_buffer(dir)
      File.rm_rf!(dir)
    end)

    text = Buffer.text(dir)
    {:ok, view, _} = live(build_conn(), "/")

    assert has_element?(
             view,
             ~s(directory[path="#{dir}"] file[record-id="alpha.txt"].line)
           )

    assert has_element?(
             view,
             ~s(file[name="alpha.txt"][kind="regular"][bytes="5"] filename[name="alpha.txt"]),
             "alpha.txt"
           )

    assert has_element?(view, ~s(file[name=".."][kind="directory"] filename), "..")
    assert has_element?(view, "size[bytes]")
    assert has_element?(view, "modified[mtime]")
    assert has_element?(view, ~s(file[permissions="-rw-r--r--"]))
    view |> element("#editor") |> render_hook("key", %{"k" => "n"})
    assert Buffer.text(dir) == text
    assert Buffer.get_local(dir, "render-mode") in [nil, false]
    assert has_element?(view, ~s(file[record-id="beta.txt"].line-content), "beta.txt")

    {:ok, _} =
      Session.eval("(with-current-buffer #{inspect(dir)} (lambda () (set-mode! \"text-mode\")))")

    assert Buffer.get_local(dir, "render-text-root") == false
    assert Buffer.get_local(dir, "render-records") == false
  end

  test "Imenu renders symbols with source locations and kinds" do
    Editor.minibuffer_close()
    Editor.set_pending([])
    {:ok, _} = Compos.Core.Session.eval("(test-one-window!)")
    {:ok, _} = Session.eval(~S|(begin
      (define zz-original-imenu-rows imenu-rows)
      (set! imenu-rows (lambda (buf) '((1 "function" "alpha" "Example documentation"))))
      (buffer-create "*semantic-symbols*")
      (switch-to-buffer! "*semantic-symbols*"))|)

    on_exit(fn ->
      Session.eval(~S|(begin (set! imenu-rows zz-original-imenu-rows) (dispatch-keys '("C-g")))|)
      Compos.Core.kill_buffer("*semantic-symbols*")
    end)

    {:ok, view, _} = live(build_conn(), "/")

    {:ok, _} = Session.eval(~S|(run-command "imenu")|)

    assert has_element?(
             view,
             ~s(symbol-list symbol-entry[kind="function"][name="alpha"] symbol-name),
             "alpha"
           )

    assert has_element?(view, "symbol-kind", "function")
    assert has_element?(view, ~s(symbol-location[source="*semantic-symbols*"][line="1"]), "L1")
  end
end
