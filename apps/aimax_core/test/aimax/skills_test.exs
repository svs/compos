defmodule Aimax.SkillsTest do
  @moduledoc """
  The skills tests that need directories of files on disk.

  The catalog and the sanitized environment are Scheme policy and live in
  priv/tests/skills-test.scm. These two stay here because they build skill
  directories, and Scheme has no way to remove one.
  """

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

end
