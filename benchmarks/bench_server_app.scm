;; KEP-0001 Phase 7 server benchmark app. Picks the server model from
;; argv[1]: "sequential" | "threaded" | "prefork" | "fiber".
(import (scheme base) (scheme write) (scheme process-context) (kaappi http))

(define (handler request)
  (make-response 200 "Hello, World!" '(("Content-Type" . "text/plain"))))

(define args (command-line))
(define model (if (>= (length args) 2) (cadr args) "sequential"))
(define port 19999)

(cond
  ((equal? model "sequential") (http-listen handler port))
  ((equal? model "threaded") (http-listen-threaded handler port))
  ((equal? model "prefork") (http-listen-prefork handler port 4))
  ((equal? model "fiber") (http-listen-fiber handler port))
  (else (error "unknown model" model)))
