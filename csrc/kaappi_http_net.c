#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>

static int last_errno = 0;

/* -----------------------------------------------------------------------
   Client: connect to host:port
   (string, int, int) -> int
   ----------------------------------------------------------------------- */
int khttp_tcp_connect(const char *host, int port, int timeout_ms) {
    struct addrinfo hints, *res, *rp;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;

    char port_str[8];
    snprintf(port_str, sizeof(port_str), "%d", port);

    int rc = getaddrinfo(host, port_str, &hints, &res);
    if (rc != 0) { last_errno = rc; return -1; }

    int fd = -1;
    for (rp = res; rp != NULL; rp = rp->ai_next) {
        fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (fd < 0) continue;
        if (timeout_ms > 0) {
            int flags = fcntl(fd, F_GETFL, 0);
            fcntl(fd, F_SETFL, flags | O_NONBLOCK);
            rc = connect(fd, rp->ai_addr, rp->ai_addrlen);
            if (rc < 0 && errno == EINPROGRESS) {
                struct pollfd pfd = { .fd = fd, .events = POLLOUT };
                rc = poll(&pfd, 1, timeout_ms);
                if (rc <= 0) { close(fd); fd = -1; continue; }
                int err = 0; socklen_t len = sizeof(err);
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len);
                if (err) { close(fd); fd = -1; last_errno = err; continue; }
            } else if (rc < 0) { last_errno = errno; close(fd); fd = -1; continue; }
            fcntl(fd, F_SETFL, flags);
        } else {
            if (connect(fd, rp->ai_addr, rp->ai_addrlen) < 0) {
                last_errno = errno; close(fd); fd = -1; continue;
            }
        }
        break;
    }
    freeaddrinfo(res);
    if (fd < 0 && last_errno == 0) last_errno = ECONNREFUSED;
    return fd;
}

/* -----------------------------------------------------------------------
   Server: socket + bind + listen in one call
   (string, int, int) -> int   — returns listen fd or -1
   ----------------------------------------------------------------------- */
int khttp_tcp_listen(const char *host, int port, int backlog) {
    struct addrinfo hints, *res;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_PASSIVE;

    char port_str[8];
    snprintf(port_str, sizeof(port_str), "%d", port);

    int rc = getaddrinfo(host, port_str, &hints, &res);
    if (rc != 0) { last_errno = rc; return -1; }

    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) { last_errno = errno; freeaddrinfo(res); return -1; }

    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    if (bind(fd, res->ai_addr, res->ai_addrlen) < 0) {
        last_errno = errno; close(fd); freeaddrinfo(res); return -1;
    }
    freeaddrinfo(res);

    if (listen(fd, backlog) < 0) {
        last_errno = errno; close(fd); return -1;
    }
    return fd;
}

/* -----------------------------------------------------------------------
   Server: accept one connection
   (int) -> int   — returns client fd or -1
   ----------------------------------------------------------------------- */
int khttp_tcp_accept(int listen_fd) {
    int fd = accept(listen_fd, NULL, NULL);
    if (fd < 0) { last_errno = errno; return -1; }
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    return fd;
}

/* -----------------------------------------------------------------------
   Send / Recv / Close / Error  (same signatures as kaappi-redis)
   ----------------------------------------------------------------------- */

/* (pointer, pointer, long) -> int */
int khttp_tcp_send(void *buf, void *fd_ptr, long len) {
    int fd = (int)(intptr_t)fd_ptr;
    ssize_t n = send(fd, buf, (size_t)len, 0);
    if (n < 0) { last_errno = errno; return -1; }
    return (int)n;
}

/* (pointer, pointer, long) -> int */
int khttp_tcp_recv(void *buf, void *fd_ptr, long len) {
    int fd = (int)(intptr_t)fd_ptr;
    ssize_t n = recv(fd, buf, (size_t)len, 0);
    if (n < 0) { last_errno = errno; return -1; }
    return (int)n;
}

/* (int) -> int */
int khttp_tcp_close(int fd) {
    int rc = close(fd);
    if (rc < 0) last_errno = errno;
    return rc;
}

/* () -> int */
int khttp_last_error(void) {
    return last_errno;
}
