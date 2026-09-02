defmodule Compos.Ui.FaceCSS do
  @moduledoc """
  The one place a face becomes CSS.

  The editor holds faces as `%{name => %{attr => value}}`. This module
  turns that map into one stylesheet: a `--NAME-ATTR` variable per
  attribute, and a `.f-NAME` class per face. A face named `ts-SCOPE` also
  styles the `.ts-SCOPE` span that tree-sitter highlighting emits, so a
  theme or a `defface!` owns every syntax colour, weight and slant.

  A face writes ONLY the attributes it declares. Writing them all put
  `color:inherit` on a face that names no foreground, and a span carries
  both classes, so a background-only overlay erased the syntax colour
  under it. Emacs reads an unspecified attribute as "leave it alone"; so
  does this.

  Two attributes are not CSS:

  * `inherit` names one face or a list of faces. An attribute the face
    does not set comes from the first parent that sets it, as in Emacs.
    The class rule reads the parent's variable, so a per-buffer remap of
    the parent reaches the child.
  * `priority` orders the class rules. Two overlays on one span resolve
    by rule order at equal specificity, so the face with the higher
    priority is written later and wins. Emacs overlay priority, on the
    face. The default is 0, and ties break by name, so the order is
    stable across renders.
  """

  @meta ["inherit", "priority"]

  @doc "The stylesheet for FACES: the variables block, then the class rules."
  def css(faces) when map_size(faces) == 0, do: ""

  def css(faces) do
    faces = Map.new(faces, fn {name, attrs} -> {to_string(name), stringify(attrs)} end)
    sources = Map.new(faces, fn {name, _} -> {name, sources(faces, name)} end)

    vars =
      faces
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map_join("", fn {name, _} -> vars(name, sources[name]) end)

    classes =
      faces
      |> Enum.filter(fn {name, _} -> name =~ ~r/^[a-zA-Z0-9_-]+$/ end)
      |> Enum.sort_by(fn {name, attrs} -> {priority(attrs), name} end)
      |> Enum.map_join("", fn {name, _} -> class(name, sources[name]) end)

    ":root{#{vars}}#{classes}"
  end

  @doc """
  The effective attributes of FACE: its own, then what it inherits. Each
  value is `{source_face, value}`. `inherit` and `priority` never inherit.
  """
  def sources(faces, name), do: sources(faces, name, [name])

  defp sources(faces, name, seen) do
    own = Map.get(faces, name, %{})

    inherited =
      own
      |> Map.get("inherit")
      |> parents()
      |> Enum.reject(&(&1 in seen))
      # the FIRST parent wins, so fold the list from the back
      |> Enum.reverse()
      |> Enum.reduce(%{}, fn parent, acc ->
        Map.merge(acc, sources(faces, parent, [parent | seen]))
      end)

    # an empty value is no value: the attribute inherits, or stays unset
    own_sources =
      own
      |> Map.drop(@meta)
      |> Map.reject(fn {_, v} -> v == "" end)
      |> Map.new(fn {k, v} -> {k, {name, v}} end)

    Map.merge(inherited, own_sources)
  end

  defp parents(nil), do: []
  defp parents(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp parents(one), do: [to_string(one)]

  defp priority(attrs) do
    case Map.get(attrs, "priority") do
      nil -> 0
      n when is_integer(n) -> n
      s -> s |> to_string() |> Integer.parse() |> elem_or(0)
    end
  end

  defp elem_or({n, _}, _), do: n
  defp elem_or(:error, default), do: default

  # every effective attribute is a variable: the face's own as a literal,
  # an inherited one as a reference to the parent's variable, so a reader
  # that only knows `var(--NAME-ATTR)` (the static stylesheet) sees the
  # inherited value too
  defp vars(name, sources) do
    Enum.map_join(sources, "", fn
      {k, {^name, v}} -> "--#{name}-#{k}:#{v};"
      {k, {parent, _}} -> "--#{name}-#{k}:var(--#{parent}-#{k});"
    end)
  end

  defp class(name, sources) do
    body =
      sources
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {k, {source, _}} -> prop(source, k) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("")

    cond do
      body == "" -> ""
      String.starts_with?(name, "ts-") -> ".f-#{name},.#{name}{#{body}}"
      true -> ".f-#{name}{#{body}}"
    end
  end

  # one face attribute -> one CSS declaration, reading the variable of the
  # face that set it. An attribute with no CSS meaning (writing-mode's
  # 'measure) stays a variable.
  defp prop(face, attr) do
    case attr do
      "fg" -> "color:var(--#{face}-fg);"
      "bg" -> "background:var(--#{face}-bg);"
      "weight" -> "font-weight:var(--#{face}-weight);"
      "style" -> "font-style:var(--#{face}-style);"
      "family" -> "font-family:var(--#{face}-family);"
      "size" -> "font-size:var(--#{face}-size);"
      "decoration" -> "text-decoration:var(--#{face}-decoration);"
      _ -> nil
    end
  end

  defp stringify(attrs) do
    Map.new(attrs, fn
      {k, v} when is_list(v) -> {to_string(k), Enum.map(v, &to_string/1)}
      {k, v} -> {to_string(k), to_string(v)}
    end)
  end
end
