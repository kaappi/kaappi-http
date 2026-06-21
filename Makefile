UNAME := $(shell uname)
ifeq ($(UNAME), Darwin)
  DYLIB_EXT := dylib
  CFLAGS_SHARED := -dynamiclib
else
  DYLIB_EXT := so
  CFLAGS_SHARED := -shared -fPIC
endif

CC ?= cc
CFLAGS := -O2 -Wall -Wextra -pedantic

.PHONY: all clean

all: libkaappi_http.$(DYLIB_EXT)

libkaappi_http.$(DYLIB_EXT): csrc/kaappi_http_net.c
	$(CC) $(CFLAGS) $(CFLAGS_SHARED) -o $@ $<

clean:
	rm -f libkaappi_http.dylib libkaappi_http.so
