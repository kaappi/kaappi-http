# kaappi-http

HTTP client and server library for [Kaappi Scheme](https://github.com/kaappi/kaappi).

Pure Scheme HTTP/1.1 protocol with a thin C TCP helper. No external dependencies
beyond libc.

## Build

```bash
make                    # builds libkaappi_http.dylib (macOS) or .so (Linux)
```

## Usage

```bash
export DYLD_LIBRARY_PATH=/path/to/kaappi-http   # macOS
kaappi --lib-path /path/to/kaappi-http/lib your-script.scm
```

### HTTP Client

```scheme
(import (kaappi http))

;; GET request
(let ((resp (http-get "http://example.com/api/users")))
  (display (response-status resp))   ; => 200
  (display (response-body resp)))    ; => "..."

;; POST with headers and body
(let ((resp (http-post "http://example.com/api/data"
              '(("Content-Type" . "application/json"))
              "{\"name\": \"Alice\"}")))
  (display (response-status resp)))

;; Also: http-put, http-delete, http-head, http-request
```

### HTTP Server

```scheme
(import (kaappi http))

(define (handler request)
  (cond
    ((equal? (request-path request) "/")
     (make-response 200 "Hello, World!"))

    ((equal? (request-path request) "/api/time")
     (make-response 200 (number->string (current-second))
       '(("Content-Type" . "application/json"))))

    (else
     (make-response 404 "Not Found"))))

(http-listen handler 8080)
;; Listening on 0.0.0.0:8080 ...
```

## API

### Client

| Procedure | Description |
|---|---|
| `(http-get url [headers])` | GET request |
| `(http-post url [headers] [body])` | POST request |
| `(http-put url [headers] [body])` | PUT request |
| `(http-delete url [headers])` | DELETE request |
| `(http-head url [headers])` | HEAD request |
| `(http-request method url headers body)` | Generic request |

### Server

| Procedure | Description |
|---|---|
| `(http-listen handler port [host])` | Start server (blocking, one connection at a time) |
| `(http-listen-threaded handler port [host])` | One SRFI-18 OS thread per connection |
| `(http-listen-prefork handler port workers [host])` | `workers` pre-forked processes |
| `(http-listen-fiber handler port [host])` | Non-blocking accept loop, one fiber per connection — thousands of connections on a single OS thread |
| `(make-response status body [headers])` | Create response |

### Request Accessors

| Procedure | Returns |
|---|---|
| `(request-method req)` | `"GET"`, `"POST"`, etc. |
| `(request-path req)` | `"/api/users"` |
| `(request-query req)` | `"page=1&limit=10"` or `""` |
| `(request-query-params req)` | `(("page" . "1") ("limit" . "10"))` |
| `(request-headers req)` | alist of headers |
| `(request-header req name)` | header value or `#f` |
| `(request-body req)` | body string |

### Response Accessors

| Procedure | Returns |
|---|---|
| `(response-status resp)` | `200`, `404`, etc. |
| `(response-reason resp)` | `"OK"`, `"Not Found"`, etc. |
| `(response-headers resp)` | alist of headers |
| `(response-header resp name)` | header value or `#f` |
| `(response-body resp)` | body string |

### URL Utilities

| Procedure | Description |
|---|---|
| `(parse-url url)` | Returns `(values host port path)` |
| `(parse-query-string qs)` | Returns alist with percent-decoding |

## Scope

**v1 supports:**
- HTTP/1.1 with `Connection: close`
- Content-Length based bodies
- `http://` URLs (no HTTPS)
- Sequential, threaded, pre-forked, or fiber-based concurrency (see Server API)
- URL query string parsing with percent-decoding

## Tests

```bash
# Offline parse tests (no network)
kaappi --lib-path lib tests/test-parse.scm

# Server integration tests (starts server, curls it)
bash tests/test-server.sh

# Fiber server concurrency test (slow client must not block a fast one)
bash tests/test-fiber-server.sh
```

## Requirements

- [Kaappi](https://github.com/kaappi/kaappi) with `(kaappi ffi)` support
- C compiler

## License

MIT
