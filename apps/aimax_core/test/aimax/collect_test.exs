defmodule Aimax.CollectTest do
  @moduledoc """
  C-c C-o turns a prompt into a buffer. The buffer keeps the prompt's
  behaviour: n/p preview, RET confirms, q cancels — same closures.
  """

  use ExUnit.Case

  alias Aimax.Core.{Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  defp log do
    {:ok, s} = Session.eval("*zz-log*")
    s
  end

  defp start_prompt! do
    {:ok, _} =
      Session.eval(~s{(begin
        (buffer-create "*zz-src*")
        (delete-other-windows!)
        (switch-to-buffer! "*zz-src*")
        (define *zz-log* '())
        (minibuffer-read-preview "Pick: "
          (list (list "alpha" "") (list "beta" "") (list "gamma" ""))
          (lambda (l) (set! *zz-log* (cons (string-append "sel:" l) *zz-log*)))
          (lambda (l) (set! *zz-log* (cons (string-append "ok:" l) *zz-log*)))
          (lambda () (set! *zz-log* (cons "cancel" *zz-log*)))))})
  end

  setup do
    Editor.minibuffer_close()
    Editor.completion_dismiss()
    Editor.set_pending([])
    Editor.delete_other_windows()

    on_exit(fn ->
      Editor.minibuffer_close()
      for b <- ["*zz-src*", "*Collect*"], do: Aimax.Core.kill_buffer(b)
      Editor.delete_other_windows()
    end)

    :ok
  end

  test "C-c C-o collects the candidates and previews the first one" do
    start_prompt!()
    press(["C-c", "C-o"])

    assert Editor.current_buffer() == "*Collect*"
    refute Editor.snapshot().minibuffer, "the prompt must close"

    text = Aimax.Core.Buffer.text("*Collect*")
    assert text =~ "alpha"
    assert text =~ "beta"
    assert text =~ "gamma"

    assert log() =~ ~s{"sel:alpha"}
    # neither confirm nor cancel ran: collect is the third way out
    refute log() =~ ~s{"ok:}
    refute log() =~ ~s{"cancel"}
  end

  test "n and p preview, RET confirms the line" do
    start_prompt!()
    press(["C-c", "C-o"])
    press(["n"])
    assert log() =~ ~s{"sel:beta"}

    press(["p"])
    assert {:ok, ~s{"sel:alpha"}} = Session.eval("(car *zz-log*)")

    # p on the first line stays on it — the header is not a candidate
    press(["p"])
    assert {:ok, ~s{"sel:alpha"}} = Session.eval("(car *zz-log*)")

    press(["n", "n"])
    press(["RET"])
    assert {:ok, ~s{"ok:gamma"}} = Session.eval("(car *zz-log*)")
    refute Aimax.Core.Buffer.exists?("*Collect*")
  end

  test "q runs the prompt's cancel handler" do
    start_prompt!()
    press(["C-c", "C-o"])
    press(["q"])

    assert {:ok, ~s{"cancel"}} = Session.eval("(car *zz-log*)")
    refute Aimax.Core.Buffer.exists?("*Collect*")
  end

  test "the preview lands in the window the prompt ran in, not in the list" do
    start_prompt!()
    press(["C-c", "C-o"])
    press(["n"])

    {:ok, wins} = Session.eval("(window-list)")
    assert wins =~ "*zz-src*", "the source window must survive: #{wins}"
    assert wins =~ "*Collect*"
    assert Editor.current_buffer() == "*Collect*", "point stays in the list"
  end

  test "collect without a prompt says so" do
    assert {:ok, _} = Session.eval(~s{(run-command "minibuffer-collect")})
    assert Editor.snapshot().echo =~ "No prompt"
  end
end
