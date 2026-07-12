;; Test server app — used by test-fiber-server.sh
(import (scheme base) (scheme write) (kaappi http))

(define (handler request)
  (let ((path (request-path request)))
    (cond
      ((equal? path "/")
       (make-response 200 "Hello, World!"))
      ((equal? path "/slow")
       (make-response 200 (request-body request)))
      (else (make-response 404 "Not Found")))))

(http-listen-fiber handler 19877)
