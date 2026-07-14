(define-library (kaappi http net)
  (import (kaappi net))
  (export tcp-connect tcp-listen tcp-listen-reuseport reuseport-balances? tcp-accept
          tcp-send tcp-recv tcp-close tcp-last-error
          tls-connect tls-send tls-recv tls-close
          set-nonblocking poll-read poll-write nb-accept))
