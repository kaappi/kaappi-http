(import (scheme base) (scheme write) (kaappi http))

(define (handler request)
  (let ((method (request-method request))
        (path   (request-path request)))

    (cond
      ((equal? path "/")
       (make-response 200
         "<h1>Welcome to Kaappi HTTP</h1><p>Try /hello or /time</p>"
         '(("Content-Type" . "text/html"))))

      ((equal? path "/hello")
       (let ((name (or (cdr (or (assoc "name" (request-query-params request))
                                '("name" . "World")))
                       "World")))
         (make-response 200
           (string-append "Hello, " name "!")
           '(("Content-Type" . "text/plain"))))  )

      ((equal? path "/time")
       (make-response 200
         (number->string (current-second))
         '(("Content-Type" . "text/plain"))))

      ((and (equal? method "POST") (equal? path "/echo"))
       (make-response 200 (request-body request)
         '(("Content-Type" . "text/plain"))))

      (else
       (make-response 404 "Not Found"
         '(("Content-Type" . "text/plain")))))))

(http-listen handler 8080)
