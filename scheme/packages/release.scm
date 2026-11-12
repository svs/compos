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

(defcustom 'release-stable-socket "~/.compos/sock"
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
    "rm -rf _build/prod/rel && s=$(date +%s) && MIX_ENV=prod BURRITO_TARGET=" (release-target-name)
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

(define (release-running-version)
  "the version of the compos that runs, such as 0.9.2; #f in a checkout"
  (let* ((info (build-info)) (v (and info (plist-get info 'version))))
    (and (string? v) (release--bare-version v))))

(effects! '(read external))

(define (release-latest k)
  "K gets the newest release of release-repo as (VERSION URL SIZE), URL being its executable for this machine's target, or #f when there is none"
  (http-get-json (string-append "https://api.github.com/repos/" release-repo "/releases/latest")
    '(timeout 15000)
    (lambda (j)
      (k (and j (string? (plist-get j 'tag_name))
              (let ((a (find (lambda (a) (string-suffix? (string-append "-" (release-target-name))
                                                         (or (plist-get a 'name) "")))
                             (let ((as (plist-get j 'assets))) (if (vector? as) (vector->list as) (or as '()))))))
                (and a (list (release--bare-version (plist-get j 'tag_name))
                             (plist-get a 'browser_download_url)
                             (plist-get a 'size)))))))))

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

(define-command "compos-update" "Update the stable compos to the newest release and restart it"
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
                         (lambda () (apply release-update! latest))))))))))
