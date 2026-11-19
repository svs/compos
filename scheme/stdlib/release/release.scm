;;; release.scm --- build the release executable and put it in service.
;;;
;;; M-x release-build-and-install builds the executable from the compos
;;; checkout, installs it where the stable compos runs from, and restarts the
;;; stable compos. M-x release-install does the last two steps for a build
;;; already made. Either runs from the stable compos or from the dev one: the
;;; stable compos restarts itself, or the dev one asks it to over its socket.
;;; Each build unpacks into its own directory (the release version carries the
;;; commit), and an install prunes the other builds' directories.
;;;
;;; M-x compos-update takes the newest GitHub release of release-repo for
;;; this machine instead of a build, and installs it the same way.

(domain! 'system)
(effects! '(write execute))

(defcustom 'release-checkout "~/src/compos"
  "The compos checkout release-build builds from."
  'group 'release 'type 'string)

(defcustom 'release-target ""
  "The Burrito target release-build builds and compos-update downloads: macos_arm,
   linux (x86_64) or linux_arm (aarch64). Empty is this machine's."
  'group 'release 'type 'string)

(defcustom 'release-bin-path "~/.local/bin/compos-stable"
  "The stable compos's executable; a restart starts it again, logging to daemon.log."
  'group 'release 'type 'string)

(defcustom 'release-stable-socket "~/.local/state/compos/sock"
  "The stable compos's socket, asked to restart after an install from another compos."
  'group 'release 'type 'string)

(define *release--machine-target* #f)

(define (release-target-name)
  "release-target, or when it is empty this machine's target, from uname -m once"
  (if (and (string? release-target) (not (equal? release-target "")))
      release-target
      (or *release--machine-target*
          (let* ((arch (string-trim (shell-command->string "uname -m")))
                 (arm? (or (equal? arch "arm64") (equal? arch "aarch64")))
                 (t (cond ((equal? (system-type) "darwin") "macos_arm")
                          (arm? "linux_arm")
                          (else "linux"))))
            (set! *release--machine-target* t)
            t))))

(define (release-build-path)
  "the executable release-build makes, in the checkout's burrito_out"
  (string-append (expand-file-name release-checkout) "/burrito_out/compos_" (release-target-name)))

(effects! '(read execute))
(public! 'release-target-name
  "(release-target-name) — the Burrito target to build: release-target, else this machine's, from uname -m once")
(public! 'release-build-path
  "(release-build-path) — the executable release-build makes, in the checkout's burrito_out")
(effects! '(write execute))

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
    ;; a full install carries all the Scheme: the overlay of hot patches goes
    (ignore-errors (lambda () (release-overlay-clear! (release-overlay-dir))))
    (message (string-append "installed " bin "; restarting the stable compos"))
    (release-restart-stable!)
    bin))

(define (release-build! k)
  "build the release executable from release-checkout in a task; K gets (OK? TEXT): the build's result line and its errors"
  (shell-command->string
   (string-append
    "rm -rf _build/prod/rel && s=$(date +%s) && "
    ;; zig cannot link against the Xcode 27 SDK; the Command Line Tools SDK links
    "if [ -d /Library/Developer/CommandLineTools ]; then export DEVELOPER_DIR=/Library/Developer/CommandLineTools; fi; "
    "MIX_ENV=prod BURRITO_TARGET=" (release-target-name)
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

;;; Updates from GitHub releases. The release workflow attaches one
;;; executable per target, named compos-VERSION-TARGET, to the tag vVERSION.

(defcustom 'release-repo "svs/compos"
  "The GitHub repository compos-update takes releases from, as OWNER/NAME."
  'group 'release 'type 'string)

(effects! '(pure))

(define (release--bare-version v)
  "V without a leading v or a +COMMIT tail: v0.9.2 and 0.9.2+abc are 0.9.2"
  (car (string-split (if (string-prefix? "v" v) (substring v 1 (string-length v)) v) "+")))

(define (release-version<? a b)
  "#t when version A is older than version B"
  (let loop ((x (map (lambda (p) (or (string->number p) 0)) (string-split (release--bare-version a) ".")))
             (y (map (lambda (p) (or (string->number p) 0)) (string-split (release--bare-version b) "."))))
    (cond ((null? y) #f)
          ((null? x) (and (find (lambda (n) (> n 0)) y) #t))
          ((< (car x) (car y)) #t)
          ((> (car x) (car y)) #f)
          (else (loop (cdr x) (cdr y))))))

(effects! '(read))

(effects! '(read external))

(define (release-latest k)
  "K gets the newest release of release-repo as (VERSION URL SIZE BUNDLE), URL being its executable for this machine's target and BUNDLE its Scheme bundle as (URL BASE) or #f, or #f when there is none. CI attaches compos-VERSION-scheme-BASE.tar.gz when only Scheme changed since commit BASE"
  (http-get-json (string-append "https://api.github.com/repos/" release-repo "/releases/latest")
    '(timeout 15000)
    (lambda (j)
      (k (and j (string? (plist-get j 'tag_name))
              (let* ((as (let ((as (plist-get j 'assets))) (if (vector? as) (vector->list as) (or as '()))))
                     (a (find (lambda (a) (string-suffix? (string-append "-" (release-target-name))
                                                          (or (plist-get a 'name) "")))
                              as))
                     (b (find (lambda (a) (let ((n (or (plist-get a 'name) "")))
                                            (and (string-contains? n "-scheme-") (string-suffix? ".tar.gz" n))))
                              as))
                     (base (and b (let* ((n (plist-get b 'name)) (i (string-search "-scheme-" n)))
                                    (substring n (+ i 8) (- (string-length n) 7))))))
                (and a (list (release--bare-version (plist-get j 'tag_name))
                             (plist-get a 'browser_download_url)
                             (plist-get a 'size)
                             (and b (list (plist-get b 'browser_download_url) base))))))))))

(effects! '(write execute external))

(define (release-update! version url size)
  "download the executable of release VERSION from URL, check it is SIZE bytes, install it as the stable compos and restart it. The download goes straight to disk and is deleted once installed"
  (let ((path (string-append (compos-cache-dir) "/compos-" version "-" (release-target-name))))
    (message (string-append "downloading compos " version "…"))
    (shell-command->string
      (string-append "curl -fsSL --retry 2 -o " (sh-quote path) " " (sh-quote url) " 2>&1 | tail -3")
      (compos-cache-dir)
      (lambda (out)
        (cond ((not (and (file-exists? path) (equal? (file-size path) size)))
               (when (file-exists? path) (delete-file! path))
               (message (string-append "compos " version " did not download: " (string-trim out))))
              (else
               (set-file-mode! path 755)
               (release-install! path)
               (when (file-exists? path) (delete-file! path))))))))

(define-command "compos-update" "Update the stable compos to the newest release: its Scheme alone when only Scheme changed, else the executable and a restart. Its first boot moves the packages to the commits the release vouches for"
  (lambda ()
    (message "looking for a newer compos…")
    (release-latest
      (lambda (latest)
        (let ((now (release-running-version)))
          (cond ((not latest)
                 (message (string-append "no compos release for " release-target " in " release-repo)))
                ((and now (not (release-version<? now (car latest))))
                 (message (string-append "compos " now " is the newest release")))
                (else
                 (y-or-n (string-append (if now (string-append "Update compos " now " to " (car latest))
                                            (string-append "Install compos " (car latest) " as the stable compos"))
                                        " and restart it? ")
                         (lambda ()
                           ;; only Scheme changed since the commit the stable runs: take the
                           ;; bundle into its overlay, no restart; else the whole executable
                           (let* ((bundle (list-ref latest 3))
                                  (commit (and bundle (release-stable-commit))))
                             (if (and bundle (release--same-commit? commit (cadr bundle)))
                                 (release-update-scheme! (car latest) (car bundle) commit)
                                 (release-update! (car latest) (cadr latest) (caddr latest)))))))))))))

(effects! '(write))

(defcustom 'release-check-updates #t
  "Look for a newer compos release at start and every few hours, and show a notice when there is one. The notice runs compos-update."
  'group 'release 'type 'boolean)

(define *release--notified* #f)

(effects! '(read external display))

(define (release-check!)
  "ask GitHub for the newest release; when it is newer than the running compos, show a notice that runs compos-update, once per version. A checkout runs no release, so it is never told"
  (let ((now (release-running-version)))
    (when (and release-check-updates now)
      (release-latest
        (lambda (latest)
          (when (and latest
                     (release-version<? now (car latest))
                     (not (equal? *release--notified* (car latest))))
            (set! *release--notified* (car latest))
            (notify! "compos" (string-append "compos " (car latest) " is out")
                     (string-append "You run " now ". Click to update and restart.")
                     (list 'command "compos-update" 'sticky #t))))))))

(define-command "compos-check-update" "Look for a newer compos release now"
  (lambda ()
    (if (release-running-version)
        (begin (set! *release--notified* #f) (release-check!))
        (message "this compos runs from a checkout, not a release"))))

;;; Ship just Scheme. A Scheme change needs no new executable: the stable
;;; compos keeps an overlay folder in its state directory whose .scm files
;;; boot loads ahead of priv's. M-x release-hot-patch puts the files changed
;;; since the stable compos's commit there and loads them into it over its
;;; socket; compos-update does the same with a release's Scheme bundle when
;;; only Scheme changed. The overlay names the commit it patches, so a full
;;; install, a new commit, leaves it behind and boot clears it.

(effects! '(pure))

(define (release-overlay-target rel)
  "(release-overlay-target REL) -- where checkout file REL goes in the overlay, as load-path finds it: scheme/stdlib/DIR/F is F, scheme/packages/R and scheme/apps/R are R, priv/R is R; #f for a file the overlay cannot carry (tests, editor.scm and the boot manifests, which Elixir loads by path)"
  (let ((after (lambda (pre) (and (string-prefix? pre rel) (substring rel (string-length pre) (string-length rel))))))
    (and (or (string-suffix? ".scm" rel) (equal? rel "apps/compos_core/priv/standard.lock"))
         (not (string-suffix? "-test.scm" rel))
         (let ((std (after "scheme/stdlib/")) (priv (after "apps/compos_core/priv/")))
           (cond (std (let ((parts (string-split std "/")))
                        (if (pair? (cdr parts)) (string-join (cdr parts) "/") std)))
                 ((after "scheme/packages/") (after "scheme/packages/"))
                 ((after "scheme/apps/") (after "scheme/apps/"))
                 (priv (and (not (member priv '("editor.scm" "init.scm" "core.scm")))
                            (not (string-prefix? "tests/" priv))
                            priv))
                 (else #f))))))

(define (release--same-commit? a b)
  (and (string? a) (string? b) (> (string-length a) 6) (> (string-length b) 6)
       (or (string-prefix? a b) (string-prefix? b a))))

(effects! '(read))

(define (release-stable-state-dir)
  "(release-stable-state-dir) -- the stable compos's state folder, the one its socket is in"
  (if (release-stable-self?)
      (compos-state-dir)
      (let* ((s (expand-file-name release-stable-socket)) (i (string-rindex s "/")))
        (if i (substring s 0 i) s))))

(define (release-overlay-dir . self)
  "(release-overlay-dir [SELF]) -- the overlay folder of the stable compos, or of this one with SELF #t"
  (string-append (if (and (pair? self) (car self)) (compos-state-dir) (release-stable-state-dir)) "/overlay"))

(define (release-overlay-manifest dir)
  "(release-overlay-manifest DIR) -- the overlay at DIR as a plist: base (the commit it patches), version and files; #f when there is none"
  (let ((p (string-append dir "/overlay.scm")))
    (and (file-exists? p)
         (let ((forms (scheme-read (read-file p))))
           (and (pair? forms) (pair? (car forms)) (eq? (car (car forms)) 'overlay) (cdr (car forms)))))))

(define (release-running-version)
  "the version of the compos that runs, such as 0.9.2, counting a Scheme bundle its overlay took; #f in a checkout"
  (let* ((info (build-info)) (v (and info (plist-get info 'version)))
         (m (and info (release-overlay-manifest (release-overlay-dir #t))))
         (ov (and m (release--same-commit? (plist-get m 'base) (plist-get info 'commit)) (plist-get m 'version))))
    (and (string? v) (release--bare-version (if (string? ov) ov v)))))

(effects! '(write execute))

(define (release-overlay-clear! dir)
  "(release-overlay-clear! DIR) -- delete the overlay at DIR: its files and its manifest; answers how many files went"
  (let ((m (release-overlay-manifest dir)))
    (if (not m)
        0
        (let ((files (or (plist-get m 'files) '())))
          (for-each (lambda (f) (let ((p (string-append dir "/" f))) (when (file-exists? p) (delete-file! p)))) files)
          (delete-file! (string-append dir "/overlay.scm"))
          (length files)))))

(define (release--stable-eval code)
  ;; CODE's value in the stable compos: this one, or the one at release-stable-socket
  (if (release-stable-self?)
      (eval (car (scheme-read code)))
      (let ((out (peer-eval (expand-file-name release-stable-socket) code)))
        (let ((forms (and (string? out) (scheme-read out)))) (and (pair? forms) (car forms))))))

(define (release-stable-commit)
  "(release-stable-commit) -- the commit the stable compos was built from, asked over its socket; #f when it does not answer"
  (ignore-errors (lambda () (release--stable-eval "(let ((i (build-info))) (and i (plist-get i 'commit)))"))))

(define (release-overlay-apply! root rels base version)
  "(release-overlay-apply! ROOT RELS BASE VERSION) -- copy each checkout file REL under ROOT into the stable compos's overlay, note the overlay patches commit BASE (as VERSION), and load each file into the stable compos; answers ((REL ok) or (REL failed) ...). Blocks on the socket: run it in a task"
  (let* ((dir (release-overlay-dir))
         (old (release-overlay-manifest dir))
         (keep (if (and old (release--same-commit? (plist-get old 'base) base)) (or (plist-get old 'files) '()) '()))
         (pairs (filter cadr (map (lambda (r) (list r (release-overlay-target r))) rels)))
         (files (let loop ((fs (append keep (map cadr pairs))) (acc '()))
                  (cond ((null? fs) (reverse acc))
                        ((member (car fs) acc) (loop (cdr fs) acc))
                        (else (loop (cdr fs) (cons (car fs) acc)))))))
    (when (and old (not (release--same-commit? (plist-get old 'base) base))) (release-overlay-clear! dir))
    (for-each (lambda (pr)
                (let ((dest (string-append dir "/" (cadr pr))))
                  (make-directory! (path-directory dest))
                  (write-file! dest (read-file (string-append root "/" (car pr))))))
              pairs)
    (write-file! (string-append dir "/overlay.scm")
                 (string-append ";; overlay.scm --- the Scheme files this compos loads ahead of priv while it runs commit base\n"
                                (pp-to-string (list 'overlay 'base base 'version version 'files files)) "\n"))
    (map (lambda (pr)
           (let* ((dest (string-append dir "/" (cadr pr)))
                  (ok (ignore-errors (lambda () (release--stable-eval (string-append "(begin (load \"" dest "\") #t)"))))))
             (list (car pr) (if (eq? ok #t) 'ok 'failed))))
         pairs)))

(define (release--hot-patch-report rs)
  (let ((bad (filter (lambda (r) (eq? (cadr r) 'failed)) rs)))
    (string-append "hot-patched the stable compos: " (number->string (- (length rs) (length bad))) " files loaded"
                   (if (pair? bad) (string-append ", failed: " (string-join (map car bad) ", ")) ""))))

(define (release-hot-patch! . k)
  "(release-hot-patch! [K]) -- in a task, load the .scm files of release-checkout changed since the stable compos's commit into the stable compos over release-stable-socket, and keep them in its overlay so its next boot loads them too; K gets ((REL ok|failed) ...), or #f when the stable compos does not answer; publishes release hot-patched"
  (task-spawn
    (lambda ()
      (let* ((done (lambda (r) (when (pair? k) ((car k) r)) r))
             (commit (release-stable-commit))
             (root (expand-file-name release-checkout)))
        (if (not (string? commit))
            (begin (message "the stable compos does not answer, or runs no release") (done #f))
            (let* ((out (shell-command->string
                          (string-append "git -C " (sh-quote root) " diff --name-only " (sh-quote commit)
                                         " -- scheme apps/compos_core/priv; git -C " (sh-quote root)
                                         " ls-files --others --exclude-standard -- scheme apps/compos_core/priv")
                          root))
                   (rels (filter (lambda (r) (and (release-overlay-target r) (file-exists? (string-append root "/" r))))
                                 (map string-trim (string-split (string-trim out) "\n")))))
              (if (null? rels)
                  (begin (message (string-append "no Scheme changed since the stable compos's " commit)) (done '()))
                  (let ((rs (release-overlay-apply! root rels commit (or (release--stable-eval "(release-running-version)") ""))))
                    (message (release--hot-patch-report rs))
                    (event-publish! "release" 'hot-patched (map car rs))
                    (done rs)))))))))

(define-command "release-hot-patch" "Load the Scheme changed since the stable compos's commit into it, and keep it in its overlay for its next boot"
  (lambda () (message "hot-patching the stable compos…") (release-hot-patch!))
  'public #t)

(effects! '(write execute external))

(define (release-update-scheme! version url base . k)
  "(release-update-scheme! VERSION URL BASE [K]) -- take release VERSION's Scheme bundle from URL, made for stable commit BASE: download and unpack it, put its files in the stable compos's overlay and load them, no restart; K gets the results or #f"
  (let* ((dir (string-append (compos-cache-dir) "/compos-" version "-scheme"))
         (tgz (string-append dir ".tar.gz")))
    (message (string-append "downloading the Scheme of compos " version "…"))
    (shell-command->string
      (string-append "mkdir -p " (sh-quote dir) " && curl -fsSL --retry 2 -o " (sh-quote tgz) " " (sh-quote url)
                     " && tar -xzf " (sh-quote tgz) " -C " (sh-quote dir) " && echo @@ok")
      (compos-cache-dir)
      (lambda (out)
        (let ((m (and (string-contains? out "@@ok")
                      (let ((forms (scheme-read (read-file (string-append dir "/scheme-bundle.scm")))))
                        (and (pair? forms) (pair? (car forms)) (cdr (car forms)))))))
          (if (not (pair? m))
              (begin (message (string-append "the Scheme of compos " version " did not download: " (string-trim out)))
                     (when (pair? k) ((car k) #f)))
              (task-spawn
                (lambda ()
                  (let ((rs (release-overlay-apply! dir (or (plist-get m 'files) '()) base version)))
                    (message (string-append "compos " version ": " (release--hot-patch-report rs) "; no restart needed"))
                    (event-publish! "release" 'scheme-updated (list version (map car rs)))
                    ;; the bundle carries the release's standard.lock: the packages follow it
                    (ignore-errors (lambda () (release--stable-eval "(begin (package-follow-release!) #t)")))
                    (when (pair? k) ((car k) rs)))))))))))

(effects! '(write))

(defvar 'release--overlay-booted #f "#t once this session loaded its overlay; the overlay's own release.scm must not load it again")

(define (release-overlay-boot!)
  "(release-overlay-boot!) -- at boot of a release: put a live overlay first on load-path and load its files over priv's; an overlay made for another commit (a full install since) is cleared. Once a session; answers the files loaded"
  (let* ((info (build-info)) (dir (release-overlay-dir #t)) (m (and info (release-overlay-manifest dir))))
    (cond (release--overlay-booted '())
          ((not m) '())
          ((not (release--same-commit? (plist-get m 'base) (plist-get info 'commit)))
           (release-overlay-clear! dir)
           '())
          (else
           (set! release--overlay-booted #t)
           (unless (member dir load-path) (set! load-path (cons dir load-path)))
           (filter (lambda (f) (ignore-errors (lambda () (load (string-append dir "/" f)) #t)))
                   (or (plist-get m 'files) '()))))))

(effects! '(pure))
(public! 'release-overlay-target "(release-overlay-target REL) -- where checkout file REL goes in the overlay, or #f for a file it cannot carry")
(effects! '(read))
(public! 'release-stable-state-dir "(release-stable-state-dir) -- the stable compos's state folder")
(public! 'release-overlay-dir "(release-overlay-dir [SELF]) -- the overlay folder of the stable compos, or of this one")
(public! 'release-overlay-manifest "(release-overlay-manifest DIR) -- the overlay at DIR as a plist: base, version, files; #f when none")
(public! 'release-running-version "(release-running-version) -- the version that runs, counting a Scheme bundle its overlay took; #f in a checkout")
(effects! '(write execute))
(public! 'release-overlay-clear! "(release-overlay-clear! DIR) -- delete the overlay at DIR; answers how many files went")
(public! 'release-stable-commit "(release-stable-commit) -- the commit the stable compos was built from, or #f")
(public! 'release-overlay-apply! "(release-overlay-apply! ROOT RELS BASE VERSION) -- copy the files RELS under ROOT into the stable overlay for commit BASE and load them into the stable compos; blocks, run it in a task")
(public! 'release-hot-patch! "(release-hot-patch! [K]) -- in a task, load the Scheme changed since the stable compos's commit into it and keep it in its overlay; K gets ((REL ok|failed) ...)")
(effects! '(write execute external))
(public! 'release-update-scheme! "(release-update-scheme! VERSION URL BASE [K]) -- take a release's Scheme bundle into the stable overlay and load it, no restart")
(effects! '(write))
(public! 'release-overlay-boot! "(release-overlay-boot!) -- at boot, load a live overlay over priv, or clear one a full install left behind")

(effects! '(write))

(require 'cron)
(cron-define! "compos-update-check" "0 */6 * * *" 'call 'release-check! 'save #f)
;; boot only: a reload of this file (a hot patch loads it too) must not
;; load the overlay again
(unless (featurep 'release) (release-overlay-boot!))
(release-check!)

