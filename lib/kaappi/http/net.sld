(define-library (kaappi http net)
  (import (scheme base) (kaappi ffi))
  (export tcp-connect tcp-listen tcp-accept
          tcp-send tcp-recv tcp-close tcp-last-error)
  (begin

    (define %lib (ffi-open "libkaappi_http"))

    (define %connect  (ffi-fn %lib "khttp_tcp_connect" '(string int int) 'int))
    (define %listen   (ffi-fn %lib "khttp_tcp_listen" '(string int int) 'int))
    (define %accept   (ffi-fn %lib "khttp_tcp_accept" '(int) 'int))
    (define %send     (ffi-fn %lib "khttp_tcp_send" '(pointer pointer long) 'int))
    (define %recv     (ffi-fn %lib "khttp_tcp_recv" '(pointer pointer long) 'int))
    (define %close    (ffi-fn %lib "khttp_tcp_close" '(int) 'int))
    (define %last-error (ffi-fn %lib "khttp_last_error" '() 'int))

    (define (tcp-connect host port . args)
      (let ((timeout (if (pair? args) (car args) 5000)))
        (let ((fd (%connect host port timeout)))
          (if (< fd 0)
              (error "tcp-connect failed" host port (%last-error))
              fd))))

    (define (tcp-listen host port . args)
      (let ((backlog (if (pair? args) (car args) 128)))
        (let ((fd (%listen host port backlog)))
          (if (< fd 0)
              (error "tcp-listen failed" host port (%last-error))
              fd))))

    (define (tcp-accept listen-fd)
      (let ((fd (%accept listen-fd)))
        (if (< fd 0)
            (error "tcp-accept failed" (%last-error))
            fd)))

    (define (tcp-send fd buf len)
      (let ((n (%send buf fd len)))
        (if (< n 0) (error "tcp-send failed" (%last-error)) n)))

    (define (tcp-recv fd buf len)
      (let ((n (%recv buf fd len)))
        (if (< n 0) (error "tcp-recv failed" (%last-error)) n)))

    (define (tcp-close fd)
      (let ((rc (%close fd)))
        (if (< rc 0) (error "tcp-close failed" (%last-error)) rc)))

    (define (tcp-last-error) (%last-error))))
