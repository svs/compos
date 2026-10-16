defmodule Compos.SubagentResultTest do
  @moduledoc """
  The turn-end hook, and what a parent reads off a child.

  A real Agent ends a real turn behind Backend.Stub, with no wire. What is
  under test is everything that hangs off that turn end:

    * agent.ex dispatches it to Scheme once the turn has RENDERED, on the
      :ui lane, and agent.scm fans it out on the agent-turn-end hook.
    * a child reports STRUCTURALLY: (subagent-result SLUG) reads the child's
      own last message and costs the parent no turn at all.
    * 'notify #t is the opt-in exception, a free-text wake into the parent.
    * subagent-wait answers a parent that fanned out to several children.
  """

  use Compos.Case

  alias Compos.Core.{Agent, Buffer, Editor, Session}

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()

    on_exit(fn ->
      # the probe listener is keyed by name, so a no-op replaces it
      Session.eval(~s[(add-hook! (list 'agent-turn-end "zz-probe") (lambda (s r ok) #f))])
      Enum.each(Agent.list(), &Agent.kill/1)

      Enum.each(Compos.Core.list_buffers(), fn name ->
        if String.starts_with?(name, "*agent") or Buffer.get_local(name, "agent-slug"),
          do: Compos.Core.kill_buffer(name)
      end)

      Editor.delete_other_windows()
    end)

    :ok
  end

  defp slug(out), do: String.trim(out, "\"")

  # a chat's durable slug and its buffer name are two different things:
  # execute* answers the slug, and the buffer is named from the short spawn
  # name. Ask the editor rather than guessing one from the other.
  defp chat_buf(s), do: slug(eval!(~s[(agent-buf "#{s}")]))

  defp eventually(fun, tries \\ 60) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true ->
        Process.sleep(50)
        eventually(fun, tries - 1)
    end
  end

  test "a finished turn reaches Scheme on the agent-turn-end hook, with the slug and the stop reason" do
    eval!("(define zz-turn-end-log '())")

    eval!("""
    (add-hook! (list 'agent-turn-end "zz-probe")
      (lambda (slug stop ok?)
        (set! zz-turn-end-log (cons (list slug stop ok?) zz-turn-end-log))))
    """)

    s = slug(eval!(~s[(execute* "go" '(backend "stub" script (((type chunk text "done.")))))]))

    assert eventually(fn -> eval!("(length zz-turn-end-log)") == "1" end),
           "the turn ended but no listener was called: #{eval!("zz-turn-end-log")}"

    assert eval!("(car zz-turn-end-log)") == ~s[("#{s}" "end_turn" #t)]

    # the hook fires AFTER the batch rendered: the assistant's turn is
    # already in the record when a listener runs
    assert eval!(~s[(plist-get (subagent-result "#{s}") 'text)]) == ~s["done."]
  end

  test "a turn that died reaches the same hook, and says it did not end normally" do
    eval!("(define zz-turn-end-log '())")

    eval!("""
    (add-hook! (list 'agent-turn-end "zz-probe")
      (lambda (slug stop ok?)
        (set! zz-turn-end-log (cons (list slug stop ok?) zz-turn-end-log))))
    """)

    # turn-failed is the backend saying the turn died with no result; the
    # Agent turns it into a turn-end whose stop reason is "error"
    s = slug(eval!(~s[(execute* "go" '(backend "stub" script (((type turn-failed)))))]))

    assert eventually(fn ->
             eval!(~s[(if (member (list "#{s}" "error" #f) zz-turn-end-log) 1 0)]) == "1"
           end),
           "no failed turn end was reported: #{eval!("zz-turn-end-log")}"

    # and the normality test is a plain function, so a caller can ask
    # without waiting for anything
    assert eval!(~s[(agent-turn-end-normal? "error")]) == "#f"
    assert eval!(~s[(agent-turn-end-normal? "cancelled")]) == "#f"
    assert eval!(~s[(agent-turn-end-normal? "end_turn")]) == "#t"
  end

  test "a child reports structurally, and the parent spends no turn reading it" do
    p = slug(eval!(~s[(execute* "" '(backend "stub" script ()))]))

    c =
      slug(
        eval!("""
        (with-edit-author "agent:#{p}"
          (lambda ()
            (execute* "what is it" '(backend "stub" script
              (((type chunk text "the answer is 42.")))))))
        """)
      )

    assert eventually(fn -> match?(%{status: :idle}, Agent.info(c)) end)
    assert eval!(~s[(subagent-parent "#{c}")]) == ~s["#{p}"]

    # the turn-end hook runs on the :ui lane after the render; the record
    # says done once it ran
    assert eventually(fn -> eval!(~s[(plist-get (subagent-result "#{c}") 'status)]) == "stopped" end)
    assert eval!(~s[(plist-get (subagent-result "#{c}") 'stop-reason)]) == ~s["end_turn"]
    assert eval!(~s[(plist-get (subagent-result "#{c}") 'text)]) == ~s["the answer is 42."]
    assert eval!(~s[(plist-get (subagent-result "#{c}") 'buffer)]) == ~s["#{chat_buf(c)}"]

    # the whole point: reading the child cost the parent nothing. Its
    # conversation of record is still empty and its thread never ran.
    assert eval!(~s[(length (chat-turns "#{chat_buf(p)}"))]) == "0"
    refute Buffer.text(chat_buf(p)) =~ ">>> you:"

    # and a collect over the parent's children answers in spawn order
    assert eval!(~s[(map (lambda (r) (plist-get r 'text)) (subagent-collect (subagent-children "#{p}")))]) ==
             ~s[("the answer is 42.")]
  end

  test "a chat that never ran a turn is idle, not done" do
    s = slug(eval!(~s[(execute* "" '(backend "stub" script ()))]))
    assert eventually(fn -> match?(%{status: :idle}, Agent.info(s)) end)

    assert eval!(~s[(plist-get (subagent-result "#{s}") 'status)]) == "idle"
    assert eval!(~s[(subagent-done? "#{s}")]) == "#f"
    assert eval!(~s[(plist-get (subagent-result "#{s}") 'text)]) == ~s[""]
  end

  test "'notify #t wakes the parent with free text" do
    # the parent needs a turn of its own to answer the wake with
    p = slug(eval!(~s[(execute* "" '(backend "stub" script (())))]))
    assert eventually(fn -> match?(%{status: :idle}, Agent.info(p)) end)

    c =
      slug(
        eval!("""
        (with-edit-author "agent:#{p}"
          (lambda ()
            (execute* "go" '(notify #t backend "stub" script
              (((type chunk text "child says hi.")))))))
        """)
      )

    assert eventually(fn -> Buffer.text(chat_buf(p)) =~ "[subagent #{c} finished its turn]" end),
           "the parent was never woken: #{Buffer.text(chat_buf(p))}"

    parent_text = Buffer.text(chat_buf(p))
    assert parent_text =~ "child says hi."
    assert parent_text =~ "(subagent-result \"#{c}\")"
  end

  test "without 'notify the parent is never woken" do
    p = slug(eval!(~s[(execute* "" '(backend "stub" script (())))]))
    assert eventually(fn -> match?(%{status: :idle}, Agent.info(p)) end)

    c =
      slug(
        eval!("""
        (with-edit-author "agent:#{p}"
          (lambda ()
            (execute* "go" '(backend "stub" script
              (((type chunk text "child says hi.")))))))
        """)
      )

    assert eventually(fn -> eval!(~s[(subagent-stopped? "#{c}")]) == "#t" end)
    Process.sleep(200)

    refute Buffer.text(chat_buf(p)) =~ "[subagent"
    assert eval!(~s[(length (chat-turns "#{chat_buf(p)}"))]) == "0"
  end

  test "subagent-wait answers once every child has reached a turn end" do
    a = slug(eval!(~s[(execute* "" '(backend "stub" script (((type chunk text "one.")))))]))
    b = slug(eval!(~s[(execute* "" '(backend "stub" script (((type chunk text "two.")))))]))
    assert eventually(fn -> match?(%{status: :idle}, Agent.info(b)) end)

    eval!("(define zz-wait-results 'pending)")

    assert eval!("""
           (subagent-wait '("#{a}" "#{b}")
             (lambda (rs) (set! zz-wait-results rs)))
           """) == "waiting"

    eval!(~s[(agent-continue! "#{a}" "go")])
    assert eventually(fn -> eval!(~s[(subagent-stopped? "#{a}")]) == "#t" end)

    # one of two is not enough
    assert eval!("(if (equal? zz-wait-results 'pending) 1 0)") == "1"

    eval!(~s[(agent-continue! "#{b}" "go")])
    assert eventually(fn -> eval!("(if (equal? zz-wait-results 'pending) 1 0)") == "0" end)

    assert eval!("(map (lambda (r) (plist-get r 'text)) zz-wait-results)") ==
             ~s[("one." "two.")]

    assert eval!("(map (lambda (r) (plist-get r 'status)) zz-wait-results)") == "(stopped stopped)"
  end

  test "subagent-wait answers at once when the children have already finished" do
    a = slug(eval!(~s[(execute* "go" '(backend "stub" script (((type chunk text "one.")))))]))
    assert eventually(fn -> eval!(~s[(subagent-stopped? "#{a}")]) == "#t" end)

    eval!("(define zz-wait-results 'pending)")

    assert eval!("""
           (subagent-wait "#{a}" (lambda (rs) (set! zz-wait-results rs)))
           """) == "done"

    assert eval!("(map (lambda (r) (plist-get r 'text)) zz-wait-results)") == ~s[("one.")]
  end

  test "done is set by the orchestrator, and a new turn clears it" do
    a = slug(eval!(~s[(execute* "go" '(backend "stub" script (((type chunk text "one.")))))]))
    assert eventually(fn -> eval!(~s[(subagent-stopped? "#{a}")]) == "#t" end)
    assert eval!(~s[(subagent-done? "#{a}")]) == "#f"

    assert eval!(~s[(subagent-mark-done! "#{a}" "checked")]) == "done"
    assert eval!(~s[(subagent-done? "#{a}")]) == "#t"
    assert eval!(~s[(plist-get (subagent-result "#{a}") 'result)]) == ~s["checked"]

    eval!(~s[(agent-continue! "#{a}" "again")])
    assert eventually(fn -> eval!(~s[(plist-get (subagent-result "#{a}") 'status)]) == "stopped" end)
    assert eval!(~s[(subagent-done? "#{a}")]) == "#f"
  end
end
