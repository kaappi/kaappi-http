# Server model benchmarks (KEP-0001 Phase 7)

Compares the four `kaappi-http` server models (`http-listen`,
`http-listen-threaded`, `http-listen-prefork`, `http-listen-fiber`) under
concurrent load. Written for
[kaappi/kaappi#1445](https://github.com/kaappi/kaappi/issues/1445) — no
`wrk`/`hey`/`ab` was available in that environment, hence the small Python
client here instead of a standard load-gen tool.

`http-listen-threaded` currently hangs on every request — see
[kaappi/kaappi#1479](https://github.com/kaappi/kaappi/issues/1479).

## Usage

```sh
# terminal 1: start a server (model = sequential | threaded | prefork | fiber)
DYLD_LIBRARY_PATH=..:../../kaappi-net kaappi \
  --lib-path ../kaappi-net/lib --lib-path ../lib benchmarks/bench_server_app.scm fiber
# (Linux: use LD_LIBRARY_PATH instead of DYLD_LIBRARY_PATH)

# terminal 2: run the load generator against it
python3 benchmarks/http_load_gen.py <port=19999> <concurrency> [total_requests]
# e.g. 1000 concurrent connections, 5000 requests total (default: concurrency * 5)
python3 benchmarks/http_load_gen.py 19999 1000 5000
```

Reports connections/sec and p50/p99/max latency for the run.
