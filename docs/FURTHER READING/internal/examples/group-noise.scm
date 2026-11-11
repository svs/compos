(define (group-noise-next noise)
  (cond ((equal? noise (quote off)) (quote quiet))
        ((equal? noise (quote quiet)) (quote loud))
        (else (quote off))))
