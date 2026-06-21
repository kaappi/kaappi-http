(define-library (kaappi http client)
  (import (scheme base) (kaappi http net) (kaappi http parse))
  (export http-request http-get http-post http-put http-delete http-head)
  (begin

    (define (http-request method url headers body)
      (let-values (((host port path) (parse-url url)))
        (let* ((fd  (tcp-connect host port))
               (buf (make-http-buffer fd))
               (req (http-format-request method path
                      (string-append host (if (= port 80) ""
                                              (string-append ":" (number->string port))))
                      headers (or body ""))))
          (http-send-all fd req)
          (let ((resp (http-read-response buf)))
            (tcp-close fd)
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
