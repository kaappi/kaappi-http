;; Integrated client+server test.
;; Uses a single connection per test: server handles one request,
;; then client sends the next one.
(import (scheme base) (scheme write)
        (kaappi http net) (kaappi http parse)
        (kaappi http client))

(define pass 0)
(define fail 0)

(define (check name expected actual)
  (if (equal? expected actual)
      (begin (set! pass (+ pass 1))
             (display "  PASS: ") (display name) (newline))
      (begin (set! fail (+ fail 1))
             (display "  FAIL: ") (display name) (newline)
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write actual) (newline))))

;; --- Test handler ---
(define (test-handler request)
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

;; Serve exactly one request, return after handling it
(define (serve-one listen-fd handler)
  (let ((client-fd (tcp-accept listen-fd)))
    (guard (exn (#t (guard (e2 (#t #f)) (tcp-close client-fd))))
      (let* ((buf (make-http-buffer client-fd))
             (request (http-read-request buf))
             (response (handler request))
             (text (http-format-response
                     (response-status response)
                     (response-reason response)
                     (response-headers response)
                     (response-body response))))
        (http-send-all client-fd text)
        (tcp-close client-fd)))))

;; Use spawn to run server for one request while client connects
(define test-port 19876)
(define listen-fd (tcp-listen "127.0.0.1" test-port))
(define base-url (string-append "http://127.0.0.1:" (number->string test-port)))

(define (run-test name url handler-fn check-fn . client-args)
  (let ((server-fiber (spawn (lambda () (serve-one listen-fd handler-fn)))))
    (let ((resp (apply http-get url client-args)))
      (fiber-join server-fiber)
      (check-fn resp))))

;; --- Tests ---

(display "=== GET / ===") (newline)
(let ((fib (spawn (lambda () (serve-one listen-fd test-handler)))))
  (let ((resp (http-get (string-append base-url "/"))))
    (fiber-join fib)
    (check "GET / status" 200 (response-status resp))
    (check "GET / body" "Hello, World!" (response-body resp))))

(display "=== GET /json ===") (newline)
(let ((fib (spawn (lambda () (serve-one listen-fd test-handler)))))
  (let ((resp (http-get (string-append base-url "/json"))))
    (fiber-join fib)
    (check "GET /json status" 200 (response-status resp))
    (check "GET /json body" "{\"ok\":true}" (response-body resp))
    (check "GET /json content-type" "application/json"
      (response-header resp "content-type"))))

(display "=== POST /echo ===") (newline)
(let ((fib (spawn (lambda () (serve-one listen-fd test-handler)))))
  (let ((resp (http-post (string-append base-url "/echo")
                '(("Content-Type" . "text/plain"))
                "echo body")))
    (fiber-join fib)
    (check "POST /echo status" 200 (response-status resp))
    (check "POST /echo body" "echo body" (response-body resp))))

(display "=== GET /missing ===") (newline)
(let ((fib (spawn (lambda () (serve-one listen-fd test-handler)))))
  (let ((resp (http-get (string-append base-url "/missing"))))
    (fiber-join fib)
    (check "GET /missing status" 404 (response-status resp))))

(display "=== GET /query ===") (newline)
(let ((fib (spawn (lambda () (serve-one listen-fd test-handler)))))
  (let ((resp (http-get (string-append base-url "/query?name=alice&age=30"))))
    (fiber-join fib)
    (check "GET /query status" 200 (response-status resp))
    (check "GET /query body" "name=alice;age=30;" (response-body resp))))

(tcp-close listen-fd)

(newline)
(display "=== Results: ")
(display pass) (display " passed, ")
(display fail) (display " failed ===")
(newline)
(when (> fail 0) (exit 1))
