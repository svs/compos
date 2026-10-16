defmodule Compos.IbufferPickerTest do
  use Compos.Case, async: false
  alias Compos.Core.{Buffer, Editor, KeyDispatch}

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    for name <- ["*picker-home*", "*picker-target*"], do: Compos.Core.create_buffer(name)
    Editor.set_window_buffer("*picker-home*")

    eval!(~S"""
    (begin
      (set! ibuffer-info #t) (set! ibuffer-pretty #t) (set! ibuffer-group-by 'group)
      (local-set-key "<f9>" "ibuffer-prompt-pretty")
      (buffer-set-local! "*picker-target*" 'mode-name "text-mode"))
    """)

    on_exit(fn ->
      eval!(
        ~S{(begin (when (minibuffer-state) (minibuffer-cancel!)) (advice-remove! 'ibuffer-table-load! 'picker-test) (advice-remove! 'ibuffer-format 'picker-plain-test))}
      )

      Editor.delete_other_windows()
      Editor.set_window_buffer("*scratch*")

      for name <- ["*picker-home*", "*picker-target*", " *buffers*"],
          do: Compos.Core.kill_buffer(name)
    end)

    :ok
  end

  test "picker opens as a dock with named columns and formatting switches reuse the snapshot" do
    KeyDispatch.handle_key("<f9>")
    assert Buffer.get_local(" *buffers*", "window-shape") == "minibuffer"
    assert is_integer(Buffer.get_local(" *buffers*", "window-dock"))
    assert Buffer.text(" *buffers*") =~ "Buffer"
    assert Buffer.text(" *buffers*") =~ "Mode"
    assert eval!(~S{(ibuffer-grouping " *buffers*")}) == "group"

    eval!(~S"""
    (begin
      (define *picker-loads* 0)
      (advice-add! 'ibuffer-table-load! 'before 'picker-test
        (lambda (buf names) (set! *picker-loads* (+ *picker-loads* 1)))))
    """)

    eval!(~S{(run-command "ibuffer-toggle-info")})
    refute Buffer.text(" *buffers*") =~ "Mode"
    eval!(~S{(run-command "ibuffer-toggle-pretty")})
    assert eval!("*picker-loads*") == "0"
    eval!(~S{(minibuffer-cancel!)})
    assert Editor.current_buffer() == "*picker-home*"
    refute Buffer.exists?(" *buffers*")
  end

  test "pretty off skips rich metadata formatting and uses theme faces" do
    KeyDispatch.handle_key("<f9>")
    eval!(~S"""
      (begin
        (define *picker-rich-formats* 0)
        (advice-add! 'ibuffer-format 'before 'picker-plain-test
          (lambda (row info? &optional group?) (set! *picker-rich-formats* (+ *picker-rich-formats* 1))))
        (ibuffer-set-render-option! " *buffers*" 'pretty #f)
        (list-redraw! " *buffers*"))
      """)
    assert eval!("*picker-rich-formats*") == "0"
    records = inspect(Buffer.get_local(" *buffers*", "render-records"), limit: :infinity)
    assert records =~ "f-dim"
    refute records =~ "ibuffer-size"
    refute records =~ "ibuffer-file"
    eval!(~S{(advice-remove! 'ibuffer-format 'picker-plain-test)})
  end

  test "filtering matches snapshot metadata, confirm visits the row, and CSS ranges describe it" do
    KeyDispatch.handle_key("<f9>")
    eval!(~S{(begin (minibuffer-change! "picker-target") (*mb-list-flush*))})
    assert eval!(~S{(list-current " *buffers*")}) == ~s("*picker-target*")
    records = Buffer.get_local(" *buffers*", "render-records")
    assert inspect(records, limit: :infinity) =~ "ibuffer-info ibuffer-mode"
    assert inspect(records, limit: :infinity) =~ "ibuffer-info ibuffer-file"
    KeyDispatch.handle_key("RET")
    assert Editor.current_buffer() == "*picker-target*"
    refute Buffer.exists?(" *buffers*")
  end

  test "filtering keeps compact field positions after the dock reports a wider viewport" do
    KeyDispatch.handle_key("<f9>")
    fields = ~S{(let* ((records (buffer-local " *buffers*" 'render-records))
                      (row (car (filter (lambda (r)
                        (equal? (cadr (assoc "record-id" (plist-get (nth 2 r) 'attrs)))
                                "*picker-target*")) records))))
                 (plist-get (nth 2 row) 'relative-fields))}
    before = eval!(fields)
    Editor.set_window_cols(Map.new(Editor.list_windows(), fn {id, _} -> {id, 240} end))
    eval!(~S{(begin (minibuffer-change! "picker-target") (*mb-list-flush*))})
    assert eval!(fields) == before
    eval!(~S{(begin (minibuffer-change! "") (*mb-list-flush*))})
    assert eval!(fields) == before
    Editor.set_window_cols(%{})
  end

  test "grouping modes and folding preserve member identity without live row reads" do
    KeyDispatch.handle_key("<f9>")

    for grouping <- ["mode", "directory", "none", "group"] do
      assert eval!(~s{(begin (ibuffer-set-grouping! '#{grouping} " *buffers*")
        (and (member "*picker-target*" (filter string? (list-entries " *buffers*"))) #t))}) ==
               "#t"
    end

    assert eval!(~S"""
           (let* ((buf " *buffers*")
                  (head (car (filter ibuffer-heading? (list-entries buf))))
                  (key (ibuffer-heading-key head)))
             (ibuffer-toggle-fold! key buf)
             (let ((closed (car (filter (lambda (r) (and (ibuffer-heading? r)
                                (equal? (ibuffer-heading-key r) key))) (list-entries buf)))))
               (and (ibuffer-heading-folded? closed)
                    (pair? (ibuffer-heading-members closed)))))
           """) == "#t"
  end

  test "management and prompt use the same renderer while management keeps marks" do
    eval!(~S{(local-set-key "<f8>" "ibuffer-pretty")})
    KeyDispatch.handle_key("<f8>")
    view = Editor.current_buffer()
    assert Buffer.get_local(view, "list-mode") == "ibuffer-pretty-mode"
    assert Buffer.get_local(view, "ibuffer-heading-rows") == true
    assert Buffer.text(view) =~ "Buffer"
    eval!(~s{(begin (list-set-query! #{inspect(view)} "picker-target")
      (list-goto-index! #{inspect(view)} 1) (run-command "list-toggle-mark"))})
    assert eval!(~s{(and (assoc "*picker-target*" (list-marks #{inspect(view)})) #t)}) == "#t"
    eval!(~s{(list-redraw! #{inspect(view)})})
    assert inspect(Buffer.get_local(view, "render-records"), limit: :infinity) =~ "ibuffer-mode"
    Compos.Core.kill_buffer(view)
  end

  test "ibuffer remains a grouped buffer even when picker grouping and info are off" do
    eval!(~S{(begin (set! ibuffer-group-by 'none) (set! ibuffer-info #f))})
    KeyDispatch.handle_key("C-x")
    KeyDispatch.handle_key("C-b")
    view = Editor.current_buffer()
    assert Buffer.get_local(view, "list-mode") == "ibuffer-mode"
    assert Editor.render_state().minibuffer == nil
    assert eval!(~s{(ibuffer-grouping #{inspect(view)})}) == "group"
    assert Buffer.text(view) =~ "text-mode"
    assert eval!(~s{(pair? (filter ibuffer-heading? (list-entries #{inspect(view)})))}) == "#t"
    Compos.Core.kill_buffer(view)
  end

  test "management adapts to window width and retains its keymap" do
    eval!(~S{(run-command "ibuffer")})
    view = Editor.current_buffer()
    win = Editor.active_window()
    for {width, layout} <- [{48, "narrow"}, {80, "compact"}, {140, "wide"}] do
      Editor.set_window_cols(%{win => width})
      eval!(~S{(window-config-changed!)})
      assert eval!(~s{(plist-get (list-active-layout #{inspect(view)}) 'name)}) == layout
      hints = inspect(Buffer.get_local(view, "footer-line-blocks"), limit: :infinity)
      assert hints =~ "RET"
      assert hints =~ "preview"
      assert hints =~ "next/previous group"
      assert hints =~ "all bindings"
      assert eval!(~S{(key-binding "m")}) == ~s("list-mark")
      assert eval!(~S{(key-binding "d")}) == ~s("list-flag-D")
      assert eval!(~S{(key-binding "g")}) == ~s("ibuffer-refresh")
    end
    eval!(~S{(set-mode! "fundamental-mode")})
    assert Buffer.get_local(view, "footer-line-blocks") == false
    Editor.set_window_cols(%{})
    Compos.Core.kill_buffer(view)
  end

  test "M-down and M-up jump groups in the management buffer" do
    eval!(~S"""
    (begin
      (run-command "ibuffer")
      (define *jump-view* (current-buffer))
      (buffer-set-local! *jump-view* 'list-source-entries
        (list (ibuffer-table-heading "A" "a" "separator" '("*picker-home*")) "*picker-home*"
              (ibuffer-table-heading "B" "b" "separator" '("*picker-target*")) "*picker-target*"))
      (list-redraw! *jump-view*)
      (list-goto-index! *jump-view* 1))
    """)
    KeyDispatch.handle_key("M-<down>")
    assert eval!(~S{(ibuffer-heading-label (list-current *jump-view*))}) == ~s("B")
    KeyDispatch.handle_key("M-<up>")
    assert eval!(~S{(ibuffer-heading-label (list-current *jump-view*))}) == ~s("A")
    KeyDispatch.handle_key("M-<up>")
    assert eval!(~S{(ibuffer-heading-label (list-current *jump-view*))}) == ~s("A")
    eval!(~S{(buffer-kill! *jump-view*)})
  end

  test "C-x b uses normal minibuffer completion without a list pane" do
    windows = Editor.list_windows()
    KeyDispatch.handle_key("C-x")
    KeyDispatch.handle_key("b")
    assert eval!("(mb-list-target)") == "#f"
    refute Buffer.exists?(" *buffers*")
    assert Enum.map(Editor.list_windows(), &elem(&1, 0)) == Enum.map(windows, &elem(&1, 0))
    eval!(~S{(minibuffer-change! "picker-target")})
    KeyDispatch.handle_key("RET")
    assert Editor.current_buffer() == "*picker-target*"
  end

  test "normal minibuffer selection previews and cancel restores the invoking buffer" do
    KeyDispatch.handle_key("C-x")
    KeyDispatch.handle_key("b")
    eval!(~S{(minibuffer-change! "picker-target")})
    assert eval!("(window-buffer (active-window))") == ~s("*picker-target*")
    KeyDispatch.handle_key("C-g")
    assert Editor.current_buffer() == "*picker-home*"
    refute Buffer.exists?(" *buffers*")
  end

  test "normal minibuffer annotates mode from one snapshot and info can be disabled" do
    KeyDispatch.handle_key("C-x")
    KeyDispatch.handle_key("b")
    candidate = Enum.find(Editor.render_state().minibuffer.candidates, &(&1.label == "*picker-target*"))
    assert candidate.hint == "text-mode"
    assert eval!("(mb-list-target)") == "#f"
    eval!(~S{(begin (minibuffer-cancel!) (set! ibuffer-info #f))})
    KeyDispatch.handle_key("C-x")
    KeyDispatch.handle_key("b")
    assert Enum.all?(Editor.render_state().minibuffer.candidates, &(&1.hint == ""))
  end

  test "native annotations include unsaved state and group without changing labels" do
    assert eval!(~S{(switch-buffer-info-candidates
      '(("file.txt" "/a/file.txt"))
      '(("/a/file.txt" "/a/file.txt" #t "text-mode" #f ("g") #f))
      '(("g" "Work")))}) == ~S{(("file.txt" "*  text-mode  Work"))}
  end

  test "bare candidates use filenames and disambiguate collisions" do
    assert eval!(~S{(switch-bare-candidates '("/a/one.txt" "/b/two.txt" "/c/two.txt" "*scratch*"))}) ==
      ~S{(("one.txt" "/a/one.txt") ("/b/two.txt" "/b/two.txt") ("/c/two.txt" "/c/two.txt") ("*scratch*" "*scratch*"))}
  end

  test "group label cache reuses names and invalidates for names, icons, and format" do
    assert eval!(~S"""
      (let* ((id (group-record-create! ":picker-cache-icon: Cache"))
             (saved-icons *name-icons*) (saved-format group-name-format))
        (name-icon! "picker-cache-icon" "A")
        (set! group-name-format "%n")
        (define *picker-name-renders* 0)
        (advice-add! 'group-name-segments 'before 'picker-cache-test
          (lambda (id) (set! *picker-name-renders* (+ *picker-name-renders* 1))))
        (ibuffer-table-group-labels)
        (set! *picker-name-renders* 0)
        (ibuffer-table-group-labels)
        (let ((reused (= *picker-name-renders* 0)))
          (name-icon! "picker-cache-icon" "B")
          (let ((icon (cadr (assoc id (ibuffer-table-group-labels)))))
            (group-record-update! id 'name ":picker-cache-icon: Renamed")
            (let ((name (cadr (assoc id (ibuffer-table-group-labels)))))
              (set! group-name-format "[%n]")
              (let ((formatted (cadr (assoc id (ibuffer-table-group-labels)))))
                (advice-remove! 'group-name-segments 'picker-cache-test)
                (group-record-delete! id)
                (set! *name-icons* saved-icons)
                (set! group-name-format saved-format)
                (and reused (equal? icon "B Cache") (equal? name "B Renamed")
                     (equal? formatted "[B Renamed]")))))))
      """) == "#t"
  end

  test "group name icons are resolved in the snapshot" do
    assert eval!(~S"""
      (let* ((id (group-record-create! ":group: Picker icons")))
        (buffer-set-local! "*picker-target*" 'group-id id)
        (ibuffer-table-load! "*picker-home*" '("*picker-target*"))
        (let ((label (nth 3 (ibuffer-table-data "*picker-home*" "*picker-target*"))))
          (group-record-delete! id)
          (equal? label (string-append (mode-icon "groups-mode") " Picker icons"))))
      """) == "#t"
  end

  test "format is pure, clips columns, and uses UTF-8 byte ranges" do
    assert eval!(~S"""
           (let* ((r (list-format-template (ibuffer-format '("x" "café λ" "text-mode" "研究" #t "/x" #f 1024) #t) #t))
                  (text (car r)) (fields (cadr r)))
             (and (<= (string-length text) 128)
                  (string-prefix? "* " text)
                  (equal? (substring-bytes text (car (cadr fields)) (cadr (cadr fields)))
                          (string-pad-right "café λ" 38))))
           """) == "#t"
  end
end
