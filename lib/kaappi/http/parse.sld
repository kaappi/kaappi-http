(define-library (kaappi http parse)
  (import (scheme base) (scheme cxr) (scheme char) (kaappi ffi) (kaappi http net))
  (export ;; Records
          make-http-request http-request?
          request-method request-path request-query request-version
          request-headers request-body request-header request-query-params
          make-response http-response?
          response-status response-reason response-headers response-body
          response-header
          ;; Parsers
          make-http-buffer http-read-request http-read-response
          ;; Formatters
          http-format-request http-format-response
          ;; URL
          parse-url parse-query-string
          ;; Send helper
          http-send-all)
  (begin

    ;; --- Request record ---

    (define-record-type <http-request>
      (%make-http-request method path query version headers body)
      http-request?
      (method  request-method)
      (path    request-path)
      (query   request-query)
      (version request-version)
      (headers request-headers)
      (body    request-body))

    (define (make-http-request method path query version headers body)
      (%make-http-request method path query version headers body))

    (define (request-header req name)
      (let ((pair (assoc name (request-headers req))))
        (if pair (cdr pair) #f)))

    (define (request-query-params req)
      (let ((q (request-query req)))
        (if (or (not q) (equal? q "")) '() (parse-query-string q))))

    ;; --- Response record ---

    (define-record-type <http-response>
      (%make-http-response status reason headers body)
      http-response?
      (status  response-status)
      (reason  response-reason)
      (headers response-headers)
      (body    response-body))

    (define (make-response status body . args)
      (let ((headers (if (pair? args) (car args) '())))
        (%make-http-response status (status->reason status) headers body)))

    (define (response-header resp name)
      (let ((pair (assoc name (response-headers resp))))
        (if pair (cdr pair) #f)))

    (define (status->reason code)
      (cond ((= code 200) "OK")
            ((= code 201) "Created")
            ((= code 204) "No Content")
            ((= code 301) "Moved Permanently")
            ((= code 302) "Found")
            ((= code 304) "Not Modified")
            ((= code 400) "Bad Request")
            ((= code 401) "Unauthorized")
            ((= code 403) "Forbidden")
            ((= code 404) "Not Found")
            ((= code 405) "Method Not Allowed")
            ((= code 500) "Internal Server Error")
            ((= code 502) "Bad Gateway")
            ((= code 503) "Service Unavailable")
            (else "Unknown")))

    ;; --- Buffered reader ---

    (define *buf-size* 8192)

    (define-record-type <http-buffer>
      (%make-http-buffer bv pos end handle recv-fn)
      http-buffer?
      (bv      buf-bv)
      (pos     buf-pos set-buf-pos!)
      (end     buf-end set-buf-end!)
      (handle  buf-handle)
      (recv-fn buf-recv-fn))

    ;; `handle` is either a raw socket fd (a fixnum, read via recv-fn +
    ;; ffi-bytevector-ptr) or a reactor-integrated Kaappi port (#1478). A port
    ;; does its own buffering, so buf-read-byte!/buf-read-bytes! read straight
    ;; from it and the software buffer below stays empty -- only the raw-fd
    ;; path needs the *buf-size* scratch bytevector.
    (define (make-http-buffer handle . args)
      (let ((recv-fn (if (pair? args) (car args) tcp-recv))
            (bv (if (port? handle) (make-bytevector 0 0) (make-bytevector *buf-size* 0))))
        (%make-http-buffer bv 0 0 handle recv-fn)))

    (define (buf-available buf)
      (- (buf-end buf) (buf-pos buf)))

    (define (buf-refill! buf)
      (let* ((bv  (buf-bv buf))
             (pos (buf-pos buf))
             (end (buf-end buf))
             (rem (- end pos))
             (cap (bytevector-length bv)))
        (when (> pos 0)
          (when (> rem 0) (bytevector-copy! bv 0 bv pos end))
          (set-buf-pos! buf 0)
          (set-buf-end! buf rem))
        (let* ((rem2 (buf-end buf))
               (space (- cap rem2)))
          (when (<= space 0) (error "HTTP buffer full"))
          (let* ((base (ffi-bytevector-ptr bv))
                 (ptr  (+ base rem2))
                 (n    ((buf-recv-fn buf) (buf-handle buf) ptr space)))
            (when (= n 0) (error "Connection closed"))
            (set-buf-end! buf (+ rem2 n))))))

    (define (buf-read-byte! buf)
      (let ((handle (buf-handle buf)))
        (if (port? handle)
            ;; Reactor-integrated socket port (#1478): read-u8 parks the
            ;; calling fiber on the reactor until a byte is available instead
            ;; of a poll-then-sleep spin; the port buffers a chunk so
            ;; subsequent per-byte reads are served without a syscall.
            (let ((b (read-u8 handle)))
              (if (eof-object? b) (error "Connection closed") b))
            (begin
              (when (= (buf-available buf) 0) (buf-refill! buf))
              (let ((b (bytevector-u8-ref (buf-bv buf) (buf-pos buf))))
                (set-buf-pos! buf (+ (buf-pos buf) 1))
                b)))))

    (define (buf-read-bytes! buf n)
      (let ((handle (buf-handle buf)))
        (if (port? handle)
            ;; Port path (#1478): read-bytevector! fills exactly n bytes,
            ;; parking the fiber on the reactor between chunks. A short read
            ;; (eof, or fewer than n) means the peer closed mid-body.
            (let ((result (make-bytevector n 0)))
              (if (= n 0)
                  result
                  (let ((r (read-bytevector! result handle 0 n)))
                    (if (and (not (eof-object? r)) (= r n))
                        result
                        (error "Connection closed")))))
            (let ((result (make-bytevector n 0)))
              (let loop ((offset 0) (remaining n))
                (if (= remaining 0)
                    result
                    (let ((avail (buf-available buf)))
                      (if (= avail 0)
                          (begin (buf-refill! buf) (loop offset remaining))
                          (let ((take (min avail remaining)))
                            (bytevector-copy! result offset
                                              (buf-bv buf) (buf-pos buf)
                                              (+ (buf-pos buf) take))
                            (set-buf-pos! buf (+ (buf-pos buf) take))
                            (loop (+ offset take) (- remaining take)))))))))))

    (define (buf-read-line! buf)
      (let ((out (open-output-string)))
        (let loop ()
          (let ((b (buf-read-byte! buf)))
            (cond
              ((= b 13)
               (let ((b2 (buf-read-byte! buf)))
                 (if (= b2 10)
                     (get-output-string out)
                     (begin (write-char (integer->char b) out)
                            (write-char (integer->char b2) out)
                            (loop)))))
              (else (write-char (integer->char b) out) (loop)))))))

    ;; --- Header parsing ---

    (define (read-headers buf)
      (let loop ((acc '()))
        (let ((line (buf-read-line! buf)))
          (if (equal? line "")
              (reverse acc)
              (let ((colon (string-find line #\:)))
                (if colon
                    (loop (cons (cons (string-downcase (substring line 0 colon))
                                      (string-trim (substring line (+ colon 1)
                                                              (string-length line))))
                                acc))
                    (loop acc)))))))

    (define (string-find s ch)
      (let ((len (string-length s)))
        (let loop ((i 0))
          (cond ((= i len) #f)
                ((char=? (string-ref s i) ch) i)
                (else (loop (+ i 1)))))))

    (define (string-trim s)
      (let ((len (string-length s)))
        (let loop ((i 0))
          (cond ((= i len) "")
                ((char=? (string-ref s i) #\space) (loop (+ i 1)))
                (else (substring s i len))))))

    (define (string-downcase s)
      (let* ((len (string-length s))
             (out (make-string len)))
        (let loop ((i 0))
          (when (< i len)
            (string-set! out i (char-downcase (string-ref s i)))
            (loop (+ i 1))))
        out))

    (define (header-value headers name)
      (let ((pair (assoc name headers)))
        (if pair (cdr pair) #f)))

    ;; --- Read body ---

    (define (read-body buf headers)
      (let ((cl (header-value headers "content-length")))
        (if cl
            (let ((len (string->number cl)))
              (if (and len (> len 0))
                  (utf8->string (buf-read-bytes! buf len))
                  ""))
            "")))

    ;; --- Request parser (for server) ---

    (define (http-read-request buf)
      (let* ((request-line (buf-read-line! buf))
             (parts (split-spaces request-line)))
        (if (< (length parts) 3)
            (error "Malformed HTTP request" request-line)
            (let* ((method  (car parts))
                   (uri     (cadr parts))
                   (version (caddr parts))
                   (qpos    (string-find uri #\?))
                   (path    (if qpos (substring uri 0 qpos) uri))
                   (query   (if qpos (substring uri (+ qpos 1) (string-length uri)) ""))
                   (headers (read-headers buf))
                   (body    (read-body buf headers)))
              (%make-http-request method path query version headers body)))))

    ;; --- Response parser (for client) ---

    (define (http-read-response buf)
      (let* ((status-line (buf-read-line! buf))
             (sp1 (string-find status-line #\space)))
        (if (not sp1)
            (error "Malformed HTTP response" status-line)
            (let* ((rest (substring status-line (+ sp1 1) (string-length status-line)))
                   (sp2 (string-find rest #\space))
                   (status-str (if sp2 (substring rest 0 sp2) rest))
                   (reason (if sp2 (substring rest (+ sp2 1) (string-length rest)) ""))
                   (status (or (string->number status-str) 0))
                   (headers (read-headers buf))
                   (body (read-body buf headers)))
              (%make-http-response status reason headers body)))))

    ;; --- Formatters ---

    (define (http-format-request method path host headers body)
      (let ((out (open-output-string)))
        (display method out) (display " " out) (display path out)
        (display " HTTP/1.1\r\n" out)
        (display "Host: " out) (display host out) (display "\r\n" out)
        (display "Connection: close\r\n" out)
        (when (and body (> (string-length body) 0))
          (display "Content-Length: " out)
          (display (bytevector-length (string->utf8 body)) out)
          (display "\r\n" out))
        (for-each
          (lambda (h)
            (display (car h) out) (display ": " out)
            (display (cdr h) out) (display "\r\n" out))
          headers)
        (display "\r\n" out)
        (when body (display body out))
        (get-output-string out)))

    (define (http-format-response status reason headers body)
      (let ((out (open-output-string))
            (body-bv (if body (string->utf8 body) (make-bytevector 0))))
        (display "HTTP/1.1 " out)
        (display status out) (display " " out) (display reason out)
        (display "\r\n" out)
        (display "Connection: close\r\n" out)
        (display "Content-Length: " out)
        (display (bytevector-length body-bv) out)
        (display "\r\n" out)
        (display "Server: kaappi-http\r\n" out)
        (for-each
          (lambda (h)
            (display (car h) out) (display ": " out)
            (display (cdr h) out) (display "\r\n" out))
          headers)
        (display "\r\n" out)
        (when body (display body out))
        (get-output-string out)))

    ;; --- URL parser ---

    (define (parse-url url)
      (let* ((https? (and (>= (string-length url) 8)
                          (equal? (substring url 0 8) "https://")))
             (http?  (and (not https?)
                          (>= (string-length url) 7)
                          (equal? (substring url 0 7) "http://")))
             (default-port (if https? 443 80))
             (after-scheme
               (cond (https? (substring url 8 (string-length url)))
                     (http?  (substring url 7 (string-length url)))
                     (else   url)))
             (slash (string-find after-scheme #\/))
             (host-port (if slash
                            (substring after-scheme 0 slash)
                            after-scheme))
             (path (if slash
                       (substring after-scheme slash (string-length after-scheme))
                       "/"))
             (colon (string-find host-port #\:))
             (host (if colon (substring host-port 0 colon) host-port))
             (port (if colon
                       (or (string->number
                             (substring host-port (+ colon 1)
                                        (string-length host-port)))
                           default-port)
                       default-port)))
        (values (if https? "https" "http") host port path)))

    ;; --- Query string parser ---

    (define (parse-query-string qs)
      (if (or (not qs) (equal? qs ""))
          '()
          (map (lambda (pair-str)
                 (let ((eq (string-find pair-str #\=)))
                   (if eq
                       (cons (percent-decode (substring pair-str 0 eq))
                             (percent-decode (substring pair-str (+ eq 1)
                                                       (string-length pair-str))))
                       (cons (percent-decode pair-str) ""))))
               (string-split qs #\&))))

    (define (percent-decode s)
      (let ((len (string-length s))
            (out (open-output-string)))
        (let loop ((i 0))
          (cond
            ((= i len) (get-output-string out))
            ((and (char=? (string-ref s i) #\%)
                  (< (+ i 2) len))
             (let ((hi (hex-digit (string-ref s (+ i 1))))
                   (lo (hex-digit (string-ref s (+ i 2)))))
               (if (and hi lo)
                   (begin (write-char (integer->char (+ (* hi 16) lo)) out)
                          (loop (+ i 3)))
                   (begin (write-char #\% out) (loop (+ i 1))))))
            ((char=? (string-ref s i) #\+)
             (write-char #\space out) (loop (+ i 1)))
            (else (write-char (string-ref s i) out) (loop (+ i 1)))))))

    (define (hex-digit ch)
      (cond ((and (char>=? ch #\0) (char<=? ch #\9))
             (- (char->integer ch) (char->integer #\0)))
            ((and (char>=? ch #\a) (char<=? ch #\f))
             (+ 10 (- (char->integer ch) (char->integer #\a))))
            ((and (char>=? ch #\A) (char<=? ch #\F))
             (+ 10 (- (char->integer ch) (char->integer #\A))))
            (else #f)))

    ;; --- Utilities ---

    (define (split-spaces s)
      (let ((len (string-length s)))
        (let loop ((i 0) (start 0) (acc '()))
          (cond
            ((= i len)
             (reverse (if (> i start)
                          (cons (substring s start i) acc)
                          acc)))
            ((char=? (string-ref s i) #\space)
             (if (> i start)
                 (loop (+ i 1) (+ i 1) (cons (substring s start i) acc))
                 (loop (+ i 1) (+ i 1) acc)))
            (else (loop (+ i 1) start acc))))))

    (define (string-split s delim)
      (let ((len (string-length s)))
        (let loop ((i 0) (start 0) (acc '()))
          (cond
            ((= i len)
             (reverse (cons (substring s start i) acc)))
            ((char=? (string-ref s i) delim)
             (loop (+ i 1) (+ i 1) (cons (substring s start i) acc)))
            (else (loop (+ i 1) start acc))))))

    ;; --- Send helper ---

    (define (http-send-all handle str . args)
      (let ((send-fn (if (pair? args) (car args) tcp-send)))
        (if (port? handle)
            ;; Port path (#1478): write-bytevector buffers into the port and
            ;; portWriteBytes drains it through the reactor, parking the fiber
            ;; on EAGAIN instead of spinning; flush guarantees everything
            ;; leaves before we return (the caller closes the port next).
            (begin
              (write-bytevector (string->utf8 str) handle)
              (flush-output-port handle))
            (let* ((bv (string->utf8 str))
                   (len (bytevector-length bv)))
              (let loop ((offset 0) (remaining len))
                (when (> remaining 0)
                  (let* ((ptr (+ (ffi-bytevector-ptr bv) offset))
                         (n   (send-fn handle ptr remaining)))
                    (loop (+ offset n) (- remaining n)))))))))))
