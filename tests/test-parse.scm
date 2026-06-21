;; Offline HTTP parsing tests (no network needed)
(import (scheme base) (scheme write) (kaappi http parse))

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

;; --- URL parsing ---
(display "=== URL Parsing ===") (newline)

(let-values (((scheme host port path) (parse-url "http://example.com/api/users")))
  (check "url scheme http" "http" scheme)
  (check "url host" "example.com" host)
  (check "url port default" 80 port)
  (check "url path" "/api/users" path))

(let-values (((scheme host port path) (parse-url "https://api.example.com/v1")))
  (check "url scheme https" "https" scheme)
  (check "url https host" "api.example.com" host)
  (check "url https port default" 443 port)
  (check "url https path" "/v1" path))

(let-values (((scheme host port path) (parse-url "http://localhost:8080/test")))
  (check "url host localhost" "localhost" host)
  (check "url port 8080" 8080 port)
  (check "url path /test" "/test" path))

(let-values (((scheme host port path) (parse-url "https://example.com:8443/secure")))
  (check "url https custom port" 8443 port)
  (check "url https custom path" "/secure" path))

(let-values (((scheme host port path) (parse-url "http://example.com")))
  (check "url no path" "/" path))

;; --- Query string parsing ---
(display "=== Query String Parsing ===") (newline)

(check "query simple"
  '(("page" . "1") ("limit" . "10"))
  (parse-query-string "page=1&limit=10"))

(check "query empty" '() (parse-query-string ""))
(check "query #f" '() (parse-query-string #f))

(check "query encoded"
  '(("name" . "hello world"))
  (parse-query-string "name=hello+world"))

(check "query percent"
  '(("q" . "a&b"))
  (parse-query-string "q=a%26b"))

;; --- Response formatting ---
(display "=== Response Formatting ===") (newline)

(let ((resp (make-response 200 "Hello")))
  (check "response status" 200 (response-status resp))
  (check "response reason" "OK" (response-reason resp))
  (check "response body" "Hello" (response-body resp)))

(let ((resp (make-response 404 "Not Found" '(("X-Custom" . "test")))))
  (check "response 404 reason" "Not Found" (response-reason resp))
  (check "response custom header" "test" (response-header resp "X-Custom")))

;; --- Request formatting ---
(display "=== Request Formatting ===") (newline)

(let ((req (http-format-request "GET" "/api/test" "example.com" '() "")))
  (check "request has method" #t (string? req))
  (check "request contains GET" #t
    (let ((idx (let loop ((i 0))
                 (if (>= i (- (string-length req) 2)) #f
                     (if (and (char=? (string-ref req i) #\G)
                              (char=? (string-ref req (+ i 1)) #\E)
                              (char=? (string-ref req (+ i 2)) #\T))
                         #t (loop (+ i 1)))))))
      (if idx #t #f))))

(newline)
(display "=== Results: ")
(display pass) (display " passed, ")
(display fail) (display " failed ===")
(newline)
(when (> fail 0) (exit 1))
