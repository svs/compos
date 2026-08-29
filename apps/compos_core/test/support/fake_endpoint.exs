# A line-oriented endpoint for tests, run as `elixir fake_endpoint.exs` from
# a Port. It is deliberately not a protocol: it answers commands with plain
# lines, which is what the Endpoint mechanism is supposed to carry.
#
#   echo WORD    -> WORD, then the sentinel "END"
#   rows N       -> N lines "row-1".."row-N", then "END"
#   quiet        -> nothing (used to prove an ask times out)
#   notice WORD  -> WORD with no sentinel and no ask outstanding
#   bye          -> exit 0
defmodule FakeEndpoint do
  def loop do
    case IO.gets("") do
      :eof -> :ok
      {:error, _} -> :ok
      line ->
        line |> String.trim() |> handle()
        loop()
    end
  end

  defp handle(""), do: :ok

  defp handle("bye"), do: System.halt(0)
  defp handle("quiet"), do: :ok
  defp handle("notice " <> word), do: say(word)

  defp handle("echo " <> word) do
    say(word)
    say("END")
  end

  defp handle("rows " <> n) do
    for i <- 1..String.to_integer(n), do: say("row-#{i}")
    say("END")
  end

  defp handle(other) do
    say("unknown: #{other}")
    say("END")
  end

  defp say(text), do: IO.puts(text)
end

FakeEndpoint.loop()
