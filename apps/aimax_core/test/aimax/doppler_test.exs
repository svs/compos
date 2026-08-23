defmodule Aimax.DopplerTest do
  @moduledoc "The Doppler app lists names and changes only explicit secrets."

  use ExUnit.Case

  alias Aimax.Core.{Editor, KeyDispatch, SchemeAPI, Session}

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  setup do
    dir = Path.join(System.tmp_dir!(), "aimax-doppler-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    script = Path.join(dir, "doppler")
    calls = Path.join(dir, "calls")

    File.write!(script, """
    #!/bin/sh
    printf '%s\\n' "$*" >> #{calls}
    case "$1" in
      projects) printf '[{"name":"personal","description":"Private"},{"name":"work","description":"Work"}]' ;;
      configs) printf '[{"name":"dev","environment":"Development"},{"name":"prod","environment":"Production"}]' ;;
      secrets)
        case "$2" in
          get) printf 'super-secret' ;;
          set|delete) : ;;
          *) printf '{"ANTHROPIC_API_KEY":{},"DATABASE_URL":{}}' ;;
        esac
        ;;
    esac
    """)

    File.chmod!(script, 0o700)
    eval!(~s{(set! doppler-program "#{script}")})
    eval!(~s{(set! key-doppler-project "personal")})
    eval!(~s{(set! key-doppler-config "dev")})
    eval!(~s{(doppler-forget!)})
    Editor.minibuffer_close()
    Editor.set_pending([])

    on_exit(fn ->
      Aimax.Core.kill_buffer("*doppler*")
      File.rm_rf!(dir)
      eval!(~s{(set! doppler-program "doppler")})
    end)

    {:ok, calls: calls}
  end

  test "doppler-mode lists names without fetching values", %{calls: calls} do
    eval!(~s{(run-command "doppler")})
    text = eval!(~s{(buffer-text "*doppler*")})

    assert text =~ "Doppler  personal/dev"
    assert text =~ "ANTHROPIC_API_KEY"
    assert text =~ "DATABASE_URL"
    refute text =~ "super-secret"
    assert File.read!(calls) =~ "secrets --project personal --config dev --only-names --json"
    refute File.read!(calls) =~ "secrets get"
    assert eval!(~s{(buffer-local "*doppler*" 'mode-name)}) == ~s{"doppler-mode"}

    blocks = eval!(~s{(buffer-local "*doppler*" 'render-blocks)})
    assert blocks =~ "c-actions"
    assert blocks =~ "doppler:row:0"
    assert blocks =~ "doppler:add"
    assert blocks =~ "doppler:execute"
    refute blocks =~ "super-secret"
  end

  test "opens as a grouped primary buffer, never a popup" do
    eval!(~s{(buffer-create "*doppler*")})
    eval!(~s{(buffer-set-local! "*doppler*" 'window-class "popup popup-right")})
    eval!(~s{(buffer-set-local! "*doppler*" 'window-style "--popup-size:38%")})

    eval!(~s{(run-command "doppler")})

    assert eval!("(current-buffer)") == ~s{"*doppler*"}
    # groups are records: buffer-group answers a stable ID, and the name
    # is what a person picked and can change
    assert eval!(~s{(group-name (buffer-group "*doppler*"))}) == ~s{"doppler"}
    assert eval!(~s{(buffer-local "*doppler*" 'window-class)}) == "#f"
    assert eval!(~s{(buffer-local "*doppler*" 'window-style)}) == "#f"
    assert eval!(~s{(display-action-for "*doppler*")}) == "same"
  end

  test "RET copies only the current secret value", %{calls: calls} do
    eval!(~s{(run-command "doppler")})
    eval!(~s{(switch-to-buffer! "*doppler*")})
    press("RET")

    assert Editor.take_clipboard("f-main") == "super-secret"
    assert File.read!(calls) =~ "secrets get ANTHROPIC_API_KEY"
    refute eval!(~s{(buffer-text "*doppler*")}) =~ "super-secret"
  end

  test "a secret value is one doppler process per session", %{calls: calls} do
    assert eval!(~s{(doppler-secret-value "personal" "dev" "SENTRY_AUTH_TOKEN")}) ==
             ~s{"super-secret"}

    fetched = length(String.split(File.read!(calls), "\n", trim: true))

    # the second read serves the cache: no new doppler process
    assert eval!(~s{(doppler-secret-value "personal" "dev" "SENTRY_AUTH_TOKEN")}) ==
             ~s{"super-secret"}
    assert length(String.split(File.read!(calls), "\n", trim: true)) == fetched

    # a write drops its entry, so the next read fetches again
    eval!(~s{(doppler-secret-set! "personal" "dev" "SENTRY_AUTH_TOKEN" "rotated")})
    eval!(~s{(doppler-secret-value "personal" "dev" "SENTRY_AUTH_TOKEN")})
    assert File.read!(calls) |> String.split("\n", trim: true) |> Enum.count(&(&1 =~ "secrets get")) == 2
  end

  test "mouse rows select and action controls run the keyboard commands", %{calls: calls} do
    eval!(~s{(run-command "doppler")})
    eval!(~s{(switch-to-buffer! "*doppler*")})

    SchemeAPI.block_click("*doppler*", "doppler:row:1")
    assert eval!(~s{(list-current "*doppler*")}) == ~s{"DATABASE_URL"}

    SchemeAPI.block_click("*doppler*", "doppler:copy")
    assert Editor.take_clipboard("f-main") == "super-secret"
    assert File.read!(calls) =~ "secrets get DATABASE_URL"

    SchemeAPI.block_click("*doppler*", "doppler:add")
    eval!(~s{(minibuffer-input! "mouse_key")})
    eval!("(minibuffer-confirm!)")
    eval!(~s{(minibuffer-input! "mouse value")})
    eval!("(minibuffer-confirm!)")
    assert File.read!(calls) =~ "secrets set MOUSE_KEY mouse value"
  end

  test "ui/actions is catalogued with a working click example" do
    description = eval!(~s{(describe-component 'ui/actions)})
    assert description =~ "clickable actions"
    assert description =~ "refresh"
    assert eval!(~s{(component 'ui/actions '(actions (("go" "Go" "RET"))))}) =~ "click \"go\""
  end

  test "+ sets a named value and does not render the value", %{calls: calls} do
    eval!(~s{(run-command "doppler")})
    eval!(~s{(switch-to-buffer! "*doppler*")})
    press("+")
    eval!(~s{(minibuffer-input! "new_token")})
    eval!("(minibuffer-confirm!)")
    eval!(~s{(minibuffer-input! "value with spaces")})
    eval!("(minibuffer-confirm!)")

    call_text = File.read!(calls)
    assert call_text =~ "secrets set NEW_TOKEN value with spaces"
    assert call_text =~ "--silent --no-interactive"
    refute eval!(~s{(buffer-text "*doppler*")}) =~ "value with spaces"
    assert Editor.snapshot().echo == "Set NEW_TOKEN"
  end

  test "d then x confirms before deleting the row", %{calls: calls} do
    eval!(~s{(run-command "doppler")})
    eval!(~s{(switch-to-buffer! "*doppler*")})
    press(["d", "x"])

    refute File.read!(calls) =~ "secrets delete"
    eval!(~s{(minibuffer-input! "yes")})
    eval!("(minibuffer-confirm!)")

    assert File.read!(calls) =~ "secrets delete ANTHROPIC_API_KEY"
    assert File.read!(calls) =~ "--yes --silent"
  end

  test "P changes the project and config used by later reads", %{calls: calls} do
    eval!(~s{(run-command "doppler")})
    eval!(~s{(switch-to-buffer! "*doppler*")})
    press("P")
    eval!(~s{(minibuffer-input! "work")})
    eval!("(minibuffer-confirm!)")
    eval!(~s{(minibuffer-input! "prod")})
    eval!("(minibuffer-confirm!)")

    assert eval!(~s{(buffer-local "*doppler*" 'doppler-project)}) == ~s{"work"}
    assert eval!(~s{(buffer-local "*doppler*" 'doppler-config)}) == ~s{"prod"}
    assert eval!(~s{(buffer-text "*doppler*")}) =~ "Doppler  work/prod"
    assert File.read!(calls) =~ "secrets --project work --config prod --only-names --json"
  end

  test "restoring doppler-mode rebuilds its keys and names" do
    eval!(~s{(buffer-create "*doppler*")})
    eval!(~s{(buffer-append! "*doppler*" "stale secret value")})
    eval!(~s{(buffer-set-local! "*doppler*" 'doppler-project "work")})
    eval!(~s{(buffer-set-local! "*doppler*" 'doppler-config "prod")})
    eval!(~s{(switch-to-buffer! "*doppler*")})
    eval!(~s{(set-mode! "doppler-mode")})

    text = eval!(~s{(buffer-text "*doppler*")})
    assert text =~ "Doppler  work/prod"
    assert text =~ "ANTHROPIC_API_KEY"
    refute text =~ "stale secret value"

    assert eval!(~s{(car (cdr (assoc "RET" (local-keys "*doppler*"))))}) ==
             ~s{"doppler-secret-copy"}
  end
end
