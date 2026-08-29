defmodule Compos.AgendaTest do
  @moduledoc """
  morg-agenda against real files, driven through the same key path the GUI
  uses. The buffer text is the plain listing and the card view is a
  projection of the same lines, so assertions read the text, the locals,
  and the block tree.
  """

  use ExUnit.Case

  alias Compos.Core.{Buffer, Editor, KeyDispatch, SchemeAPI, Session}

  @agenda "*Agenda*"

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  setup do
    dir = Path.join(System.tmp_dir!(), "compos-agenda-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()

    on_exit(fn ->
      Session.eval("(set! morg-agenda-files (list))")
      Session.eval("(set! *agenda-cache* (list))")
      if Buffer.exists?(@agenda), do: Compos.Core.kill_buffer(@agenda)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  # local dates, because the Scheme side reads `date +%F`
  defp day(offset) do
    {{y, m, d}, _} = :calendar.local_time()
    Date.new!(y, m, d) |> Date.add(offset)
  end

  defp stamp(offset), do: "<#{Date.to_iso8601(day(offset))}>"
  defp stamp(offset, time), do: "<#{Date.to_iso8601(day(offset))} #{time}>"

  defp open_agenda(dir) do
    {:ok, _} = Session.eval(~s[(set! morg-agenda-files (list "#{dir}"))])
    {:ok, _} = Session.eval(~s[(run-command "morg-agenda")])
    assert Editor.current_buffer() == @agenda
    @agenda
  end

  defp goto_line(buf, n) do
    {:ok, _} = Session.eval("(goto-char! (line-start-position #{n}))")
    Buffer.point(buf)
  end

  defp index(buf) do
    for [line, file, pos] <- Buffer.get_local(buf, "agenda-index") || [],
        do: %{line: line, file: file, pos: pos}
  end

  defp blocks(buf), do: (Buffer.get_local(buf, "render-blocks") || []) |> Enum.map(&pl/1)

  defp walk_blocks(b), do: [b | Enum.flat_map(b[:children] || [], &walk_blocks/1)]

  defp rows(buf) do
    blocks(buf)
    |> Enum.flat_map(&walk_blocks/1)
    |> Enum.filter(&((&1[:class] || "") =~ "agenda-row"))
  end

  defp cards(buf) do
    blocks(buf)
    |> Enum.flat_map(&walk_blocks/1)
    |> Enum.filter(&((&1[:class] || "") =~ "agenda-day"))
  end

  defp row_segs(row), do: Enum.map(row[:segs] || [], fn [c, t] -> {c, t} end)

  defp pl([{:sym, _} | _] = plist) do
    plist
    |> Enum.chunk_every(2)
    |> Map.new(fn [{:sym, k}, v] -> {String.to_atom(k), if(is_list(v), do: pl_list(v), else: v)} end)
  end

  defp pl(other), do: other

  defp pl_list(l), do: Enum.map(l, &pl/1)

  # --- the scan ---------------------------------------------------------------

  test "a dated heading lands on its day, with state, tags, time and file", %{dir: dir} do
    File.write!(Path.join(dir, "work.md"), """
    # TODO Standup with the team #{stamp(0, "09:30")} :work:
    notes under it
    ## DONE Old thing #{stamp(0)}
    """)

    buf = open_agenda(dir)
    text = Buffer.text(buf)

    assert text =~ "Standup with the team"
    assert text =~ "09:30"
    assert text =~ ":work:"
    assert text =~ "— work.md"

    # the card view carries the same facts as segs
    row = Enum.find(rows(buf), &(&1[:segs] |> inspect() =~ "Standup"))
    segs = row_segs(row)
    assert {"agenda-time", "09:30"} in segs
    assert {"agenda-badge agenda-todo", "TODO"} in segs
    assert {"agenda-tags", ":work:"} in segs
    assert {"agenda-file", "work.md"} in segs

    # DONE renders struck through, and the timestamp never shows in a title
    done = Enum.find(rows(buf), &(&1[:segs] |> inspect() =~ "Old thing"))
    assert done[:class] =~ "agenda-row-done"
    refute inspect(done[:segs]) =~ "<"
  end

  test "SCHEDULED and DEADLINE body lines attach to the heading above", %{dir: dir} do
    File.write!(Path.join(dir, "proj.md"), """
    # TODO Ship the release
    DEADLINE: #{stamp(2)}
    body text
    """)

    buf = open_agenda(dir)

    assert Buffer.text(buf) =~ "DEADLINE"
    assert Buffer.text(buf) =~ "Ship the release"
    # the entry points at the heading, not the planning line
    assert [%{pos: 0}] = index(buf)
  end

  test "an overdue deadline shows on today as late; DONE stays away", %{dir: dir} do
    File.write!(Path.join(dir, "late.md"), """
    # TODO Pay the invoice
    DEADLINE: #{stamp(-3)}
    # DONE Already paid
    DEADLINE: #{stamp(-3)}
    """)

    buf = open_agenda(dir)
    text = Buffer.text(buf)

    assert text =~ "DEADLINE 3d late"
    assert text =~ "Pay the invoice"
    refute text =~ "Already paid"
  end

  test "a # inside a code fence is not a heading", %{dir: dir} do
    File.write!(Path.join(dir, "code.md"), """
    ```sh
    # TODO fake heading #{stamp(0)}
    ```
    # TODO Real entry #{stamp(0)}
    """)

    buf = open_agenda(dir)

    refute Buffer.text(buf) =~ "fake heading"
    assert Buffer.text(buf) =~ "Real entry"
  end

  # --- keys -------------------------------------------------------------------

  test "n steps onto the entry and RET opens the file at its heading", %{dir: dir} do
    path = Path.join(dir, "work.md")
    File.write!(path, """
    some preamble
    # TODO Water the plants #{stamp(0)}
    """)

    buf = open_agenda(dir)
    Editor.set_window_buffer(buf)
    goto_line(buf, 1)

    press("n")
    [entry] = index(buf)
    line = Compos.Core.Text.line_index(Buffer.text(buf), Buffer.point(buf)) + 1
    assert line == entry.line

    press("RET")
    assert Editor.current_buffer() == path
    assert Buffer.point(path) == entry.pos
    assert Buffer.text(path) |> binary_part(entry.pos, 6) == "# TODO"
  end

  test "brackets move by week and dot returns to today", %{dir: dir} do
    File.write!(Path.join(dir, "weeks.md"), """
    # TODO Previous #{stamp(-7)}
    # TODO Current #{stamp(0)}
    # TODO Next #{stamp(7)}
    """)

    buf = open_agenda(dir)
    Editor.set_window_buffer(buf)
    assert Buffer.text(buf) =~ "Current"
    refute Buffer.text(buf) =~ "Previous"
    refute Buffer.text(buf) =~ "Next"

    press("]")
    assert Buffer.get_local(buf, "agenda-start-offset") == 7
    assert Buffer.text(buf) =~ "Next"
    refute Buffer.text(buf) =~ "Current"

    press("[")
    assert Buffer.get_local(buf, "agenda-start-offset") == 0
    assert Buffer.text(buf) =~ "Current"

    press("[")
    assert Buffer.get_local(buf, "agenda-start-offset") == -7
    assert Buffer.text(buf) =~ "Previous"
    refute Buffer.text(buf) =~ "Current"

    press(".")
    assert Buffer.get_local(buf, "agenda-start-offset") == 0
    assert Buffer.text(buf) =~ "Current"
  end

  test "the selected week survives refresh and mode restore", %{dir: dir} do
    File.write!(Path.join(dir, "next.md"), "# TODO Next week #{stamp(7)}\n")

    buf = open_agenda(dir)
    Editor.set_window_buffer(buf)
    press("]")
    assert Buffer.text(buf) =~ "Next week"

    press("g")
    assert Buffer.get_local(buf, "agenda-start-offset") == 7
    assert Buffer.text(buf) =~ "Next week"

    {:ok, _} = Session.eval(~s[(buffer-set-local! "#{buf}" 'render-blocks (list))])
    {:ok, _} = Session.eval(~s[(set-mode! "morg-agenda-mode")])

    assert Buffer.get_local(buf, "agenda-start-offset") == 7
    assert Buffer.text(buf) =~ "Next week"
  end

  test "a previous week keeps overdue planning on its original day", %{dir: dir} do
    File.write!(Path.join(dir, "past.md"), """
    # TODO Historical deadline
    DEADLINE: #{stamp(-7)}
    """)

    buf = open_agenda(dir)
    Editor.set_window_buffer(buf)
    assert Buffer.text(buf) =~ "7d late"

    press("[")
    assert Buffer.text(buf) =~ "Historical deadline"
    refute Buffer.text(buf) =~ "late"
  end

  test "TAB folds the day: the local, the card and the text agree", %{dir: dir} do
    File.write!(Path.join(dir, "work.md"), "# TODO One thing #{stamp(0)}\n")

    buf = open_agenda(dir)
    Editor.set_window_buffer(buf)
    [entry] = index(buf)
    goto_line(buf, entry.line)

    press("TAB")
    assert [_] = Buffer.get_local(buf, "agenda-closed-days")
    today = Enum.find(cards(buf), &(&1[:class] =~ "agenda-today"))
    refute inspect(today) =~ "agenda-row"
    assert [{_, _}] = Buffer.hidden(buf, "agenda")

    press("TAB")
    assert Buffer.get_local(buf, "agenda-closed-days") == []
    today = Enum.find(cards(buf), &(&1[:class] =~ "agenda-today"))
    assert inspect(today) =~ "agenda-row"
    assert Buffer.hidden(buf, "agenda") == []
  end

  test "the closed day survives a mode re-run, the diff-mode restore path", %{dir: dir} do
    File.write!(Path.join(dir, "work.md"), "# TODO One thing #{stamp(0)}\n")

    buf = open_agenda(dir)
    Editor.set_window_buffer(buf)
    [entry] = index(buf)
    goto_line(buf, entry.line)
    press("TAB")
    [closed] = Buffer.get_local(buf, "agenda-closed-days")

    # what a desktop restore does: locals stay, projections rebuild
    {:ok, _} = Session.eval(~s[(buffer-set-local! "#{buf}" 'render-blocks (list))])
    {:ok, _} = Session.eval(~s[(set-mode! "morg-agenda-mode")])

    assert Buffer.get_local(buf, "agenda-closed-days") == [closed]
    today = Enum.find(cards(buf), &(&1[:class] =~ "agenda-today"))
    refute inspect(today) =~ "agenda-row"
  end

  # --- clicks -----------------------------------------------------------------

  test "a day header click folds; an entry click visits", %{dir: dir} do
    path = Path.join(dir, "work.md")
    File.write!(path, "# TODO Click me #{stamp(0)}\n")

    buf = open_agenda(dir)
    Editor.set_window_buffer(buf)
    [entry] = index(buf)

    today = Enum.find(cards(buf), &(&1[:class] =~ "agenda-today"))
    head = Enum.find(walk_blocks(today), &(&1[:class] == "c-fold-head"))
    SchemeAPI.block_click(buf, head[:click])
    assert [_] = Buffer.get_local(buf, "agenda-closed-days")

    SchemeAPI.block_click(buf, "e-#{entry.line}")
    assert Editor.current_buffer() == path
  end

  # --- views and refresh ------------------------------------------------------

  test "C-c C-v toggles the plain listing and back", %{dir: dir} do
    File.write!(Path.join(dir, "work.md"), "# TODO One thing #{stamp(0)}\n")

    buf = open_agenda(dir)
    Editor.set_window_buffer(buf)
    assert Buffer.get_local(buf, "render-mode") == "blocks"

    press(["C-c", "C-v"])
    assert Buffer.get_local(buf, "render-mode") == false

    press(["C-c", "C-v"])
    assert Buffer.get_local(buf, "render-mode") == "blocks"
  end

  test "g re-reads a changed file past the mtime cache", %{dir: dir} do
    path = Path.join(dir, "work.md")
    File.write!(path, "# TODO First title #{stamp(0)}\n")

    buf = open_agenda(dir)
    Editor.set_window_buffer(buf)
    assert Buffer.text(buf) =~ "First title"

    File.write!(path, "# TODO Second title #{stamp(0)}\n")
    # mtime has one-second resolution; move it forward so the cache misses
    File.touch!(path, :calendar.local_time() |> shift_seconds(5))

    press("g")
    assert Buffer.text(buf) =~ "Second title"
    refute Buffer.text(buf) =~ "First title"
  end

  defp shift_seconds(datetime, s) do
    datetime
    |> :calendar.datetime_to_gregorian_seconds()
    |> Kernel.+(s)
    |> :calendar.gregorian_seconds_to_datetime()
  end

  test "no configured files shows the hint, not an empty week", %{dir: _dir} do
    {:ok, _} = Session.eval("(set! morg-agenda-files (list))")
    {:ok, _} = Session.eval(~s[(run-command "morg-agenda")])

    assert [empty] = blocks(@agenda)
    assert empty[:class] =~ "agenda-empty"
    assert empty[:text] =~ "morg-agenda-files"
  end
end
