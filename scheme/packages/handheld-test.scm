;;; handheld-test.scm --- the handheld client's policy, on keys this test binds.
;;;
;;; No production binding appears here. The chord register is tested with
;;; a dummy key under <f9>, and the chip test binds its own key too.

(domain! 'testing)
(effects! '(write))

(define *handheld-test-fired* '())

(define (handheld-test-scene thunk)
  (with-frame
    (lambda (frame)
      (with-fresh-group "zz-handheld-second"
        (lambda (gid)
          (with-stub '*handheld-test-fired* '()
            (lambda ()
              (unwind-protect
                (lambda () (thunk))
                (lambda ()
                  (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
                            '("zz-handheld-tab" "zz-handheld-keys" "zz-handheld-recent" "zz-handheld-search" "zz-handheld-chip" "zz-handheld-chips-plain" "zz-handheld-chips-chat" "zz-handheld-rail"))
                  (for-each global-unset-key '("<f9> h" "<f9> a" "<f9> b" "<f9> r" "<f9> s" "<f9> c")))))))))))

(define (handheld-test-fired? tag) (member tag *handheld-test-fired*))

(define-command "handheld-test-dummy" "Test command: record that it ran"
  (lambda () (set! *handheld-test-fired* (cons 'dummy *handheld-test-fired*))))

(deftest 'the-composer-tells-a-chord-from-a-command-from-prose
  "classify: a key token opens a chord, M-x NAME is a command, the rest is prose"
  (lambda ()
    (check-equal! (handheld-classify "C-c b") '(keys ("C-c" "b")) "a modified key then a letter is a chord")
    (check-equal! (handheld-classify "<f9> a") '(keys ("<f9>" "a")) "a named key opens a chord")
    (check-equal! (handheld-classify "M-x") '(keys ("M-x")) "M-x alone is the key")
    (check-equal! (handheld-classify "M-x handheld-test-dummy") '(command "handheld-test-dummy")
                  "M-x and a name is a command")
    (check-equal! (handheld-classify "  what did aker say?  ") '(prose "what did aker say?")
                  "a sentence is prose, trimmed")
    (check-equal! (handheld-classify "C-c is a chord") '(prose "C-c is a chord")
                  "a chord followed by words is prose")
    (check-equal! (handheld-classify "   ") '(empty) "blank is empty")))

(deftest 'the-chord-register-presses-the-keys-it-names
  "compose a dummy chord and the command bound to it runs"
  (lambda ()
    (handheld-test-scene
      (lambda ()
        (global-set-key "<f9> h" "handheld-test-dummy")
        (check-equal! (handheld-compose! "<f9> h") 'keys "the composer used the chord register")
        (check-true! (wait-until (lambda () (handheld-test-fired? 'dummy)) 3000 20)
                     "and the bound command ran")))))

(deftest 'the-command-register-runs-the-named-command
  "M-x NAME runs NAME at once; an unknown name is refused"
  (lambda ()
    (handheld-test-scene
      (lambda ()
        (check-equal! (handheld-compose! "M-x handheld-test-dummy") 'command "a known name runs")
        (check-true! (handheld-test-fired? 'dummy) "and the command ran")
        (check-equal! (handheld-compose! "M-x handheld-no-such-command") 'unknown "an unknown name is refused")))))

(deftest 'the-tab-rail-is-the-groups-and-a-tap-lands-in-the-chat
  "a buffer's group is on the rail; the tap switches to it and shows its chat"
  (lambda ()
    (handheld-test-scene
      (lambda ()
        (let* ((buf (test-buffer! "zz-handheld-tab" "one\ntwo\n"))
               (g (begin (delete-other-windows!) (switch-to-buffer! buf) (group-ensure! buf))))
          (check-true! g "the buffer founded a group")
          (let ((row (assoc g (handheld-tabs g))))
            (check-true! row "the rail names the group")
            (check-equal! (nth 2 row) "group" "every tab is a group")
            (check-equal! (nth 3 row) #t "and the current one is flagged"))
          ;; founding the group put the frame in it, so this tap is on the
          ;; current group: the buffers come up as a prompt
          (check-equal! (handheld-tab! g) g "a tap on the current group answers the group")
          (check-true! (minibuffer-active?) "and opens its buffers as a prompt")
          (run-command "minibuffer-cancel")
          ;; a second group takes the frame away; the tap on the first is a switch
          (let ((g2 (or (group-resolve-id "zz-handheld-second")
                        (group-record-create! "zz-handheld-second"))))
            (switch-to-group! g2)
            (check-true! (and g2 (not (equal? g2 g)) (equal? (frame-group) g2))
                         "the frame stands in a second group")
            (let ((chat (handheld-tab! g)))
              (check-true! (and chat (chat-buffer? chat)) "the tap on another group lands in its chat")
              (check-equal! (current-buffer) chat "and that chat is current")
              (check-equal! (frame-group) g "and the frame stands in the group")))
          (check-equal! (handheld-tab-hold! g) g "a hold answers the group")
          (check-true! (minibuffer-active?) "and opens the prompt too")
          (run-command "minibuffer-cancel")
          (check-false! (minibuffer-active?) "C-g closes it"))))))

(deftest 'the-keys-panel-places-every-binding-in-its-section
  "a single key sits in its family, a sequence under its prefix; a local key wins"
  (lambda ()
    (handheld-test-scene
      (lambda ()
        (check-equal! (handheld-key-place "q") '("plain" "q") "a bare key is plain")
        (check-equal! (handheld-key-place "C-f") '("C-" "C-f") "a control key is in C-")
        (check-equal! (handheld-key-place "M-x") '("M-" "M-x") "a meta key is in M-")
        (check-equal! (handheld-key-place "<f9> a n") '("<f9>" "a n") "a sequence sits under its first key")
        (let ((buf (test-buffer! "zz-handheld-keys" "")))
          (delete-other-windows!)
          (switch-to-buffer! buf)
          (global-set-key "<f9> a" "handheld-test-dummy")
          (global-set-key "<f9> b" "keyboard-quit")
          (local-set-key* buf "<f9> a" "keyboard-quit")
          (let* ((panel (handheld-keys buf))
                 (sec (assoc "<f9>" panel))
                 (rows (and sec (car (cdr sec)))))
            (check-true! sec "the prefix this test bound is a section")
            (check-equal! (car (cdr (assoc "a" rows))) "keyboard-quit" "the local binding wins over the global one")
            (check-equal! (car (cdr (assoc "b" rows))) "keyboard-quit" "and the global one is there too")
            (check-equal! (nth 3 (assoc "a" rows)) 0 "a letter ranks first")
            (check-true! (assoc "plain" panel) "plain keys have a section")
            (check-false! (assoc "self-insert-command" (map (lambda (r) (list (car (cdr r)))) (car (cdr (assoc "plain" panel)))))
                          "self-insert is not listed")))))))

(deftest 'recents-lead-the-panel-and-a-recent-row-runs-by-name
  "a command the phone ran comes first under recent, with the key that reaches it"
  (lambda ()
    (handheld-test-scene
      (lambda ()
        (let ((buf (test-buffer! "zz-handheld-recent" "")))
          (delete-other-windows!)
          (switch-to-buffer! buf)
          (global-set-key "<f9> r" "handheld-test-dummy")
          (check-true! (handheld-run-command! "handheld-test-dummy") "a known name runs")
          (check-true! (handheld-test-fired? 'dummy) "and the command ran")
          (let* ((panel (handheld-keys buf))
                 (recent (assoc "recent" panel)))
            (check-true! recent "the panel has a recent section")
            (check-equal! (car (car panel)) "recent" "and it comes first")
            (check-equal! (car (car (cdr recent))) '("<f9> r" "handheld-test-dummy" "Test command: record that it ran" 0)
                          "the newest command leads, with the key that reaches it"))
          (global-unset-key "<f9> r")
          (check-equal! (car (car (car (cdr (assoc "recent" (handheld-keys buf)))))) "M-x"
                        "an unbound recent shows M-x")
          (check-false! (handheld-run-command! "handheld-no-such-command") "an unknown name is refused"))))))

(deftest 'typing-in-the-panel-searches-every-command
  "a term finds a command by name, key, or doc, bound or not; a bound row leads with its key"
  (lambda ()
    (handheld-test-scene
      (lambda ()
        (let ((buf (test-buffer! "zz-handheld-search" "")))
          (delete-other-windows!)
          (switch-to-buffer! buf)
          (check-equal! (handheld-search buf "") '() "empty text is no rows")
          (check-equal! (handheld-search buf "   ") '() "blank text is no rows")
          (check-equal! (handheld-search buf "zz-no-such-command-anywhere") '()
                        "a term nothing carries is no rows")
          (check-equal! (car (handheld-search buf "handheld-test-dummy"))
                        '("M-x" "handheld-test-dummy" "Test command: record that it ran" 1)
                        "an unbound command is found by name, and M-x reaches it")
          (check-equal! (car (cdr (car (handheld-search buf "record that it RAN dummy"))))
                        "handheld-test-dummy" "terms match the doc in any order and any case")
          (global-set-key "<f9> s" "handheld-test-dummy")
          (check-equal! (car (handheld-search buf "dummy"))
                        '("<f9> s" "handheld-test-dummy" "Test command: record that it ran" 0)
                        "a bound command carries its key and ranks first")
          (check-equal! (car (cdr (car (handheld-search buf "<f9> s"))))
                        "handheld-test-dummy" "a key is a term too")
          (let ((rows (handheld-search buf "quit")))
            (check-true! (pair? rows) "quit names commands")
            (check-true! (<= (length rows) *handheld-search-max*) "the list is capped")))))))

(deftest 'a-chip-teaches-the-key-bound-to-its-command
  "a chip carries the chord bound to its command, or M-x when nothing binds it"
  (lambda ()
    (handheld-test-scene
      (lambda ()
        (let ((buf (test-buffer! "zz-handheld-chip" "")))
          (global-set-key "<f9> c" "handheld-test-dummy")
          (check-equal! (handheld-chip "Dummy" "handheld-test-dummy" buf)
                        '("Dummy" "<f9> c")
                        "a bound command's chip is its key")
          (global-unset-key "<f9> c")
          (check-equal! (handheld-chip "Dummy" "handheld-test-dummy" buf)
                        '("Dummy" "M-x handheld-test-dummy")
                        "an unbound command's chip is M-x and its name"))))))

(deftest 'the-composer-chips-carry-no-switch-buffer-chip
  "a chat buffer's chips lead with config; no view offers a switch-buffer chip"
  (lambda ()
    (handheld-test-scene
      (lambda ()
        (let* ((plain (test-buffer! "zz-handheld-chips-plain" ""))
               (chat (test-buffer! "zz-handheld-chips-chat" "")))
          (buffer-set-local! chat 'mode-name "chat-mode")
          (check-equal! (map car (handheld-chips chat))
                        '("config" "Every command")
                        "the chat buffer's chips are config and every command")
          (check-equal! (map car (handheld-chips plain))
                        '("Chat about this" "Every command")
                        "a plain buffer's chips are chat about this and every command"))))))

(deftest 'the-rail-moves-point-to-the-line-it-names
  "scrub to a line and point sits at its start; out-of-range lines clamp"
  (lambda ()
    (handheld-test-scene
      (lambda ()
        (let ((buf (test-buffer! "zz-handheld-rail" "one\ntwo\nthree\n")))
          (delete-other-windows!)
          (switch-to-buffer! buf)
          (check-equal! (handheld-scrub! 2) 2 "line two is reachable")
          (check-equal! (point) 4 "and point is at its start")
          (check-equal! (handheld-scrub! 99) 4 "a line past the end clamps to the last line"))))))
