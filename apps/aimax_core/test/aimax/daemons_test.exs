defmodule Aimax.DaemonsTest do
  @moduledoc "Daemon registry, workspace ownership, and the C-x d list."

  use ExUnit.Case

  alias Aimax.Core.{Browser, Editor, KeyDispatch, Session}

  defp eval!(code) do
    {:ok, out} = Session.eval(code)
    out
  end

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  defp stub_browser do
    test = self()

    pid =
      spawn_link(fn ->
        receive_frames = fn receive_frames ->
          receive do
            {:browser_send, text} ->
              send(test, {:browser_frame, Jason.decode!(text)})
              receive_frames.(receive_frames)
          end
        end

        receive_frames.(receive_frames)
      end)

    Browser.attach(pid)
    on_exit(fn -> Browser.detach(pid) end)
  end

  setup do
    path = Application.fetch_env!(:aimax_core, :daemon_registry_path)
    File.rm(path)
    eval!("(daemon-register-current! #f)")
    Editor.minibuffer_close()
    Editor.set_pending([])

    on_exit(fn ->
      Aimax.Core.kill_buffer("*daemons*")
      Aimax.Core.kill_buffer("*workspaces*")
      Aimax.Core.kill_buffer("*workspace-source*")
      File.rm(path)
      eval!("(daemon-register-current! #f)")
    end)

    :ok
  end

  test "C-x d opens the daemon table and RET requests same-tab navigation" do
    eval!(~s{(daemon-register! "remote" "https://dev.example.test" "server")})

    press(["C-x", "d"])

    assert Editor.current_buffer() == "*daemons*"
    assert eval!(~s{(buffer-text "*daemons*")}) =~ "remote"
    assert eval!(~s{(buffer-text "*daemons*")}) =~ "current"
    assert eval!(~s{(buffer-text "*daemons*")}) =~ "CURRENT  aimax · workspace"
    assert eval!(~s{(buffer-local "*daemons*" 'mode-name)}) == ~s{"daemons-mode"}

    # Desktop restore re-runs the saved mode. It rebuilds the table and keys
    # from the shared registry without storing derived row text.
    eval!(~s{(set-mode! "daemons-mode")})
    assert eval!(~s{(buffer-text "*daemons*")}) =~ "remote"

    assert eval!(~s{(car (cdr (assoc "RET" (local-keys "*daemons*"))))}) ==
             ~s{"daemon-visit"}

    press("n")
    press("RET")

    assert Editor.take_navigation("f-main") ==
             "https://dev.example.test?daemon-switch=1"
  end

  test "a stopped worktree daemon starts before the tab switches" do
    workspace =
      Path.join(System.tmp_dir!(), "daemon-switch-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "apps/aimax_core"))
    File.write!(Path.join(workspace, "mix.exs"), "# test checkout\n")
    test = self()

    Application.put_env(:aimax_core, :workspace_daemon_provisioner, fn path, name ->
      send(test, {:daemon_started, path, name})
      {:ok, %{url: "http://localhost:4212", home: "/tmp/a1-home", port: 4212}}
    end)

    on_exit(fn ->
      Application.delete_env(:aimax_core, :workspace_daemon_provisioner)
      File.rm_rf!(workspace)
    end)

    eval!(
      ~s{(daemon-assign-workspace! "worktree-a1" "http://localhost:4204" "/tmp/a1-home" "#{workspace}")}
    )

    press(["C-x", "d"])
    press("n")
    press("RET")

    assert_receive {:daemon_started, ^workspace, "a1"}

    assert Editor.take_navigation("f-main") ==
             "http://localhost:4212?daemon-switch=1"
  end

  test "a worktree switch stays put when its daemon cannot start" do
    workspace =
      Path.join(System.tmp_dir!(), "daemon-failed-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "apps/aimax_core"))
    File.write!(Path.join(workspace, "mix.exs"), "# test checkout\n")

    Application.put_env(:aimax_core, :workspace_daemon_provisioner, fn _path, _name ->
      {:error, :boot_failed}
    end)

    on_exit(fn ->
      Application.delete_env(:aimax_core, :workspace_daemon_provisioner)
      File.rm_rf!(workspace)
    end)

    eval!(
      ~s{(daemon-assign-workspace! "worktree-broken" "http://localhost:4298" "/tmp/broken-home" "#{workspace}")}
    )

    press(["C-x", "d"])
    press("n")
    press("RET")

    assert Editor.take_navigation("f-main") == nil
    assert Editor.snapshot().echo =~ "workspace daemon failed"
  end

  test "one workspace cannot belong to two registered daemons" do
    workspace = "/tmp/daemon-owned-#{System.unique_integer([:positive])}"
    daemon_url = eval!("(editor-url)") |> String.trim("\"")
    assert eval!(~s{(daemon-claim-workspace! "#{workspace}")}) =~ daemon_url

    current = eval!(~s{(daemon-workspace-owner "#{workspace}")})
    assert current =~ ~s{name "aimax"}

    path = Application.fetch_env!(:aimax_core, :daemon_registry_path)

    entries = Jason.decode!(File.read!(path))

    remote = %{
      "name" => "remote",
      "url" => "https://remote.example.test",
      "location" => "server",
      "workspace" => workspace,
      "workspaces" => [workspace]
    }

    current =
      Enum.map(entries, fn entry ->
        if entry["url"] == daemon_url,
          do: Map.put(entry, "workspaces", []),
          else: entry
      end)

    File.write!(path, Jason.encode!([remote | current]))

    assert {:error, error} = Session.eval(~s{(daemon-claim-workspace! "#{workspace}")})
    assert error =~ "workspace belongs to another daemon"
  end

  test "a workspace can be assigned to its provisioned daemon" do
    workspace = "/tmp/daemon-feature-#{System.unique_integer([:positive])}"

    eval!(
      ~s{(daemon-assign-workspace! "worktree-a1" "http://localhost:4204" "/tmp/a1-home" "#{workspace}")}
    )

    owner = eval!(~s{(daemon-workspace-owner "#{workspace}")})
    assert owner =~ ~s{name "worktree-a1"}
    assert owner =~ ~s{url "http://localhost:4204"}
    assert owner =~ workspace
  end

  test "C-x w lists workspaces and RET opens the selected daemon in a new tab" do
    stub_browser()
    workspace = "/tmp/workspace-tab-#{System.unique_integer([:positive])}"

    eval!(
      ~s{(daemon-assign-workspace! "worktree-tab" "http://localhost:4208" "/tmp/tab-home" "#{workspace}")}
    )

    eval!(~s{(daemon-name-workspace! "#{workspace}" "ai-max" "workspace prompts")})

    eval!(
      ~s{(begin (buffer-create "*workspace-source*") (switch-to-buffer! "*workspace-source*"))}
    )

    press(["C-x", "w"])

    assert Editor.current_buffer() == "*workspaces*"
    assert eval!(~s{(buffer-text "*workspaces*")}) =~ "ai-max"
    assert eval!(~s{(buffer-text "*workspaces*")}) =~ "workspace prompts"
    assert eval!(~s{(buffer-text "*workspaces*")}) =~ workspace
    assert eval!(~s{(buffer-local "*workspaces*" 'mode-name)}) == ~s{"workspaces-mode"}

    eval!(~s{(list-goto-first-entry "*workspaces*")})
    press("RET")

    assert_receive {:browser_frame, %{"op" => "open", "url" => "http://localhost:4208"}}
  end

  test "C-x w starts a stopped worktree daemon before opening its tab" do
    stub_browser()

    workspace =
      Path.join(System.tmp_dir!(), "workspace-start-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "apps/aimax_core"))
    File.write!(Path.join(workspace, "mix.exs"), "# test checkout\n")
    test = self()

    Application.put_env(:aimax_core, :workspace_daemon_provisioner, fn path, name ->
      send(test, {:daemon_started, path, name})
      {:ok, %{url: "http://localhost:4214", home: "/tmp/a2-home", port: 4214}}
    end)

    on_exit(fn ->
      Application.delete_env(:aimax_core, :workspace_daemon_provisioner)
      File.rm_rf!(workspace)
    end)

    eval!(
      ~s{(daemon-assign-workspace! "worktree-a2" "http://localhost:4208" "/tmp/a2-home" "#{workspace}")}
    )

    press(["C-x", "w"])
    eval!(~s{(list-goto-first-entry "*workspaces*")})
    press("RET")

    assert_receive {:daemon_started, ^workspace, "a2"}
    assert_receive {:browser_frame, %{"op" => "open", "url" => "http://localhost:4214"}}
  end
end
