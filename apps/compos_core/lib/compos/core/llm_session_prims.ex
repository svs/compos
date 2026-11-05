defmodule Compos.Core.LLMSession.Prims do
  @moduledoc "The Scheme primitives of this mechanism; the policy is in Scheme."

  import Compos.Core.Prims

  alias Compos.Core.Roots

  @doc "Every primitive under its {name, doc} key."
  def entries do
    %{
      # --- backend-neutral LLM sessions -------------------------------------
      # A frontend may install callbacks scoped to this session. Omitted
      # callbacks fall back to the chat globals below, preserving existing
      # agent integrations while inline/document frontends use the same
      # lifecycle and backend adapters.
      {"llm-session-open!",
       "(llm-session-open! ID CONFIG [CONTEXT EVENTS RECORD PERMISSION]) — open a backend-neutral LLM session."} =>
        fn [id, config | rest] ->
          keys = [:context, :handler, :record, :permission]

          callbacks =
            keys
            |> Enum.zip(rest)
            |> Map.new(fn {key, callback} -> {key, callback} end)

          case Compos.Core.LLMSession.open(s(id), plist_to_map(config), callbacks) do
            {:ok, _pid} ->
              s(id)

            {:error, {:already_started, _}} ->
              raise_scheme("LLM session already running: #{s(id)}")

            {:error, reason} ->
              raise_scheme("llm-session-open!: #{inspect(reason)}")
          end
        end,
      {"llm-session-send!",
       "(llm-session-send! ID TEXT [DISPLAY IMAGES]) — send or queue a message on an LLM session; IMAGES is ((MIME PATH) ...)."} =>
        fn [id, text | rest] ->
          display =
            case rest do
              [d | _] when is_binary(d) -> d
              _ -> nil
            end

          # attachments the user pasted: ((MIME PATH) ...). The bytes are
          # already a file on disk — only the path travels.
          images =
            case rest do
              [_, list | _] when is_list(list) ->
                for [mime, path] <- list,
                    is_binary(mime),
                    is_binary(path),
                    do: %{mime: mime, path: path}

              _ ->
                []
            end

          case Compos.Core.LLMSession.send(s(id), to_string(text), display, images) do
            :sent -> {:sym, "sent"}
            :queued -> {:sym, "queued"}
            {:error, r} -> raise_scheme("llm-session-send!: #{inspect(r)}")
          end
        end,
      {"llm-session-cancel!", "(llm-session-cancel! ID) — cancel an LLM session's current turn."} =>
        fn [id] ->
          Compos.Core.LLMSession.cancel(s(id))
          :void
        end,
      {"llm-session-dequeue!",
       "(llm-session-dequeue! ID TEXT) — remove one queued prompt without running it; #f when it already left the queue."} =>
        fn [id, text] ->
          case Compos.Core.LLMSession.dequeue(s(id), s(text)) do
            :ok -> true
            {:error, _} -> false
          end
        end,
      {"llm-session-promote!",
       "(llm-session-promote! ID TEXT) — move one queued prompt to the front of the queue; #f when it already left the queue."} =>
        fn [id, text] ->
          case Compos.Core.LLMSession.promote(s(id), s(text)) do
            :ok -> true
            {:error, _} -> false
          end
        end,
      {"llm-session-close!", "(llm-session-close! ID) — close an LLM session."} => fn [id] ->
        Compos.Core.LLMSession.close(s(id))
        :void
      end,
      {"llm-session-set-model!",
       "(llm-session-set-model! ID MODEL) — switch a live LLM session's model when supported."} =>
        fn [id, model] ->
          case Compos.Core.LLMSession.set_model(s(id), s(model)) do
            :ok -> true
            {:error, _} -> false
          end
        end,
      {"llm-session-set-effort!",
       "(llm-session-set-effort! ID EFFORT) — set reasoning effort for subsequent turns when supported."} =>
        fn [id, effort] ->
          case Compos.Core.LLMSession.set_effort(s(id), s(effort)) do
            :ok -> true
            {:error, _} -> false
          end
        end,
      {"llm-session-set-mode!",
       "(llm-session-set-mode! ID MODE) — switch a live LLM session's permission mode when supported."} =>
        fn [id, mode] ->
          case Compos.Core.LLMSession.set_mode(s(id), s(mode)) do
            :ok -> true
            {:error, _} -> false
          end
        end,
      {"llm-session-on-event!",
       "(llm-session-on-event! HANDLER) — set the default normalized-event handler for LLM sessions."} =>
        fn [handler] ->
          Roots.put({:agent_handler}, handler)
          :void
        end,
      {"llm-session-context-fn!",
       "(llm-session-context-fn! HANDLER) — set the default turn-context provider for LLM sessions."} =>
        fn [handler] ->
          Roots.put({:agent_context}, handler)
          :void
        end,
      {"llm-session-record-fn!",
       "(llm-session-record-fn! HANDLER) — set the default conversation-record writer for LLM sessions."} =>
        fn [handler] ->
          Roots.put({:agent_record}, handler)
          :void
        end,
      {"llm-session-permission-fn!",
       "(llm-session-permission-fn! HANDLER) — set the default tool permission policy for LLM sessions."} =>
        fn [handler] ->
          Roots.put({:agent_permission}, handler)
          :void
        end
    }
  end
end
