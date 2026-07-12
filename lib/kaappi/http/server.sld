(define-library (kaappi http server)
  (import (scheme base) (scheme write)
          (srfi 18) (kaappi fibers) (kaappi ffi) (kaappi http net) (kaappi http parse))
  (export http-listen http-listen-threaded http-listen-prefork http-listen-fiber)
  (begin

    (define (handle-client handler client-fd . args)
      (let ((recv-fn (if (pair? args) (car args) tcp-recv))
            (send-fn (if (and (pair? args) (pair? (cdr args))) (cadr args) tcp-send)))
        (guard (exn (#t (guard (e2 (#t #f)) (tcp-close client-fd))))
          (let* ((buf (make-http-buffer client-fd recv-fn))
                 (request (http-read-request buf))
                 (response (guard (exn (#t (make-response 500 "Internal Server Error")))
                             (handler request)))
                 (text (http-format-response
                         (response-status response)
                         (response-reason response)
                         (response-headers response)
                         (response-body response))))
            (http-send-all client-fd text send-fn)
            (tcp-close client-fd)))))

    ;; Sequential server
    (define (http-listen handler port . args)
      (let ((host (if (pair? args) (car args) "0.0.0.0")))
        (let ((listen-fd (tcp-listen host port)))
          (display "Listening on ")
          (display host) (display ":") (display port)
          (newline)
          (let loop ()
            (let ((client-fd (tcp-accept listen-fd)))
              (handle-client handler client-fd)
              (loop))))))

    ;; Threaded server — one OS thread per connection via SRFI-18
    (define (http-listen-threaded handler port . args)
      (let ((host (if (pair? args) (car args) "0.0.0.0")))
        (let ((listen-fd (tcp-listen host port)))
          (display "Listening on ")
          (display host) (display ":") (display port)
          (display " (threaded)") (newline)
          (let loop ()
            (let ((client-fd (tcp-accept listen-fd)))
              (thread-start!
                (make-thread
                  (lambda ()
                    ;; Raw handling — avoid library calls that need GC in child thread
                    (guard (exn (#t (guard (e2 (#t #f)) (tcp-close client-fd))))
                      (let* ((buf (make-http-buffer client-fd))
                             (request (http-read-request buf))
                             (response (guard (exn (#t (make-response 500 "Internal Server Error")))
                                         (handler request)))
                             (text (http-format-response
                                     (response-status response)
                                     (response-reason response)
                                     (response-headers response)
                                     (response-body response))))
                        (http-send-all client-fd text)
                        (tcp-close client-fd))))))
              (loop))))))

    ;; Pre-fork concurrent server
    (define %libc (ffi-open #f))
    (define %fork (ffi-fn %libc "fork" '() 'int))
    (define %wait (ffi-fn %libc "wait" '(pointer) 'int))

    (define (http-listen-prefork handler port workers . args)
      (let ((host (if (pair? args) (car args) "0.0.0.0")))
        (let ((listen-fd (tcp-listen host port)))
          (display "Listening on ")
          (display host) (display ":") (display port)
          (display " (") (display workers) (display " workers)")
          (newline)
          (let fork-loop ((i 0) (pids '()))
            (if (= i workers)
                (begin
                  (display "Workers started: ")
                  (display (reverse pids))
                  (newline)
                  (let wait-loop ((n workers))
                    (when (> n 0)
                      (%wait 0)
                      (wait-loop (- n 1)))))
                (let ((pid (%fork)))
                  (cond
                    ((= pid 0)
                     (let loop ()
                       (let ((client-fd (tcp-accept listen-fd)))
                         (handle-client handler client-fd)
                         (loop))))
                    ((> pid 0)
                     (fork-loop (+ i 1) (cons pid pids)))
                    (else
                     (error "fork failed")))))))))

    ;; Fiber server — non-blocking accept loop, one cheap fiber per
    ;; connection, all on a single OS thread and GC heap.

    ;; Interval a fiber parks for (via the reactor's timer heap, not a
    ;; busy loop — see thread-sleep!) between readiness checks on a
    ;; non-blocking fd. Short enough to stay responsive, long enough to
    ;; avoid spinning the CPU while idle.
    (define %poll-interval 0.001)

    (define (fiber-recv fd ptr len)
      (let loop ()
        (let ((ready (poll-read fd 0)))
          (cond
            ((= ready 1) (tcp-recv fd ptr len))
            ((= ready 0) (thread-sleep! %poll-interval) (loop))
            (else (error "poll-read failed" (tcp-last-error)))))))

    (define (fiber-send fd ptr len)
      (let loop ()
        (let ((ready (poll-write fd 0)))
          (cond
            ((= ready 1) (tcp-send fd ptr len))
            ((= ready 0) (thread-sleep! %poll-interval) (loop))
            (else (error "poll-write failed" (tcp-last-error)))))))

    (define (http-listen-fiber handler port . args)
      (let ((host (if (pair? args) (car args) "0.0.0.0")))
        (let ((listen-fd (tcp-listen host port)))
          (set-nonblocking listen-fd)
          (display "Listening on ")
          (display host) (display ":") (display port)
          (display " (fiber)") (newline)
          (let loop ()
            (let ((client-fd (nb-accept listen-fd)))
              (cond
                ((= client-fd -2) (thread-sleep! %poll-interval))
                ((< client-fd 0) (error "tcp-accept failed" (tcp-last-error)))
                (else
                 (set-nonblocking client-fd)
                 (spawn (lambda () (handle-client handler client-fd fiber-recv fiber-send))))))
            (loop)))))))
