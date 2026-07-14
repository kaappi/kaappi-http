;; Test server app — used by test-parallel-server.sh
;; Echoes the request path so the client can verify each response matched its
;; own request (catches cross-wired connections under concurrency).
(import (scheme base) (scheme write) (kaappi http))

(define (handler request)
  (make-response 200
    (string-append "ok:" (request-path request))
    '(("Content-Type" . "text/plain"))))

;; 4 threads. On Linux each binds its own SO_REUSEPORT socket (kernel-balanced);
;; on Darwin one acceptor distributes fds to worker threads.
(http-listen-parallel handler 19878 4)
