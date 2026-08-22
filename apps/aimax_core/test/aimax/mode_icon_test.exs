defmodule Aimax.ModeIconTest do
  @moduledoc """
  One glyph names a mode. Dired, ibuffer and the prompts all read the same
  registry, so a chat looks like a chat wherever it is listed. The glyphs
  are Nerd Font characters: one cell each, in the colour of the text.
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Session}

  defp eval!(src) do
    {:ok, out} = Session.eval(src)
    out
  end

  describe "the registry" do
    test "a mode answers with its own icon" do
      assert eval!(~s{(mode-icon "chat-mode")}) == ~s{""}
      assert eval!(~s{(mode-icon "Dired")}) == ~s{""}
      assert eval!(~s{(mode-icon "elixir-mode")}) == ~s{""}
    end

    test "a mode that declares none reads as a plain document" do
      assert eval!(~s{(mode-icon "zz-no-such-mode")}) == ~s{""}
      assert eval!(~s{(mode-icon #f)}) == ~s{""}
    end

    test "mode-icon! declares one, and declaring again replaces it" do
      eval!(~s{(mode-icon! "zz-icon-mode" "")})
      assert eval!(~s{(mode-icon "zz-icon-mode")}) == ~s{""}

      eval!(~s{(mode-icon! "zz-icon-mode" "")})
      assert eval!(~s{(mode-icon "zz-icon-mode")}) == ~s{""}
    end

    test "mode-label writes the icon in front of the name" do
      assert eval!(~s{(mode-label "chat-mode")}) == ~s{" chat-mode"}
      assert eval!(~s{(mode-label #f)}) == ~s{" Fundamental"}
    end

    test "a file name wears the icon of the mode it would open in" do
      assert eval!(~s{(file-icon "a.ex")}) == ~s{""}
      assert eval!(~s{(file-icon "a.md")}) == ~s{""}
      assert eval!(~s{(file-icon "a.rs")}) == ~s{""}
      # a listing marks a directory with a trailing slash
      assert eval!(~s{(file-icon "sub/")}) == ~s{""}
      # a name no rule claims still gets an icon
      assert eval!(~s{(file-icon "LICENSE")}) == ~s{""}
    end

    test "a buffer wears the icon of the mode it is in" do
      eval!(~s{(buffer-create "*zz-icon*")})
      eval!(~s{(buffer-set-local! "*zz-icon*" 'mode-name "chat-mode")})

      assert eval!(~s{(buffer-icon "*zz-icon*")}) == ~s{""}

      Aimax.Core.kill_buffer("*zz-icon*")
    end
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

    test "the switcher leads each row's annotation with the icon" do
      eval!(~s{(buffer-create "*zz-icon-chat*")})
      eval!(~s{(buffer-set-local! "*zz-icon-chat*" 'mode-name "chat-mode")})
      eval!(~s{(run-command "switch-to-buffer")})

      # the annotation follows the name, and the icon leads it
      assert Buffer.text("*switch*") =~ ~r/\*zz-icon-chat\* +\x{F086}/u

      eval!(~s{(run-command "switch-quit")})
      Aimax.Core.kill_buffer("*zz-icon-chat*")
    end

    test "the buffer prompt annotates with the same icon" do
      eval!(~s{(buffer-create "*zz-icon-chat2*")})
      eval!(~s{(buffer-set-local! "*zz-icon-chat2*" 'mode-name "chat-mode")})

      out = eval!(~s{(annotate 'buffer (list "*zz-icon-chat2*"))})
      assert out =~ ~r/ +chat-mode/

      Aimax.Core.kill_buffer("*zz-icon-chat2*")
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
