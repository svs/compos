defmodule Aimax.Ui.AgentTranscript do
  @moduledoc """
  The agent transcript block list, isolated in a LiveComponent.

  The isolation is the mechanism: on every patch the LiveView client
  rebuilds the whole view's HTML and walks the whole DOM against it.
  With the transcript inline, one keystroke in the input row walked
  every block of the conversation, and the walk grew with the chat.
  As a component with unchanged assigns, the diff ships a skip
  placeholder instead, and the client never enters this subtree.

  The parent passes `blocks` from its decorate cache, so the list is
  reference-equal between input edits and only changes when the block
  model changes. Events here carry no `phx-target`: they go to the
  parent LiveView, which owns every handler.
  """
  use Phoenix.LiveComponent

  @impl true
  def render(assigns) do
    ~H"""
    <div class="ag-scroll">
      <%= for b <- @blocks do %>
        <%= case b.kind do %>
          <% :user -> %>
            <div class="ag-user"><span class="ag-label">YOU</span><div class="ag-user-text">{b.text}</div></div>
          <% :queued -> %>
            <div class="ag-user ag-queued"><span class="ag-label">YOU</span><div class="ag-user-text">{b.text}</div></div>
          <% :prose -> %>
            <div class="ag-prose">{Phoenix.HTML.raw(b.html)}</div>
          <% :thought -> %>
            <details class="ag-thought"><summary>thought</summary><div class="ag-thought-text">{b.text}</div></details>
          <% :tool -> %>
            <details class={"ag-tool #{b.status}"} open={b.open}>
              <summary
                phx-click="agent_card"
                phx-value-win={@win}
                phx-value-id={b.id}
                aria-label={"#{b.verb} #{b.title}, #{b.status}. Toggle call details"}
                onclick="event.preventDefault()"
              >
                <span class="ag-chevron" aria-hidden="true">›</span>
                <span class={"ag-dot #{b.status}"}></span>
                <span class="ag-verb ag-kind">{b.verb}</span>
                <span class="ag-summary-copy">
                  <span class="ag-title" title={b.title}>{b.title}</span>
                  <span :if={!b.open && b.preview != ""} class="ag-preview">{b.preview}</span>
                </span>
                <span class={"ag-tstatus #{b.status}"}>{b.status}</span>
              </summary>
              <pre :if={b.body != ""} class="ag-body">{b.body}</pre>
            </details>
          <% :plan -> %>
            <pre class="ag-plan">{b.text}</pre>
          <% :permission -> %>
            <div class="ag-perm">
              <span class="ag-perm-title">needs permission — {b.title}</span>
              <button
                class="ag-btn allow"
                phx-click="ui_cmd"
                phx-value-win={@win}
                phx-value-cmd="agent-permission-allow"
              >Allow</button>
              <button
                class="ag-btn session"
                phx-click="ui_cmd"
                phx-value-win={@win}
                phx-value-cmd="agent-permission-always"
              >Always</button>
              <button
                class="ag-btn deny"
                phx-click="ui_cmd"
                phx-value-win={@win}
                phx-value-cmd="agent-permission-deny"
              >Deny</button>
            </div>
          <% :question -> %>
            <div class="ag-question">
              <div class="ag-question-title">{b.question}</div>
              <div class="ag-question-answers">
                <button
                  :for={answer <- b.answers}
                  class="ag-btn answer"
                  phx-click="agent_answer"
                  phx-value-win={@win}
                  phx-value-slug={b.slug}
                  phx-value-question={b.id}
                  phx-value-answer={answer}
                >{answer}</button>
              </div>
              <div class="ag-question-hint">Choose an answer or type another reply below.</div>
            </div>
          <% :waiting -> %>
            <div class="ag-wait">⋯ thinking</div>
          <% :meta -> %>
            <div class="ag-meta">{b.text}</div>
        <% end %>
      <% end %>
    </div>
    """
  end
end
