# gopher

A Common Lisp client library for Gopher and the small-web protocols around it.
It is meant to be the engine of a native macOS browser, so every protocol comes
back in the same document model, and the UI renders one thing.

| Scheme       | Protocol                              | Transport            |
|--------------|---------------------------------------|----------------------|
| `gopher://`  | Gopher (RFC 1436, RFC 4266 URLs), Gopher+ | TCP, optional TLS |
| `gophers://` | Gopher over TLS                       | TLS                  |
| `gemini://`  | Gemini                                | TLS (TOFU)           |
| `titan://`   | Titan uploads                         | TLS (TOFU)           |
| `spartan://` | Spartan (incl. uploads, `=:` prompts) | TCP                  |
| `nex://`     | Nex                                   | TCP                  |
| `guppy://`   | Guppy v0.4                            | UDP                  |
| `finger://`  | Finger (RFC 1288)                     | TCP                  |

SBCL, dependencies via [ocicl](https://github.com/ocicl/ocicl), tests with FiveAM.
TLS uses cl+ssl, so OpenSSL must be installed (Homebrew's is fine).

## Build and test

```
ocicl install                  # restore dependencies into ./ocicl
make test                      # hermetic suite: in-process servers for every protocol
GOPHER_LIVE_TESTS=1 make test  # also talk to real servers
make build                     # bin/gopher
```

## Using the library

```lisp
(asdf:load-system :gopher)

(defvar *r* (gopher:fetch "gemini://geminiprotocol.net/"))
(gopher:response-status *r*)     ; => :SUCCESS
(gopher:response-mime-type *r*)  ; => "text/gemini"
(gopher:response-trust *r*)      ; => :NEW  (certificate recorded, trust on first use)

(let ((doc (gopher:response-document *r*)))
  (loop for line across (gopher:document-lines doc)
        do (format t "~A ~A~%" (gopher:line-kind line) (gopher:line-text line))))

(gopher:fetch "gopher://gopher.floodgap.com/7/v2/vs" :query "lisp")   ; Gopher search
(gopher:fetch "floodgap.com")                                        ; scheme defaults to gopher
(gopher:upload "gemini://example.org/wiki/page" "new text" :token "secret")  ; Titan
(gopher:gopher-attributes "gopher://example.org/0/file")             ; Gopher+ records
```

`fetch` keywords: `:timeout`, `:max-size`, `:tls` (`:never`/`:try`/`:require`
for `gopher://`), `:verify` (`:tofu`, `:none`, or a predicate),
`:known-hosts`, `:client-certificate` / `:client-key`, `:on-progress`,
`:handle` (cancellation), `:sink` (stream the body to a binary stream), `:query`,
`:data`, `:mime-type`, `:token`, `:gopher-plus`, `:follow-redirects`,
`:max-redirects`. See its docstring.

### Responses and statuses

What the server said is a `response`, not a condition: input wanted, not found,
a client certificate required. `response-status` is a keyword (`:success`,
`:input`, `:sensitive-input`, `:redirect`, `:not-found`,
`:client-certificate-required` ...). `response-category` reduces it to
`:success :input :redirect :temporary-failure :permanent-failure
:client-certificate`, and a browser branches on that.

Redirects within a scheme are followed, and `response-redirects` records the
chain. A redirect to another scheme (gemini to https, a Gopher `h` item to
the web, a Gopher telnet item) comes back as a `:redirect` response for the
caller to hand off.

Conditions are signalled only when there is no usable reply. All of them are
under `small-web-error`: `connection-error`, `timeout-error`, `tls-error`,
`certificate-mismatch`, `protocol-error`, `response-too-large`,
`redirect-error`, `request-cancelled`, `unsupported-scheme`, `url-parse-error`.

### The document model

`response-document` parses the body into a `document` holding a vector of
`document-line`s. Line kinds are `:text`, `:link`, `:input-prompt`, `:heading`
(levels 1–3), `:list-item`, `:quote`, `:preformatted` (a whole block, with
alt text) and `:error`. Links carry an absolute URL. Gopher menu items also
carry `line-item-type`, `line-item-kind` (`:menu :text :search :image :binary
:telnet ...`) and their raw host/port/selector. Plain text becomes a single
`:preformatted` block.

### Trust on first use

The first certificate seen for a host:port is recorded. A different unexpired
certificate later signals `certificate-mismatch` with two restarts:
`accept-new-certificate` continues the same request, and
`reject-certificate` aborts it. An expired record is replaced silently. Stores
implement `lookup-known-host`, `store-known-host`, `forget-known-host` and
`list-known-hosts`: `make-memory-known-hosts` (default `*known-hosts*`),
`make-file-known-hosts`, or a subclass of your own (for example, the
Keychain).

### Threads and cancellation

`fetch` is safe to call from many threads at once. Give it a
`(make-request-handle)` as `:handle`, and `(cancel-request handle)` from another
thread shuts the socket down. The fetch then signals `request-cancelled`.
`:on-progress` is called with bytes so far after each chunk.

## The driver: `bin/gopher`

```
gopher get gopher://gopher.floodgap.com/
gopher get -q lisp gopher://gopher.floodgap.com/7/v2/vs
gopher get -v gemini://geminiprotocol.net/       # status, URL, certificate on stderr
gopher get -o cat.png gopher://example.org/I/cat.png
gopher info gopher://example.org/1/              # Gopher+ attributes
gopher upload titan://example.org/page page.gmi --token secret
gopher known-hosts [--forget host:port]
```

Certificates are remembered in `~/.config/gopher/known_hosts`. Exit status: 0
success, 3 a non-success reply, 4 TLS/certificate, 5 connection/timeout, 6
protocol error, 7 too large, 64 usage.

## Limitations

- Gopher+ `+ASK` forms are parsed as attribute blocks but not submitted.
- No client-certificate generation. Pass existing PEM files.
- Host names are used as given (no IDNA/punycode conversion).
- cl+ssl's certificate-date and subject helpers fail on OpenSSL 4, so the
  library reads those fields with its own calls (`src/transport.lisp`).
