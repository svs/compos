defmodule Aimax.OnChangeTest do
  use ExUnit.Case

  alias Aimax.Core
  alias Aimax.Core.{Buffer, Session}

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  test "scheme hook fires on edits from any source, with coalesced args" do
    src = uniq("watched")
    sink = uniq("sink")
    {:ok, _} = Core.create_buffer(src)
    {:ok, _} = Core.create_buffer(sink)

    {:ok, id} =
      Session.eval("""
      (on-change! "#{src}"
        (lambda (pos inserted deleted source)
          (buffer-append! "#{sink}"
            (string-append (number->string pos) ":" inserted ":"
                           (number->string deleted) ":" source "\\n"))))
      """)

    assert String.match?(id, ~r/^\d+$/)

    :ok = Buffer.append(src, "hello", source: :editor)
    Process.sleep(150)
    assert Buffer.text(sink) == "0:hello:0:editor\n"

    # a user burst coalesces into one firing
    :ok = Buffer.insert_at(src, 5, "a")
    :ok = Buffer.insert_at(src, 6, "b")
    Process.sleep(150)
    assert Buffer.text(sink) == "0:hello:0:editor\n5:ab:0:user\n"

    # removal stops firing
    {:ok, _} = Session.eval("(remove-on-change! #{id})")
    :ok = Buffer.append(src, "x")
    Process.sleep(120)
    assert Buffer.text(sink) == "0:hello:0:editor\n5:ab:0:user\n"
  end

  test "undo-sourced changes reach the hook (the fold/overlay heal path)" do
    src = uniq("watched")
    sink = uniq("sink")
    {:ok, _} = Core.create_buffer(src)
    {:ok, _} = Core.create_buffer(sink)

    {:ok, _} =
      Session.eval("""
      (on-change! "#{src}"
        (lambda (pos inserted deleted source)
          (buffer-append! "#{sink}" (string-append source "\\n"))))
      """)

    :ok = Buffer.append(src, "hi")
    Process.sleep(120)
    :ok = Buffer.undo(src)
    Process.sleep(120)
    assert Buffer.text(sink) =~ "undo"
  end
end
