defmodule Aimax.GraphqlTest do
  @moduledoc """
  packages/graphql.scm — the client, offline.

  Nothing here reaches a network. What a real server decides is its own
  business; what this file holds is the part the editor decides: the
  registry keeps no secrets, a failure comes back in the same shape as an
  answer, a schema is searched by words, and a parsed answer reads.
  """

  use ExUnit.Case, async: false

  alias Aimax.Core.Session

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  setup do
    eval!("(graphql-forget! 'test)")
    :ok
  end

  # A schema, as introspection sends one, planted straight into the cache so
  # the schema questions can be asked with no server on the other end.
  # DETAIL is how much of it a server allowed: full, no-args, shallow, names.
  defp plant_schema!(detail \\ "full") do
    eval!("""
    (begin
      (graphql-schema-forget! 'test)
      (set! *graphql-schemas*
        (cons (list 'test
                    (list (list 'name "Query" 'kind "OBJECT" 'description "the root"
                                'fields (list (list 'name "candidate"
                                                    'description "one candidate by id"
                                                    'type (list 'kind "OBJECT" 'name "Candidate")
                                                    'args (list (list 'name "id"
                                                                      'type (list 'kind "NON_NULL"
                                                                                  'ofType (list 'kind "SCALAR" 'name "ID")))))))
                          (list 'name "Candidate" 'kind "OBJECT" 'description "a person applying"
                                'fields (list (list 'name "name" 'description "their full name"
                                                    'type (list 'kind "SCALAR" 'name "String"))
                                              (list 'name "stages" 'description "every stage reached"
                                                    'type (list 'kind "NON_NULL"
                                                                'ofType (list 'kind "LIST"
                                                                              'ofType (list 'kind "OBJECT" 'name "Stage"))))))
                          (list 'name "__Type" 'kind "OBJECT" 'description "introspection"
                                'fields (list (list 'name "candidate" 'description "never shown"
                                                    'type (list 'kind "SCALAR" 'name "String")))))
                    (list 'queryType (list 'name "Query") 'mutationType (list 'name "Mutation"))
                    '#{detail})
              *graphql-schemas*))
      'ok)
    """)
  end

  describe "the registry" do
    test "an endpoint is named once and listed by name" do
      eval!(~S|(graphql-register! 'test "https://example.test/gql" 'doc "a test endpoint")|)

      listed = eval!("(graphql-endpoints)")
      assert listed =~ "test"
      assert listed =~ "https://example.test/gql"
      assert listed =~ "a test endpoint"
    end

    test "the registry holds key references, never keys" do
      eval!(~S"""
      (graphql-register! 'test "https://example.test/gql"
        'headers (list 'Authorization (list "Bearer " "@TEST_GQL_TOKEN")))
      """)

      # what is stored is the reference; resolution happens at request time
      assert eval!("(nth 2 (graphql--endpoint 'test))") =~ "@TEST_GQL_TOKEN"
      refute eval!("(graphql-endpoints)") =~ "TEST_GQL_TOKEN"
    end

    test "registering the same name again replaces it" do
      eval!(~S|(graphql-register! 'test "https://one.test/gql")|)
      eval!(~S|(graphql-register! 'test "https://two.test/gql")|)

      listed = eval!("(graphql-endpoints)")
      assert listed =~ "two.test"
      refute listed =~ "one.test"
    end

    test "with nothing registered the list says what to do" do
      eval!("(graphql-forget! 'test)")

      assert eval!(~S|(if (null? *graphql-endpoints*) (graphql-endpoints) "skip")|) =~
               "graphql-register!"
    end
  end

  describe "failure" do
    test "an unknown endpoint answers in the shape of an answer, not a throw" do
      reply = eval!(~S|(graphql-post 'nowhere "query { me { name } }")|)

      assert reply =~ "errors"
      assert reply =~ "no such GraphQL endpoint: nowhere"
    end

    test "graphql-errors reads every message, with its path" do
      assert eval!(~S"""
             (graphql-errors
               (list 'errors (list (list 'message "not authorised" 'path (list "me" "email"))
                                   (list 'message "unknown field"))))
             """) =~ "not authorised"

      assert eval!(~S"""
             (graphql-errors
               (list 'errors (list (list 'message "not authorised" 'path (list "me" "email")))))
             """) =~ "me.email"
    end

    test "a clean reply has no errors" do
      assert eval!(~S|(graphql-errors (list 'data (list 'me (list 'name "s"))))|) == "#f"
    end
  end

  describe "the schema" do
    test "apropos finds a field by words in any order" do
      plant_schema!()

      hits = eval!(~S|(graphql-apropos 'test "candidate stage")|)
      assert hits =~ "Candidate.stages"
      refute hits =~ "Candidate.name"
    end

    test "a field line carries its arguments and its list and non-null marks" do
      plant_schema!()

      assert eval!(~S|(graphql-apropos 'test "candidate id")|) =~ "Query.candidate(id: ID!)"
      assert eval!(~S|(graphql-apropos 'test "stages")|) =~ "[Stage]!"
    end

    test "introspection's own types stay out of the answers" do
      plant_schema!()

      refute eval!(~S|(graphql-apropos 'test "candidate")|) =~ "__Type"
      refute eval!(~S|(graphql-describe 'test "Candidate")|) =~ "__Type"
    end

    test "nothing found says so, in words" do
      plant_schema!()

      assert eval!(~S|(graphql-apropos 'test "zebra")|) =~ "nothing in test's schema"
    end

    test "describe gives one type in full" do
      plant_schema!()

      described = eval!(~S|(graphql-describe 'test "Candidate")|)
      assert described =~ "a person applying"
      assert described =~ "Candidate.name: String"
      assert described =~ "their full name"
    end

    test "describe is case-insensitive, and points at apropos when it misses" do
      plant_schema!()

      assert eval!(~S|(graphql-describe 'test "candidate")|) =~ "Candidate.name"
      assert eval!(~S|(graphql-describe 'test "Nope")|) =~ "graphql-apropos"
    end

    test "roots name where a query and a mutation start" do
      plant_schema!()

      roots = eval!("(graphql-roots 'test)")
      assert roots =~ "query:    Query"
      assert roots =~ "mutation: Mutation"
    end

    test "a capped schema says it is capped, and says how" do
      plant_schema!("no-args")

      assert eval!(~S|(graphql-describe 'test "Candidate")|) =~ "field arguments are missing"

      plant_schema!("shallow")

      assert eval!(~S|(graphql-apropos 'test "candidate")|) =~ "non-null marks are missing"
    end

    test "a full schema says nothing about being capped" do
      plant_schema!()

      refute eval!(~S|(graphql-describe 'test "Candidate")|) =~ "capped"
    end

    test "forgetting the endpoint forgets its schema" do
      plant_schema!()
      eval!("(graphql-forget! 'test)")

      assert eval!("(assoc 'test *graphql-schemas*)") == "#f"
    end
  end

  describe "reading the answer" do
    # Session.eval answers with the printed form, so a newline arrives as the
    # two characters \ and n. The indentation is the whole point here, so the
    # answer is pinned entire rather than sampled.
    test "an object indents, an array bullets, and null reads as null" do
      printed =
        eval!(~S"""
        (graphql-print
          (list 'me (list 'name "s" 'email #f
                          'stages (list (list 'name "screen" 'passed #t)
                                        (list 'name "onsite" 'passed #f)))))
        """)

      assert printed ==
               ~S{"me:\n  name: s\n  email: null\n  stages:\n} <>
                 ~S{    - name: screen\n      passed: true\n} <>
                 ~S{    - name: onsite\n      passed: null\n"}
    end

    test "a scalar prints alone" do
      assert eval!(~S|(graphql-print "hello")|) == ~S{"hello\n"}
      assert eval!("(graphql-print 42)") == ~S{"42\n"}
    end

    test "an empty list is a list, not an object" do
      assert eval!("(graphql-print '())") == ~S{"[]\n"}
    end
  end

  describe "the catalog" do
    test "the functions are findable by words, with their effects" do
      assert eval!(~S|(catalog-entry 'function "graphql-apropos")|) =~ ~s{package "graphql"}
      assert eval!(~S|(catalog-entry 'function "graphql")|) =~ "external"
      assert eval!(~S|(catalog-entry 'function "graphql-register!")|) =~ ~s{effects ("write")}
    end

    test "the commands declare their own domain and effects, so nothing guesses" do
      entry = eval!(~S|(catalog-entry 'command "graphql-query")|)
      assert entry =~ ~s{domain "graphql"}
      assert entry =~ ~s{metadata-source "declared"}
      assert entry =~ ~s{effects ("write" "external")}

      assert eval!(~S|(catalog-entry 'command "graphql-endpoints")|) =~ ~s{effects ("read")}
    end

    test "apropos finds graphql by the word graphql" do
      found = eval!(~S|(apropos "graphql schema")|)
      assert found =~ "graphql-apropos"
    end

    test "the recipes a package declares reach the recipe book" do
      assert eval!(~S|(apropos "run a graphql query")|) =~ "graphql"
    end
  end
end
