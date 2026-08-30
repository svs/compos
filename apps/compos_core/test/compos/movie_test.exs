defmodule Compos.MovieTest do
  @moduledoc "The frame-wide Provenance movie and its stream overlay."

  use ExUnit.Case, async: false

  alias Compos.Core.{Buffer, Editor, KeyDispatch, Session}

  defp eval!(source) do
    {:ok, printed} = Session.eval(source)
    printed
  end

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    name = "*movie-source-#{System.unique_integer([:positive])}*"
    {:ok, ^name} = Compos.Core.create_buffer(name, text: "base")

    on_exit(fn ->
      Editor.minibuffer_close()
      Editor.set_window_buffer("*scratch*")
      for buffer <- ["*movie-stream*", "*movie: #{name}*", name] do
        Compos.Core.kill_buffer(buffer)
      end
    end)

    %{name: name}
  end

  test "the stream seeks the frame-wide movie and q restores the work", %{name: name} do
    :ok = Buffer.insert_at(name, 4, "!", source: {:agent, "movie-test"})
    eval!(~s{(switch-to-buffer! "#{name}")})
    eval!(~s{(run-command "buffer-movie")})

    movie = "*movie: #{name}*"
    assert Buffer.text(movie) == "base"
    assert Editor.current_buffer() == "*movie-stream*"
    assert eval!(~s{(window-showing "#{movie}")}) != "#f"

    KeyDispatch.handle_key("n")
    assert Buffer.text(movie) == "base!"

    KeyDispatch.handle_key("q")
    assert Editor.current_buffer() == name
    refute Buffer.exists?(movie)
    refute Buffer.exists?("*movie-stream*")
  end
end
