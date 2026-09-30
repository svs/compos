defmodule Compos.Core.JitLock do
  @moduledoc """
  Emacs jit-lock: faces for the text a window draws, and no other text.

  The buffer marks the text it handed out with the `fontified` text
  property, as Emacs does. Display asks for the lines it builds. The
  buffer answers with the parts that carry no `fontified` and marks them.
  Scheme runs `fontification-functions` on each part and paints overlays.

  `fontified` is not sticky, so typed text carries none. An edit also
  takes `fontified` off the whole lines it touches (Emacs
  `jit-lock-after-change`), so only those lines run again.

  A part is byte positions at one buffer version, and Scheme paints it
  later. An edit between the two moves the bytes. So the runner gets the
  version, and a paint for an old version changes nothing. The mark holds
  the version as its value, and the mark moved with the text, so the
  buffer can take back exactly the text of that late paint, where it is
  now, and the next draw asks for it again.

  The switch is global and off by default. While it is off, Display asks
  nothing and a buffer marks nothing.
  """

  alias Compos.Core.{Itree, Lane, Session, TextProps}

  @key {__MODULE__, :on}
  @prop "fontified"
  # the Scheme function that runs fontification-functions on one range
  @runner "jit-lock--fontify"

  @doc "The text property that marks fontified text."
  def prop, do: @prop

  @doc "True while some Scheme function is on `fontification-functions`."
  def on?, do: :persistent_term.get(@key, false)

  @doc "Scheme turns the switch on and off as the hook gains and loses functions."
  def enable(on?) when is_boolean(on?) do
    if on?() != on?, do: :persistent_term.put(@key, on?)
    :ok
  end

  @doc "True when PROPS marks any text as fontified."
  def marked?(props), do: Map.has_key?(props, @prop)

  @doc "The parts of START..STOP that carry no `fontified`, in order."
  def gaps(props, start, stop) when is_map(props) do
    props |> Map.get(@prop) |> Itree.query(start, stop) |> gaps(start, stop)
  end

  # DONE is a sorted, disjoint list of the marked spans.
  def gaps(done, start, stop) when is_list(done) do
    {acc, pos} =
      Enum.reduce(done, {[], start}, fn span, {acc, pos} ->
        {s, e} = span_bounds(span)

        cond do
          e <= pos or s >= stop -> {acc, pos}
          s > pos -> {[{pos, s} | acc], max(pos, e)}
          true -> {acc, max(pos, e)}
        end
      end)

    acc = if pos < stop, do: [{pos, stop} | acc], else: acc
    Enum.reverse(acc)
  end

  defp span_bounds({s, e}), do: {s, e}
  defp span_bounds({s, e, _}), do: {s, e}

  @doc """
  Mark START..STOP as fontified. The value names the request, VERSION and
  START, so a late paint can find its own text after the text moved.
  """
  def mark(props, start, stop, version), do: TextProps.put(props, start, stop, @prop, [version, start])

  @doc "Take the mark off START..STOP: an edit touched these lines."
  def touch(props, start, stop), do: TextProps.remove(props, start, stop, [@prop])

  @doc "Take every mark off: the next draw fontifies its lines again."
  def forget(props), do: Map.delete(props, @prop)

  @doc """
  Take off the mark of the request VERSION, START, where its text is now.
  A painter that widened its range paints under another START: then every
  mark of VERSION goes, and the next draw asks for all of them again.
  """
  def forget_request(props, version, start) do
    case Map.get(props, @prop) do
      nil ->
        props

      tree ->
        own = Itree.reject(tree, fn {_, _, v} -> v == [version, start] end)

        tree =
          if Itree.size(own) == Itree.size(tree),
            do: Itree.reject(tree, fn {_, _, v} -> match?([^version, _], v) end),
            else: own

        if tree == nil, do: Map.delete(props, @prop), else: Map.put(props, @prop, tree)
    end
  end

  @doc """
  Run the Scheme runner on each range, on the buffer's lane, off the
  caller's process. The buffer process calls this: it must not wait on
  Scheme, and Scheme calls back into the buffer.
  """
  def dispatch(_name, _version, []), do: :ok

  def dispatch(name, version, ranges) do
    Task.start(fn ->
      if Session.ready?() do
        lane = Lane.for_buffer(name)

        for {s, e} <- ranges do
          try do
            Session.call_named(@runner, [name, s, e, version], nil, 30_000, lane)
          catch
            _, _ -> :ok
          end
        end
      end
    end)

    :ok
  end
end
