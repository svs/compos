defmodule Compos.SpotifyTest do
  @moduledoc """
  The player is a tab. These tests hold the wire, not Chrome: they assert the
  ops the commands put on it, and answer the way the extension would.
  """

  use ExUnit.Case

  alias Compos.Core.{Browser, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

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
    # chrome.scm warms its tab cache the moment the extension attaches, so the
    # first frame on this socket is that warm-up, not the command's
    flush()
    pid
  end

  defp flush do
    receive do
      {:frame, _} -> flush()
    after
      60 -> :ok
    end
  end

  defp reply(id, result), do: Browser.incoming(Jason.encode!(%{id: id, ok: true, result: result}))

  # the tabs answer the extension would send: one player, one other page
  defp answer_tabs(id) do
    reply(id, %{
      "tabs" => [
        %{"id" => 3, "url" => "https://news.example.com/", "title" => "News"},
        %{"id" => 9, "url" => "https://open.spotify.com/album/x", "title" => "Spotify"}
      ]
    })
  end

  setup do
    on_exit(fn ->
      Session.eval("(when (minibuffer-state) (minibuffer-cancel!))")
    end)

    :ok
  end

  test "C-c S s finds the player tab and presses its play button" do
    stub_socket()
    press(["C-c", "S", "s"])

    assert_receive {:frame, %{"op" => "tabs", "id" => id}}
    answer_tabs(id)

    assert_receive {:frame, %{"op" => "eval", "tab" => 9, "code" => code} = f}
    assert code =~ "control-button-playpause"

    # the page's own world: an extension may not evaluate a string in the
    # isolated one, and Spotify's answer is a CSP refusal
    assert f["world"] == "main"
  end

  test "next, previous and now-playing each press their own control" do
    stub_socket()

    for {cmd, needle} <- [
          {"spotify-next", "control-button-skip-forward"},
          {"spotify-previous", "control-button-skip-back"},
          {"spotify-now-playing", "now-playing-widget"}
        ] do
      eval!(~s[(run-command "#{cmd}")])
      assert_receive {:frame, %{"op" => "tabs", "id" => id}}
      answer_tabs(id)
      assert_receive {:frame, %{"op" => "eval", "tab" => 9, "code" => code}}
      assert code =~ needle
    end
  end

  test "with no player tab it opens one and says so, rather than doing nothing" do
    stub_socket()
    eval!(~s[(run-command "spotify-play-pause")])

    assert_receive {:frame, %{"op" => "tabs", "id" => id}}
    reply(id, %{"tabs" => [%{"id" => 3, "url" => "https://news.example.com/", "title" => "News"}]})

    assert_receive {:frame, %{"op" => "open", "url" => url}}
    assert url =~ "open.spotify.com"
  end

  test "search sends the query to the player's own page and raises the tab" do
    stub_socket()
    eval!(~s[(run-command "spotify-search")])
    eval!(~s[(minibuffer-input! "miles davis")])
    eval!("(minibuffer-confirm!)")

    assert_receive {:frame, %{"op" => "tabs", "id" => id}}
    answer_tabs(id)

    assert_receive {:frame, %{"op" => "eval", "tab" => 9, "code" => code}}
    assert code =~ "open.spotify.com/search/"
    # the query travels as JSON, so a quote in a song title cannot break out
    assert code =~ ~s("miles davis")

    assert_receive {:frame, %{"op" => "activate", "tab" => 9}}
  end

  # The tool is what the assistant holds. It waits for the page, so each test
  # answers the frame from another process while the interpreter blocks.
  defp tool(args) do
    task = Task.async(fn -> eval!(~s[(llm-tool-call "spotify" (list #{args}))]) end)
    task
  end

  defp answer(op, result) do
    assert_receive {:frame, %{"op" => ^op, "id" => id}}, 2000
    reply(id, result)
  end

  defp answer_player_tab, do: answer("tabs", %{"tabs" => [%{"id" => 9, "url" => "https://open.spotify.com/"}]})

  test "the assistant asks for the track and gets the answer in its own turn" do
    stub_socket()
    t = tool(~s['action "now-playing"])

    answer_player_tab()
    assert_receive {:frame, %{"op" => "eval", "tab" => 9, "world" => "main"} = f}, 2000
    assert f["code"] =~ "context-item-link"
    reply(f["id"], %{"value" => "Windowpane — Opeth"})

    # the point of the whole exercise: the answer comes back INSIDE the call,
    # so the model can say it in the same turn
    assert Task.await(t, 3000) =~ "Windowpane — Opeth"
  end

  test "pause reads the button before it presses it" do
    stub_socket()
    t = tool(~s['action "pause"])

    answer_player_tab()
    assert_receive {:frame, %{"op" => "eval", "id" => id, "code" => code}}, 2000
    assert code =~ "want==='pause'"
    reply(id, %{"value" => "paused"})

    assert Task.await(t, 3000) =~ "paused"
  end

  test "play with words searches, then presses the result that matches them" do
    stub_socket()
    t = tool(~s['action "play" 'query "blackwater park opeth"])

    answer_player_tab()
    assert_receive {:frame, %{"op" => "eval", "id" => nav, "code" => go}}, 2000
    assert go =~ "open.spotify.com/search/"
    assert go =~ "blackwater park opeth"
    reply(nav, %{"value" => "searching"})

    # the results are not drawn yet, so it asks again
    answer_player_tab()
    assert_receive {:frame, %{"op" => "eval", "id" => miss, "code" => try1}}, 2000
    assert try1 =~ "play-button"
    reply(miss, %{"value" => ""})

    answer_player_tab()
    assert_receive {:frame, %{"op" => "eval", "id" => hit}}, 2000
    reply(hit, %{"value" => "Play Blackwater Park"})

    assert Task.await(t, 5000) =~ "playing Play Blackwater Park"
  end

  test "volume without a level asks for one, rather than guessing" do
    stub_socket()
    assert eval!(~s[(llm-tool-call "spotify" (list 'action "volume"))]) =~ "0 to 100"
  end

  test "the volume verbs move the media element, both ways" do
    stub_socket()

    eval!(~s[(run-command "spotify-volume-up")])
    assert_receive {:frame, %{"op" => "tabs", "id" => id}}
    answer_tabs(id)
    assert_receive {:frame, %{"op" => "eval", "code" => up}}
    assert up =~ "m.volume+(0.1)"

    eval!(~s[(run-command "spotify-volume-down")])
    assert_receive {:frame, %{"op" => "tabs", "id" => id2}}
    answer_tabs(id2)
    assert_receive {:frame, %{"op" => "eval", "code" => down}}
    assert down =~ "m.volume+(-0.1)"
  end
end
