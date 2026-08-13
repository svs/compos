defmodule Aimax.AproposTest do
  @moduledoc """
  R7's done-when: the agent's first question has one good answer.

  "What can I call" was answered by four registries that nothing searched
  across, and by a name-only matcher that never read a doc. These hold the
  line on the search, on what an entry must carry, and on the cold-start
  path — an agent that has just connected and knows nothing.
  """

  use ExUnit.Case

  alias Aimax.Core.Session

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  describe "the catalog" do
    test "every public entry carries a signature and a category" do
      # (name doc sig category) — the sig is parsed out of the doc, so an
      # entry written the house way needs no extra work to be discoverable
      assert {:ok, "()"} =
               Session.eval("""
               (filter (lambda (e)
                         (or (not (nth 2 e))
                             (equal? (nth 2 e) "")
                             (not (nth 3 e))))
                       (public-api))
               """)
    end

    test "no entry is left in the default category" do
      assert {:ok, "()"} =
               Session.eval(~s{(filter (lambda (e) (equal? (nth 3 e) 'misc)) (public-api))})
    end

    test "a doc written the house way splits into signature and prose" do
      eval!(~s{(public! 'zz-split "(zz-split A B) — does a thing with A and B" 'testing)})
      entry = eval!(~s{(public-entry "zz-split")})

      assert entry =~ ~s{"(zz-split A B)"}
      assert entry =~ ~s{"does a thing with A and B"}
      assert entry =~ "testing"

      # a doc with no leading form still gets a usable signature
      eval!(~s{(public! 'zz-plain "Just a description." 'testing)})
      assert eval!(~s{(public-entry "zz-plain")}) =~ ~s{"(zz-plain)"}

      # a nested form is balanced, not cut at the first paren
      eval!(~s{(public! 'zz-nest "(zz-nest '((a b) c)) — nested" 'testing)})
      assert eval!(~s{(public-entry "zz-nest")}) =~ ~s{"(zz-nest '((a b) c))"}
    end

    test "categories name the shape of the surface" do
      cats = eval!("(public-categories)")

      for c <- ~w(buffers editing windows commands chat discovery) do
        assert cats =~ c, "expected a #{c} category"
      end

      # and one lists whole
      assert eval!(~s{(length (apropos-category 'windows))}) != "0"
    end
  end

  describe "the search" do
    test "doc text is searched, not only names" do
      # the phrase is in the doc of a function whose NAME does not contain
      # it — the case the old name-only matcher could never answer
      hits = eval!(~s{(apropos "most recently used")})
      assert hits =~ "buffer-list-mru"
    end

    test "every word must appear" do
      assert eval!(~s{(apropos "buffer zzzznotaword")}) == "()"
    end

    test "commands, keys and settings are all in one answer" do
      assert eval!(~s{(map (lambda (h) (plist-get h 'kind)) (apropos "chat"))}) =~ "command"
      assert eval!(~s{(apropos "find-file")}) =~ "key"
      assert eval!(~s{(apropos "permission timeout")}) =~ "variable"
    end

    test "a near-miss on a name lands anyway" do
      hits = eval!(~s{(apropos "buffer-tekst")})
      assert hits =~ "buffer-text"
      assert hits =~ "closest name"
    end
  end

  describe "the cold start" do
    test "a connecting agent is told what it is holding and how to look" do
      hello = eval!("(hello)")

      # who it is talking to, and the one call that answers everything else
      assert hello =~ "apropos"
      assert hello =~ "eval"
      # the categories, so it can ask for an area rather than guess
      assert hello =~ "buffers"
      assert hello =~ "windows"
    end

    test "the done-when: one hello, one apropos, the right expression" do
      # a cold agent wants to split the window and open a file in it. It
      # has never seen this editor.
      assert eval!("(hello)") =~ "apropos"

      hits = eval!(~s{(apropos "split window")})
      assert hits =~ "split-window!"

      hits = eval!(~s{(apropos "open a file")})
      assert hits =~ "visit"

      # and the recipe says it in one line, which is cheaper still: the
      # whole composition, not three names to assemble
      recipe = eval!(~s{(apropos "open a file in a split")})
      assert recipe =~ "recipe"
      assert recipe =~ "split-window!"
      assert recipe =~ "visit"
    end

    test "the primer carries recipes, so a cold agent has working lines" do
      hello = eval!("(hello)")
      assert hello =~ "RECIPES"
      assert hello =~ "(visit"
    end
  end
end
