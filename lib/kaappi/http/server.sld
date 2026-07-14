(define-library (kaappi http server)
  (import (scheme base) (scheme write)
          (srfi 18) (kaappi fibers) (kaappi ffi) (kaappi http net) (kaappi http parse))
  (export http-listen http-listen-threaded http-listen-prefork http-listen-fiber
          http-listen-parallel)
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
            (loop)))))

    ;; --- Multi-core server (KEP-0002 §9) ---
    ;;
    ;; Spreads serving across N OS threads. Blocks forever, like the other
    ;; http-listen-* servers (shut down by terminating the process).
    ;;
    ;;   (http-listen-parallel handler port)               ; processor-count threads
    ;;   (http-listen-parallel handler port thread-count)
    ;;   (http-listen-parallel handler port thread-count host)
    ;;
    ;; Two paths, chosen at runtime by (reuseport-balances?):
    ;;
    ;;  * Linux -- each thread binds its OWN SO_REUSEPORT socket and runs a
    ;;    full fiber accept loop; the kernel hashes inbound connections across
    ;;    the sockets (measured near-uniform), so the machine serves
    ;;    threads x fibers = cores x thousands-of-connections. No shared accept
    ;;    state, no fd passing.
    ;;
    ;;  * Darwin/BSD -- SO_REUSEPORT does NOT balance there (every connection
    ;;    lands on the last-bound socket -- measured in
    ;;    kaappi-net/research/reuseport-accept-distribution/), so one acceptor
    ;;    thread accepts on a single socket and hands each accepted fd (a plain
    ;;    fixnum, valid process-wide) to a pool of worker threads over a shared
    ;;    channel; each worker fiber-multiplexes its connections just like the
    ;;    Linux path (see %parallel-distributor). Same threads x fibers model,
    ;;    reached with a userspace distributor instead of the kernel. The
    ;;    shared channel is the only cross-thread state and it stays shallow --
    ;;    workers drain it about as fast as one acceptor fills it.

    ;; One fiber accept loop on a fresh listen fd: accept, spawn a fiber per
    ;; connection, forever. `open-listen` is a thunk so each caller (each
    ;; thread on the reuseport path) opens its own socket.
    (define (%fiber-accept-loop handler open-listen)
      (let ((listen-fd (open-listen)))
        (set-nonblocking listen-fd)
        (let loop ()
          (let ((client-fd (nb-accept listen-fd)))
            (cond
              ((= client-fd -2) (thread-sleep! %poll-interval))
              ((< client-fd 0) (error "tcp-accept failed" (tcp-last-error)))
              (else
               (set-nonblocking client-fd)
               (spawn (lambda () (handle-client handler client-fd fiber-recv fiber-send))))))
          (loop))))

    ;; Linux path: N threads, each its own SO_REUSEPORT socket + accept loop.
    ;; The calling thread runs the Nth loop, so all N cores are used.
    (define (%parallel-reuseport handler port host n)
      (let spawn-loop ((i 1))
        (if (< i n)
            (begin
              (thread-start!
                (make-thread
                  (lambda ()
                    (%fiber-accept-loop handler
                      (lambda () (tcp-listen-reuseport host port))))))
              (spawn-loop (+ i 1)))
            (%fiber-accept-loop handler
              (lambda () (tcp-listen-reuseport host port))))))

    ;; Darwin/BSD path: one acceptor thread + N worker threads + a shared fd
    ;; channel (KEP-0002 §9). The acceptor pulls each connection off the single
    ;; listen socket and hands its fd (a fixnum, valid process-wide) to a
    ;; worker; each worker handles one connection to completion, then asks for
    ;; the next. Concurrency is the worker count (one blocking connection per
    ;; worker at a time), not per-worker fiber multiplexing: a secondary
    ;; thread that parks on channel-receive does not run other ready fibers, so
    ;; the reliable shape here is a blocking receive + a blocking handler
    ;; rather than spawned fibers. The shared channel carries only fds and it
    ;; stays shallow -- workers drain it about as fast as one acceptor fills
    ;; it. This is the correctness fallback for a platform whose kernel refuses
    ;; to balance SO_REUSEPORT; the kernel-balanced Linux path above keeps the
    ;; full threads x fibers model.
    (define (%parallel-distributor handler port host n)
      (let ((fds (make-channel)))
        (let spawn-loop ((i 0))
          (when (< i n)
            (thread-start!
              (make-thread
                (lambda ()
                  ;; Poll the fd channel (zero timeout) rather than block on
                  ;; it: a fiber that blocks in channel-receive freezes its
                  ;; thread, but thread-sleep! yields to sibling fibers, so
                  ;; polling + sleeping keeps every spawned connection handler
                  ;; making progress while still picking up new fds. #f = empty
                  ;; (fds are fixnums), eof = channel closed.
                  (let loop ()
                    (let ((fd (channel-receive fds 0 #f)))
                      (cond
                        ((eof-object? fd) #f)
                        ((not fd) (thread-sleep! %poll-interval) (loop))
                        (else
                         (set-nonblocking fd)
                         (spawn (lambda () (handle-client handler fd fiber-recv fiber-send)))
                         (loop))))))))
            (spawn-loop (+ i 1))))
        ;; Acceptor on the calling thread: blocking accept, hand fd to a
        ;; worker, forever.
        (let ((listen-fd (tcp-listen host port)))
          (let loop ()
            (channel-send fds (tcp-accept listen-fd))
            (loop)))))

    (define (http-listen-parallel handler port . args)
      (let ((n (if (pair? args) (car args) (processor-count)))
            (host (if (and (pair? args) (pair? (cdr args))) (cadr args) "0.0.0.0")))
        (when (or (not (integer? n)) (not (exact? n)) (< n 1))
          (error "http-listen-parallel: thread-count must be a positive integer" n))
        (display "Listening on ")
        (display host) (display ":") (display port)
        (display " (parallel, ") (display n)
        (display (if (reuseport-balances?) " x reuseport)" " x acceptor)"))
        (newline)
        (if (reuseport-balances?)
            (%parallel-reuseport handler port host n)
            (%parallel-distributor handler port host n))))))
