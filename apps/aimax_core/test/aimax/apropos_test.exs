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
    test "entries carry package, namespace, domain and effects" do
      entry = eval!(~s{(catalog-entry 'function "buffer-text")})

      assert entry =~ ~s{package "editor"}
      assert entry =~ ~s{namespace "core"}
      assert entry =~ ~s{domain "buffers"}
      assert entry =~ ~s{effects ("read")}

      assert eval!(~s{(catalog-entry 'function "buffer-append!")}) =~ ~s{effects ("write")}
      assert eval!(~s{(catalog-entry 'function "buffer-kill!")}) =~ ~s{effects ("destroy")}
    end

    test "load units stamp their registrations" do
      assert eval!(~s{(catalog-entry 'function "apropos-page")}) =~ ~s{package "help"}

      assert eval!(~s{(catalog-entry 'setting "permission-timeout-ms")}) =~
               ~s{package "agent"}
    end

    test "the bundled backfill leaves no unknown metadata" do
      assert {:ok, "()"} =
               Session.eval("""
               (filter (lambda (e)
                         (and (equal? (plist-get e 'origin) "bundled")
                              (or (equal? (plist-get e 'domain) "unknown")
                                  (member "unknown" (plist-get e 'effects)))))
                       (catalog))
               """)
    end

    test "new bundled declarations cannot silently expand the Luna backfill" do
      # A new Scheme declaration must stamp itself. Change this frozen count
      # only after regenerating and reviewing the Luna artifact.
      assert eval!("""
             (length (filter (lambda (e)
                               (equal? (plist-get e 'metadata-source) "luna"))
                             (catalog)))
             """) == "653"

      assert Aimax.Core.CatalogBackfill.count() == 713
    end

    test "new Scheme must stamp metadata instead of receiving a safe guess" do
      eval!("""
      (package! 'my-extension 'my-extension)
      (define-command "zz-unstamped" "Reads a harmless value" (lambda () #t))
      (package! 'user 'user)
      """)

      unstamped = eval!(~s{(catalog-entry 'command "zz-unstamped")})
      assert unstamped =~ ~s{package "my-extension"}
      assert unstamped =~ ~s{origin "user"}
      assert unstamped =~ ~s{domain "unknown"}
      assert unstamped =~ ~s{effects ("unknown")}
      assert unstamped =~ ~s{metadata-source "unknown"}

      eval!("""
      (domain! 'files)
      (effects! '(destroy external))
      (define-command "zz-stamped" "Delete a remote test file" (lambda () #t))
      (domain! 'unknown)
      (effects! '(unknown))
      """)

      stamped = eval!(~s{(catalog-entry 'command "zz-stamped")})
      assert stamped =~ ~s{domain "files"}
      assert stamped =~ ~s{effects ("destroy" "external")}
      assert stamped =~ ~s{metadata-source "declared"}
    end

    test "Luna-classified consequential entries carry metadata" do
      assert eval!(~s{(catalog-entry 'function "llm")}) =~
               ~s{effects ("read" "external" "execute" "spend")}

      assert eval!(~s{(catalog-entry 'command "eval-buffer")}) =~
               ~s{effects ("write" "execute")}

      assert eval!(~s{(catalog-entry 'command "notmuch-trash")}) =~
               ~s{effects ("destroy")}

      llm = eval!(~s{(catalog-entry 'function "llm")})
      assert llm =~ ~s{metadata-source "luna"}
      assert llm =~ ~s{metadata-model "openai:gpt-5.6-luna"}
      assert llm =~ ~s{metadata-confidence 0.98}
    end

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

    test "kind, package, namespace, domain and effect filters compose" do
      hits = eval!(~s{(apropos "card" 'kind 'component 'namespace 'ui 'effect 'pure)})
      assert hits =~ "ui/card"
      refute hits =~ "diff-card"

      assert eval!(~s{(apropos "" 'package 'help 'kind 'function)}) =~ "apropos-page"
      assert eval!(~s{(apropos "" 'domain 'windows 'effect 'read)}) =~ "window"
      assert eval!(~s{(apropos "" 'effect 'destroy)}) =~ "buffer-kill!"
    end

    test "components use the main catalog and expose a runnable contract" do
      hit = eval!(~s{(car (apropos-components "bordered container"))})
      assert hit =~ ~s{kind "component"}
      assert hit =~ ~s{qualified-name "ui/card"}
      assert hit =~ "props"
      assert hit =~ "example"
      assert hit =~ ~s{effects ("pure")}

      rendered = eval!(~s{(component 'ui/badge '(text "ready" class "success"))})
      assert rendered =~ "c-badge success"
      assert rendered =~ "ready"
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

  describe "internal primitives" do
    # R7's last gap: scope "all" listed names with no docs. The sweep gave
    # every Elixir primitive a one-line doc; these hold that line.

    test "every builtin bound in the session carries a doc" do
      # session_primitives is private, so the interpreter is the registry
      # of record: a builtin global without a doc is the sweep regressing
      assert {:ok, "()"} =
               Session.eval("""
               (filter (lambda (n)
                         (and (string-prefix? "#<builtin"
                                (function-source (symbol-value (string->symbol n))))
                              (not (primitive-doc n))))
                       (global-names))
               """)
    end

    test "no doc names a primitive that does not exist" do
      assert {:ok, "()"} =
               Session.eval("""
               (filter (lambda (p) (not (boundp (string->symbol (car p)))))
                       (primitive-docs))
               """)
    end

    test "docs cover the registration maps exactly, both ways" do
      for {prims, docs} <- [
            {Aimax.Scheme.Builtins.all(), Aimax.Scheme.Builtins.docs()},
            {Aimax.Core.SchemeAPI.primitives(), Aimax.Core.SchemeAPI.docs()}
          ] do
        assert Enum.sort(Map.keys(prims)) == Enum.sort(Map.keys(docs))
      end
    end

    test "every doc is written the house way: signature, dash, sentence" do
      all =
        Aimax.Scheme.Builtins.docs()
        |> Map.merge(Aimax.Core.SchemeAPI.docs())
        |> Map.merge(Aimax.Core.Session.docs())

      bad =
        Enum.reject(all, fn {name, doc} ->
          String.starts_with?(doc, "(#{name}") and String.contains?(doc, " — ")
        end)

      assert bad == []
    end
  end
end
