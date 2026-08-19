defmodule Aimax.CommandPaletteTest do
  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(str), do: str |> String.graphemes() |> press()

  defp wait_for(fun, tries \\ 100)
  defp wait_for(fun, 0), do: assert(fun.())

  defp wait_for(fun, tries) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_for(fun, tries - 1)
    end
  end

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()
    Editor.set_window_buffer("palette-#{System.unique_integer([:positive])}")
    on_exit(fn -> Editor.minibuffer_close() end)
    :ok
  end

  test "M-x stays command-name completion while Cmd-k searches command docs" do
    {:ok, _} =
      Session.eval(
        ~s{(define-command "zz-palette-doc" "Polish the purple submarine" (lambda () #t))}
      )

    press("M-x")
    type("purple submarine")
    refute Enum.any?(Editor.render_state().minibuffer.candidates, &(&1.label == "zz-palette-doc"))
    press("C-g")

    press("s-k")
    resting_total = Editor.render_state().minibuffer.total
    type("purple submarine")

    # The old pool remains visible during a burst; only the final query scans
    # apropos and replaces it.
    assert Editor.render_state().minibuffer.total == resting_total

    wait_for(fn ->
      mb = Editor.render_state().minibuffer
      mb.total < resting_total and Enum.any?(mb.candidates, &(&1.label == "zz-palette-doc"))
    end)
  end

  test "Cmd-k finds recipes and asks for their declared inputs" do
    press("s-k")
    type("open file split")

    wait_for(fn ->
      Enum.any?(
        Editor.render_state().minibuffer.candidates,
        &(&1.label == "open a file in a split")
      )
    end)

    mb = Editor.render_state().minibuffer
    assert Enum.any?(mb.candidates, &(&1.label == "open a file in a split"))

    press("RET")
    mb = Editor.render_state().minibuffer
    assert mb.prompt == "File: "
    assert mb.input == ""
    refute mb.input =~ "/abs/path"
  end

  test "choosing a command runs it and contributes to M-x history" do
    {:ok, _} =
      Session.eval(
        ~s{(define-command "zz-palette-run" "Launch the copper narwhal" (lambda () (buffer-create "*palette-ran*")))}
      )

    press("s-k")
    type("copper narwhal")

    wait_for(fn ->
      Editor.render_state().minibuffer.total < length(Session.command_names())
    end)

    labels = Enum.map(Editor.render_state().minibuffer.candidates, & &1.label)
    index = Enum.find_index(labels, &(&1 == "zz-palette-run"))
    assert index
    press(List.duplicate("C-n", index))
    press("RET")
    assert Buffer.exists?("*palette-ran*")

    press("M-x")
    assert hd(Editor.render_state().minibuffer.candidates).label == "zz-palette-run"
  end

  test "the browser prompt bridge requeries the dynamic palette" do
    {:ok, _} =
      Session.eval(
        ~s{(define-command "zz-browser-palette" "Polish the silver cuttlefish" (lambda () #t))}
      )

    {:ok, _} = Session.eval(~s{(run-command "command-palette")})

    for char <- String.graphemes("silver cuttlefish") do
      {:ok, _} = Session.eval(~s{(chrome--mb-key "#{char}")})
    end

    wait_for(fn ->
      Enum.any?(
        Editor.render_state().minibuffer.candidates,
        &(&1.label == "zz-browser-palette")
      )
    end)

    assert Enum.any?(
             Editor.render_state().minibuffer.candidates,
             &(&1.label == "zz-browser-palette")
           )
  end

  test "core debounce keeps only the newest value" do
    {:ok, _} = Session.eval(~s{(define *zz-debounce-value* "unset")})

    {:ok, _} =
      Session.eval("""
      (begin
        (debounce! "zz-test" 30 (lambda (v) (set! *zz-debounce-value* v)) "old")
        (debounce! "zz-test" 30 (lambda (v) (set! *zz-debounce-value* v)) "new"))
      """)

    wait_for(fn -> Session.eval("*zz-debounce-value*") == {:ok, ~s{"new"}} end)
    Process.sleep(40)
    assert Session.eval("*zz-debounce-value*") == {:ok, ~s{"new"}}
  end

  test "recipe inputs are quoted as data, never evaluated as source" do
    {:ok, _} =
      Session.eval(
        ~s{(command-palette--run-recipe (assoc "show a message in the echo area" *recipes*))}
      )

    assert Editor.render_state().minibuffer.prompt == "Message: "
    payload = ~s{x") (buffer-create "*recipe-injected*") ("}
    Editor.minibuffer_set_input(payload)
    press("RET")

    refute Buffer.exists?("*recipe-injected*")
  end

  test "no templated recipe is missing its input declarations" do
    assert Session.eval("""
           (filter (lambda (recipe)
                     (and (string-contains? (cadr recipe) "{{")
                          (null? (caddr recipe))))
                   *recipes*)
           """) == {:ok, "()"}

    {:ok, recipes} = Session.eval("(recipes)")
    refute recipes =~ "/abs/path"
  end

  test "a pending palette refresh cannot overwrite a later prompt" do
    press("s-k")
    type("open file split")
    press("C-g")
    press("M-x")

    Process.sleep(120)
    assert Editor.render_state().minibuffer.prompt == "M-x "
  end
end
