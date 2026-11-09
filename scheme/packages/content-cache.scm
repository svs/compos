;;; content-cache.scm --- A content-addressed cache over pluggable sinks.
;;;
;;; A key names what made a value: (content-key PART ...) hashes the
;;; parts, so a changed source, model or prompt is a different key and
;;; nothing ever needs invalidating. A namespace reads through a chain of
;;; sinks, fastest first. A hit is copied up into the faster sinks it
;;; passed on the way down; a put goes to every sink in the chain.
;;;
;;; A sink is a plist of three procedures:
;;;   'get (NS KEY) -> the string, or #f
;;;   'put (NS KEY VALUE)
;;;   'del (NS KEY)
;;; memory and disk come with the editor; cache-sink-define! adds others,
;;; a SQLite table or a store on another machine, without touching a caller.

(domain! 'cache)
(effects! '(write))

(defgroup 'content-cache "A content-addressed cache over pluggable sinks.")

(defcustom 'content-cache-chain '(memory disk)
  "The sinks a namespace reads through, fastest first, unless it names its own."
  'group 'content-cache 'type 'list)

(defcustom 'content-cache-memory-max 2000
  "How many entries the memory sink keeps before it forgets the oldest."
  'group 'content-cache 'type 'number)

(defcustom 'content-cache-root ""
  "Where the cache keeps its files, one folder per namespace; empty means the compos cache folder, ~/.cache/compos."
  'group 'content-cache 'type 'string)

(define *content-cache-sinks* '())
(define *content-cache-chains* '())
(define *content-cache-flights* '())

;;; Keys

(define (content-key &rest parts)
  (content-hash (format "~s" parts)))

;;; Sinks and chains

(define (cache-sink-define! name sink)
  (set! *content-cache-sinks*
        (cons (list name sink)
              (filter (lambda (s) (not (eq? (car s) name))) *content-cache-sinks*)))
  name)

(define (cache-sink name)
  (let ((hit (assq name *content-cache-sinks*))) (and hit (cadr hit))))

(define (cache-sinks) (reverse (map car *content-cache-sinks*)))

(define (cache-chain-set! ns names)
  (set! *content-cache-chains*
        (cons (list ns names)
              (filter (lambda (c) (not (equal? (car c) ns))) *content-cache-chains*)))
  names)

(define (cache-chain ns)
  (let ((hit (assoc ns *content-cache-chains*)))
    (filter cache-sink (if hit (cadr hit) content-cache-chain))))

;; A sink that raises is a miss, never a broken caller.
(define (cache--call name op &rest args)
  (let ((f (plist-get (cache-sink name) op)))
    (and f (ignore-errors (lambda () (apply f args))))))

;;; Reads and writes

(define (cache-get ns key)
  (let loop ((names (cache-chain ns)) (passed '()))
    (if (null? names)
        #f
        (let ((v (cache--call (car names) 'get ns key)))
          (if (string? v)
              (begin (for-each (lambda (s) (cache--call s 'put ns key v)) passed) v)
              (loop (cdr names) (cons (car names) passed)))))))

(define (cache-put! ns key value)
  (for-each (lambda (s) (cache--call s 'put ns key value)) (cache-chain ns))
  value)

(define (cache-del! ns key)
  (for-each (lambda (s) (cache--call s 'del ns key)) (cache-chain ns))
  #t)

;; The value now when the chain has it; else PRODUCE runs once, however
;; many callers ask while it works, and every waiting K gets the answer.
;; PRODUCE is (lambda (k) ...) and calls (k STRING), or (k #f) on failure.
(define (cache--flight ns key)
  (let ((hit (assoc (list ns key) *content-cache-flights*))) (and hit (cadr hit))))

(define (cache--flight-set! ns key waiters)
  (set! *content-cache-flights*
        (append (if waiters (list (list (list ns key) waiters)) '())
                (filter (lambda (f) (not (equal? (car f) (list ns key))))
                        *content-cache-flights*))))

(define (cache-fetch ns key produce k)
  (let ((hit (cache-get ns key)))
    (cond
     (hit (k hit) hit)
     ((cache--flight ns key)
      (cache--flight-set! ns key (cons k (cache--flight ns key)))
      #f)
     (else
      (cache--flight-set! ns key (list k))
      (produce
       (lambda (value)
         (let ((waiters (reverse (or (cache--flight ns key) '()))))
           (cache--flight-set! ns key #f)
           (when (string? value) (cache-put! ns key value))
           (for-each (lambda (w) (w value)) waiters))))
      #f))))

(define (cache-pending? ns key)
  (and (cache--flight ns key) #t))

;;; The memory sink: this session, newest first, bounded.

(define *content-cache-memory* '())

(define (cache--memory-drop ns key)
  (filter (lambda (e) (not (equal? (car e) (list ns key)))) *content-cache-memory*))

(cache-sink-define! 'memory
  (list 'get (lambda (ns key)
               (let ((hit (assoc (list ns key) *content-cache-memory*)))
                 (and hit (cadr hit))))
        'put (lambda (ns key value)
               (let ((rest (cache--memory-drop ns key)))
                 (set! *content-cache-memory*
                       (cons (list (list ns key) value)
                             (take rest (min (length rest)
                                             (max 0 (- content-cache-memory-max 1))))))))
        'del (lambda (ns key)
               (set! *content-cache-memory* (cache--memory-drop ns key)))))

;;; The disk sink: one file per entry, fanned out by the key's first byte.

(define (content-cache-dir)
  (if (equal? content-cache-root "")
      (compos-cache-dir)
      content-cache-root))

(define (cache--disk-path ns key)
  (string-append (content-cache-dir) "/"
                 (if (symbol? ns) (symbol->string ns) ns) "/"
                 (substring key 0 2) "/" key))

(cache-sink-define! 'disk
  (list 'get (lambda (ns key)
               (let ((p (cache--disk-path ns key)))
                 (and (file-exists? p) (read-file p))))
        'put (lambda (ns key value)
               (raw-write-file! (cache--disk-path ns key) value)
               (cache--sweep-soon! ns))
        'del (lambda (ns key)
               (let ((p (cache--disk-path ns key)))
                 (when (file-exists? p) (delete-file! p))))))

;;; --- files ------------------------------------------------------------------
;;; A namespace also keeps files that a tool reads by path: a rendered page,
;;; an image, an etag. cache-path names one in the namespace's folder. Each
;;; namespace has a size cap; the sweep drops its oldest entries past it. An
;;; entry is one name at the top of the folder, a file or a whole folder, so a
;;; folder of rendered pages goes or stays as one.

(defcustom 'content-cache-max-mb 500
  "The most megabytes one cache namespace keeps on disk. Past it, the sweep deletes the oldest entries."
  'group 'content-cache 'type 'integer)

(define *content-cache-swept* '())

(define (cache--ns-dir ns)
  (string-append (content-cache-dir) "/" (if (symbol? ns) (symbol->string ns) ns)))

(define (cache-path ns name)
  (let* ((root (cache--ns-dir ns))
         (path (if (equal? name "") root (string-append root "/" name)))
         (dir (if (equal? name "") root (car (path-split path)))))
    (unless (file-directory? dir) (make-directory! dir))
    (cache--sweep-soon! ns)
    path))

(define (cache--name e)
  (if (string-suffix? "/" e) (substring e 0 (- (string-length e) 1)) e))

(define (cache--delete! path)
  (when (file-directory? path)
    (for-each (lambda (e) (cache--delete! (string-append path "/" (cache--name e)))) (list-dir path)))
  (delete-file! path))

(define (cache--entry-size path)
  (if (file-directory? path)
      (apply + (map (lambda (e) (cache--entry-size (string-append path "/" (cache--name e))))
                    (list-dir path)))
      (file-size path)))

(define (cache--entries ns)
  (let ((dir (cache--ns-dir ns)))
    (if (file-directory? dir)
        (map (lambda (e)
               (let ((p (string-append dir "/" (cache--name e))))
                 (list (file-mtime p) p (cache--entry-size p))))
             (list-dir dir))
        '())))

(define (cache-sweep! ns)
  (let ((cap (* content-cache-max-mb 1024 1024)))
    (let loop ((es (reverse (sort (cache--entries ns)))) (total 0) (dropped 0))
      (cond ((null? es) dropped)
            ((> (+ total (caddr (car es))) cap)
             (for-each (lambda (e) (ignore-errors (lambda () (cache--delete! (cadr e))))) es)
             (+ dropped (length es)))
            (else (loop (cdr es) (+ total (caddr (car es))) dropped))))))

;; a sweep at most once an hour for each namespace, in a task, started by a
;; write: the cache trims itself while it is used and costs nothing when idle
(define (cache--sweep-soon! ns)
  (let ((last (assoc ns *content-cache-swept*))
        (now (current-time)))
    (when (or (not last) (> (- now (cadr last)) 3600))
      (set! *content-cache-swept*
            (cons (list ns now) (filter (lambda (s) (not (equal? (car s) ns))) *content-cache-swept*)))
      (task-spawn (lambda () (cache-sweep! ns))))))

(effects! '(pure))
(public! 'content-key
  "(content-key PART ...) — the cache key for a value made from PARTS: hash the source text with the model and prompt version, everything that changes the answer")
(effects! '(read))
(public! 'cache-get
  "(cache-get NS KEY) — the cached string, read through NS's sink chain fastest first, a hit copied into the faster sinks; #f on a miss")
(public! 'cache-chain "(cache-chain NS) — the sink names NS reads through, fastest first")
(public! 'cache-sinks "(cache-sinks) — every defined sink name")
(public! 'cache-pending? "(cache-pending? NS KEY) — #t while a cache-fetch is producing KEY")
(public! 'content-cache-dir "(content-cache-dir) — the cache folder, one folder per namespace")
(effects! '(write))
(public! 'cache-put! "(cache-put! NS KEY VALUE) — store the string VALUE in every sink of NS's chain")
(public! 'cache-del! "(cache-del! NS KEY) — drop KEY from every sink of NS's chain")
(public! 'cache-path "(cache-path NS NAME) — the path of the file NAME that NS keeps in the cache folder, its folder made; NAME \"\" is the folder itself")
(effects! '(destroy))
(public! 'cache-sweep! "(cache-sweep! NS) — delete NS's oldest entries until it fits content-cache-max-mb; how many went")
(effects! '(write))
(public! 'cache-fetch
  "(cache-fetch NS KEY PRODUCE K) — K gets the cached value now, or once (PRODUCE k) makes it; concurrent asks for one KEY share one PRODUCE; the value on a hit, else #f")
(public! 'cache-sink-define!
  "(cache-sink-define! NAME SINK) — add or replace a sink; SINK is a plist of 'get (NS KEY), 'put (NS KEY VALUE) and 'del (NS KEY)")
(public! 'cache-chain-set!
  "(cache-chain-set! NS NAMES) — give NS its own sink chain, fastest first")
