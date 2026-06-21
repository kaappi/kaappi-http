(define-library (kaappi http client)
  (import (scheme base) (kaappi http net) (kaappi http parse))
  (export http-request http-get http-post http-put http-delete http-head)
  (begin

    (define (http-request method url headers body)
      (let-values (((scheme host port path) (parse-url url)))
        (let* ((tls? (equal? scheme "https"))
               (handle (if tls?
                           (tls-connect host port)
                           (tcp-connect host port)))
               (send-fn (if tls? tls-send tcp-send))
               (recv-fn (if tls? tls-recv tcp-recv))
               (close-fn (if tls? tls-close tcp-close))
               (buf (make-http-buffer handle recv-fn))
               (host-header
                 (cond ((and tls? (= port 443)) host)
                       ((and (not tls?) (= port 80)) host)
                       (else (string-append host ":" (number->string port)))))
               (req (http-format-request method path host-header
                      headers (or body ""))))
          (http-send-all handle req send-fn)
          (let ((resp (http-read-response buf)))
            (close-fn handle)
            resp))))

    (define (http-get url . args)
      (http-request "GET" url (if (pair? args) (car args) '()) #f))

    (define (http-post url . args)
      (let ((headers (if (pair? args) (car args) '()))
            (body    (if (and (pair? args) (pair? (cdr args))) (cadr args) "")))
        (http-request "POST" url headers body)))

    (define (http-put url . args)
      (let ((headers (if (pair? args) (car args) '()))
            (body    (if (and (pair? args) (pair? (cdr args))) (cadr args) "")))
        (http-request "PUT" url headers body)))

    (define (http-delete url . args)
      (http-request "DELETE" url (if (pair? args) (car args) '()) #f))

    (define (http-head url . args)
      (http-request "HEAD" url (if (pair? args) (car args) '()) #f))))
