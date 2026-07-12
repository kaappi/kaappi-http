;; Integrated client+server test.
;; Uses a single connection per test: server handles one request,
;; then client sends the next one.
;;
;; The server fiber and the client call must run concurrently: `spawn`
;; only queues a fiber (nothing runs until the main fiber gives up
;; control), and kaappi's fiber scheduler is cooperative on a single OS
;; thread, so a blocking FFI call (tcp-accept/tcp-recv, used by both
;; serve-one and http-get) cannot be preempted to switch fibers mid-call.
;; So the client runs on a separate SRFI-18 OS thread instead, genuinely
;; concurrent with the server fiber. kaappi's SRFI-18 threads are
;; share-nothing (each gets its own heap), so record types don't survive
;; thread-join! — the client thunk extracts plain values before returning.
(import (scheme base) (scheme write) (srfi 18)
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

;; Runs the server fiber and the client thunk concurrently: the client
;; thunk executes on its own OS thread (see note above) and must return a
;; plain (status body headers) list rather than a response record.
(define (run-test handler-fn client-thunk check-fn)
  (let ((server-fiber (spawn (lambda () (serve-one listen-fd handler-fn))))
        (client-thread (make-thread client-thunk)))
    (thread-start! client-thread)
    (fiber-join server-fiber)
    (check-fn (thread-join! client-thread))))

(define (result-status r) (car r))
(define (result-body r) (cadr r))
(define (result-header r name)
  (let ((pair (assoc name (caddr r))))
    (if pair (cdr pair) #f)))

(define (client-result resp)
  (list (response-status resp) (response-body resp) (response-headers resp)))

;; --- Tests ---

(display "=== GET / ===") (newline)
(run-test test-handler
  (lambda () (client-result (http-get (string-append base-url "/"))))
  (lambda (r)
    (check "GET / status" 200 (result-status r))
    (check "GET / body" "Hello, World!" (result-body r))))

(display "=== GET /json ===") (newline)
(run-test test-handler
  (lambda () (client-result (http-get (string-append base-url "/json"))))
  (lambda (r)
    (check "GET /json status" 200 (result-status r))
    (check "GET /json body" "{\"ok\":true}" (result-body r))
    (check "GET /json content-type" "application/json"
      (result-header r "content-type"))))

(display "=== POST /echo ===") (newline)
(run-test test-handler
  (lambda ()
    (client-result (http-post (string-append base-url "/echo")
                     '(("Content-Type" . "text/plain"))
                     "echo body")))
  (lambda (r)
    (check "POST /echo status" 200 (result-status r))
    (check "POST /echo body" "echo body" (result-body r))))

(display "=== GET /missing ===") (newline)
(run-test test-handler
  (lambda () (client-result (http-get (string-append base-url "/missing"))))
  (lambda (r)
    (check "GET /missing status" 404 (result-status r))))

(display "=== GET /query ===") (newline)
(run-test test-handler
  (lambda () (client-result (http-get (string-append base-url "/query?name=alice&age=30"))))
  (lambda (r)
    (check "GET /query status" 200 (result-status r))
    (check "GET /query body" "name=alice;age=30;" (result-body r))))

(tcp-close listen-fd)

(newline)
(display "=== Results: ")
(display pass) (display " passed, ")
(display fail) (display " failed ===")
(newline)
(when (> fail 0) (exit 1))
