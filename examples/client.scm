(import (scheme base) (scheme write) (kaappi http))

;; GET request
(display "=== GET http://httpbin.org/get ===") (newline)
(let ((resp (http-get "http://httpbin.org/get")))
  (display "Status: ") (display (response-status resp)) (newline)
  (display "Body (first 200 chars): ")
  (let ((body (response-body resp)))
    (display (if (> (string-length body) 200)
                 (substring body 0 200)
                 body)))
  (newline))

(newline)

;; POST request
(display "=== POST http://httpbin.org/post ===") (newline)
(let ((resp (http-post "http://httpbin.org/post"
              '(("Content-Type" . "application/json"))
              "{\"hello\": \"from kaappi\"}")))
  (display "Status: ") (display (response-status resp)) (newline)
  (display "Body (first 200 chars): ")
  (let ((body (response-body resp)))
    (display (if (> (string-length body) 200)
                 (substring body 0 200)
                 body)))
  (newline))
