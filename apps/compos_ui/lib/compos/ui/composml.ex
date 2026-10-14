defmodule Compos.Ui.ComposML do
  @moduledoc """
  ComposML's semantic vocabulary and tracked Phoenix template compiler.

  `~M` preserves semantic elements in the DOM. It uses Phoenix's parser,
  escaping, component machinery, and incremental engine directly. It does not
  turn the view into raw HTML or replace tags inside strings or scripts.
  """
  @behaviour Phoenix.LiveView.TagEngine

  @elements ~w(frame windows split window buffer line modeline headerline
    buffer-name mode position headline statusbar status progress tabs tab field
    label metric key-hints minibuffer completions completion which-key transcript
    message user agent toolcall info summary permission plan tool-call arguments result eval activity prompt input cursor toolbar echo
    action action-key value group text row card preview empty properties list item message-body question answers hint header)

  @mail_elements ~w(mailboxes mailbox mailbox-name unread-count message-count
    mail-query mail-threads mail-thread mail-subject mail-date mail-participants
    mail-tags mail-tag mail-message mail-from mail-to mail-body mail-attachments mail-attachment)

  # A hiring queue reads as applications, an application, and what was
  # written about it. The words are the site's own, so a view of one
  # application says what it holds and not which box it drew.
  @recruiting_elements ~w(applications application candidate
    application-state application-stars application-verdict application-role
    application-applied application-meta application-link application-actions
    application-event assessment letter)

  def domain_elements, do: @mail_elements ++ @recruiting_elements ++ ~w(morg-agenda agenda-day agenda-entry directory file filename size modified permissions vcs-status icon size-bar buffers buffer buffer-list buffer-entry chat-list chat-entry buffer-name buffer-mode buffer-size buffer-state buffer-icon buffer-group buffer-activity chat-name chat-state chat-tokens chat-model symbol-list symbol-entry symbol-name symbol-kind symbol-location agenda-title agenda-time agenda-deadline agenda-scheduled agenda-task-state agenda-tags agenda-source)

  def elements, do: Enum.map(@elements, &("c-" <> &1))

  defmacro sigil_M({:<<>>, meta, [source]}, modifiers) when modifiers == [] do
    unless Macro.Env.has_var?(__CALLER__, {:assigns, nil}) do
      raise ArgumentError, "~M requires an assigns map"
    end

    Phoenix.LiveView.TagEngine.compile(source,
      file: __CALLER__.file,
      line: __CALLER__.line + 1,
      caller: __CALLER__,
      indentation: meta[:indentation] || 0,
      tag_handler: __MODULE__
    )
  end

  @impl true
  def classify_type("c-" <> name = tag) do
    if name in @elements,
      do: {:tag, tag},
      else: {:error, "unknown ComposML element <#{tag}>"}
  end

  def classify_type(tag) when tag in ["div", "span"],
    do: {:error, "use a semantic ComposML element (or c-group/c-text) instead of <#{tag}>"}

  def classify_type(tag), do: Phoenix.LiveView.HTMLEngine.classify_type(tag)

  @impl true
  defdelegate void?(tag), to: Phoenix.LiveView.HTMLEngine
  @impl true
  defdelegate handle_attributes(ast, meta), to: Phoenix.LiveView.HTMLEngine
  @impl true
  defdelegate annotate_body(caller), to: Phoenix.LiveView.HTMLEngine
  @impl true
  defdelegate annotate_slot(name, meta, close_meta, caller), to: Phoenix.LiveView.HTMLEngine
  @impl true
  defdelegate annotate_caller(file, line, caller), to: Phoenix.LiveView.HTMLEngine
end
