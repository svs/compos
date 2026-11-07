defmodule Compos.FaceBatchTest do
  @moduledoc """
  A theme is hundreds of face writes. themes.scm owns the face table and
  puts a batch on the page as one change, so the page never renders a
  half-applied theme (a cleared default size moved every window's scroll).
  The Editor keeps only the map the page renders.
  """
  use ExUnit.Case, async: false
  alias Compos.Core.{Editor, Events, Session}

  defp ev!(code) do
    {:ok, out} = Session.eval(code)
    out
  end

  defp drain_changes(n \\ 0) do
    receive do
      {:editor_change, _} -> drain_changes(n + 1)
    after
      200 -> n
    end
  end

  setup do
    clear = fn -> ev!("(face-clear! 'zz-batch-a) (face-clear! 'zz-batch-b)") end
    clear.()
    on_exit(clear)
    :ok
  end

  test "a batch applies clears and sets in one broadcast" do
    ev!(~S{(set-face-attribute! 'zz-batch-a 'fg "red" 'weight "700")})
    Events.subscribe_editor()
    drain_changes()

    ev!(~S{(face-batch! '((clear zz-batch-a) (set zz-batch-a fg "blue") (set zz-batch-b bg "white") (set zz-batch-b fg "black")))})

    assert drain_changes() == 1
    faces = Editor.faces()
    assert faces["zz-batch-a"] == %{"fg" => "blue"}, "the clear forgot the weight"
    assert faces["zz-batch-b"] == %{"bg" => "white", "fg" => "black"}
  end

  test "a batch that changes nothing broadcasts nothing" do
    Events.subscribe_editor()
    drain_changes()
    ev!("(face-batch! '((clear zz-batch-never)))")
    assert drain_changes() == 0
  end

  test "the table and the page agree" do
    ev!(~S{(set-face-attribute! 'zz-batch-a 'fg "green" 'inherit 'dim)})
    ev!(~S{(set-face-attribute! 'zz-batch-a 'weight "600")})

    assert Editor.faces()["zz-batch-a"] == %{"fg" => "green", "inherit" => "dim", "weight" => "600"}
    assert ev!("(face-attribute 'zz-batch-a 'inherit)") == ~S{"dim"}
    assert ev!(~S{(and (member "zz-batch-a" (face-list)) #t)}) == "#t"
  end
end
