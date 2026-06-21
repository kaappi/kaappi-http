UNAME := $(shell uname)
ifeq ($(UNAME), Darwin)
  DYLIB_EXT := dylib
  CFLAGS_SHARED := -dynamiclib
else
  DYLIB_EXT := so
  CFLAGS_SHARED := -shared -fPIC
endif

CC ?= cc
CFLAGS := -O2 -Wall -Wextra

SSL_CFLAGS := $(shell pkg-config --cflags openssl 2>/dev/null)
SSL_LDFLAGS := $(shell pkg-config --libs openssl 2>/dev/null)

.PHONY: all clean

all: libkaappi_http.$(DYLIB_EXT)

libkaappi_http.$(DYLIB_EXT): csrc/kaappi_http_net.c
	$(CC) $(CFLAGS) $(SSL_CFLAGS) $(CFLAGS_SHARED) -o $@ $< $(SSL_LDFLAGS)

clean:
	rm -f libkaappi_http.dylib libkaappi_http.so
