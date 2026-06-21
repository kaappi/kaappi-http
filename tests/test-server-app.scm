;; Test server app — used by test-server.sh
(import (scheme base) (scheme write) (kaappi http))

(define (handler request)
  (let ((path (request-path request))
        (method (request-method request)))
    (cond
      ((equal? path "/")
       (make-response 200 "Hello, World!"))
      ((equal? path "/json")
       (make-response 200 "{\"ok\":true}"
         '(("Content-Type" . "application/json"))))
      ((and (equal? method "POST") (equal? path "/echo"))
       (make-response 200 (request-body request)))
      ((equal? path "/query")
       (let ((params (request-query-params request)))
         (make-response 200
           (let ((out (open-output-string)))
             (for-each (lambda (p)
                         (display (car p) out) (display "=" out)
                         (display (cdr p) out) (display ";" out))
                       params)
             (get-output-string out)))))
      (else (make-response 404 "Not Found")))))

(http-listen handler 19876)
