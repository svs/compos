defmodule Aimax.ProjectSearchTest do
  @moduledoc """
  project-ripgrep: one rg run, the matches are candidates, the highlighted
  one previews in the invoking window and RET jumps to it.
  project-find-file: the root comes first, then directories and files. The
  directory you enter lists itself and its children.
  """

  use ExUnit.Case

  alias Aimax.Core.{Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  defp eval!(src) do
    {:ok, out} = Session.eval(src)
    out
  end

  defp window_buffer, do: eval!("(window-buffer (active-window))")

  setup do
    Editor.minibuffer_close()
    Editor.completion_dismiss()
    Editor.set_pending([])
    Editor.delete_other_windows()

    root = Path.join(System.tmp_dir!(), "ps-proj-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/a.txt"), "one\nneedle here\nthree\n")
    File.write!(Path.join(root, "lib/b.txt"), "alpha\nbeta\nneedle again\n")
    File.write!(Path.join(root, "top.txt"), "nothing to find\n")
    {_, 0} = System.cmd("git", ["init", "-q"], cd: root)

    on_exit(fn ->
      Editor.minibuffer_close()

      for f <- ["lib/a.txt", "lib/b.txt", "top.txt"],
          do: Aimax.Core.kill_buffer(Path.join(root, f))

      Aimax.Core.kill_buffer("*zz-ps*")
      Aimax.Core.kill_buffer(root)
      Editor.delete_other_windows()
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  describe "rg--parse" do
    test "reads the path, the line number and the text" do
      out = eval!(~s{(rg--parse "lib/a.txt:2:needle here")})
      assert out =~ ~s{"lib/a.txt:2"}
      assert out =~ ~s{"lib/a.txt"}
      assert out =~ "2"
      assert out =~ ~s{"needle here"}
    end

    test "keeps every colon in the matched text" do
      assert eval!(~s{(rg--parse "a.ex:7:  key: value: more")}) =~ ~s{"key: value: more"}
    end

    test "drops the leading ./ rg prints for an explicit search path" do
      assert eval!(~s{(rg--parse "./lib/a.txt:2:needle")}) =~ ~s{("lib/a.txt:2" "lib/a.txt"}
    end

    test "drops a line that carries no line number" do
      assert {:ok, "#f"} = Session.eval(~s{(rg--parse "rg: no such file")})
      assert {:ok, "#f"} = Session.eval(~s{(rg--parse "")})
    end
  end

  describe "project-ripgrep" do
    test "agent policy can consume project search as structured data", %{root: root} do
      assert {:ok, matches} =
               Session.eval(~s{
                 (with-edit-author "agent:orientation"
                   (lambda () (project-search-matches "#{root}" "needle")))})

      assert matches =~ ~s{"lib/a.txt:2" "lib/a.txt" 2 "needle here"}
      assert matches =~ ~s{"lib/b.txt:3" "lib/b.txt" 3 "needle again"}
    end

    test "RET on the first match opens that file at that line", %{root: root} do
      eval!(~s{(project-ripgrep-in "#{root}" "needle")})

      mb = Editor.render_state().minibuffer
      labels = Enum.map(mb.candidates, & &1.label)
      assert "lib/a.txt:2" in labels
      assert "lib/b.txt:3" in labels
      refute Enum.any?(labels, &String.starts_with?(&1, "top.txt"))
      assert Enum.find(mb.candidates, &(&1.label == "lib/a.txt:2")).hint == "needle here"

      press("RET")

      assert eval!("(current-buffer)") == ~s{"#{root}/lib/a.txt"}
      # line 2 starts after "one\n"
      assert eval!("(point)") == "4"
    end

    test "the highlighted match previews, C-g puts the old buffer back", %{root: root} do
      eval!(~s{(begin (buffer-create "*zz-ps*") (switch-to-buffer! "*zz-ps*"))})
      eval!(~s{(project-ripgrep-in "#{root}" "needle")})

      # selection starts on the first match; C-n moves to the second and
      # the invoking window follows it
      press(["C-n"])
      assert window_buffer() == ~s{"#{root}/lib/b.txt"}

      press(["C-g"])
      assert window_buffer() == ~s{"*zz-ps*"}
    end

    test "a pattern with no match says so and opens no prompt", %{root: root} do
      eval!(~s{(project-ripgrep-in "#{root}" "zzz-no-such-text")})
      refute Editor.render_state().minibuffer
    end

    test "the command is registered and C-x p g runs it" do
      assert eval!(~s{(command-doc "project-ripgrep")}) =~ "ripgrep"
      assert eval!(~s{(key-for-command "project-ripgrep")}) == ~s{"C-x p g"}
    end
  end

  describe "project-find-file candidates" do
    test "project-switch-project enters the selected project's group", %{root: root} do
      mail = "zz-ps-mail-#{System.unique_integer([:positive])}"

      eval!(~s{
        (begin
          (buffer-create "#{mail}")
          (buffer-add-group! "#{mail}" (group-ensure-record! "#{mail}"))
          (switch-to-buffer! "#{mail}")
          (switch-to-group! "#{mail}")
          (project-remember! "#{root}"))})

      on_exit(fn ->
        eval!(~s{
          (begin
            (let ((mail-id (group-resolve-id "#{mail}"))
                  (project-id (group-resolve-id "#{root}")))
              (when mail-id (group-record-delete! mail-id))
              (when project-id (group-record-delete! project-id)))
            #t)})

        Aimax.Core.kill_buffer(mail)
      end)

      press(["C-x", "p", "p"])
      press(String.graphemes(root))
      press("RET")
      press("RET")

      assert eval!("(current-buffer)") == ~s{"#{root}"}
      assert eval!("(group-name (frame-group))") == ~s{"#{root}"}
      assert eval!("(buffer-in-group? (current-buffer) (frame-group))") == "#t"
    end

    test "project-switch-project with a prefix can create an explicit destination", %{root: root} do
      source = "zz-ps-prefix-source-#{System.unique_integer([:positive])}"
      target = "zz-ps-prefix-target-#{System.unique_integer([:positive])}"

      eval!(~s{
        (begin
          (buffer-create "#{source}")
          (buffer-add-group! "#{source}" (group-ensure-record! "#{source}"))
          (switch-to-buffer! "#{source}")
          (switch-to-group! "#{source}")
          (project-remember! "#{root}"))})

      on_exit(fn ->
        eval!(~s{
          (begin
            (for-each
              (lambda (name)
                (let ((id (group-resolve-id name)))
                  (when id (group-record-delete! id))))
              (list "#{source}" "#{target}" "#{root}"))
            #t)})

        Aimax.Core.kill_buffer(source)
      end)

      press(["C-u", "C-x", "p", "p"])
      assert Editor.render_state().minibuffer.prompt == "Switch to project: "

      press(String.graphemes(root))
      press("RET")
      assert Editor.render_state().minibuffer.prompt == "Switch project to group: "

      press(String.graphemes(target))
      press("RET")
      assert Editor.render_state().minibuffer.prompt == "Find file in #{Path.basename(root)}: "

      press("RET")

      assert eval!("(current-buffer)") == ~s{"#{root}"}
      assert eval!("(group-name (frame-group))") == ~s{"#{target}"}
      assert eval!(~s{(buffer-in-group? "#{root}" "#{target}")}) == "#t"
      assert eval!(~s{(group-resolve-id "#{target}")}) != "#f"
      assert eval!(~s{(group-resolve-id "#{root}")}) == "#f"
    end

    test "cancelling the explicit group choice preserves the current group", %{root: root} do
      source = "zz-ps-prefix-cancel-#{System.unique_integer([:positive])}"
      target = "zz-ps-prefix-unused-#{System.unique_integer([:positive])}"

      eval!(~s{
        (begin
          (buffer-create "#{source}")
          (buffer-add-group! "#{source}" (group-ensure-record! "#{source}"))
          (group-ensure-record! "#{target}")
          (switch-to-buffer! "#{source}")
          (switch-to-group! "#{source}")
          (project-remember! "#{root}"))})

      on_exit(fn ->
        eval!(~s{
          (begin
            (for-each
              (lambda (name)
                (let ((id (group-resolve-id name)))
                  (when id (group-record-delete! id))))
              (list "#{source}" "#{target}" "#{root}"))
            #t)})

        Aimax.Core.kill_buffer(source)
      end)

      press(["C-u", "C-x", "p", "p"])
      press(String.graphemes(root))
      press(["RET", "C-g"])

      refute Editor.render_state().minibuffer
      assert eval!("(current-buffer)") == ~s{"#{source}"}
      assert eval!("(group-name (frame-group))") == ~s{"#{source}"}
      assert eval!(~s{(group-resolve-id "#{root}")}) == "#f"
    end

    test "find-file uses the selected frame group without a prefix", %{root: root} do
      source = "zz-ps-find-current-#{System.unique_integer([:positive])}"
      path = Path.join(root, "top.txt")

      eval!(~s{
        (begin
          (buffer-create "#{source}")
          (buffer-add-group! "#{source}" (group-ensure-record! "#{source}"))
          (switch-to-buffer! "#{source}")
          (switch-to-group! "#{source}"))})

      on_exit(fn ->
        eval!(~s{
          (let ((id (group-resolve-id "#{source}")))
            (when id (group-record-delete! id)))})

        Aimax.Core.kill_buffer(source)
      end)

      press(["C-x", "C-f"])
      assert Editor.render_state().minibuffer.prompt == "Find file: "
      press(String.graphemes(path))
      press("RET")

      assert eval!(~s{(buffer-in-group? "#{path}" "#{source}")}) == "#t"
    end

    test "find-file-in-group creates and switches to a new chosen group before visiting", %{
      root: root
    } do
      source = "zz-ps-find-source-#{System.unique_integer([:positive])}"
      target = "zz-ps-find-target-#{System.unique_integer([:positive])}"
      path = Path.join(root, "top.txt")

      eval!(~s{
        (begin
          (buffer-create "#{source}")
          (buffer-add-group! "#{source}" (group-ensure-record! "#{source}"))
          (switch-to-buffer! "#{source}")
          (switch-to-group! "#{source}"))})

      on_exit(fn ->
        eval!(~s{
          (begin
            (for-each
              (lambda (name)
                (let ((id (group-resolve-id name)))
                  (when id (group-record-delete! id))))
              (list "#{source}" "#{target}"))
            #t)})

        Aimax.Core.kill_buffer(source)
      end)

      press(["C-u", "C-x", "C-f"])
      assert Editor.render_state().minibuffer.prompt == "Switch file to group: "

      press(String.graphemes(target))
      press("RET")
      assert Editor.render_state().minibuffer.prompt == "Find file: "
      assert eval!("(group-name (frame-group))") == ~s{"#{target}"}

      press(String.graphemes(path))
      press("RET")

      assert eval!("(current-buffer)") == ~s{"#{path}"}
      assert eval!(~s{(group-resolve-id "#{target}")}) != "#f"
      assert eval!(~s{(buffer-in-group? "#{path}" "#{target}")}) == "#t"
    end

    test "dired-in-group creates its destination and keeps an existing membership", %{
      root: root
    } do
      source = "zz-ps-dired-source-#{System.unique_integer([:positive])}"
      other = "zz-ps-dired-other-#{System.unique_integer([:positive])}"
      target = "zz-ps-dired-target-#{System.unique_integer([:positive])}"

      eval!(~s{
        (begin
          (visit-in-group "#{root}" (group-ensure-record! "#{other}"))
          (buffer-create "#{source}")
          (buffer-add-group! "#{source}" (group-ensure-record! "#{source}"))
          (switch-to-buffer! "#{source}")
          (switch-to-group! "#{source}")
          (global-set-key "<f9> d" "dired-in-group"))})

      on_exit(fn ->
        eval!(~s{
          (begin
            (for-each
              (lambda (name)
                (let ((id (group-resolve-id name)))
                  (when id (group-record-delete! id))))
              (list "#{source}" "#{other}" "#{target}"))
            #t)})

        Aimax.Core.kill_buffer(source)
      end)

      press(["<f9>", "d"])
      assert Editor.render_state().minibuffer.prompt == "Switch Dired to group: "

      press(String.graphemes(target))
      press("RET")
      assert Editor.render_state().minibuffer.prompt == "Dired (directory): "
      assert eval!("(group-name (frame-group))") == ~s{"#{target}"}

      press(String.graphemes(root))
      press("RET")

      assert eval!("(current-buffer)") == ~s{"#{root}"}
      assert eval!(~s{(buffer-in-group? "#{root}" "#{other}")}) == "#t"
      assert eval!(~s{(buffer-in-group? "#{root}" "#{target}")}) == "#t"
    end

    test "project-switch-project-in-group creates the chosen destination", %{root: root} do
      source = "zz-ps-command-source-#{System.unique_integer([:positive])}"
      target = "zz-ps-command-target-#{System.unique_integer([:positive])}"

      eval!(~s{
        (begin
          (buffer-create "#{source}")
          (buffer-add-group! "#{source}" (group-ensure-record! "#{source}"))
          (switch-to-buffer! "#{source}")
          (switch-to-group! "#{source}")
          (project-remember! "#{root}")
          (global-set-key "<f9> p" "project-switch-project-in-group"))})

      on_exit(fn ->
        eval!(~s{
          (begin
            (for-each
              (lambda (name)
                (let ((id (group-resolve-id name)))
                  (when id (group-record-delete! id))))
              (list "#{source}" "#{target}" "#{root}"))
            #t)})

        Aimax.Core.kill_buffer(source)
      end)

      press(["<f9>", "p"])
      press(String.graphemes(root))
      press("RET")
      assert Editor.render_state().minibuffer.prompt == "Switch project to group: "

      press(String.graphemes(target))
      press(["RET", "RET"])

      assert eval!("(current-buffer)") == ~s{"#{root}"}
      assert eval!("(group-name (frame-group))") == ~s{"#{target}"}
      assert eval!(~s{(buffer-in-group? "#{root}" "#{target}")}) == "#t"
    end

    test "project-switch-project preserves an existing Dired buffer's other group", %{root: root} do
      other = "zz-ps-other-#{System.unique_integer([:positive])}"

      eval!(~s{
        (begin
          (switch-to-group! (group-ensure-record! "#{other}"))
          (visit-in-group "#{root}" (frame-group))
          (project-remember! "#{root}"))})

      on_exit(fn ->
        eval!(~s{
          (begin
            (let ((other-id (group-resolve-id "#{other}"))
                  (project-id (group-resolve-id "#{root}")))
              (when other-id (group-record-delete! other-id))
              (when project-id (group-record-delete! project-id)))
            #t)})
      end)

      press(["C-x", "p", "p"])
      press(String.graphemes(root))
      press(["RET", "RET"])

      assert eval!("(group-name (frame-group))") == ~s{"#{root}"}
      assert eval!(~s{(buffer-in-group? "#{root}" "#{root}")}) == "#t"
      assert eval!(~s{(buffer-in-group? "#{root}" "#{other}")}) == "#t"
    end

    test "a project grouping rule can override the destination group", %{root: root} do
      source = "zz-ps-source-#{System.unique_integer([:positive])}"
      target = "zz-ps-target-#{System.unique_integer([:positive])}"
      rule = "zz-ps-route-#{System.unique_integer([:positive])}"

      eval!(~s{
        (begin
          (buffer-create "#{source}")
          (buffer-add-group! "#{source}" (group-ensure-record! "#{source}"))
          (group-ensure-record! "#{target}")
          (switch-to-buffer! "#{source}")
          (switch-to-group! "#{source}")
          (add-project-grouping-rule! "#{rule}"
            (lambda (candidate) (equal? candidate "#{root}"))
            (lambda (candidate) "#{target}"))
          (project-remember! "#{root}"))})

      project_package = Application.app_dir(:aimax_core, "priv/packages/project.scm")
      assert {:ok, %{files: 1}} = Session.reload_files([project_package])
      assert eval!(~s{(project-group-target "#{root}")}) == ~s{"#{target}"}

      on_exit(fn ->
        eval!(~s{
          (begin
            (remove-project-grouping-rule! "#{rule}")
            (for-each
              (lambda (name)
                (let ((id (group-resolve-id name)))
                  (when id (group-record-delete! id))))
              (list "#{source}" "#{target}" "#{root}"))
            #t)})

        Aimax.Core.kill_buffer(source)
      end)

      press(["C-x", "p", "p"])
      press(String.graphemes(root))
      press(["RET", "RET"])

      assert eval!("(group-name (frame-group))") == ~s{"#{target}"}
      assert eval!(~s{(buffer-in-group? "#{root}" "#{target}")}) == "#t"
      assert eval!(~s{(group-resolve-id "#{root}")}) == "#f"
    end

    test "the root comes first, then directories, open files, and the rest", %{root: root} do
      eval!(~s{(visit "#{root}/lib/b.txt")})

      cands = eval!(~s{(project-file-candidates "#{root}")})
      assert cands =~ ~s{("lib/" "dired")}
      assert cands =~ ~s{("lib/b.txt" "open")}
      assert cands =~ ~s{("lib/a.txt" "")}

      # the directory leads the prompt: RET opens the root in dired
      assert String.starts_with?(cands, ~s{(("./" "dired")})

      idx = fn text -> :binary.match(cands, text) |> elem(0) end
      assert idx.(~s{("lib/" "dired")}) < idx.(~s{("lib/b.txt" "open")})
      assert idx.(~s{("lib/b.txt" "open")}) < idx.(~s{("lib/a.txt" "")})

      # an open file is listed once — as the open one
      assert eval!(~s{(project-open-files "#{root}")}) == ~s{("lib/b.txt")}
      refute cands =~ ~s{("lib/b.txt" "")}
    end

    test "both spellings of the root open dired" do
      assert eval!(~s{(project-dired-input? ".")}) == "#t"
      assert eval!(~s{(project-dired-input? "./")}) == "#t"
      assert eval!(~s{(project-dired-input? "lib/a.txt")}) == "#f"
    end

    test "the directory you type into lists itself and its own files", %{root: root} do
      File.write!(Path.join(root, "lib/ignored.log"), "x")
      File.write!(Path.join(root, ".gitignore"), "*.log\n")

      base = ~s{(project-file-candidates "#{root}")}
      pool = eval!(~s{(project--pool "#{root}" #{base} "lib/")})

      # the typed directory leads, so RET opens it in dired
      assert String.starts_with?(pool, ~s{(("lib/" "dired")})
      # git ignores the .log file; the disk still offers it
      assert pool =~ ~s{("lib/ignored.log" "")}
      # a file git knows is listed once, by the disk pass
      assert pool =~ ~s{("lib/a.txt" "")}
      refute pool =~ ~s{("lib/a.txt" "") ("lib/a.txt" "")}
    end

    test "an empty directory part keeps git's own list", %{root: root} do
      base = ~s{(project-file-candidates "#{root}")}
      assert eval!(~s{(project--pool "#{root}" #{base} "")}) == eval!(base)
    end

    test "the prompt lists the directory as you type into it", %{root: root} do
      eval!(~s{(project-find-file-in "#{root}")})
      assert Editor.render_state().minibuffer

      press(["l", "i", "b"])

      assert [
               %{label: "lib/", selected: true},
               %{label: "lib/a.txt"},
               %{label: "lib/b.txt"}
             ] = Editor.render_state().minibuffer.candidates

      press(["TAB"])
      mb = Editor.render_state().minibuffer
      assert mb.input == "lib/"
      assert Enum.map(mb.candidates, & &1.label) == ["lib/", "lib/a.txt", "lib/b.txt"]

      press(["C-g"])
    end

    test "a file git does not know still opens", %{root: root} do
      eval!(~s{(project-find-file-in "#{root}")})
      press(String.graphemes("lib/brand-new.txt"))
      press(["RET"])

      assert window_buffer() == ~s{"#{root}/lib/brand-new.txt"}
      Aimax.Core.kill_buffer("#{root}/lib/brand-new.txt")
    end

    test "a file outside the project does not become a candidate", %{root: root} do
      other = Path.join(System.tmp_dir!(), "ps-other-#{System.unique_integer([:positive])}.txt")
      File.write!(other, "x")
      eval!(~s{(visit "#{other}")})

      assert eval!(~s{(project-open-files "#{root}")}) == "()"

      Aimax.Core.kill_buffer(other)
      File.rm_rf!(other)
    end

    test "a file outside the project stays out of project-buffers", %{root: root} do
      other = Path.join(System.tmp_dir!(), "ps-out-#{System.unique_integer([:positive])}.txt")
      File.write!(other, "x")
      eval!(~s{(visit "#{other}")})
      eval!(~s{(visit "#{root}/lib/a.txt")})

      bufs = eval!(~s{(project-buffers "#{root}")})
      assert bufs =~ "#{root}/lib/a.txt"
      refute bufs =~ other

      Aimax.Core.kill_buffer(other)
      File.rm_rf!(other)
    end

    test "the root row opens the root in dired", %{root: root} do
      eval!(~s{(project-find-file-in "#{root}")})
      mb = Editor.render_state().minibuffer
      assert Enum.find(mb.candidates, &(&1.label == "./"))

      # the directory leads the prompt, so RET opens it
      press("RET")
      assert eval!("(current-buffer)") == ~s{"#{root}"}
      assert eval!(~s{(buffer-local (current-buffer) 'mode-name)}) == ~s{"Dired"}
    end

    test "a saved project root with a trailing slash opens inside that project", %{root: root} do
      eval!(~s{(project-find-file-in "#{root}/")})

      # The old path join produced ROOT//lib/a.txt. Its double slash means
      # /lib/a.txt, so type a specific file to test the canonical root.
      press(String.graphemes("lib/a.txt"))
      press(["RET"])

      assert eval!("(current-buffer)") == ~s{"#{root}/lib/a.txt"}
    end
  end

  describe "project-kill-all" do
    test "the prompt counts the buffers and y kills them", %{root: root} do
      eval!(~s{(visit "#{root}/lib/a.txt")})
      eval!(~s{(visit "#{root}/lib/b.txt")})
      eval!(~s{(dired-open "#{root}")})
      eval!(~s{(visit "#{root}/top.txt")})

      # the dired listing of the root counts too: its directory is the root
      assert eval!(~s{(project-buffers "#{root}")}) =~ root

      eval!(~s{(run-command "project-kill-all")})
      mb = Editor.render_state().minibuffer
      assert mb.prompt == "Kill 4 buffers in #{Path.basename(root)}? (y or n) "
      # a question offers no candidates
      assert mb.candidates == []

      press("y")
      refute Editor.render_state().minibuffer
      refute eval!("(buffer-list)") =~ root
    end

    test "n keeps every buffer", %{root: root} do
      eval!(~s{(visit "#{root}/lib/a.txt")})

      eval!(~s{(run-command "project-kill-all")})
      press("n")

      refute Editor.render_state().minibuffer
      assert eval!("(buffer-list)") =~ "#{root}/lib/a.txt"
    end

    test "any other key leaves the question standing", %{root: root} do
      eval!(~s{(visit "#{root}/lib/a.txt")})

      eval!(~s{(run-command "project-kill-all")})
      press(["x", "q"])

      mb = Editor.render_state().minibuffer
      assert mb.prompt =~ "(y or n)"
      assert mb.input == ""
      # a question is not a completion prompt: the UI reads the style
      assert mb.style == "question"

      press("n")
      assert eval!("(buffer-list)") =~ "#{root}/lib/a.txt"
    end

    test "RET is not an answer: it asks again", %{root: root} do
      eval!(~s{(visit "#{root}/lib/a.txt")})

      eval!(~s{(run-command "project-kill-all")})
      before = Editor.render_state().minibuffer.prompt
      press("RET")

      assert Editor.render_state().minibuffer.prompt == before
      assert eval!("(buffer-list)") =~ "#{root}/lib/a.txt"

      press("n")
      refute Editor.render_state().minibuffer
    end

    test "a modified file asks to save, and y writes it before the kill", %{root: root} do
      eval!(~s{(visit "#{root}/lib/a.txt")})
      eval!(~s{(insert! "dirty ")})

      eval!(~s{(run-command "project-kill-all")})
      press("y")

      # the kill question is answered; the save question stands
      assert Editor.render_state().minibuffer.prompt ==
               "Save #{root}/lib/a.txt? (y or n) "

      press("y")
      refute Editor.render_state().minibuffer
      assert File.read!(Path.join(root, "lib/a.txt")) =~ "dirty one"
      refute eval!("(buffer-list)") =~ "#{root}/lib/a.txt"
    end

    test "a modified file you do not save stays open", %{root: root} do
      eval!(~s{(visit "#{root}/lib/b.txt")})
      eval!(~s{(visit "#{root}/lib/a.txt")})
      eval!(~s{(insert! "dirty ")})

      eval!(~s{(run-command "project-kill-all")})
      press(["y", "n"])

      refute Editor.render_state().minibuffer
      bufs = eval!("(buffer-list)")
      assert bufs =~ "#{root}/lib/a.txt"
      refute bufs =~ "#{root}/lib/b.txt"
      # the file on disk keeps what it had
      refute File.read!(Path.join(root, "lib/a.txt")) =~ "dirty"
    end

    test "every modified file gets its own question", %{root: root} do
      eval!(~s{(visit "#{root}/lib/a.txt")})
      eval!(~s{(insert! "one ")})
      eval!(~s{(visit "#{root}/lib/b.txt")})
      eval!(~s{(insert! "two ")})

      eval!(~s{(run-command "project-kill-all")})
      press("y")
      assert Editor.render_state().minibuffer.prompt =~ "Save "
      press("n")
      assert Editor.render_state().minibuffer.prompt =~ "Save "
      press("n")

      refute Editor.render_state().minibuffer
      bufs = eval!("(buffer-list)")
      assert bufs =~ "#{root}/lib/a.txt"
      assert bufs =~ "#{root}/lib/b.txt"
    end

    test "outside a project the command kills nothing" do
      eval!(~s{(begin (buffer-create "*zz-ps*") (switch-to-buffer! "*zz-ps*"))})
      eval!(~s{(buffer-set-local! "*zz-ps*" 'default-directory "#{System.tmp_dir!()}/")})

      eval!(~s{(run-command "project-kill-all")})
      refute Editor.render_state().minibuffer
      assert eval!("(buffer-list)") =~ "*zz-ps*"
    end

    test "the command is registered and C-x p k runs it" do
      assert eval!(~s{(command-doc "project-kill-all")}) =~ "Kill every buffer"
      assert eval!(~s{(key-for-command "project-kill-all")}) == ~s{"C-x p k"}
    end
  end
end
