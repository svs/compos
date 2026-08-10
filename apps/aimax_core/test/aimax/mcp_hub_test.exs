defmodule Aimax.MCPHubTest do
  @moduledoc """
  The MCP hub (packages/mcp-hub.scm) and the mechanism under it: what a
  connection discovers beyond tools, what it leaves behind when it dies, and
  the list buffer driven the way a person drives it — through KeyDispatch.
  """

  use ExUnit.Case

  alias Aimax.Core.{Editor, KeyDispatch, MCP, Session}

  @fixture Path.expand("../support/fake_mcp_server.exs", __DIR__)

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  defp wait_until(fun, tries \\ 300) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true ->
        Process.sleep(20)
        wait_until(fun, tries - 1)
    end
  end

  defp connect!(name) do
    on_exit(fn -> MCP.disconnect(name) end)
    {:ok, _} = MCP.connect(name, %{"command" => "elixir", "args" => [@fixture]})
    wait_until(fn -> MCP.tool_specs([name]) != [] end)
  end

  describe "discovery beyond tools" do
    test "resources land, and a server that overstates prompts stays alive" do
      connect!("hubfake")

      wait_until(fn -> MCP.detail("hubfake").resources != [] end)

      d = MCP.detail("hubfake")
      assert [%{"name" => "fake.txt"}] = d.resources
      assert d.prompts == []
      assert d.server_info["name"] == "fake-mcp"
      assert d.tools == [["echo", "Echo back v."]]

      # the -32601 for prompts/list must not have taken the connection down
      assert MCP.connected?("hubfake")
      assert {:ok, "echo:still here"} = MCP.call("hubfake", "echo", %{"v" => "still here"})
    end

    test "connections carry the counts the hub lists" do
      connect!("hubcounts")
      wait_until(fn -> MCP.detail("hubcounts").resources != [] end)

      assert %{status: :ready, type: :stdio, tools: 1, resources: 1, prompts: 0} =
               Enum.find(MCP.connections(), &(&1.name == "hubcounts"))
    end
  end

  describe "the log" do
    test "records both directions and outlives the connection" do
      connect!("hublog")
      assert {:ok, _} = MCP.call("hublog", "echo", %{"v" => "logged"})

      log = MCP.log("hublog")
      assert Enum.any?(log, &(&1.dir == :out and &1.text =~ "initialize"))
      assert Enum.any?(log, &(&1.dir == :in and &1.text =~ "fake-mcp"))
      assert Enum.any?(log, &(&1.dir == :out and &1.text =~ "tools/call"))

      MCP.disconnect("hublog")
      wait_until(fn -> not MCP.connected?("hublog") end)

      # the row went away; the reason it went away did not
      assert %{status: :stopped} = MCP.last("hublog")
      assert Enum.any?(MCP.log("hublog"), &(&1.text =~ "initialize"))
    end

    test "a server that never starts still explains itself" do
      {:ok, _} = MCP.connect("hubgone", %{"command" => "no-such-binary-zz"})
      wait_until(fn -> match?(%{status: :error}, MCP.last("hubgone")) end)

      assert %{status: :error} = MCP.detail("hubgone")
      assert Enum.any?(MCP.log("hubgone"), &(&1.dir == :note and &1.text =~ "command not found"))
    end
  end

  describe "the hub buffer" do
    setup do
      Editor.minibuffer_close()
      Editor.delete_other_windows()

      eval!(~s{(mcp-register! 'zzhub (list 'command "elixir" 'args (list "#{@fixture}")))})
      eval!(~s{(define-preset! 'zzhubpack "hub test pack" '(zzhub))})

      on_exit(fn ->
        MCP.disconnect("zzhub")
        Enum.each(["*mcp-hub*", "*mcp: zzhub*", "*mcp-log: zzhub*"], &Aimax.Core.kill_buffer/1)
      end)

      :ok
    end

    defp open_hub_on_zzhub do
      eval!(~s{(run-command "mcp-hub")})
      eval!(~s{(switch-to-buffer! "*mcp-hub*")})
      # header, column names, then rows: 'aimax first, ours last — and the
      # trailing newline means end-of-buffer lands one past the last row
      eval!("(end-of-buffer!)")
      eval!("(previous-line!)")
      eval!("(beginning-of-line!)")
      assert eval!("(mcp-hub-current)") == ~s{"zzhub"}
    end

    test "lists every registered server, running or not, with its presets" do
      open_hub_on_zzhub()

      text = eval!(~s{(buffer-text "*mcp-hub*")})
      assert text =~ "NAME"
      assert text =~ "aimax"
      assert text =~ "zzhub"
      assert text =~ "stopped"
      # ours is the only row carrying that preset
      assert text =~ "zzhubpack"
    end

    test "s starts the server on the line and the row goes ready by itself" do
      open_hub_on_zzhub()

      press("s")
      wait_until(fn -> MCP.connected?("zzhub") end)

      # no g pressed: mcp-on-change! redraws when the handshake lands
      wait_until(fn -> eval!(~s{(buffer-text "*mcp-hub*")}) =~ "ready" end)
      assert eval!(~s{(buffer-text "*mcp-hub*")}) =~ "stdio"
    end

    test "RET shows what the server serves, l shows the wire" do
      open_hub_on_zzhub()
      press("s")
      wait_until(fn -> MCP.tool_specs(["zzhub"]) != [] end)

      press("RET")
      detail = eval!(~s{(buffer-text "*mcp: zzhub*")})
      assert detail =~ "zzhub — stdio, ready"
      assert detail =~ "fake-mcp"
      assert detail =~ "Tools (1)"
      assert detail =~ "echo"
      assert detail =~ "Echo back v."
      assert detail =~ "Resources (1)"
      assert detail =~ "Prompts (0)"

      eval!(~s{(switch-to-buffer! "*mcp-hub*")})
      press("l")
      assert eval!(~s{(buffer-text "*mcp-log: zzhub*")}) =~ "initialize"
    end

    test "k stops it and the row falls back to what it left behind" do
      open_hub_on_zzhub()
      press("s")
      wait_until(fn -> MCP.connected?("zzhub") end)

      eval!(~s{(switch-to-buffer! "*mcp-hub*")})
      press("k")
      wait_until(fn -> not MCP.connected?("zzhub") end)
      wait_until(fn -> eval!(~s{(buffer-text "*mcp-hub*")}) =~ "stopped" end)
    end

    # the restore path: desktop lays content + locals down and calls
    # set-mode!, and the setup fn must rebuild from the locals it finds
    # rather than leave last session's text standing
    test "a restored detail buffer comes back live, not as a frozen screenshot" do
      eval!(~s{(buffer-create "*mcp: zzstale*")})
      eval!(~s{(buffer-append! "*mcp: zzstale*" "zzstale — stdio, ready\\nTools (9)\\n")})
      eval!(~s{(buffer-set-local! "*mcp: zzstale*" 'mcp-hub-name "zzstale")})
      eval!(~s{(switch-to-buffer! "*mcp: zzstale*")})

      eval!(~s{(set-mode! "mcp-detail-mode")})

      text = eval!(~s{(buffer-text "*mcp: zzstale*")})
      assert text =~ "not started"
      refute text =~ "Tools (9)"

      on_exit(fn -> Aimax.Core.kill_buffer("*mcp: zzstale*") end)
    end

    # a name no test has ever connected: nothing live, and no record left
    # behind either, which is the only state with nothing to show
    test "a server never started says so instead of opening an empty detail" do
      eval!(~s{(mcp-register! 'zznever '(command "zz-never-server"))})
      eval!(~s{(mcp-hub-show-detail "zznever")})

      assert eval!(~s{(buffer-exists? "*mcp: zznever*")}) == "#f"
      assert eval!(~s{(buffer-text "*messages*")}) =~ "has never been started"
    end
  end
end
