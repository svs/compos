defmodule Compos.Core.IRC do
  @moduledoc "IRC wire protocol codec. Transport and client policy stay outside this module."

  @doc "Parse one IRC line into prefix, command, params, and trailing text."
  def parse(line) when is_binary(line) do
    line = String.trim_trailing(line, "\r\n")

    {prefix, rest} =
      case line do
        <<":", tail::binary>> ->
          case String.split(tail, " ", parts: 2) do
            [p, r] -> {p, r}
            [p] -> {p, ""}
          end

        _ ->
          {nil, line}
      end

    {head, trailing} =
      case String.split(rest, " :", parts: 2) do
        [h, t] -> {h, t}
        [h] -> {h, nil}
      end

    words = String.split(head, " ", trim: true)

    {command, params} =
      case words do
        [command | ps] -> {command, ps}
        [] -> {"", []}
      end

    %{prefix: prefix, command: command, params: params, trailing: trailing, raw: line}
  end

  @doc "Encode an IRC command from a command, parameters, and optional trailing text."
  def format(command, params \\ [], trailing \\ nil) do
    fields = [String.upcase(to_string(command)) | Enum.map(params, &to_string/1)]
    body = Enum.join(fields, " ")
    body = if trailing == nil, do: body, else: body <> " :" <> to_string(trailing)
    body <> "\r\n"
  end
end
