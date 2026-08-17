defmodule Aimax.OnChangeTest do
  use ExUnit.Case

  alias Aimax.Core
  alias Aimax.Core.{Buffer, Editor, Session}

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # rules fire only for visible buffers, so a watched buffer goes into the
  # window first — the same state a reader's buffer is in
  defp show(buf) do
    Editor.delete_other_windows()
    Editor.set_window_buffer(buf)
  end

  test "scheme hook fires on edits from any source, with coalesced args" do
    src = uniq("watched")
    sink = uniq("sink")
    {:ok, _} = Core.create_buffer(src)
    {:ok, _} = Core.create_buffer(sink)
    show(src)

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
    show(src)

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

  test "a set-local phantom change does not fire the hook" do
    src = uniq("watched")
    sink = uniq("sink")
    {:ok, _} = Core.create_buffer(src)
    {:ok, _} = Core.create_buffer(sink)
    show(src)

    # the morg regression: a handler that writes a local on every change
    # fed itself through the :locals broadcast, forever, at one full core
    {:ok, _} =
      Session.eval("""
      (on-change! "#{src}"
        (lambda (pos inserted deleted source)
          (buffer-set-local! "#{src}" 'probe-touch #t)
          (buffer-append! "#{sink}" (string-append source "\\n"))))
      """)

    :ok = Buffer.set_local(src, "some-local", 1)
    Process.sleep(150)
    assert Buffer.text(sink) == ""

    # a real edit still fires, and the handler's own set-local does not
    # re-fire it
    :ok = Buffer.append(src, "hi")
    Process.sleep(300)
    assert Buffer.text(sink) == "user\n"
  end

  test "an invisible buffer parks the work and fires once when shown" do
    src = uniq("hidden")
    sink = uniq("sink")
    other = uniq("screen")
    {:ok, _} = Core.create_buffer(src)
    {:ok, _} = Core.create_buffer(sink)
    {:ok, _} = Core.create_buffer(other)
    show(other)

    {:ok, _} =
      Session.eval("""
      (on-change! "#{src}"
        (lambda (pos inserted deleted source)
          (buffer-append! "#{sink}" (string-append inserted ":" source "\\n"))))
      """)

    :ok = Buffer.append(src, "one", source: :editor)
    :ok = Buffer.append(src, "two", source: :editor)
    Process.sleep(200)
    assert Buffer.text(sink) == ""

    # showing the buffer flushes the parked redo, coalesced into one call
    show(src)
    Process.sleep(150)
    assert Buffer.text(sink) == "onetwo:editor\n"
  end

  test "a hidden buffer in the current buffer's group still fires" do
    src = uniq("grouped")
    sink = uniq("sink")
    screen = uniq("screen")
    {:ok, _} = Core.create_buffer(src)
    {:ok, _} = Core.create_buffer(sink)
    {:ok, _} = Core.create_buffer(screen)
    :ok = Buffer.set_local(src, "group", "ws")
    :ok = Buffer.set_local(screen, "group", "ws")
    show(screen)

    {:ok, _} =
      Session.eval("""
      (on-change! "#{src}"
        (lambda (pos inserted deleted source)
          (buffer-append! "#{sink}" inserted)))
      """)

    :ok = Buffer.append(src, "sibling", source: :editor)
    Process.sleep(150)
    assert Buffer.text(sink) == "sibling"
  end

  test "an eager hook fires while the buffer is invisible" do
    src = uniq("hidden")
    sink = uniq("sink")
    other = uniq("screen")
    {:ok, _} = Core.create_buffer(src)
    {:ok, _} = Core.create_buffer(sink)
    {:ok, _} = Core.create_buffer(other)
    show(other)

    {:ok, _} =
      Session.eval("""
      (on-change! "#{src}"
        (lambda (pos inserted deleted source)
          (buffer-append! "#{sink}" inserted))
        'eager)
      """)

    :ok = Buffer.append(src, "now", source: :editor)
    Process.sleep(150)
    assert Buffer.text(sink) == "now"
  end
end
