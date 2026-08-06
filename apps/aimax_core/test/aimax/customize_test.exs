defmodule Aimax.CustomizeTest do
  @moduledoc "defcustom registry, custom file persistence, buffer-face remapping."

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(str), do: str |> String.graphemes() |> press()

  # Session.eval returns the value printed write-style
  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp custom_file, do: Path.join(Aimax.Core.home(), "custom.scm")

  setup do
    File.rm(custom_file())
    Editor.minibuffer_close()
    Editor.set_pending([])
    on_exit(fn -> Editor.minibuffer_close() end)
    :ok
  end

  describe "defcustom registry" do
    test "defines the variable with its default" do
      eval!("(defcustom 'cz-alpha 42 \"A test knob.\" 'group 'test 'type 'number)")
      assert eval!("cz-alpha") == "42"
    end

    test "an existing user binding beats the default" do
      eval!("(define cz-user-set \"mine\")")
      eval!("(defcustom 'cz-user-set \"default\" \"Doc.\")")
      assert eval!("cz-user-set") == ~s{"mine"}
    end

    test "describe-variable-data returns value, doc, group" do
      eval!("(defcustom 'cz-desc 7 \"Described.\" 'group 'test)")
      d = eval!("(describe-variable-data 'cz-desc)")
      assert d =~ "value 7"
      assert d =~ ~s{doc "Described."}
      assert d =~ "group test"
    end

    test "customize-apropos matches names and docs" do
      eval!("(defcustom 'cz-needle-var 1 \"Plain.\")")
      eval!("(defcustom 'cz-other 2 \"Contains needle in doc.\")")
      names = eval!("(map (lambda (d) (custom--plist-get d 'name)) (customize-apropos \"needle\"))")
      assert names =~ "cz-needle-var"
      assert names =~ "cz-other"
    end

    test "setter runs on customize-set!" do
      eval!("(defcustom 'cz-watched 0 \"Doc.\" 'set (lambda (v) (set-symbol-value! 'cz-witness v)))")
      eval!("(customize-set! 'cz-watched 9)")
      assert eval!("cz-watched") == "9"
      assert eval!("cz-witness") == "9"
    end
  end

  describe "custom file persistence" do
    test "customize-save! writes a file that round-trips" do
      eval!("(defcustom 'cz-saved \"a\" \"Doc.\")")
      eval!("(customize-save! 'cz-saved \"b\")")

      content = File.read!(custom_file())
      assert content =~ "(custom-set-variables!"
      assert content =~ ~s{'(cz-saved "b")}

      # simulate the next boot: reset the var, then load the custom file
      eval!("(set-symbol-value! 'cz-saved \"a\")")
      eval!("(load \"#{custom_file()}\")")
      assert eval!("cz-saved") == ~s{"b"}
    end

    test "customize-save-face! persists and wins over load-theme" do
      eval!("(customize-save-face! 'default 'family \"TestFont\")")
      assert File.read!(custom_file()) =~ ~s{'(default (family "TestFont"))}

      eval!("(load-theme \"paper\")")
      faces = Editor.render_state().faces
      assert faces["default"]["family"] == "TestFont"
    end

    test "saved variable values load at the defcustom default stage" do
      # what happens at boot: custom file applied, later defcustom must respect it
      eval!("(custom-set-variables! '(cz-early \"fromfile\"))")
      eval!("(defcustom 'cz-early \"default\" \"Doc.\")")
      assert eval!("cz-early") == ~s{"fromfile"}
    end
  end

  describe "buffer-face remapping" do
    defp fresh_buffer(name, text) do
      Editor.minibuffer_close()
      Editor.delete_other_windows()
      Editor.set_window_buffer(name)
      :ok = Buffer.append(name, text, source: :editor)
      name
    end

    test "buffer-face! renders CSS vars into the style local" do
      buf = fresh_buffer("cz-face-#{System.unique_integer([:positive])}", "text")

      eval!(~s{(buffer-face! 'family "Spectral" 'size "17px")})

      style = Buffer.get_local(buf, "style")
      assert style =~ "--default-family:Spectral;"
      assert style =~ "--default-size:17px;"
      assert Buffer.get_local(buf, "face-remap") != nil
    end

    test "face-remap! is per-face and re-remapping replaces" do
      buf = fresh_buffer("cz-remap-#{System.unique_integer([:positive])}", "text")

      eval!(~s{(face-remap! 'org-level-1 'size "22px")})
      eval!(~s{(buffer-face! 'family "Serif")})
      eval!(~s{(buffer-face! 'family "Mono")})

      style = Buffer.get_local(buf, "style")
      assert style =~ "--org-level-1-size:22px;"
      assert style =~ "--default-family:Mono;"
      refute style =~ "Serif"
    end

    test "M-x customize chains picker into value prompt and saves" do
      eval!("(defcustom 'cz-interactive \"before\" \"Interactively set.\")")

      press(["M-x"])
      type("customize")
      press(["RET"])
      # variable picker
      type("cz-interactive")
      press(["RET"])
      # value prompt — a Scheme expression
      assert Editor.render_state().minibuffer != nil
      type(~s{"after"})
      press(["RET"])

      assert eval!("cz-interactive") == ~s{"after"}
      assert File.read!(custom_file()) =~ ~s{'(cz-interactive "after")}
    end

    test "org-mode applies the customized font" do
      eval!(~s{(customize-set! 'org-font-family "CustomOrgFont")})

      buf = fresh_buffer("cz-org-#{System.unique_integer([:positive])}.org", "* headline\n")
      eval!(~s{(set-mode! "org-mode")})

      assert Buffer.get_local(buf, "style") =~ "--default-family:CustomOrgFont;"
    end
  end
end
