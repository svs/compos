defmodule Compos.FilterNavigationTest do
  use Compos.Case, async: false
  alias Compos.Core.{Buffer, Editor}

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    Editor.set_window_buffer("*scratch*")

    for name <- ["*zz-nav-a*", "*zz-nav-b*", "*zz-excluded*"] do
      Compos.Core.create_buffer(name, text: "body")
      Buffer.set_local(name, "mode-name", "chat-mode")
    end

    on_exit(fn ->
      Editor.minibuffer_close()
      eval!("(chat-list-search-reset!) (advice-remove! 'ibuffer-row-match 'zz-metadata-count)")
      Editor.delete_other_windows()
      Editor.set_window_buffer("*scratch*")

      for name <- ["*zz-nav-a*", "*zz-nav-b*", "*zz-excluded*", "*ibuffer*", "*chat-list*"],
          do: Compos.Core.kill_buffer(name)
    end)

    :ok
  end

  for mode <- ["chat-list-mode", "ibuffer-mode"] do
    @mode mode
    test "#{mode} retains filtering through arrows, C-g, and row motion until backslash" do
      eval!("""
      (list-mode-show! "#{@mode}")
      (define *nf-view* (current-buffer))
      (buffer-set-local! *nf-view* 'ibuffer-grouping 'none)
      (list-refresh! *nf-view*)
      """)

      press("/")
      press(String.graphemes("zz-nav-"))
      press("<down>")
      assert eval!("(list-query *nf-view*)") == ~s("zz-nav-")
      selected = eval!("(list-current *nf-view*)")
      Process.sleep(250)
      assert eval!("(list-current *nf-view*)") == selected
      assert eval!("(length (filter string? (list-entries *nf-view*)))") == "2"
      press(["<down>", "<up>", "C-n", "C-p"])
      Process.sleep(250)
      assert eval!("(minibuffer-input)") == ~s("zz-nav-")
      assert eval!("(list-query *nf-view*)") == ~s("zz-nav-")
      assert eval!("(length (filter string? (list-entries *nf-view*)))") == "2"
      press("C-g")
      press(["n", "p"])
      assert eval!("(list-query *nf-view*)") == ~s("zz-nav-")
      assert eval!("(length (filter string? (list-entries *nf-view*)))") == "2"
      press("\\")
      assert eval!("(list-query *nf-view*)") == ~s("")
      assert String.to_integer(eval!("(length (filter string? (list-entries *nf-view*)))")) > 2
    end
  end

  test "ordinary typing pauses do not start filtering before the user finishes" do
    eval!("""
    (list-mode-show! "ibuffer-mode")
    (define *nf-view* (current-buffer))
    """)

    press("/")

    for {key, input} <- [{"z", "z"}, {"z", "zz"}, {"-", "zz-"}] do
      press(key)
      assert eval!("(minibuffer-input)") == inspect(input)
      Process.sleep(100)
      assert eval!("(list-query *nf-view*)") == ~s("")
    end

    # Finishing the prompt applies the latest input without waiting for idle.
    press("C-g")
    assert eval!("(list-query *nf-view*)") == ~s("zz-")
  end

  test "four quick deletes redraw the list once for the final input" do
    eval!("""
    (list-mode-show! "ibuffer-mode")
    (define *nf-view* (current-buffer))
    (list-set-query! *nf-view* "zz-nav-")
    (define *nf-delete-draws* '())
    (advice-add! 'list-render! 'before 'zz-delete-burst
      (lambda (buf fetch)
        (when (equal? buf *nf-view*)
          (set! *nf-delete-draws* (cons (list-query buf) *nf-delete-draws*)))))
    """)

    on_exit(fn -> eval!("(advice-remove! 'list-render! 'zz-delete-burst)") end)
    press("/")

    for _ <- 1..4 do
      Compos.Core.Input.dispatch("DEL")
      Process.sleep(40)
      assert eval!("*nf-delete-draws*") == "()"
    end

    assert eval!("(minibuffer-input)") == ~s("zz-")

    Enum.reduce_while(1..100, nil, fn _, _ ->
      if eval!("*nf-delete-draws*") != "()",
        do: {:halt, nil},
        else:
          (
            Process.sleep(10)
            {:cont, nil}
          )
    end)

    assert eval!("*nf-delete-draws*") == ~s{("zz-")}
    Process.sleep(350)
    assert eval!("*nf-delete-draws*") == ~s{("zz-")}
    press("C-g")
  end

  test "folding uses the existing source and restores its members without a fetch" do
    eval!(~S"""
    (begin
      (define *nf-fetches* 0)
      (define-list-mode! "zz-fold-performance-mode"
        (ibuffer-mode-opts
          (list 'buffer "*zz-fold-performance*"
                'stamp #f
                'rows (lambda (buf)
                  (set! *nf-fetches* (+ *nf-fetches* 1))
                  (append
                    (ibuffer-section buf "First" "first" '("*zz-nav-a*" "*zz-nav-b*") "faint")
                    (ibuffer-section buf "Other" "other" '("*zz-excluded*") "faint"))))))
      (list-mode-show! "zz-fold-performance-mode")
      (define *nf-view* (current-buffer))
      (define *nf-before* (list-source-entries *nf-view*))
      (set! *nf-fetches* 0)
      (ibuffer-toggle-fold! "first" *nf-view*))
    """)

    assert eval!("*nf-fetches*") == "0"
    assert eval!("(length (list-source-entries *nf-view*))") == "3"
    eval!("(ibuffer-toggle-fold! \"first\" *nf-view*)")
    assert eval!("*nf-fetches*") == "0"
    assert eval!("(equal? *nf-before* (list-source-entries *nf-view*))") == "#t"
    Compos.Core.kill_buffer("*zz-fold-performance*")
  end

  test "search separates title, metadata and transcript matches without duplicates" do
    Buffer.set_local("*zz-nav-a*", "chat-summary", "separationneedle title")
    Buffer.set_local("*zz-nav-b*", "chat-summary", "A different title")
    Buffer.set_local("*zz-nav-b*", "agent-slug", "separationneedle")

    for b <- ["*zz-nav-a*", "*zz-nav-b*", "*zz-excluded*"],
        do: Buffer.append(b, " separationneedle", source: :editor)

    eval!(~S{(list-mode-show! "chat-list-mode") (define *nf-view* (current-buffer)) (ibuffer-set-grouping! 'none *nf-view*)})
    press("/")
    press(String.graphemes("separationneedle"))
    press("C-g")
    for _ <- 1..100, eval!(~S{(chat-list-hit "*zz-excluded*")}) == "#f", do: Process.sleep(20)

    assert eval!("(map ibuffer-heading-label (filter ibuffer-heading? (list-entries *nf-view*)))") ==
             ~s{("Name matches" "Other matches" "Text matches")}

    assert eval!("(filter string? (list-entries *nf-view*))") ==
             ~s{("*zz-nav-a*" "*zz-nav-b*" "*zz-excluded*")}

    assert eval!(
             "(filter (lambda (row) (and (ibuffer-heading? row) (list-selectable? *nf-view* row))) (list-entries *nf-view*))"
           ) == "()"

    assert eval!("(buffer-text *nf-view*)") =~ "TEXT MATCHES"
    press("\\")
    assert eval!("(list-query *nf-view*)") == ~s("")
  end

  test "ibuffer mode queries are exact and filtered group counts match visible members" do
    Buffer.set_local("*zz-excluded*", "mode-name", "whatsapp-chat-mode")

    eval!(~S"""
    (list-mode-show! "ibuffer-mode")
    (define *nf-view* (current-buffer))
    (buffer-set-locals! *nf-view* '(ibuffer-scope ("*zz-nav-a*" "*zz-nav-b*" "*zz-excluded*") ibuffer-grouping mode))
    (list-refresh! *nf-view*)
    """)

    press("/")
    press(String.graphemes("chat-mode"))
    press("C-g")
    assert eval!("(filter string? (list-entries *nf-view*))") == ~s{("*zz-nav-a*" "*zz-nav-b*")}

    assert eval!("(map ibuffer-heading-count (filter ibuffer-heading? (list-entries *nf-view*)))") ==
             "(2)"

    eval!(~S{(list-set-query! *nf-view* "chat-mode z")})
    assert eval!("(length (filter string? (list-entries *nf-view*)))") == "3"
    eval!(~S{(list-set-query! *nf-view* "zz-nav-a")})

    assert eval!("(map ibuffer-heading-count (filter ibuffer-heading? (list-entries *nf-view*)))") ==
             "(1)"

    assert eval!("(list-source-entries *nf-view*)") =~ "*zz-nav-b*"
  end

  test "ibuffer typing does no table work until its deferred query is flushed" do
    eval!(~S"""
    (define *nf-draws* 0)
    (define-list-mode! "zz-deferred-filter-mode"
      (ibuffer-mode-opts (list 'buffer "*zz-deferred-filter*" 'filter-delay-ms 10000
        'rows (lambda (buf) '("*zz-nav-a*" "*zz-nav-b*"))
        'columns (lambda (buf) (set! *nf-draws* (+ *nf-draws* 1)) (list (list "name" 40))))))
    (list-mode-show! "zz-deferred-filter-mode")
    (define *nf-view* (current-buffer))
    (set! *nf-draws* 0)
    """)

    press("/")
    press(String.graphemes("zz-nav-a"))
    assert eval!("(minibuffer-input)") == ~s("zz-nav-a")
    assert eval!("*nf-draws*") == "0"
    press("C-g")
    assert eval!("(list-query *nf-view*)") == ~s("zz-nav-a")
    assert eval!("(filter string? (list-entries *nf-view*))") == ~s{("*zz-nav-a*")}
    Compos.Core.kill_buffer("*zz-deferred-filter*")
  end

  test "query edits reuse marginalia and ibuffer excludes chat transcript hits" do
    eval!(~S"""
    (define *nf-metadata-reads* 0)
    (advice-add! 'ibuffer-row-match 'before 'zz-metadata-count
      (lambda (row) (set! *nf-metadata-reads* (+ *nf-metadata-reads* 1))))
    (list-mode-show! "ibuffer-mode")
    (define *nf-view* (current-buffer))
    (buffer-set-locals! *nf-view* '(ibuffer-scope ("*zz-nav-a*" "*zz-nav-b*") ibuffer-grouping none))
    (list-refresh! *nf-view*)
    (list-set-query! *nf-view* "zz-nav")
    """)

    reads = eval!("*nf-metadata-reads*")
    eval!(~S{(list-set-query! *nf-view* "zz-nav-a") (list-set-query! *nf-view* "zz-nav")})
    assert eval!("*nf-metadata-reads*") == reads

    eval!(~S"""
    (set! *mode-list-search* '("chat-mode" "transcriptonlyneedle" (("*zz-nav-a*" "transcriptonlyneedle"))))
    (list-refresh! *nf-view*)
    (list-set-query! *nf-view* "transcriptonlyneedle")
    """)

    assert eval!("(filter string? (list-entries *nf-view*))") == "()"
    assert String.to_integer(eval!("*nf-metadata-reads*")) > String.to_integer(reads)
    eval!("(advice-remove! 'ibuffer-row-match 'zz-metadata-count)")
  end
end
