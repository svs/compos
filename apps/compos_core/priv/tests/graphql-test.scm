;;; graphql-test.scm --- packages/graphql.scm, the client, offline.
;;;
;;; Nothing here reaches a network. What a real server decides is its own
;;; business; what this file holds is the part the editor decides: the
;;; registry keeps no secrets, a failure comes back in the same shape as an
;;; answer, a schema is searched by words, and a parsed answer reads.

(domain! 'testing)
(effects! '(write))

;; A schema, as introspection sends one, planted straight into the cache so
;; the schema questions can be asked with no server on the other end.
;; DETAIL is how much of it a server allowed: full, no-args, shallow, names.
(define (t--gql-plant! detail)
  (graphql-schema-forget! 'zztest)
  (set! *graphql-schemas*
    (cons (list 'zztest
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
                detail)
          *graphql-schemas*))
  'zztest)

;; The registry and the schema cache are global. Every test leaves both the
;; way it found them.
(define (t--gql-reset!) (graphql-forget! 'zztest))

(effects! '(read))

(define (t--gql-names entries)
  (map (lambda (e) (plist-get e 'name)) entries))

(effects! '(write))

;;; --- the registry -------------------------------------------------------------

(deftest 'an-endpoint-is-named-once-and-listed-by-name
  "the listing names the endpoint, its URL and its doc"
  (lambda ()
    (t--gql-reset!)
    (graphql-register! 'zztest "https://example.test/gql" 'doc "a test endpoint")
    (let ((listed (graphql-endpoints)))
      (check-contains! listed "zztest" "the name")
      (check-contains! listed "https://example.test/gql" "the URL")
      (check-contains! listed "a test endpoint" "the doc"))
    (t--gql-reset!)))

(deftest 'the-registry-holds-key-references-never-keys
  "what is stored is the reference; resolution happens at request time"
  (lambda ()
    (t--gql-reset!)
    (graphql-register! 'zztest "https://example.test/gql"
      'headers (list 'Authorization (list "Bearer " "@TEST_GQL_TOKEN")))
    (check-contains! (value->string (nth 2 (graphql--endpoint 'zztest)))
                     "@TEST_GQL_TOKEN" "the headers hold the reference")
    (check-false! (string-contains? (graphql-endpoints) "TEST_GQL_TOKEN")
                  "the listing shows no token")
    (t--gql-reset!)))

(deftest 'registering-the-same-name-again-replaces-it
  "one name, one endpoint"
  (lambda ()
    (t--gql-reset!)
    (graphql-register! 'zztest "https://one.test/gql")
    (graphql-register! 'zztest "https://two.test/gql")
    (let ((listed (graphql-endpoints)))
      (check-contains! listed "two.test" "the second URL")
      (check-false! (string-contains? listed "one.test") "the first URL is gone"))
    (t--gql-reset!)))

(deftest 'with-nothing-registered-the-list-says-what-to-do
  "an empty registry names the call that fills it"
  (lambda ()
    (t--gql-reset!)
    (if (null? *graphql-endpoints*)
        (check-contains! (graphql-endpoints) "graphql-register!" "the empty listing")
        #t)))

;;; --- failure ------------------------------------------------------------------

(deftest 'an-unknown-endpoint-answers-in-the-shape-of-an-answer
  "a missing endpoint is an errors reply, not a throw"
  (lambda ()
    (let ((reply (graphql-post 'zznowhere "query { me { name } }")))
      (check-true! (graphql--has? reply 'errors) "the reply carries errors")
      (check-contains! (graphql-errors reply)
                       "no such GraphQL endpoint: zznowhere" "the reason"))))

(deftest 'graphql-errors-reads-every-message-with-its-path
  "every message, and the path it came from"
  (lambda ()
    (check-contains!
      (graphql-errors
        (list 'errors (list (list 'message "not authorised" 'path (list "me" "email"))
                            (list 'message "unknown field"))))
      "not authorised" "the first message")
    (check-contains!
      (graphql-errors
        (list 'errors (list (list 'message "not authorised" 'path (list "me" "email")))))
      "me.email" "the path")))

(deftest 'a-clean-reply-has-no-errors
  "data alone answers #f"
  (lambda ()
    (check-false! (graphql-errors (list 'data (list 'me (list 'name "s"))))
                  "a clean reply")))

;;; --- the schema ---------------------------------------------------------------

(deftest 'apropos-finds-a-field-by-words-in-any-order
  "every word must match, in any order"
  (lambda ()
    (t--gql-plant! 'full)
    (let ((hits (graphql-apropos 'zztest "candidate stage")))
      (check-contains! hits "Candidate.stages" "the field that holds both words")
      (check-false! (string-contains? hits "Candidate.name") "the field that holds one"))
    (t--gql-reset!)))

(deftest 'a-field-line-carries-its-arguments-and-its-marks
  "the arguments, the list mark and the non-null mark all print"
  (lambda ()
    (t--gql-plant! 'full)
    (check-contains! (graphql-apropos 'zztest "candidate id")
                     "Query.candidate(id: ID!)" "the argument line")
    (check-contains! (graphql-apropos 'zztest "stages") "[Stage]!" "the marks")
    (t--gql-reset!)))

(deftest 'introspections-own-types-stay-out-of-the-answers
  "__Type is the server talking about itself"
  (lambda ()
    (t--gql-plant! 'full)
    (check-false! (string-contains? (graphql-apropos 'zztest "candidate") "__Type")
                  "apropos hides it")
    (check-false! (string-contains? (graphql-describe 'zztest "Candidate") "__Type")
                  "describe hides it")
    (t--gql-reset!)))

(deftest 'nothing-found-says-so-in-words
  "a miss names the endpoint and the words"
  (lambda ()
    (t--gql-plant! 'full)
    (check-contains! (graphql-apropos 'zztest "zebra")
                     "nothing in zztest's schema" "the miss")
    (t--gql-reset!)))

(deftest 'describe-gives-one-type-in-full
  "the type, its description, and every field with its own"
  (lambda ()
    (t--gql-plant! 'full)
    (let ((described (graphql-describe 'zztest "Candidate")))
      (check-contains! described "a person applying" "the type description")
      (check-contains! described "Candidate.name: String" "the field line")
      (check-contains! described "their full name" "the field description"))
    (t--gql-reset!)))

(deftest 'describe-is-case-insensitive-and-points-at-apropos-when-it-misses
  "a lower-case name still finds the type; a miss names the next call"
  (lambda ()
    (t--gql-plant! 'full)
    (check-contains! (graphql-describe 'zztest "candidate") "Candidate.name" "the lower-case name")
    (check-contains! (graphql-describe 'zztest "Nope") "graphql-apropos" "the miss")
    (t--gql-reset!)))

(deftest 'roots-name-where-a-query-and-a-mutation-start
  "the two entry points every schema declares"
  (lambda ()
    (t--gql-plant! 'full)
    (let ((roots (graphql-roots 'zztest)))
      (check-contains! roots "query:    Query" "the query root")
      (check-contains! roots "mutation: Mutation" "the mutation root"))
    (t--gql-reset!)))

(deftest 'a-capped-schema-says-it-is-capped-and-says-how
  "the note names what the cap took away"
  (lambda ()
    (t--gql-plant! 'no-args)
    (check-contains! (graphql-describe 'zztest "Candidate")
                     "field arguments are missing" "the no-args note")
    (t--gql-plant! 'shallow)
    (check-contains! (graphql-apropos 'zztest "candidate")
                     "non-null marks are missing" "the shallow note")
    (t--gql-reset!)))

(deftest 'a-full-schema-says-nothing-about-being-capped
  "a full answer carries no note"
  (lambda ()
    (t--gql-plant! 'full)
    (check-false! (string-contains? (graphql-describe 'zztest "Candidate") "capped")
                  "no note")
    (t--gql-reset!)))

(deftest 'forgetting-the-endpoint-forgets-its-schema
  "one call drops both"
  (lambda ()
    (t--gql-plant! 'full)
    (graphql-forget! 'zztest)
    (check-false! (assoc 'zztest *graphql-schemas*) "the cached schema is gone")))

;;; --- reading the answer -------------------------------------------------------

(deftest 'an-object-indents-an-array-bullets-and-null-reads-as-null
  "the indentation is the whole point, so the answer is pinned entire"
  (lambda ()
    (check-equal!
      (graphql-print
        (list 'me (list 'name "s" 'email #f
                        'stages (list (list 'name "screen" 'passed #t)
                                      (list 'name "onsite" 'passed #f)))))
      (string-append "me:\n  name: s\n  email: null\n  stages:\n"
                     "    - name: screen\n      passed: true\n"
                     "    - name: onsite\n      passed: null\n")
      "the printed answer")))

(deftest 'a-scalar-prints-alone
  "no key, no bullet"
  (lambda ()
    (check-equal! (graphql-print "hello") "hello\n" "a string")
    (check-equal! (graphql-print 42) "42\n" "a number")))

(deftest 'an-empty-list-is-a-list-not-an-object
  "() is the empty array, because JSON sends no empty object here"
  (lambda ()
    (check-equal! (graphql-print '()) "[]\n" "the empty list")))

;;; --- the catalog --------------------------------------------------------------

(deftest 'the-graphql-functions-are-findable-with-their-effects
  "the package stamps every public function"
  (lambda ()
    (check-equal! (plist-get (catalog-entry 'function "graphql-apropos") 'package)
                  "graphql" "the package")
    (check-true! (member "external" (plist-get (catalog-entry 'function "graphql") 'effects))
                 "graphql reaches the network")
    (check-equal! (plist-get (catalog-entry 'function "graphql-register!") 'effects)
                  '("write") "graphql-register! only writes")))

(deftest 'the-graphql-commands-declare-their-own-domain-and-effects
  "nothing guesses: the package says it"
  (lambda ()
    (let ((entry (catalog-entry 'command "graphql-query")))
      (check-equal! (plist-get entry 'domain) "graphql" "the domain")
      (check-equal! (plist-get entry 'metadata-source) "declared" "declared, not inferred")
      (check-equal! (plist-get entry 'effects) '("write" "external") "the effects"))
    (check-equal! (plist-get (catalog-entry 'command "graphql-endpoints") 'effects)
                  '("read") "listing only reads")))

(deftest 'apropos-finds-graphql-by-the-word-graphql
  "the functions reach the catalog search"
  (lambda ()
    (check-true! (member "graphql-apropos" (t--gql-names (apropos "graphql schema")))
                 "graphql-apropos is found")))

(deftest 'the-recipes-a-package-declares-reach-the-recipe-book
  "a recipe is catalogued like everything else"
  (lambda ()
    (let ((found (apropos "run a graphql query")))
      (check-true! (member "run a graphql query" (t--gql-names found)) "the recipe is found")
      (check-true! (member "recipe" (map (lambda (e) (plist-get e 'kind)) found))
                   "it is catalogued as a recipe"))))
