defmodule Aimax.ChromeTest do
  @moduledoc """
  The browser wire, both directions.

  No Chrome here — `Aimax.Core.Browser` runs against a stub socket process, the
  way the Stub agent backend stands in for a real one. Outbound tests assert
  what lands on the wire; inbound tests feed the daemon the frames a tab would
  send when someone presses M-x in it.

  What the editor DECIDES — which tabs are beside you, a tab's label, the
  order of the switch list — needs no extension and lives in
  priv/tests/chrome-test.scm.
  """

  use ExUnit.Case

  alias Aimax.Core.{Browser, Buffer, Editor, Session}

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  # stands in for the extension's WebSocket transport: every frame the daemon
  # pushes is forwarded here, so we can assert on the protocol itself
  defp stub_socket do
    test = self()

    pid =
      spawn_link(fn ->
        recv = fn recv ->
          receive do
            {:browser_send, text} ->
              send(test, {:frame, Jason.decode!(text)})
              recv.(recv)
          end
        end

        recv.(recv)
      end)

    Browser.attach(pid)
    on_exit(fn -> Browser.detach(pid) end)
    pid
  end

  # a request from the browser, as the extension would send it
  defp request(id, op, args \\ %{}) do
    Browser.incoming(Jason.encode!(Map.merge(args, %{"id" => id, "op" => op})))
  end

  # these tests make buffers in the shared session; leaving them behind changes
  # what buffer-list returns for everyone downstream
  setup do
    on_exit(fn ->
      # a prompt left open belongs to the whole session, and the next test
      # would find the editor already asking it something
      Session.eval("(when (minibuffer-state) (minibuffer-cancel!))")

      for b <- ["*chrome-test*", "*ran-it*", "*tabs*", "*picked-beta*"] do
        Session.eval(~s[(when (buffer-exists? "#{b}") (buffer-kill! "#{b}"))])
      end

      # the frame's browser window is session state too: left set, it sends
      # the next test's tabs into a window that does not exist
      Session.eval("(set-frame-local! 'chrome-window #f)")
    end)

    :ok
  end

  describe "outbound — Scheme addresses a tab" do
    test "a message to a tab goes out as an overlay op" do
      stub_socket()
      eval!(~s[(tab-say 7 "hello from the editor")])

      assert_receive {:frame, f}
      assert f["op"] == "overlay"
      assert f["tab"] == 7
      assert f["text"] == "hello from the editor"
    end

    test "typing is a distinct op, because it needs trusted input" do
      stub_socket()
      eval!(~s[(tab-type 7 "svs@wrok.ae")])

      assert_receive {:frame, %{"op" => "type", "tab" => 7, "text" => "svs@wrok.ae"}}
    end

    test "a click carries viewport coordinates" do
      stub_socket()
      eval!("(tab-click 7 120 340)")

      assert_receive {:frame, %{"op" => "click", "tab" => 7, "x" => 120, "y" => 340}}
    end

    test "eval defaults to the isolated world; -main asks for the page's own" do
      stub_socket()

      eval!(~s[(tab-eval 7 "document.title" (lambda (v) #t))])
      assert_receive {:frame, f1}
      assert f1["op"] == "eval"
      refute f1["world"]

      eval!(~s[(tab-eval-main 7 "window.__APP__" (lambda (r) #t))])
      assert_receive {:frame, %{"world" => "main"}}
    end

    test "a reply reaches the Scheme handler" do
      stub_socket()
      eval!(~s[(tab-read 7 (lambda (r) (buffer-create "*chrome-test*")
                             (buffer-append! "*chrome-test*" (chrome--get r 'title))))])

      assert_receive {:frame, %{"op" => "read", "id" => id}}

      Browser.incoming(
        Jason.encode!(%{id: id, ok: true, result: %{"title" => "Inbox", "url" => "https://x/"}})
      )

      wait_for(fn ->
        Buffer.exists?("*chrome-test*") and Buffer.text("*chrome-test*") =~ "Inbox"
      end)
    end

    test "with no extension the caller is told, rather than hanging" do
      Browser.detach(self())
      refute Browser.connected?()

      me = self()
      Browser.call("tabs", %{}, &send(me, {:reply, &1}))
      assert_receive {:reply, {:error, msg}}
      assert msg =~ "extension"
    end
  end

  describe "inbound — a tab asks the daemon" do
    # M-x in a page runs the editor's own execute-extended-command and renders
    # the minibuffer it opens. There is no second command list and no second
    # matcher — the overlay used to filter its own copy with a cruder match, so
    # the same query ranked differently in a tab than in ai-max.
    test "M-x is the editor's own command, prompt and all" do
      stub_socket()
      request(1, "run", %{"tab" => 12, "name" => "execute-extended-command"})

      assert_receive {:frame, %{"id" => 1, "ok" => true, "result" => r}}, 2000
      assert r["open"] == true
      assert r["minibuffer"]["prompt"] == "M-x "

      # the real table, not a copy: hundreds of commands, MRU-ordered, each
      # annotated the way the editor's own M-x annotates them
      assert r["minibuffer"]["total"] > 100
      names = Enum.map(r["minibuffer"]["candidates"], & &1["label"])
      assert "execute-extended-command" in names

      # and it filters with the editor's matcher, not one of the overlay's
      eval!(~s[(minibuffer-input! "listtab")])
      assert eval!(~s[(map (lambda (c) (chrome--get c 'label))
                           (chrome--get (minibuffer-state) 'candidates))]) =~ "list-tabs"
    end

    test "picking a command runs it here, in the daemon" do
      stub_socket()
      eval!(~s[(define-command "chrome-test-marker" "t" (lambda () (buffer-create "*ran-it*")))])

      request(2, "run", %{"tab" => 12, "name" => "chrome-test-marker"})

      assert_receive {:frame, %{"id" => 2, "ok" => true}}, 2000
      wait_for(fn -> Buffer.exists?("*ran-it*") end)
    end

    test "an unknown op is answered, not dropped" do
      stub_socket()
      request(3, "nonsense")

      assert_receive {:frame, %{"id" => 3, "ok" => true, "result" => %{"error" => err}}}, 2000
      assert err =~ "unknown op"
    end

    # Deliberately an empty key list. dispatch-keys hands the real dispatcher a
    # task, and the dispatcher is stateful for ANY key — even an unbound one
    # sets the echo area and breaks the undo chain. Fired asynchronously in a
    # shared session, that lands in whichever test runs next; it cost two
    # unrelated tests before this comment existed. What's under test here is
    # the routing, so route nothing.
    test "a chord is routed to the chord handler and answered" do
      stub_socket()
      request(4, "chord", %{"tab" => 12, "keys" => []})

      assert_receive {:frame, %{"id" => 4, "ok" => true, "result" => %{"message" => ""}}}, 2000
    end

  end

  # The gap that made C-x b look broken: the command reached the daemon and
  # opened a prompt in the editor window, where the person who pressed it
  # wasn't looking. A tab has to be able to see the question and answer it.
  describe "the editor's questions, asked in the tab" do
    # opened directly rather than through a chord: dispatch-keys is
    # deliberately asynchronous, and this is about the prompt, not the timing
    defp open_prompt do
      eval!("""
      (minibuffer-read "Pick: " '("alpha" "beta" "gamma")
        (lambda (x) (buffer-create (string-append "*picked-" x "*"))))
      """)
    end

    test "an open prompt is reported to the tab, with its candidates" do
      stub_socket()
      open_prompt()
      request(10, "mb-state")

      assert_receive {:frame, %{"id" => 10, "ok" => true, "result" => r}}, 2000
      assert r["open"] == true
      assert r["minibuffer"]["prompt"] == "Pick: "
      assert Enum.map(r["minibuffer"]["candidates"], & &1["label"]) == ~w(alpha beta gamma)
    end

    test "typing from the tab narrows the daemon's candidate list" do
      stub_socket()
      open_prompt()
      request(11, "mb-key", %{"spec" => "b"})

      assert_receive {:frame, %{"id" => 11, "ok" => true, "result" => r}}, 2000
      assert r["minibuffer"]["input"] == "b"
      assert Enum.map(r["minibuffer"]["candidates"], & &1["label"]) == ["beta"]
    end

    test "RET from the tab runs the prompt's callback and closes it" do
      stub_socket()
      open_prompt()

      request(12, "mb-key", %{"spec" => "b"})
      assert_receive {:frame, %{"id" => 12, "ok" => true}}, 2000

      request(13, "mb-key", %{"spec" => "RET"})
      assert_receive {:frame, %{"id" => 13, "ok" => true, "result" => %{"open" => false}}}, 2000

      # the callback ran here, in the editor, with the tab's answer
      wait_for(fn -> Buffer.exists?("*picked-beta*") end)
    end

    test "C-g from the tab cancels it" do
      stub_socket()
      open_prompt()

      request(14, "mb-key", %{"spec" => "C-g"})
      assert_receive {:frame, %{"id" => 14, "ok" => true, "result" => %{"open" => false}}}, 2000
      assert eval!("(minibuffer-state)") == "#f"
    end

    test "a key aimed at no prompt says so instead of guessing" do
      stub_socket()
      request(15, "mb-key", %{"spec" => "x"})

      assert_receive {:frame, %{"id" => 15, "ok" => true, "result" => %{"message" => m}}}, 2000
      assert m == "no prompt"
    end
  end

  # Coming back from a web page is not the same as moving around inside the
  # editor. You clicked a link out of a mail, and C-x b RET has to put you back
  # where you were — not rearrange the three-window scene you left.
  describe "returning from a page" do
    test "a buffer already on screen is selected, not pulled somewhere else" do
      eval!(~s[(begin (buffer-create "*mail-index*") (buffer-create "*mail-show*"))])
      # a two-window scene, with the target visible in the OTHER window
      eval!(~s[(begin (switch-to-buffer! "*mail-index*") (split-window! "h")
                      (other-window!) (switch-to-buffer! "*mail-show*") (other-window!))])

      before = eval!("(window-list)")
      assert before =~ "*mail-show*"
      assert eval!("(current-buffer)") == ~s("*mail-index*")

      # the window showing it is found, so nothing is pulled
      win = eval!(~s[(chrome--window-showing "*mail-show*")])
      refute win == "#f"

      eval!(~s[(select-window! #{win})])
      assert eval!("(current-buffer)") == ~s("*mail-show*")
      # the scene is intact: both windows still show what they showed
      assert eval!("(window-list)") == before
    end

    # a tab you can switch to belongs in the same list as the buffers
    # the same list wherever you press it — only what selecting DOES differs
    test "C-x b is the editor's own command, redefined rather than rebound" do
      assert eval!(~s[(key-for-command "switch-to-buffer")]) == ~s("C-x b")
    end

    test "with no extension attached the prompt is still just the buffer list" do
      Browser.detach(self())
      refute Browser.connected?()

      Session.eval(~s[(run-command "switch-to-buffer-prompt")])
      # a prompt opened rather than the command dying on the missing browser
      assert eval!(~s[(chrome--get (minibuffer-state) 'prompt)]) =~ "Switch to (default"
      Session.eval("(minibuffer-cancel!)")
    end

    # Buffers are not tracked here at all — buffer-list-mru is the editor's own
    # ring, updated wherever a buffer is displayed, the same choke point Emacs
    # uses. A second history here only saw switches through this one command,
    # so it drifted and then outranked the truth. The only fact kept is the tab
    # you were last in and the ring's head at that moment; if the head has not
    # moved, nothing has been displayed since and the tab still leads.
    test "C-x b from a page routes to the returning prompt, not raw dispatch" do
      assert eval!(~s[(chrome--chord-command '("C-x" "b"))]) == ~s("switch-to-buffer-prompt")
      # anything without its own browser meaning still goes through the keymap
      assert eval!(~s[(chrome--chord-command '("C-x" "o"))]) == "#f"
    end

    test "confirming a prompt raises the editor; cancelling does not" do
      stub_socket()
      open_prompt()

      request(20, "mb-key", %{"spec" => "RET"})
      assert_receive {:frame, %{"id" => 20, "ok" => true, "result" => %{"raise" => true}}}, 2000

      open_prompt()
      request(21, "mb-key", %{"spec" => "C-g"})
      assert_receive {:frame, %{"id" => 21, "ok" => true, "result" => r}}, 2000
      refute r["raise"]
    end
  end

  # One frame, one browser window. The daemon has to know which window a frame
  # is displayed in, or a tab it opens lands wherever Chrome looked last — a
  # chat on the left screen answering on the right one.
  describe "one frame, one browser window" do
    defp this_frame, do: eval!("(selected-frame)") |> String.trim("\"")

    test "the editor page's registration binds its frame to its window" do
      stub_socket()

      request(30, "register", %{"frame" => this_frame(), "window" => 91})
      assert_receive {:frame, %{"id" => 30, "ok" => true}}, 2000

      assert eval!("(chrome-window)") == "91"
    end

    test "a key pressed in a page binds the window too" do
      stub_socket()

      request(31, "mb-state", %{"frame" => this_frame(), "window" => 92, "tab" => 7})
      assert_receive {:frame, %{"id" => 31, "ok" => true}}, 2000

      assert eval!("(chrome-window)") == "92"
    end

    test "a tab opens in the frame's own window" do
      stub_socket()
      eval!("(set-frame-local! 'chrome-window 91)")

      eval!(~s[(tab-open "https://example.com/")])
      assert_receive {:frame, %{"op" => "open", "url" => "https://example.com/", "window" => 91}}
    end

    test "an explicit window wins over the frame's" do
      stub_socket()
      eval!("(set-frame-local! 'chrome-window 91)")

      eval!(~s[(tab-open "https://example.com/" 92)])
      assert_receive {:frame, %{"op" => "open", "window" => 92}}
    end

    # no binding is not an error: Chrome picks the window it focused last,
    # which is what every earlier version did
    test "an unbound frame names no window at all" do
      stub_socket()
      eval!("(set-frame-local! 'chrome-window #f)")

      eval!(~s[(tab-open "https://example.com/")])
      assert_receive {:frame, %{"op" => "open"} = f}
      refute Map.has_key?(f, "window")
    end
  end

  describe "refresh-frames" do
    test "sweeps every frame no browser tab answers for, keeps the rest" do
      stub_socket()

      here = this_frame()
      {:ok, shown} = Editor.attach_frame(nil)
      {:ok, dead1} = Editor.attach_frame(nil)
      {:ok, dead2} = Editor.attach_frame(nil)
      on_exit(fn -> Enum.each([shown], &Editor.delete_frame/1) end)

      # attach_frame bumps the frame MRU, so pin the command's own frame
      assert :ok = Session.run_command("refresh-frames", here)

      assert_receive {:frame, %{"op" => "frames", "id" => id}}, 2000

      Browser.incoming(
        Jason.encode!(%{
          "id" => id,
          "ok" => true,
          "result" => %{"frames" => [%{"window" => 91, "tab" => 7, "frame" => shown}]}
        })
      )

      assert eventually(fn ->
               frames = Editor.frame_list()
               dead1 not in frames and dead2 not in frames
             end)

      frames = Editor.frame_list()
      assert here in frames
      assert shown in frames
    end
  end

  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(50)
        eventually(fun, tries - 1)
    end
  end

  describe "scheme_to_json" do
    test "a plist becomes an object, a plain list an array" do
      assert Session.scheme_to_json([{:sym, "a"}, 1, {:sym, "b"}, 2]) == %{"a" => 1, "b" => 2}
      assert Session.scheme_to_json([1, 2, 3]) == [1, 2, 3]
      # odd length can't be a plist, so it stays a list
      assert Session.scheme_to_json([{:sym, "a"}, 1, 2]) == ["a", 1, 2]
    end

    test "nesting and scheme's falsehood survive the trip" do
      assert Session.scheme_to_json([{:sym, "xs"}, [[{:sym, "n"}, 1]]]) == %{
               "xs" => [%{"n" => 1}]
             }

      assert Session.scheme_to_json(false) == false
    end
  end

  defp wait_for(fun, tries \\ 60) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true -> Process.sleep(25) && wait_for(fun, tries - 1)
    end
  end
end
