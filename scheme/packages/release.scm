;;; release.scm --- build the release executable and put it in service.
;;;
;;; M-x release-build-and-install builds the executable from the compos
;;; checkout, installs it where the launchd agent starts it, and restarts the
;;; stable compos. M-x release-install does the last two steps for a build
;;; already made. Either runs from the stable compos or from the dev one: the
;;; stable compos restarts itself, or the dev one asks it to over its socket.
;;; Each build unpacks into its own directory (the release version carries the
;;; commit), and an install prunes the other builds' directories.

(domain! 'system)
(effects! '(write execute))

(defcustom 'release-checkout "~/src/compos"
  "The compos checkout release-build builds from."
  'group 'release 'type 'string)

(defcustom 'release-target "macos_arm"
  "The Burrito target release-build builds: macos_arm or linux."
  'group 'release 'type 'string)

(defcustom 'release-bin-path "~/.local/bin/compos-stable"
  "The stable compos's executable, the one its launchd agent starts."
  'group 'release 'type 'string)

(defcustom 'release-stable-socket "~/.compos/sock"
  "The stable compos's socket, asked to restart after an install from another compos."
  'group 'release 'type 'string)

(define (release-build-path)
  "the executable release-build makes, in the checkout's burrito_out"
  (string-append (expand-file-name release-checkout) "/burrito_out/compos_" release-target))

(define (release-stable-self?)
  "#t when this compos is the stable one: a release started from release-bin-path. A checkout started from a stable shell inherits the variable, so it must be a release too"
  (and (not (compos-project-dir))
       (equal? (getenv "__BURRITO_BIN_PATH") (expand-file-name release-bin-path))))

(define (release-restart-stable!)
  "restart the stable compos: this one, or the one at release-stable-socket"
  (if (release-stable-self?)
      (daemon-restart!)
      (peer-eval (expand-file-name release-stable-socket) "(daemon-restart!)")))

(define (release-install! &optional src)
  "install SRC, by default the last build, as the stable compos and restart it; answers the installed path"
  (let ((bin (release-install-binary! (or src (release-build-path)) release-bin-path)))
    (message (string-append "installed " bin "; restarting the stable compos"))
    (release-restart-stable!)
    bin))

(define (release-build! k)
  "build the release executable from release-checkout in a task; K gets (OK? TEXT): the build's result line and its errors"
  (shell-command->string
   (string-append
    "rm -rf _build/prod/rel && s=$(date +%s) && MIX_ENV=prod BURRITO_TARGET=" release-target
    " mix release --overwrite > /tmp/compos-release-build.log 2>&1; rc=$?; "
    "echo \"rc=$rc $(( $(date +%s)-s ))s\"; "
    "grep -m3 -B2 -A8 -E '^\\*\\* \\(|^error' /tmp/compos-release-build.log | head -40")
   (expand-file-name release-checkout)
   (lambda (out) (k (string-prefix? "rc=0 " out) out))))

(define-command "release-install" "Install the last release build as the stable compos and restart it"
  (lambda () (release-install!)))

(define-command "release-build-and-install" "Build the release from the checkout, install it as the stable compos, and restart it"
  (lambda ()
    (message "building the release…")
    (release-build!
     (lambda (ok? out)
       (if ok?
           (release-install!)
           (message (string-append "release build failed: " out)))))))
