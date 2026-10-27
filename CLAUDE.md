# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

A client library for Gopher, Gopher+, gophers, Gemini, Titan, Spartan, Nex,
Guppy (UDP) and Finger, which will become the engine of a native macOS browser.
It also builds a clingon CLI. SBCL, ocicl, FiveAM. Client only. The servers
in `test/servers.lisp` are fixtures.

## Build & test

```
ocicl install                  # dependencies (ocicl/ is gitignored)
make test                      # hermetic suite
GOPHER_LIVE_TESTS=1 make test  # plus real servers
make build                     # bin/gopher via program-op
make certs                     # regenerate test/fixtures/*.pem
make clean                     # fasls + ASDF cache for this tree
```

To run one test from a REPL, `(asdf:load-system :gopher/test)` and then
`(fiveam:run! 'gopher/test::redirects)`, or name a suite such as
`'gopher/test::gemini`. Batch runs go through `gopher/test:run-tests`, which
returns the status. ASDF's test-op signals on failure.

Changing a struct's slots needs `make clean` first.

## Architecture

Serial load order (see `gopher.asd`):

```
package → conditions → url → encoding → transport → tofu → document → registry
        → gemtext → gopher → gopher-plus → gemini → titan → spartan → nex
        → guppy → finger → client → render          (cli is its own system)
```

- `registry.lisp`: `define-scheme-handler` maps schemes to
  `(lambda (url request) → response)`. `fetch` (`client.lisp`) only looks
  handlers up, follows same-scheme redirects, and clears `:query`/`:data` after
  the first hop. Adding a protocol is one new file plus a line in the `.asd`.
- `transport.lisp`: the `request` struct (all fetch options), connections,
  `read-body` (max-size, progress, sink, cancellation), and error translation.
  The translation uses **HANDLER-BIND, not HANDLER-CASE**, so that
  `certificate-mismatch` restarts survive to the caller. For the same reason,
  `open-connection` cleans up with unwind-protect, not a handler.
- TLS uses `:unwrap-stream-p nil` so that usocket's read timeout applies.
  `ssl-read-chunk` does one `SSL_read`, so an abrupt close (no close_notify,
  common on Gemini) keeps every byte. cl+ssl reports a Lisp-BIO IO-TIMEOUT as
  an SSL error, and the translator maps it back to `timeout-error`.
- cl+ssl's `certificate-not-after-time` and its subject-name helper call
  `ASN1_STRING_data`, which OpenSSL 4 removed. `x509-validity` and
  `x509-subject-common-names` call OpenSSL directly.
- Server "no" answers are `response`s with a status keyword (`document.lisp`
  `status-category`), never conditions.
- Gopher paths are opaque: `?` and `#` are part of the selector, and `%09`
  separates the search and Gopher+ fields.

## Tests

Each protocol has a fixture handler (a function of one binary stream) run by
`start-server` / `with-server`, with `:tls t` and `:request-client-cert t`
available. The Guppy fixture is a real UDP server that can drop or reorder
packets. CLI tests call `clingon:run` with `gopher/cli:*exit-hook*` rebound,
so the image doesn't quit.
