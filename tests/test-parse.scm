;; Offline HTTP parsing tests (no network needed)
(import (scheme base) (scheme write) (kaappi http parse))

;; Feeds http-read-response/http-read-request from an in-memory byte source
;; instead of a real socket -- make-http-buffer's port branch (#1478) reads
;; via plain read-u8/read-bytevector!, so any binary input port works.
(define (fake-response-from-bytes raw)
  (http-read-response (make-http-buffer (open-input-bytevector (string->utf8 raw)))))

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

;; --- Header lookup case-insensitivity (#1746) ---
(display "=== Header Lookup Case-Insensitivity ===") (newline)

(let ((resp (make-response 200 "" '(("content-type" . "text/html")))))
  (check "lowercase-stored, exact lookup" "text/html" (response-header resp "content-type"))
  (check "lowercase-stored, mixed lookup" "text/html" (response-header resp "Content-Type"))
  (check "lowercase-stored, upper lookup" "text/html" (response-header resp "CONTENT-TYPE")))

(let ((resp (make-response 200 "" '(("Content-Type" . "text/html")))))
  (check "mixed-stored, lower lookup" "text/html" (response-header resp "content-type")))

(let ((req (make-http-request "GET" "/" "" "HTTP/1.1" '(("X-Token" . "abc")) "")))
  (check "request-header case-insensitive" "abc" (request-header req "x-token")))

;; --- Chunked transfer-encoding body decoding (#1746) ---
(display "=== Chunked Transfer-Encoding ===") (newline)

(let ((resp (fake-response-from-bytes
              (string-append "HTTP/1.1 200 OK\r\n"
                              "Transfer-Encoding: chunked\r\n"
                              "\r\n"
                              "5\r\nHello\r\n"
                              "6\r\n World\r\n"
                              "0\r\n"
                              "\r\n"))))
  (check "chunked status" 200 (response-status resp))
  (check "chunked body assembled" "Hello World" (response-body resp))
  (check "chunked transfer-encoding header preserved" "chunked"
    (response-header resp "transfer-encoding")))

;; A chunked response whose only chunk is the zero-length terminator.
(let ((resp (fake-response-from-bytes
              (string-append "HTTP/1.1 204 No Content\r\n"
                              "Transfer-Encoding: chunked\r\n"
                              "\r\n"
                              "0\r\n"
                              "\r\n"))))
  (check "chunked empty body" "" (response-body resp)))

;; Chunk extensions (";name=value" after the size) must be ignored.
(let ((resp (fake-response-from-bytes
              (string-append "HTTP/1.1 200 OK\r\n"
                              "Transfer-Encoding: chunked\r\n"
                              "\r\n"
                              "3;ext=1\r\nabc\r\n"
                              "0\r\n"
                              "\r\n"))))
  (check "chunked with chunk-extension" "abc" (response-body resp)))

;; A trailer field line between the terminating chunk and the final blank
;; line must be skipped rather than misread as body or a new status line.
(let ((resp (fake-response-from-bytes
              (string-append "HTTP/1.1 200 OK\r\n"
                              "Transfer-Encoding: chunked\r\n"
                              "\r\n"
                              "2\r\nhi\r\n"
                              "0\r\n"
                              "X-Trailer: done\r\n"
                              "\r\n"))))
  (check "chunked with trailer" "hi" (response-body resp)))

;; Content-Length responses must still work unchanged.
(let ((resp (fake-response-from-bytes
              (string-append "HTTP/1.1 200 OK\r\n"
                              "Content-Length: 5\r\n"
                              "\r\n"
                              "Howdy"))))
  (check "content-length body unaffected" "Howdy" (response-body resp)))

(newline)
(display "=== Results: ")
(display pass) (display " passed, ")
(display fail) (display " failed ===")
(newline)
(when (> fail 0) (exit 1))
