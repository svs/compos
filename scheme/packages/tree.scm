;;; tree.scm --- a tree of plists, addressed by id.
;;;
;;; A tree is a root plist whose children sit under a key, each child a
;;; plist with children of its own, down to leaves. SHAPE names the levels,
;;; top down: one (CHILDREN-KEY ID-KEY) per level. The root's children are
;;; under the first CHILDREN-KEY, and each of them names itself by the
;;; first ID-KEY. An ID-KEY of #f makes that level leaves: the child is its
;;; own id. The window model is
;;;
;;;   ((panes id) (windows key) (buffers #f))
;;;
;;; Every id is unique in the tree, so a node is found by its id alone.
;;; The root is 'root. Every call is pure: it takes a tree and answers a
;;; new one, or a value read from it.
;;;
;;; Every call walks the tree; the trees here are small. A tree that grows
;;; can keep an index beside its root (id -> path) for find and parent;
;;; the calls keep their signatures.

(domain! 'functions)
(effects! '(pure))

(define (tree--id spec node)
  "The id of NODE at the level SPEC describes."
  (let ((k (cadr spec))) (if k (plist-get node k) node)))

(define (tree--kids spec node)
  "The children of NODE, under SPEC's children key."
  (or (plist-get node (car spec)) '()))

(define (tree--set-kids spec node kids)
  "NODE with KIDS as its children."
  (plist-put node (car spec) kids))

(define (tree--insert-at lst i x)
  "LST with X at index I; #f or an I past the end appends."
  (let ((i (if (number? i) (max 0 (min i (length lst))) (length lst))))
    (append (list-head lst i) (list x) (list-tail lst i))))

(define (tree--locate shape t id)
  "(NODE SHAPE-BELOW) for ID, or #f. SHAPE-BELOW describes NODE's
   children."
  (if (eq? id 'root)
      (list t shape)
      (and (pair? shape)
           (let ((spec (car shape)))
             (let loop ((ks (tree--kids spec t)))
               (cond ((null? ks) #f)
                     ((equal? (tree--id spec (car ks)) id) (list (car ks) (cdr shape)))
                     ((and (pair? (cdr shape)) (tree--locate (cdr shape) (car ks) id)))
                     (else (loop (cdr ks)))))))))

(define (tree-find shape t id)
  "The node whose id is ID, or #f."
  (let ((at (tree--locate shape t id))) (and at (car at))))

(define (tree--parent shape t id here)
  (and (pair? shape)
       (let ((spec (car shape)))
         (let loop ((ks (tree--kids spec t)))
           (cond ((null? ks) #f)
                 ((equal? (tree--id spec (car ks)) id) here)
                 ((and (pair? (cdr shape)) (tree--parent (cdr shape) (car ks) id (tree--id spec (car ks)))))
                 (else (loop (cdr ks))))))))

(define (tree-parent shape t id)
  "The id of ID's parent, 'root for a child of the root, #f when the
   tree has no ID."
  (tree--parent shape t id 'root))

(define (tree-children shape t id)
  "The ids of ID's children, in order; () for a leaf or an unknown ID."
  (let ((at (tree--locate shape t id)))
    (if (and at (pair? (cadr at)))
        (let ((spec (car (cadr at)))) (map (lambda (c) (tree--id spec c)) (tree--kids spec (car at))))
        '())))

(define (tree-index shape t id)
  "ID's place among its parent's children, from 0, or #f."
  (let loop ((ks (tree-children shape t (tree-parent shape t id))) (i 0))
    (cond ((null? ks) #f) ((equal? (car ks) id) i) (else (loop (cdr ks) (+ i 1))))))

(define (tree--update shape t id fn)
  (if (eq? id 'root)
      (fn t shape)
      (if (null? shape)
          t
          (let ((spec (car shape)))
            (tree--set-kids spec t
              (map (lambda (c)
                     (cond ((equal? (tree--id spec c) id) (fn c (cdr shape)))
                           ((pair? (cdr shape)) (tree--update (cdr shape) c id fn))
                           (else c)))
                   (tree--kids spec t)))))))

(define (tree-update shape t id fn)
  "T with node ID replaced by (FN NODE). An unknown ID changes nothing."
  (tree--update shape t id (lambda (node below) (fn node))))

(define (tree-insert shape t parent node &optional at)
  "T with NODE among PARENT's children at index AT, the end when AT is
   absent. An unknown PARENT changes nothing."
  (tree--update shape t parent
    (lambda (p below)
      (if (null? below) p (tree--set-kids (car below) p (tree--insert-at (tree--kids (car below) p) at node))))))

(define (tree-remove shape t id)
  "T without node ID and everything under it."
  (if (null? shape)
      t
      (let ((spec (car shape)))
        (tree--set-kids spec t
          (apply append
                 (map (lambda (c)
                        (cond ((equal? (tree--id spec c) id) '())
                              ((pair? (cdr shape)) (list (tree-remove (cdr shape) c id)))
                              (else (list c))))
                      (tree--kids spec t)))))))

(define (tree-move shape t id parent &optional at)
  "Node ID, with everything under it, moves among PARENT's children to
   index AT, the end when AT is absent. An unknown ID or PARENT changes
   nothing."
  (let ((n (tree-find shape t id)))
    (if (and n (tree--locate shape t parent))
        (tree-insert shape (tree-remove shape t id) parent n at)
        t)))

(define (tree-nodes shape t depth)
  "Every node at DEPTH, in order: 1 is the root's children."
  (if (or (null? shape) (< depth 1))
      '()
      (let ((kids (tree--kids (car shape) t)))
        (if (= depth 1)
            kids
            (apply append (map (lambda (c) (tree-nodes (cdr shape) c (- depth 1))) kids))))))

(define (tree-map shape t depth fn)
  "T with every node at DEPTH replaced by (FN NODE)."
  (if (or (null? shape) (< depth 1))
      t
      (let ((spec (car shape)))
        (tree--set-kids spec t
          (map (lambda (c) (if (= depth 1) (fn c) (tree-map (cdr shape) c (- depth 1) fn)))
               (tree--kids spec t))))))

(public! 'tree-find "(tree-find SHAPE TREE ID) -> the node whose id is ID, or #f; pure")
(public! 'tree-parent "(tree-parent SHAPE TREE ID) -> its parent's id, 'root, or #f; pure")
(public! 'tree-children "(tree-children SHAPE TREE ID) -> the ids of its children, in order; pure")
(public! 'tree-index "(tree-index SHAPE TREE ID) -> its place among its parent's children, or #f; pure")
(public! 'tree-update "(tree-update SHAPE TREE ID FN) -> TREE with node ID replaced by (FN NODE); pure")
(public! 'tree-insert "(tree-insert SHAPE TREE PARENT NODE [AT]) -> TREE with NODE among PARENT's children at AT; pure")
(public! 'tree-remove "(tree-remove SHAPE TREE ID) -> TREE without ID and its subtree; pure")
(public! 'tree-move "(tree-move SHAPE TREE ID PARENT [AT]) -> TREE with ID under PARENT at AT; pure")
(public! 'tree-nodes "(tree-nodes SHAPE TREE DEPTH) -> every node at DEPTH, 1 the root's children; pure")
(public! 'tree-map "(tree-map SHAPE TREE DEPTH FN) -> TREE with every node at DEPTH replaced by (FN NODE); pure")
(for-each (lambda (n) (catalog-meta! 'function n 'effects '(pure)))
          '("tree-find" "tree-parent" "tree-children" "tree-index" "tree-update" "tree-insert"
            "tree-remove" "tree-move" "tree-nodes" "tree-map"))

(provide 'tree)
