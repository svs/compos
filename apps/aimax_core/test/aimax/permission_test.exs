defmodule Aimax.PermissionTest do
  @moduledoc """
  W5's done-when: ONE policy, three modalities, identical on both lanes.

  In approve mode a long agent turn completes with zero prompts, and a
  send-mail attempt still banners — proved on the ACP lane (Stub) and the
  direct lane (ReqLLM). Double-answering is a no-op; killing a chat with a
  pending request resolves it; ask mode behaves exactly as before.
  """

  use ExUnit.Case

  alias Aimax.Core.{Agent, Buffer, Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp focus(buf),
    do: {:ok, _} = Session.eval(~s[(begin (switch-to-buffer! "#{buf}") (end-of-buffer!))])

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()

    on_exit(fn ->
      Application.delete_env(:aimax_core, :llm_chat_fun)
      Enum.each(Agent.list(), &Agent.kill/1)

      Enum.each(Aimax.Core.list_buffers(), fn name ->
        if String.starts_with?(name, "*chat:") or Buffer.get_local(name, "agent-slug"),
          do: Aimax.Core.kill_buffer(name)
      end)

      Editor.delete_other_windows()
    end)

    :ok
  end

  describe "the policy itself" do
    test "the deny-list catches irreversible outward acts, and only those" do
      for verb <- [
            "send-mail",
            "sendmail",
            "mail-send",
            "Send Message to bob@example.com",
            "permanently delete",
            "empty-trash",
            "git push",
            "publish"
          ] do
        assert eval!(~s{(permission-denied-verb? "#{verb}")}) != "#f",
               "expected #{verb} to be deny-listed"
      end

      for safe <- ["buffer-text", "read foo.ex", "eval-scheme", "mail-search tag:inbox"] do
        assert eval!(~s{(permission-denied-verb? "#{safe}")}) == "#f",
               "expected #{safe} to pass"
      end
    end

    test "mode decides everything the deny-list doesn't" do
      buf = "*zz-policy*"
      eval!(~s{(buffer-create "#{buf}")})
      on_exit(fn -> Aimax.Core.kill_buffer(buf) end)

      # default (approve): ordinary tools run, deny-listed ones ask
      assert eval!(~s{(*permission-policy* "#{buf}" "eval-scheme" "tool" "(+ 1 1)")}) ==
               "allow-always"

      assert eval!(~s{(*permission-policy* "#{buf}" "eval-scheme" "tool" "(mail-send ...)")}) ==
               "ask"

      # ask mode: everything asks
      eval!(~s{(buffer-set-local! "#{buf}" 'chat-permission-mode 'ask)})
      assert eval!(~s{(*permission-policy* "#{buf}" "eval-scheme" "tool" "(+ 1 1)")}) == "ask"

      # auto: same as approve at OUR chokepoints — the deny-list holds
      eval!(~s{(buffer-set-local! "#{buf}" 'chat-permission-mode 'auto)})
      assert eval!(~s{(*permission-policy* "#{buf}" "eval-scheme" "tool" "(+ 1 1)")}) ==
               "allow-always"

      assert eval!(~s{(*permission-policy* "#{buf}" "eval-scheme" "tool" "(mail-send ...)")}) ==
               "ask"
    end

    test "a tool's declared side effects decide before the chat mode does" do
      buf = "*zz-effects*"
      eval!(~s{(buffer-create "#{buf}")})

      eval!("""
      (define-tool! 'zz-shred "test: irreversible" '()
        (lambda (args) "gone") '(destroy))
      """)

      on_exit(fn ->
        Aimax.Core.kill_buffer(buf)
        Session.eval("(set! *llm-tools* (remove (lambda (t) (equal? (car t) 'zz-shred)) *llm-tools*))")
      end)

      # read-only tools never ask, even in ask mode
      eval!(~s{(buffer-set-local! "#{buf}" 'chat-permission-mode 'ask)})
      assert eval!(~s{(*permission-policy* "#{buf}" "apropos" "tool" "apropos args")}) ==
               "allow-always"

      # destroy-effect tools ask, even in approve mode
      eval!(~s{(buffer-set-local! "#{buf}" 'chat-permission-mode 'approve)})
      assert eval!(~s{(*permission-policy* "#{buf}" "zz-shred" "tool" "zz-shred args")}) ==
               "ask"

      # a tool the catalog does not know falls through to the mode
      assert eval!(~s{(*permission-policy* "#{buf}" "zz-unknown" "tool" "zz-unknown args")}) ==
               "allow-always"
    end

    test "a per-agent profile denies its own patterns; no profile is allow-all" do
      buf = "*zz-profile*"
      eval!(~s{(buffer-create "#{buf}")})
      on_exit(fn -> Aimax.Core.kill_buffer(buf) end)

      # no profile: the shared deny-list holds, everything else allows
      assert eval!(~s{(*permission-policy* "#{buf}" "eval-scheme" "tool" "(graphql-run ...)")}) ==
               "allow-always"

      # a profile with one extra deny pattern rejects exactly that verb
      eval!(
        ~s{(buffer-set-local! "#{buf}" 'agent-permission-profile '(deny-patterns ("graphql")))}
      )

      assert eval!(~s{(*permission-policy* "#{buf}" "eval-scheme" "tool" "(graphql-run ...)")}) ==
               "reject"

      # ...and leaves everything else alone
      assert eval!(~s{(*permission-policy* "#{buf}" "eval-scheme" "tool" "(+ 1 1)")}) ==
               "allow-always"

      # the pure seam permission packages call: #f profile is allow-all
      assert eval!(~s{(profile-denies? #f "anything")}) == "#f"
      assert eval!(~s{(profile-denies? '(deny-patterns ("git push")) "git push origin")}) !=
               "#f"
    end

    test "modes can grant a named command through the shared policy" do
      allowed = "*zz-command-allowed*"
      other = "*zz-command-other*"
      eval!(~s{(begin (buffer-create "#{allowed}") (buffer-create "#{other}"))})

      on_exit(fn ->
        Aimax.Core.kill_buffer(allowed)
        Aimax.Core.kill_buffer(other)
      end)

      eval!(
        ~s{(allow-command-when! "zz-reload"
              (lambda (buf) (equal? buf "#{allowed}")))}
      )

      assert eval!(~s{(*permission-policy* "#{allowed}" "zz-reload" "command" "")}) ==
               "allow-always"

      assert eval!(~s{(*permission-policy* "#{other}" "zz-reload" "command" "")}) ==
               "ask"
    end

    test "the MCP proxy refuses deny-listed payloads even when the agent stopped asking" do
      args = Base.encode64(Jason.encode!(%{"code" => ~s{(mail-send "bob" "hi")}}))

      out =
        eval!(~s{(mcp-proxy-call "eval-scheme" "#{args}")})
        |> String.trim("\"")
        |> Base.decode64!()

      assert out =~ "refused"
      # the pattern that caught it, so the agent knows what to ask for
      assert out =~ "mail"

      # an ordinary payload still runs
      ok = Base.encode64(Jason.encode!(%{"code" => "(+ 20 22)"}))

      assert eval!(~s{(mcp-proxy-call "eval-scheme" "#{ok}")})
             |> String.trim("\"")
             |> Base.decode64!() =~ "42"
    end
  end

  describe "the ACP lane (Stub backend)" do
    test "approve mode: 20 tool calls, zero prompts; send-mail still banners" do
      calls =
        for i <- 1..20 do
          ~s{(type permission rpc-id #{i} title "Read file#{i}.ex" kind "read" } <>
            ~s{options (("ok" "Allow" "allow_once")))}
        end
        |> Enum.join("\n")

      {:ok, _} =
        Session.eval("""
        (execute* "go" '(backend "stub" script
          ((#{calls}
            (type chunk text "twenty done"))
           ((type permission rpc-id 99 title "Send mail to the team" kind "external"
                  options (("ok" "Allow" "allow_once")))))))
        """)

      buf = "*chat:a1*"

      # every request answered by policy, invisibly: no banner ever rendered
      assert eventually(fn -> Buffer.text(buf) =~ "twenty done" end)
      assert eventually(fn -> match?(%{status: :idle}, Agent.info("a1")) end)
      refute Buffer.text(buf) =~ "needs permission"

      refute (Buffer.get_local(buf, "agent-blocks") || [])
             |> Enum.any?(&match?([_, _, "permission" | _], &1))

      # ...and the stub was really answered 20 times, with the allow option
      assert %{queued: 0} = Agent.info("a1")

      # now a deny-listed act on the SAME chat: this one stops
      {:ok, _} = Session.eval(~s[(agent-prompt! "a1" "clean up")])
      assert eventually(fn -> Buffer.text(buf) =~ "needs permission: Send mail to the team" end)
      assert %{status: :needs_attention} = Agent.info("a1")
    end
  end

  describe "the direct lane (ReqLLM backend)" do
    test "approve mode runs tools ungated; a deny-listed call banners and blocks" do
      me = self()

      Application.put_env(:aimax_core, :llm_chat_fun, fn req ->
        if Enum.any?(req.messages, &(is_list(&1.content) and &1.content != [])) do
          {:ok,
           %{
             "stop_reason" => "end_turn",
             "content" => [%{"type" => "text", "text" => "finished"}],
             "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
           }}
        else
          send(me, :round1)

          {:ok,
           %{
             "stop_reason" => "tool_use",
             "content" => [
               %{
                 "type" => "tool_use",
                 "id" => "t1",
                 "name" => "eval-scheme",
                 "input" => %{"code" => "(+ 1 1)"}
               }
             ],
             "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
           }}
        end
      end)

      {:ok, _} = Session.eval(~s{(execute* "add" '(connector "api"))})
      buf = "*chat:a1*"

      assert_receive :round1, 2_000
      assert eventually(fn -> Buffer.text(buf) =~ "finished" end)
      # an ordinary tool ran with no banner at all
      refute Buffer.text(buf) =~ "needs permission"
      assert Buffer.text(buf) =~ "▸ tool · eval-scheme"
    end

    test "a deny-listed tool call banners on the direct lane and answers through the same keys" do
      Application.put_env(:aimax_core, :llm_chat_fun, fn req ->
        if Enum.any?(req.messages, &(is_list(&1.content) and &1.content != [])) do
          # the tool result came back — report what the gate did
          [%{content: [%{content: result} | _]} | _] = Enum.reverse(req.messages)

          {:ok,
           %{
             "stop_reason" => "end_turn",
             "content" => [%{"type" => "text", "text" => "tool said: #{result}"}],
             "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
           }}
        else
          {:ok,
           %{
             "stop_reason" => "tool_use",
             "content" => [
               %{
                 "type" => "tool_use",
                 "id" => "t1",
                 "name" => "eval-scheme",
                 "input" => %{"code" => ~s{(mail-send "bob" "hi")}}
               }
             ],
             "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
           }}
        end
      end)

      {:ok, _} = Session.eval(~s{(execute* "mail bob" '(connector "api"))})
      buf = "*chat:a1*"

      # the SAME banner, the SAME block kind, the SAME keys as the ACP lane
      assert eventually(fn -> Buffer.text(buf) =~ "needs permission: eval-scheme" end)
      assert eventually(fn -> match?(%{status: :needs_attention}, Agent.info("a1")) end)

      assert (Buffer.get_local(buf, "agent-blocks") || [])
             |> Enum.any?(&match?([_, _, "permission" | _], &1))

      focus(buf)
      press(["C-c", "C-n"])

      # denied -> the tool never ran, the model was told, the turn finished
      assert eventually(fn -> Buffer.text(buf) =~ "permission denied" end)
      assert eventually(fn -> Buffer.text(buf) =~ "tool said:" end)
      assert eventually(fn -> match?(%{status: :idle}, Agent.info("a1")) end)
    end
  end

  describe "robustness" do
    test "double-answering is a no-op, and killing a chat resolves a pending request" do
      {:ok, _} =
        Session.eval("""
        (execute* "go" '(permission-mode ask backend "stub" script
          (((type permission rpc-id 5 title "Write x" kind "edit"
                  options (("ok" "Allow" "allow_once")))
            (type chunk text "after")))))
        """)

      assert eventually(fn -> match?(%{status: :needs_attention}, Agent.info("a1")) end)

      # answering twice: the second is silently ignored, not an error
      assert :ok = Agent.respond_permission("a1", 5, "ok")
      assert :ok = Agent.respond_permission("a1", 5, "ok")
      assert eventually(fn -> Buffer.text("*chat:a1*") =~ "after" end)

      # a fresh request, then kill the thread: the backend is answered
      # (cancelled) rather than left blocked forever
      {:ok, _} =
        Session.eval("""
        (execute* "go" '(permission-mode ask backend "stub" script
          (((type permission rpc-id 9 title "Write y" kind "edit"
                  options (("ok" "Allow" "allow_once")))))))
        """)

      assert eventually(fn -> match?(%{status: :needs_attention}, Agent.info("a2")) end)
      assert :ok = Agent.kill("a2")
      assert eventually(fn -> not Agent.running?("a2") end)
    end

    test "an unwatched chat's banner auto-denies on its deadline" do
      {:ok, _} = Session.eval(~s{(set! permission-timeout-ms 300)})
      on_exit(fn -> Session.eval(~s{(set! permission-timeout-ms 120000)}) end)

      {:ok, _} =
        Session.eval("""
        (execute* "" '(permission-mode ask backend "stub" script
          (((type permission rpc-id 3 title "Write z" kind "edit"
                  options (("ok" "Allow" "allow_once")))
            (type chunk text "moved on")))))
        """)

      buf = "*chat:a1*"

      # nobody is looking at it BEFORE the request arrives — that is the
      # condition that arms the deadline, so the turn starts after the
      # window is gone rather than racing it
      Editor.delete_other_windows()
      {:ok, _} = Session.eval(~s[(switch-to-buffer! "*scratch*")])

      {:ok, _} = Session.eval(~s[(agent-prompt! "a1" "go")])
      assert eventually(fn -> match?(%{status: :needs_attention}, Agent.info("a1")) end)

      # ...so it denies itself and the turn continues
      assert eventually(fn -> Buffer.text(buf) =~ "timed out" end, 60)
      assert eventually(fn -> match?(%{status: :idle}, Agent.info("a1")) end, 60)
    end
  end

  # R5: one gate. Three chokepoints used to hold three policies — the ACP
  # lane could not see a tool call's arguments at all, the proxy applied
  # the deny-list alone, and a crashing policy let the call through.
  describe "one gate" do
    test "the same payload is refused on all three chokepoints" do
      payload = ~s{(mail-send "bob@example.com" "hi")}

      # 1. the policy, asked directly — what both lanes consult
      assert eval!(~s{(*permission-policy* #f "eval-scheme" "tool" #{inspect(payload)})}) == "ask"

      # 2. the ACP lane sees the same string, because the permission event
      #    now carries the tool call's arguments and not just its title
      assert eval!(~s{(permission-denied-verb? #{inspect("Run command " <> payload)})}) != "#f"

      # 3. the proxy, which nobody can answer, refuses outright
      args = Base.encode64(Jason.encode!(%{"code" => payload}))

      out =
        eval!(~s{(mcp-proxy-call "eval-scheme" "#{args}")})
        |> String.trim("\"")
        |> Base.decode64!()

      assert out =~ "refused"
    end

    test "a chat in ask mode is in ask mode on the proxy too" do
      # the proxy has no chat, so it reads the default — which IS the
      # chat-wide setting a user changes with C-c p
      eval!("(set! *permission-default-mode* 'ask)")
      on_exit(fn -> Session.eval("(set! *permission-default-mode* 'approve)") end)

      args = Base.encode64(Jason.encode!(%{"code" => "(+ 1 1)"}))

      out =
        eval!(~s{(mcp-proxy-call "eval-scheme" "#{args}")})
        |> String.trim("\"")
        |> Base.decode64!()

      # it used to run: the proxy applied the deny-list and nothing else
      assert out =~ "refused"
      assert out =~ "ask"
    end

    test "a policy that crashes denies the call instead of waving it through" do
      me = self()

      Application.put_env(:aimax_core, :llm_chat_fun, fn req ->
        if Enum.any?(req.messages, &is_list(&1.content)) do
          send(me, {:result, req.messages |> List.last() |> Map.get(:content)})

          {:ok,
           %{"stop_reason" => "end_turn", "content" => [%{"type" => "text", "text" => "done"}],
             "usage" => %{"input_tokens" => 1, "output_tokens" => 1}}}
        else
          {:ok,
           %{
             "stop_reason" => "tool_use",
             "content" => [
               %{"type" => "tool_use", "id" => "t1", "name" => "eval-scheme",
                 "input" => %{"code" => "(+ 1 1)"}}
             ],
             "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
           }}
        end
      end)

      # a policy that raises on every call — the shape of a user's broken
      # override in ~/.aimax/init.scm
      eval!("(agent-permission-fn! (lambda (slug name kind raw) (car '())))")

      on_exit(fn ->
        Session.eval("""
        (agent-permission-fn!
          (lambda (slug name kind raw)
            (let* ((buf (agent-buf slug)) (v (*permission-policy* buf name kind raw)))
              (cond ((equal? v 'reject) 'reject) ((equal? v 'ask) 'ask) (else 'allow)))))
        """)
      end)

      {:ok, _} = Session.eval(~s{(execute* "" '(connector "api"))})
      buf = "*chat:a1*"
      focus(buf)
      Session.eval(~s{(agent-prompt! "a1" "run the tool")})

      assert_receive {:result, [%{content: result} | _]}, 3_000

      # fail closed: the tool did not run, and the transcript names the
      # thing to fix rather than silently allowing everything
      assert result =~ "crashed"
      refute result == "2"
      assert eventually(fn -> Buffer.text(buf) =~ "permission policy crashed" end)
    end
  end

  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true ->
        Process.sleep(50)
        eventually(fun, tries - 1)
    end
  end
end
