;;; morg-structure-test.scm --- the Markdown structural API.
;;;
;;; markdown-outline / markdown-find / markdown-read / markdown-replace! /
;;; markdown-insert-after! address a section by the LINE its heading is
;;; on, so an agent edits one section and never a whole file.
;;;
;;; The 24 tests that press a key stay in ExUnit. Folding, TODO cycling
;;; and the babel blocks ARE key behaviour.

(domain! 'testing)
(effects! '(write))

(define t--morg-buf "zz-morg.md")

(define (t--morg! text)
  (test-buffer! t--morg-buf text)
  (with-current-buffer t--morg-buf (lambda () (set-mode! "morg-mode")))
  t--morg-buf)

(define (t--morg-done!) (when (buffer-known? t--morg-buf) (buffer-kill! t--morg-buf)))

(deftest 'md-files-open-in-morg-mode
  "the extension decides, like every other mode"
  (lambda ()
    (check-equal! (auto-mode-for "notes.md") "morg-mode" "a .md file")))

(deftest 'the-markdown-api-outlines-and-finds-headings-outside-fences
  "a # inside a fenced block is code, not a heading"
  (lambda ()
    (t--morg! "# One\nbody\n## Child\ntext\n```sh\n# not a heading\n```\n# Two\n")
    (check-equal! (markdown-outline t--morg-buf)
                  '((1 1 "One") (3 2 "Child") (8 1 "Two")) "the outline")
    (check-equal! (markdown-find t--morg-buf "Child")
                  '((3 2 "Child")) "the search")
    (t--morg-done!)))

(deftest 'the-markdown-api-reads-the-section-that-holds-a-body-line
  "a body line belongs to the nearest heading above it"
  (lambda ()
    (t--morg! "# One\nbody\n## Child\ntext\n# Two\ntail\n")
    (check-equal! (markdown-read t--morg-buf 4) "## Child\ntext\n" "the child section")
    (check-equal! (markdown-read t--morg-buf 1) "# One\nbody\n## Child\ntext\n"
                  "the parent takes its children with it")
    (t--morg-done!)))

(deftest 'the-markdown-api-replaces-one-duplicate-section-by-line
  "two headings share a name, and the line says which one"
  (lambda ()
    (t--morg! "# Same\nfirst\n# Same\nsecond\n# Last\ntail\n")
    (check-contains! (markdown-replace! t--morg-buf 3 "# Same\nchanged")
                     "replaced the Markdown section" "the report")
    (check-equal! (buffer-text t--morg-buf)
                  "# Same\nfirst\n# Same\nchanged\n# Last\ntail\n"
                  "only the second one changed")
    (t--morg-done!)))

(deftest 'the-markdown-api-inserts-a-peer-after-a-section
  "after the section and its children, not after its heading"
  (lambda ()
    (t--morg! "# One\nbody\n# Three\ntail\n")
    (check-contains! (markdown-insert-after! t--morg-buf 1 "# Two\nnew")
                     "inserted Markdown" "the report")
    (check-equal! (buffer-text t--morg-buf) "# One\nbody\n# Two\nnew\n# Three\ntail\n"
                  "the peer landed between them")
    (t--morg-done!)))

(deftest 'the-markdown-api-reports-preamble-and-invalid-lines
  "a line no section holds is an answer, not a guess"
  (lambda ()
    (t--morg! "preamble\n\n# One\nbody\n")
    (check-contains! (markdown-read t--morg-buf 1)
                     "no Markdown section holds line 1" "the preamble")
    (check-contains! (markdown-read t--morg-buf 99) "outside the buffer" "a line past the end")
    (t--morg-done!)))

(deftest 'the-markdown-editing-skill-exposes-the-section-api
  "an agent reads the skill and finds the calls"
  (lambda ()
    (let ((body (skill "markdown-editing")))
      (check-contains! body "markdown-outline" "the read call")
      (check-contains! body "markdown-replace!" "and the write one"))
    (let ((entry (catalog-entry 'function "markdown-replace!")))
      (check-equal! (plist-get entry 'package) "morg" "the package")
      (check-equal! (plist-get entry 'domain) "writing" "the domain")
      (check-equal! (plist-get entry 'effects) '("write") "the effects"))))

(deftest 'morg-babel-and-morg-tangle-load-as-package-extensions
  "each is its own package, stamped by the loader"
  (lambda ()
    (check-true! (member "morg-babel" (command-names)) "morg-babel is a command")
    (check-true! (member "morg-tangle" (command-names)) "and so is morg-tangle")
    (check-equal! (plist-get (catalog-entry 'command "morg-babel") 'package)
                  "morg-babel" "babel names its own package")
    (check-equal! (plist-get (catalog-entry 'command "morg-tangle") 'package)
                  "morg-tangle" "and so does tangle")))
