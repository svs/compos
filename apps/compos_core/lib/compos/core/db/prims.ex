defmodule Compos.Core.DB.Prims do
  @moduledoc "The Scheme primitives of this mechanism; the policy is in Scheme."

  import Compos.Core.Prims
  alias Compos.Core.Session

  alias Compos.Core.Roots

  @doc "Every primitive under its {name, doc} key."
  def entries do
    %{
      # --- Databases (Compos.Core.DB; policy in packages/db.scm) ------------
      {"db-connect!",
       "(db-connect! NAME SPEC) — open a named database connection; SPEC has 'adapter 'database 'user 'password 'host or 'socket_dir 'port 'ssl."} =>
        fn [name, spec] ->
          case Compos.Core.DB.connect(s(name), plist_to_map(spec)) do
            {:ok, _} -> :void
            {:error, msg} -> raise_scheme("db-connect!: #{msg}")
          end
        end,
      {"db-disconnect!", "(db-disconnect! NAME) — close the database connection NAME."} => fn [
                                                                                                name
                                                                                              ] ->
        Compos.Core.DB.disconnect(s(name))
        :void
      end,
      {"db-connected?", "(db-connected? NAME) — #t when NAME is open."} => fn [name] ->
        Compos.Core.DB.whereis(s(name)) != nil
      end,
      {"db-adapters", "(db-adapters) — the database adapters this build can open."} => fn [] ->
        String.split(Compos.Core.DB.known_adapters(), ", ")
      end,
      {"db-query",
       "(db-query NAME-OR-TRANSACTION SQL [PARAMS] [CB]) — without CB, run on the calling lane and return RESULT; with CB, answer asynchronously with (OK RESULT)."} =>
        fn
          [target, sql] ->
            db_query_sync(db_target(target), s(sql), [])

          [target, sql, params] when is_list(params) ->
            db_query_sync(db_target(target), s(sql), db_params(params))

          [name, sql, params, callback] ->
            Compos.Core.DB.query(s(name), s(sql), db_params(params), db_cb(callback))
            :void

          [name, sql, callback] ->
            Compos.Core.DB.query(s(name), s(sql), [], db_cb(callback))
            :void
        end,
      {"db-with-transaction",
       "(db-with-transaction NAME PROC) — call PROC with a scoped transaction handle; commit and return its value, or roll back on error."} =>
        fn [name, procedure], store ->
          case Compos.Core.DB.with_transaction(s(name), fn transaction ->
                 Compos.Scheme.Eval.apply_fn(procedure, [transaction], store)
               end) do
            {:ok, result_and_store} -> result_and_store
            {:error, msg} -> raise_scheme("db-with-transaction: #{msg}")
          end
        end
    }
  end

  # Scheme values -> bound query parameters. A parameter is never spliced
  # into SQL text, so a string stays a string whatever it contains.
  defp db_params(list) when is_list(list), do: Enum.map(list, &db_param/1)
  defp db_params(_), do: []
  defp db_param({:sym, "null"}), do: nil
  defp db_param(false), do: false
  defp db_param(true), do: true
  defp db_param({:sym, other}), do: other
  defp db_param(v), do: v
  # A decoded row value -> a Scheme term. SQL NULL becomes #f, the same
  # answer json-parse gives, and a numeric becomes text so no precision is
  # lost on the way through a float.
  defp db_value(nil), do: false
  defp db_value(%Decimal{} = d), do: Decimal.to_string(d)
  defp db_value(%DateTime{} = t), do: DateTime.to_iso8601(t)
  defp db_value(%NaiveDateTime{} = t), do: NaiveDateTime.to_iso8601(t)
  defp db_value(%Date{} = d), do: Date.to_iso8601(d)
  defp db_value(%Time{} = t), do: Time.to_iso8601(t)
  defp db_value(v) when is_list(v), do: Enum.map(v, &db_value/1)
  defp db_value(v) when is_map(v) and not is_struct(v), do: Compos.Core.LLM.json_to_scheme(v)
  defp db_value(v) when is_struct(v), do: inspect(v)
  defp db_value(v), do: v

  defp db_cb(callback) do
    refkey = {:db_call, make_ref()}
    Roots.hold(refkey, callback)

    fn result ->
      try do
        Session.apply_callback(callback, db_callback_args(result))
      after
        Roots.drop(refkey)
      end
    end
  end

  defp db_query_sync(name, sql, params) do
    case Compos.Core.DB.query(name, sql, params) do
      {:ok, result} ->
        db_result(result)

      {:error, msg} ->
        raise_scheme("db-query: #{msg}")
    end
  end

  defp db_result(result) do
    [true, value] = db_callback_args({:ok, result})
    value
  end

  defp db_target(%Compos.Core.DB.Transaction{} = transaction), do: transaction
  defp db_target(name), do: s(name)

  defp db_callback_args({:ok, r}) do
    [
      true,
      [
        {:sym, "columns"},
        r.columns,
        {:sym, "rows"},
        Enum.map(r.rows, fn row -> Enum.map(row, &db_value/1) end),
        {:sym, "count"},
        r.num_rows,
        {:sym, "command"},
        r.command
      ]
    ]
  end

  defp db_callback_args({:error, msg}), do: [false, to_string(msg)]
end
