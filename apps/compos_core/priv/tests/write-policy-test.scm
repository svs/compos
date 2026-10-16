;;; write-policy-test.scm --- the rules that decide which writes happen.
;;;
;;; The case these rules exist for: on 2026-09-09 a chat buffer wrote its
;;; transcript over layouts.ex, and the daemon could not boot, because a
;;; clobbered .ex file fails the compile.

(domain! 'testing)
(effects! '(write))

(define t--wp-dir (string-append (compos-home) "/write-policy-test"))
(define t--wp-buf "*write-policy-test*")
(define t--wp-chat "*write-policy-test-chat*")

(define (t--wp-path name)
  (make-directory! t--wp-dir)
  (string-append t--wp-dir "/" name))

(define (t--wp-clean! &rest paths)
  (set! *write-permit* #f)
  (for-each (lambda (b) (when (buffer-exists? b)
                          (buffer-mark-saved! b)
                          (buffer-kill! b)))
            (list t--wp-buf t--wp-chat))
  (for-each (lambda (p) (when (file-exists? p) (delete-file! p))) paths))

;; a plain buffer that holds text and never read any file
(define (t--wp-make-buffer! name text)
  (buffer-create name)
  (buffer-append! name text)
  name)

(deftest 'write-policy-refuses-a-buffer-that-never-read-the-file
  "the disaster: a buffer saves over a file whose text it never held"
  (lambda ()
    (let ((p (t--wp-path "source.txt")))
      (t--wp-clean! p)
      (write-file! p "the real file\n")
      (t--wp-make-buffer! t--wp-buf "a transcript\n")
      (check-true! (write-refusal p t--wp-buf #f) "the rule refuses the save")
      (check-false! (ignore-errors
                      (lambda ()
                        (with-current-buffer t--wp-buf
                          (lambda () (buffer-save! p)))))
                    "the save raises instead of writing")
      (check-equal! (read-file p) "the real file\n" "the file keeps its text")
      (t--wp-clean! p))))

(deftest 'write-policy-allows-a-buffer-to-save-its-own-file
  "the ordinary save is untouched"
  (lambda ()
    (let ((p (t--wp-path "own.txt")))
      (t--wp-clean! p)
      (write-file! p "first\n")
      (visit p)
      (buffer-append! p "second\n")
      (check-false! (write-refusal p p #f) "a buffer may write the file it read")
      (with-current-buffer p (lambda () (buffer-save!)))
      (check-equal! (read-file p) "first\nsecond\n" "the save lands")
      (when (buffer-exists? p) (buffer-mark-saved! p) (buffer-kill! p))
      (t--wp-clean! p))))

(deftest 'write-policy-leaves-a-program-write-alone
  "a file a program owns has no source buffer, so no rule applies"
  (lambda ()
    (let ((p (t--wp-path "owned.scm")))
      (t--wp-clean! p)
      (check-false! (write-refusal p #f #f) "no source buffer, no rule")
      (write-file! p "(display 1)\n")
      (check-equal! (read-file p) "(display 1)\n" "the program write lands")
      (t--wp-clean! p))))

(deftest 'write-policy-permit-buys-one-write-to-one-file
  "the answer a person gives to the overwrite question, and nothing more"
  (lambda ()
    (let ((p (t--wp-path "confirmed.txt"))
          (other (t--wp-path "other.txt")))
      (t--wp-clean! p other)
      (write-file! p "before\n")
      (write-file! other "untouched\n")
      (t--wp-make-buffer! t--wp-buf "after\n")
      (allow-one-write! p)
      (check-false! (write-check! p t--wp-buf) "the permit clears the rule")
      (check-contains! (write-check! p t--wp-buf)
                       "never read it"
                       "the permit is spent after one write")
      (allow-one-write! p)
      (check-contains! (write-check! other t--wp-buf)
                       "never read it"
                       "a permit for one file does not carry to another")
      (t--wp-clean! p other))))

(deftest 'write-policy-keeps-a-chat-out-of-a-source-file
  "a chat buffer writes a conversation, so it writes only .chat or .md"
  (lambda ()
    (let ((ex (t--wp-path "clobbered.ex"))
          (chat (t--wp-path "kept.chat")))
      (t--wp-clean! ex chat)
      (t--wp-make-buffer! t--wp-chat "companion . transcript\n")
      (buffer-set-local! t--wp-chat 'agent-slug "test-slug")
      (check-true! (write-refusal ex t--wp-chat #f) "a chat may not become an .ex file")
      (check-true! (write-refusal ex t--wp-chat #t) "and no answer to a question changes that")
      (check-false! (write-refusal chat t--wp-chat #f)
                    "a chat may become a .chat file")
      (t--wp-clean! ex chat))))

(deftest 'write-policy-keeps-scheme-in-a-scheme-root
  "a .scm joins other Scheme, or starts under a Scheme root, and nowhere else"
  (lambda ()
    ;; outside the config home on purpose: the home is itself a Scheme root
    (let* ((bare "/tmp/compos-write-policy-bare")
           (stray (string-append bare "/stray.scm"))
           (neighbour (string-append bare "/already.scm")))
      (t--wp-clean! stray neighbour)
      (make-directory! bare)
      (t--wp-make-buffer! t--wp-buf "(display 1)\n")
      (check-true! (write-refusal stray t--wp-buf #f) "a .scm cannot start in a directory that holds none")
      (check-true! (write-refusal stray t--wp-buf #t) "the rule is absolute: a permit does not lift it")
      (write-file! neighbour "(display 2)\n")
      (check-false! (write-refusal stray t--wp-buf #f)
                    "one .scm in the directory makes it a Scheme directory")
      (check-false! (write-refusal (string-append (compos-home) "/packages/new.scm")
                                   t--wp-buf #f)
                    "the config home is a Scheme root, so a new file may start there")
      (t--wp-clean! stray neighbour))))

(deftest 'write-policy-reads-a-root-through-its-symlink
  "priv has two names in development, and both name one directory"
  (lambda ()
    (let ((linked (string-append (compos-priv-dir) "/packages/no-such-file.scm")))
      (t--wp-clean!)
      (t--wp-make-buffer! t--wp-buf "(display 1)\n")
      (check-false! (write-refusal linked t--wp-buf #f)
                    "the _build spelling of priv is the same root")
      (check-false! (write-refusal (file-realpath linked) t--wp-buf #f)
                    "and so is the source spelling")
      (t--wp-clean!))))
