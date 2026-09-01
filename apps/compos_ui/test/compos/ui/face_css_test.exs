defmodule Compos.Ui.FaceCSSTest do
  use ExUnit.Case, async: true

  alias Compos.Ui.FaceCSS

  test "a face writes only the attributes it declares" do
    css = FaceCSS.css(%{"tint" => %{"bg" => "#eee"}})
    assert css =~ "--tint-bg:#eee;"
    assert css =~ ".f-tint{background:var(--tint-bg);}"
    refute css =~ "color:"
  end

  test "an attribute with no CSS meaning stays a variable" do
    css = FaceCSS.css(%{"writing" => %{"measure" => "64ch"}})
    assert css =~ "--writing-measure:64ch;"
    refute css =~ ".f-writing"
  end

  test "inherit takes an unset attribute from the parent, by reference" do
    faces = %{
      "dim" => %{"fg" => "#888"},
      "shadow" => %{"inherit" => "dim"},
      "warn" => %{"fg" => "#a50", "inherit" => "dim"}
    }

    css = FaceCSS.css(faces)
    # the class reads the parent's variable, so a remap of dim reaches shadow
    assert css =~ ".f-shadow{color:var(--dim-fg);}"
    # the variable exists too, for a reader that only knows var(--shadow-fg)
    assert css =~ "--shadow-fg:var(--dim-fg);"
    # an own attribute beats the inherited one
    assert css =~ ".f-warn{color:var(--warn-fg);}"
    assert css =~ "--warn-fg:#a50;"
  end

  test "inherit follows a chain and the first parent in a list wins" do
    faces = %{
      "a" => %{"fg" => "#111", "weight" => "700"},
      "b" => %{"fg" => "#222"},
      "c" => %{"inherit" => ["b", "a"]},
      "d" => %{"inherit" => "c"}
    }

    css = FaceCSS.css(faces)
    assert css =~ ".f-c{color:var(--b-fg);font-weight:var(--a-weight);}"
    assert css =~ ".f-d{color:var(--b-fg);font-weight:var(--a-weight);}"
  end

  test "an inherit cycle ends" do
    faces = %{"x" => %{"inherit" => "y", "fg" => "#1"}, "y" => %{"inherit" => "x"}}
    css = FaceCSS.css(faces)
    assert css =~ ".f-y{color:var(--x-fg);}"
  end

  test "priority orders the class rules, so the higher face wins on a shared span" do
    faces = %{
      "zebra" => %{"bg" => "#1", "priority" => "5"},
      "apple" => %{"bg" => "#2", "priority" => "10"},
      "mango" => %{"bg" => "#3"}
    }

    css = FaceCSS.css(faces)
    [_, classes] = String.split(css, "}", parts: 2)
    mango = :binary.match(classes, ".f-mango") |> elem(0)
    zebra = :binary.match(classes, ".f-zebra") |> elem(0)
    apple = :binary.match(classes, ".f-apple") |> elem(0)
    assert mango < zebra and zebra < apple
  end

  test "a ts- face styles the tree-sitter span as well" do
    css = FaceCSS.css(%{"ts-keyword" => %{"fg" => "#26356b", "weight" => "600"}})
    assert css =~ ".f-ts-keyword,.ts-keyword{color:var(--ts-keyword-fg);font-weight:var(--ts-keyword-weight);}"
  end

  test "symbols and atoms are accepted as names and values" do
    css = FaceCSS.css(%{"ts-keyword" => %{fg: "#1"}, "ts-label": %{inherit: :"ts-keyword"}})
    assert css =~ ".f-ts-label,.ts-label{color:var(--ts-keyword-fg);}"
  end
end
