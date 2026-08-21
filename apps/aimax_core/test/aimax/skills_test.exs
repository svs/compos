defmodule Aimax.SkillsTest do
  @moduledoc "skills.scm: the skill catalog and the sanitized Codex home."

  use ExUnit.Case

  alias Aimax.Core.Session

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp unquote_str(printed), do: String.trim(printed, "\"")

  setup do
    on_exit(fn ->
      eval!("(customize-set! 'codex-home-sanitized #t)")
      eval!(~s{(customize-set! 'codex-scrub-env '("OPENAI_API_KEY" "OPENAI_BASE_URL"))})
    end)

    :ok
  end

  test "the loader scans priv/skills into the catalog" do
    assert eval!("(skills)") =~ "code-editing"
    entry = eval!(~s{(catalog-entry 'skill "code-editing")})
    assert entry =~ "skill"
    assert entry =~ "Load before the first code edit"
  end

  test "(skill NAME) returns the body without the frontmatter" do
    body = eval!(~s{(skill "code-editing")})
    assert body =~ "code-outline"
    assert body =~ "smallest edit"
    refute body =~ "description:"
  end

  test "an unknown skill answers with the available names" do
    assert eval!(~s{(skill "zz-none")}) =~ "no such skill"
    assert eval!(~s{(skill "zz-none")}) =~ "code-editing"
  end

  test "skills-note indexes every skill, one line each" do
    note = eval!("(skills-note)")
    assert note =~ ~s{(skill \\"code-editing\\")}
    assert note =~ "Load a skill with eval-scheme"
  end

  test "skills-note-without hides an active skill from the on-demand index" do
    note = eval!(~s{(skills-note-without "code-editing")})
    refute note =~ ~s{(skill \\"code-editing\\")}
  end

  test "the chat system prompt carries the index for an aimax-tools chat" do
    buf = "*sk-chat-#{System.unique_integer([:positive])}*"
    eval!(~s{(buffer-create "#{buf}")})
    on_exit(fn -> Aimax.Core.kill_buffer(buf) end)

    assert eval!(~s{(chat-tool-system "#{buf}")}) =~ "SKILLS"
  end

  test "a user skill in ~/.aimax/skills joins the catalog and wins by name" do
    home = unquote_str(eval!("(aimax-home)"))
    dir = Path.join([home, "skills", "zz-user-skill"])

    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "SKILL.md"), """
    ---
    name: zz-user-skill
    description: A user skill for the test.
    ---

    The user's own instructions.
    """)

    on_exit(fn ->
      File.rm_rf!(Path.dirname(dir) |> Path.join("zz-user-skill"))
      eval!("(skills-scan!)")
    end)

    eval!("(skills-scan!)")
    assert eval!("(skills)") =~ "zz-user-skill"
    assert eval!(~s{(skill "zz-user-skill")}) =~ "The user's own instructions."

    File.write!(Path.join(dir, "SKILL.md"), """
    ---
    name: zz-user-skill
    description: A user skill for the test.
    ---

    Changed on disk after the scan.
    """)

    assert eval!(~s{(skill "zz-user-skill")}) =~ "Changed on disk after the scan."
  end

  test "codex-config-with-env points codex at the sanitized home and scrubs keys" do
    env = eval!(~s{(plist-get (codex-config-with-env '(backend "codex-app-server")) 'env)})
    assert env =~ "CODEX_HOME"
    assert env =~ ~s{("OPENAI_API_KEY" #f)}

    home = unquote_str(eval!("(codex-home)"))
    assert File.exists?(Path.join([home, "skills", "code-editing", "SKILL.md"]))
  end

  test "the sweep keeps codex's own state dirs and still drops a stale skill" do
    home = unquote_str(eval!("(codex-home)"))

    # codex writes its built-in skills under .system — no SKILL.md at the
    # top, so the sweep must skip it instead of raising enoent
    sys = Path.join([home, "skills", ".system", "imagegen"])
    File.mkdir_p!(sys)

    stale = Path.join([home, "skills", "zz-stale"])
    File.mkdir_p!(stale)
    File.write!(Path.join(stale, "SKILL.md"), "gone soon")

    assert eval!("(begin (codex-home-render-skills! (codex-home)) #t)") == "#t"
    assert File.dir?(sys)
    refute File.exists?(Path.join(stale, "SKILL.md"))
  end

  test "agent-resolve-config gives every codex thread the sanitized env" do
    env = eval!(~s{(plist-get (agent-resolve-config '(connector "codex-app-server")) 'env)})
    assert env =~ "CODEX_HOME"
  end

  test "codex-home-sanitized #f leaves the config alone" do
    eval!("(customize-set! 'codex-home-sanitized #f)")
    conf = eval!(~s{(codex-config-with-env '(backend "codex-app-server"))})
    refute conf =~ "CODEX_HOME"
  end

  test "the api lane keeps its own environment" do
    env = eval!(~s{(plist-get (agent-resolve-config '(connector "api")) 'env)})
    refute env =~ "CODEX_HOME"
  end
end
