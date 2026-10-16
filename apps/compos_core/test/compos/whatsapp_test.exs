defmodule Compos.WhatsappTest do
  @moduledoc """
  The WhatsApp modes use a held MCP seam. These tests verify the list,
  conversation, refresh, and reply paths without external traffic.
  """

  use Compos.Case, async: false

  alias Compos.Core.{Buffer, Editor, KeyDispatch}

  @list_buffer "*WhatsApp*"
  @chat_buffer "*WhatsApp conversation*"

  defp open_chat do
    eval!(~S|(run-command "whatsapp")|)
    eval!(~S|(switch-to-buffer! "*WhatsApp*")|)
    eval!(~S|(list-goto-first-entry "*WhatsApp*")|)
    press("RET")
  end

  setup do
    Compos.Core.kill_buffer(@list_buffer)
    Compos.Core.kill_buffer(@chat_buffer)
    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()

    prior_group_setting = eval!("whatsapp-group")

    eval!(~S"""
    (begin
      (set! whatsapp-group "whatsapp")
      (define *zz-whatsapp-list-fetches* 0)
      (define *zz-whatsapp-message-fetches* 0)
      (define *zz-whatsapp-sent* #f)
      (set! *whatsapp-call*
        (lambda (server tool args &optional cb)
          (cond
            ((equal? tool "list_chats")
             (set! *zz-whatsapp-list-fetches*
                   (+ *zz-whatsapp-list-fetches* 1))
             "{\"jid\":\"123@s.whatsapp.net\",\"name\":\"Mukund Jha Jha\",\"last_message_time\":\"2026-09-05T11:49:38+05:30\",\"last_message\":\"it's the weekend\",\"last_is_from_me\":1}")
            ((equal? tool "list_messages")
             (set! *zz-whatsapp-message-fetches*
                   (+ *zz-whatsapp-message-fetches* 1))
             (let ((text
                     "[2026-09-05 11:49:38] Chat: Mukund From: Me: it's the weekend\n"))
               (if cb (cb #t text) text)))
            ((equal? tool *whatsapp-reply-tool*)
             (set! *zz-whatsapp-sent* args)
             (if cb (cb #t "{\"success\":true}") "{\"success\":true}"))
            (else
              (if cb (cb #f "unknown tool") ""))))))
    """)

    on_exit(fn ->
      eval!("(set! whatsapp-group #{prior_group_setting})")
      eval!("(set! *whatsapp-call* mcp-call!)")
      Editor.minibuffer_close()
      Compos.Core.kill_buffer(@list_buffer)
      Compos.Core.kill_buffer(@chat_buffer)
    end)

    :ok
  end

  test "WhatsApp app buffers remain eligible for group layouts" do
    open_chat()
    assert eval!(~S|(buffer-special? "*WhatsApp*")|) == "#f"
    assert eval!(~S|(buffer-special? "*WhatsApp conversation*")|) == "#f"
    assert eval!(~S|(fill-candidate? "*WhatsApp*")|) == "#t"
  end

  test "empty destination opens in the current group" do
    eval!(~S|(switch-to-group! (group-ensure-record! "zz-whatsapp-here"))|)
    eval!(~S|(set! whatsapp-group "") (run-command "whatsapp")|)
    assert eval!("(group-name (frame-group))") == ~S("zz-whatsapp-here")
    assert eval!(~S|(buffer-in-group? "*WhatsApp*" "zz-whatsapp-here")|) == "#t"
    assert eval!(~S|(buffer-in-group? "*WhatsApp conversation*" "zz-whatsapp-here")|) == "#t"
  end

  test "named destination is selected before the scene creates buffers" do
    eval!(~S|(set! whatsapp-group "zz-whatsapp-destination") (run-command "whatsapp")|)
    assert eval!("(group-name (frame-group))") == ~S("zz-whatsapp-destination")
    assert eval!(~S|(buffer-in-group? "*WhatsApp*" "zz-whatsapp-destination")|) == "#t"

    assert eval!(~S|(buffer-in-group? "*WhatsApp conversation*" "zz-whatsapp-destination")|) ==
             "#t"
  end

  test "empty destination without a current group stays ungrouped" do
    eval!(~S"""
    (set-frame-local! 'current-group #f)
    (set-frame-local! 'pinned-group #f)
    (set! whatsapp-group "")
    (run-command "whatsapp")
    """)

    assert eval!("(frame-group)") == "#f"
    assert eval!(~S|(buffer-group "*WhatsApp*")|) == "#f"
    assert eval!(~S|(buffer-group "*WhatsApp conversation*")|) == "#f"
  end

  test "filter narrows WhatsApp chats locally" do
    eval!(~S|(run-command "whatsapp")|)
    assert eval!(~S|(group-name (frame-group))|) == ~S("whatsapp")
    assert eval!(~S|(window-buffer (scene-window 'index))|) == ~S("*WhatsApp*")

    assert eval!(~S|(window-buffer (scene-window 'show))|) ==
             ~S("*WhatsApp conversation*")

    assert eval!(~S|(group-name (buffer-group "*WhatsApp*"))|) == ~S("whatsapp")
    eval!(~S|(list-set-query! "*WhatsApp*" "jha")|)

    text = Buffer.text(@list_buffer)
    assert text =~ "/jha   1 of 1"
    assert text =~ "Mukund Jha Jha"

    eval!(~S|(list-set-query! "*WhatsApp*" "missing")|)

    text = Buffer.text(@list_buffer)
    assert text =~ "/missing   0 of 1"
    refute text =~ "Mukund Jha Jha"
  end

  test "RET opens a compact conversation and g refreshes it" do
    open_chat()

    assert eval!(~S|(group-name (buffer-group "*WhatsApp conversation*"))|) ==
             ~S("whatsapp")

    assert Buffer.text(@list_buffer) =~ "Mukund"
    assert Buffer.text(@list_buffer) =~ "me: it's the weekend"
    # the buffer holds the transcript the server printed, unedited:
    # the grammar reads it, and the blocks are the compact reading
    assert Buffer.text(@chat_buffer) =~ "[2026-09-05 11:49:38] Chat: Mukund From: Me:"

    assert eval!(~S|(map whatsapp--msg-sender (whatsapp--messages "*WhatsApp conversation*"))|) ==
             ~S|("Me")|

    assert eval!(~S|(map whatsapp--msg-body (whatsapp--messages "*WhatsApp conversation*"))|) ==
             ~S|("it's the weekend")|

    assert eval!(~S|(buffer-local "*WhatsApp conversation*" 'render-mode)|) ==
             ~S("blocks")

    assert eval!(~S|(length (buffer-local "*WhatsApp conversation*" 'render-blocks))|) ==
             "2"

    assert eval!(~S|(buffer-local "*WhatsApp conversation*" 'whatsapp-jid)|) ==
             ~S("123@s.whatsapp.net")

    assert eval!(~S|(window-buffer (scene-window 'show))|) ==
             ~S("*WhatsApp conversation*")

    assert eval!("*zz-whatsapp-message-fetches*") == "1"

    eval!(~S|(switch-to-buffer! "*WhatsApp conversation*")|)
    press("g")

    assert eval!("*zz-whatsapp-message-fetches*") == "2"
  end

  test "r replies to the selected chat from the index" do
    eval!(~S|(run-command "whatsapp")|)
    eval!(~S|(switch-to-buffer! "*WhatsApp*")|)
    eval!(~S|(list-goto-first-entry "*WhatsApp*")|)

    press("r")
    "From the index" |> String.graphemes() |> Enum.each(&KeyDispatch.handle_key/1)
    press("RET")

    sent = eval!("*zz-whatsapp-sent*")
    assert sent =~ ~S(recipient "123@s.whatsapp.net")
    assert sent =~ ~S(message "From the index")
    assert eval!("*zz-whatsapp-message-fetches*") == "0"
  end

  test "r collects a reply and sends it to the open chat" do
    open_chat()

    eval!(~S|(switch-to-buffer! "*WhatsApp conversation*")|)
    press("r")
    "On my way" |> String.graphemes() |> Enum.each(&KeyDispatch.handle_key/1)
    press("RET")

    sent = eval!("*zz-whatsapp-sent*")
    assert sent =~ ~S(recipient "123@s.whatsapp.net")
    # the one message on screen is the one being answered, so the
    # reply carries it: the transport has no reply-to field
    assert sent =~ "> Me: it's the weekend"
    assert sent =~ "On my way"
    assert eval!("*zz-whatsapp-message-fetches*") == "2"
  end

  test "messages are the unit of motion, and a reply quotes the one selected" do
    open_chat()

    eval!(~S"""
    (whatsapp--render-conversation! "*WhatsApp conversation*"
      (string-append
        "[2026-09-05 11:48:00] Chat: Mukund From: Mukund: are you around\n"
        "[2026-09-05 11:49:38] Chat: Mukund From: Me: it's the weekend\n"))
    """)

    assert eval!(~S|(length (whatsapp--messages "*WhatsApp conversation*"))|) == "2"

    # the transcript arrives newest first, so the message at the top is
    # the one a reader lands on
    assert eval!(
             ~S|(whatsapp--msg-sender (whatsapp--current-message "*WhatsApp conversation*"))|
           ) == ~S("Mukund")

    eval!(~S"""
    (with-current-buffer "*WhatsApp conversation*"
      (lambda () (run-command "whatsapp-next-message")))
    """)

    assert eval!(
             ~S|(whatsapp--msg-sender (whatsapp--current-message "*WhatsApp conversation*"))|
           ) == ~S("Me")

    eval!(~S"""
    (with-current-buffer "*WhatsApp conversation*"
      (lambda () (run-command "whatsapp-prev-message")))
    """)

    assert eval!(
             ~S|(whatsapp--msg-sender (whatsapp--current-message "*WhatsApp conversation*"))|
           ) == ~S("Mukund")

    assert eval!(~S|(value->string (buffer-local "*WhatsApp conversation*" 'render-blocks))|) =~
             "whatsapp-message-current"

    eval!(~S|(switch-to-buffer! "*WhatsApp conversation*")|)
    eval!(~S|(run-command "whatsapp-reply")|)
    "yes" |> String.graphemes() |> Enum.each(&KeyDispatch.handle_key/1)
    press("RET")

    sent = eval!("*zz-whatsapp-sent*")
    assert sent =~ "> Mukund: are you around"
    assert sent =~ "yes"
  end

  test "a late response cannot overwrite a newly selected chat" do
    eval!(~S"""
    (begin
      (buffer-create "*WhatsApp conversation*")
      (buffer-set-local! "*WhatsApp conversation*" 'whatsapp-jid "old@lid")
      (define *zz-whatsapp-late-callback* #f)
      (set! *whatsapp-call*
        (lambda (server tool args &optional cb)
          (set! *zz-whatsapp-late-callback* cb)
          ""))
      (whatsapp--refresh-conversation! "*WhatsApp conversation*")
      (buffer-set-local! "*WhatsApp conversation*" 'whatsapp-jid "new@lid")
      (*zz-whatsapp-late-callback* #t
        "[2026-09-05 20:00:00] Chat: Old From: Old: stale response\n"))
    """)

    refute Buffer.text(@chat_buffer) =~ "stale response"

    assert eval!(~S|(buffer-local "*WhatsApp conversation*" 'whatsapp-jid)|) ==
             ~S("new@lid")
  end

  test "mode setup keeps restored conversation identity and commands" do
    open_chat()

    eval!(~S"""
    (with-current-buffer "*WhatsApp conversation*"
      (lambda () (set-mode! "whatsapp-chat-mode")))
    """)

    eval!(~S|(switch-to-buffer! "*WhatsApp conversation*")|)
    press("g")

    assert eval!("*zz-whatsapp-message-fetches*") == "2"
    assert Buffer.text(@chat_buffer) =~ "it's the weekend"
  end
end
