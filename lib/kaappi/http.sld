(define-library (kaappi http)
  (import (kaappi http parse)
          (kaappi http client)
          (kaappi http server))
  (export
    ;; Client
    http-request http-get http-post http-put http-delete http-head
    ;; Server
    http-listen http-listen-threaded http-listen-prefork
    ;; Request accessors
    make-http-request http-request?
    request-method request-path request-query request-version
    request-headers request-body request-header request-query-params
    ;; Response
    make-response http-response?
    response-status response-reason response-headers response-body
    response-header
    ;; URL utilities
    parse-url parse-query-string))
