;;; actor-test.scm --- isolated Scheme actors and their mailboxes.
;;;
;;; Actor behavior is Scheme policy, so it is tested here in Scheme. The
;;; ExUnit actor tests cover only runtime boundaries that Scheme must not
;;; be able to cross, such as exporting a live closure.

(domain! 'testing)
(effects! '(write))

(deftest 'an-actor-owns-state-and-processes-its-mailbox-in-order
  "casts and calls reach one serial mailbox and update private state"
  (lambda ()
    (let ((actor
            (actor-spawn
              (lambda (state message)
                (if (equal? message 'increment)
                    (list (+ state 1) #t)
                    (if (equal? message 'self)
                        (list state (actor-self))
                        (list state state))))
              0)))
      (actor-send! actor 'increment)
      (actor-send! actor 'increment)
      (check-equal! (actor-call actor 'get) 2 "both casts ran before the call")
      (check-true! (actor-ref? actor) "spawn returned an actor reference")
      (check-true! (actor-alive? actor) "the actor is alive")
      (check-equal! (actor-call actor 'self) actor "actor-self identifies the receiver")
      (check-false! (actor-self) "the test itself is not an actor")
      (actor-stop! actor)
      (check-false! (actor-alive? actor) "stop invalidated the reference"))))

(deftest 'an-actor-has-a-private-snapshot-of-scheme-state
  "an actor can mutate its globals without mutating the spawning session"
  (lambda ()
    (define zz-actor-private-global 10)
    (let ((actor
            (actor-spawn
              (lambda (state message)
                (set! zz-actor-private-global message)
                (list state zz-actor-private-global))
              #f)))
      (check-equal! (actor-call actor 99) 99 "the actor sees its mutation")
      (check-equal! zz-actor-private-global 10 "the spawning session keeps its value")
      (actor-stop! actor))))

(deftest 'actor-spawn-copies-lexical-captures
  "the behavior keeps bindings that were local at spawn time"
  (lambda ()
    (let ((offset 7))
      (let ((actor
              (actor-spawn
                (lambda (state message) (list state (+ message offset)))
                #f)))
        (check-equal! (actor-call actor 5) 12 "the copied closure sees offset")
        (actor-stop! actor)))))

(deftest 'actors-share-buffers-through-the-buffer-service
  "isolated Scheme state does not copy editor buffers"
  (lambda ()
    (let ((buf (test-buffer! "*zz-actor-shared*" "shared text"))
          (actor
            (actor-spawn
              (lambda (state buffer) (list state (buffer-text buffer)))
              #f)))
      (check-equal! (actor-call actor buf) "shared text" "the actor reads the live buffer")
      (actor-stop! actor)
      (buffer-kill! buf))))

(deftest 'an-actor-can-spawn-an-isolated-child
  "actor references are data and can cross actor boundaries"
  (lambda ()
    (let ((parent
            (actor-spawn
              (lambda (state message)
                (let ((offset 3))
                  (list state
                        (actor-spawn
                          (lambda (child-state child-message)
                            (list child-state (+ child-message offset)))
                          #f))))
              #f)))
      (let ((child (actor-call parent 'spawn)))
        (check-true! (actor-ref? child) "the parent replied with its child")
        (check-equal! (actor-call child 4) 7 "the child owns its copied capture")
        (actor-stop! child)
        (actor-stop! parent)))))

(deftest 'an-actor-can-monitor-another-actor
  "a stopped target becomes a normal down message in the observer mailbox"
  (lambda ()
    (let ((observer
            (actor-spawn
              (lambda (state message)
                (if (equal? message 'get)
                    (list state state)
                    (list message #t)))
              #f))
          (target (actor-spawn (lambda (state message) (list state #t)) #f)))
      (actor-monitor! observer target 'watched)
      (actor-stop! target)
      (check-true!
        (wait-until (lambda () (pair? (actor-call observer 'get))) 500 10)
        "the observer receives a down message")
      (let ((down (actor-call observer 'get)))
        (check-equal! (car down) 'down "the message identifies a failure")
        (check-equal! (cadr down) 'watched "the tag identifies the target"))
      (actor-stop! observer))))

(deftest 'actor-after-sends-through-the-normal-mailbox
  "a delayed message updates state before a later call"
  (lambda ()
    (let ((actor
            (actor-spawn
              (lambda (state message)
                (if (equal? message 'get)
                    (list state state)
                    (list message #t)))
              #f)))
      (actor-after! 10 actor 'arrived)
      (check-true!
        (wait-until (lambda () (equal? (actor-call actor 'get) 'arrived)) 500 10)
        "the delayed message arrived")
      (actor-stop! actor))))
