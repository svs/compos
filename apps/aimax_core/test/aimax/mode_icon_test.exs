defmodule Aimax.ModeIconTest do
  @moduledoc """
  The icon tests that need a directory of files on disk.

  The registry itself is Scheme policy and lives in
  priv/tests/mode-icon-test.scm. These two stay here because they build a
  fixture directory, and Scheme has no way to remove one.
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Session}

  defp eval!(src) do
    {:ok, out} = Session.eval(src)
    out
  end

  describe "the lists" do
    setup do
      root = Path.join(System.tmp_dir!(), "mi-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "subdir"))
      File.write!(Path.join(root, "one.ex"), "x\n")
      File.write!(Path.join(root, "two.md"), "# x\n")

      on_exit(fn ->
        Aimax.Core.kill_buffer(root)
        File.rm_rf!(root)
      end)

      {:ok, root: root}
    end

    test "dired leads each row with the icon", %{root: root} do
      eval!(~s{(dired-open "#{root}")})
      text = Buffer.text(root)

      assert text =~ ~r/ +one\.ex/
      assert text =~ ~r/ +two\.md/
      assert text =~ ~r/ +subdir\//
      # ".." is a directory too, and it wears Dired's icon
      assert text =~ ~r/ +\.\./
    end

    test "the file prompt annotates with the same icon", %{root: root} do
      out =
        eval!(~s{(begin (set! *marginalia-file-dir* "#{root}/")
                        (annotate 'file (list "one.ex" "subdir/")))})

      assert out =~ ~r/ +elixir-mode/
      assert out =~ ~r/ +Dired/
    end
  end
end
