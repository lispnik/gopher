# gopher

A Common Lisp client library for Gopher and the small-web protocols around it.
It is meant to be the engine of a native macOS browser, so every protocol comes
back in the same document model and the UI renders one thing. It also builds
a command-line driver (`bin/gopher`).

| Scheme       | Protocol                                   | Transport            |
|--------------|--------------------------------------------|----------------------|
| `gopher://`  | Gopher (RFC 1436, RFC 4266 URLs), Gopher+  | TCP, optional TLS    |
| `gophers://` | Gopher over TLS                            | TLS                  |
| `gemini://`  | Gemini                                     | TLS (TOFU)           |
| `titan://`   | Titan uploads                              | TLS (TOFU)           |
| `spartan://` | Spartan (incl. uploads, `=:` prompts)      | TCP                  |
| `nex://`     | Nex                                        | TCP                  |
| `guppy://`   | Guppy v0.4                                 | UDP                  |
| `finger://`  | Finger (RFC 1288)                          | TCP                  |

SBCL, dependencies via [ocicl](https://github.com/ocicl/ocicl), tests with FiveAM.
TLS uses cl+ssl, so OpenSSL 3 or later must be installed (Homebrew's is fine).

## Build and test

```
ocicl install                  # restore dependencies into ./ocicl
make test                      # hermetic suite: in-process servers for every protocol
GOPHER_LIVE_TESTS=1 make test  # also talk to real servers
make build                     # bin/gopher
make docs                      # docs/API.md, generated from the docstrings
```

The complete reference is [docs/API.md](docs/API.md).

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

`fetch` options, all keywords (its docstring has the details):

| Option | Purpose |
|---|---|
| `:timeout`, `:connect-timeout`, `:read-timeout` | seconds to connect / per read |
| `:deadline` | seconds for the whole fetch, redirects included |
| `:proxy` | SOCKS5 proxy, e.g. `"socks5://127.0.0.1:9050"` (Tor; names resolved remotely) |
| `:tls` | `:never` / `:try` / `:require` for `gopher://` |
| `:verify`, `:known-hosts` | certificate checking: `:tofu`, `:none`, or a predicate; the trust store |
| `:client-certificate`, `:client-key` | Gemini identity PEM files |
| `:on-lines`, `:on-data`, `:on-progress` | streaming (below) and progress |
| `:handle` | a `request-handle` for cancelling from another thread |
| `:sink` | a binary stream to write the body to instead of memory |
| `:max-size` | largest body to keep in memory |
| `:cache` | a `response-cache` to answer from and fill |
| `:query`, `:data`, `:mime-type`, `:token` | input and uploads |
| `:gopher-plus`, `:gopher-plus-answers` | Gopher+ views, attributes and forms |
| `:follow-redirects`, `:max-redirects` | redirect policy |

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
(levels 1–3), `:list-item`, `:quote`, `:preformatted` and `:error`. Links
carry an absolute URL. Gopher menu items also carry `line-item-type`,
`line-item-kind` (`:menu :text :search :image :binary :telnet ...`) and their
raw host/port/selector. Plain text is one `:preformatted` line per line;
a gemtext preformatted block is a single line with its alt text.

### Streaming

`:on-lines` receives batches of `document-line`s while the body is still
arriving. They are the same lines `response-document` returns at the end, from
the same parsers, so a browser can draw them as they come and not redraw. A
gemtext preformatted block is delivered when its closing fence arrives. Reads
return as soon as data is available, on plain TCP, TLS and Guppy alike.
`:on-data` gets the raw chunks.

```lisp
(gopher:fetch "gopher://gopher.floodgap.com/"
              :on-lines (lambda (lines) (dolist (l lines) (draw l))))
```

### Trust on first use

The first certificate seen for a host:port is recorded. A different unexpired
certificate later signals `certificate-mismatch` with two restarts:
`accept-new-certificate` continues the same request, and `reject-certificate`
aborts it. An expired record is replaced silently. Stores implement
`lookup-known-host`, `store-known-host`, `forget-known-host` and
`list-known-hosts`: `make-memory-known-hosts` (the default `*known-hosts*`),
`make-file-known-hosts`, or a subclass of your own (for example, the Keychain).

### Identities

`(gopher:make-identity "me.crt" "me.key" :common-name "me")` creates a
self-signed client certificate (EC P-256 by default; also `:rsa` and
`:ed25519`) and writes the key with mode 0600. Pass the files as
`:client-certificate` / `:client-key`.

### Browser helpers

- `make-response-cache` is an LRU cache bounded by entries, bytes and age. Pass
  it as `:cache`. Only successful responses are stored, never uploads.
- `make-history`, `history-visit`, `history-back`, `history-forward` and
  `history-current` give back/forward navigation for a tab.
- International domain names are stored as `xn--` (Punycode). Use
  `url-display-string` or `url-display-host` for the address bar.
- `gopher-tls-status` reports what `:tls :try` learned about a server, and
  `forget-gopher-tls-status` resets it. `gopher-plus-server-p` tells you
  whether a server speaks Gopher+.
- For Gopher+ forms, `gopher-plus-record-questions` lists the `+ASK`
  questions, and `gopher-plus-submit` sends the answers.

### Threads and cancellation

`fetch` is safe to call from many threads at once. Give it a
`(make-request-handle)` as `:handle`, then call `(cancel-request handle)` from
another thread to shut the socket down. The fetch then signals
`request-cancelled`.

## Using it from a Cocoa app

The browser is meant to call this library directly from Lisp (through an
Objective-C bridge), so there is no C interface. Call `fetch` off the main
thread. The `:on-lines`, `:on-data` and `:on-progress` callbacks run on the
fetching thread, so hand their results to the main thread before touching
AppKit.

## The driver: `bin/gopher`

```
gopher get gopher://gopher.floodgap.com/          # drawn as it arrives
gopher get -q lisp gopher://gopher.floodgap.com/7/v2/vs
gopher get -v gemini://geminiprotocol.net/        # status, URL, certificate on stderr
gopher get -o cat.png gopher://example.org/I/cat.png
gopher get --proxy socks5://127.0.0.1:9050 gemini://example.onion/
gopher get --identity me gemini://example.org/account
gopher identity create me [--key-type rsa] [--days 365]
gopher identity list
gopher info gopher://example.org/1/              # Gopher+ attributes
gopher upload titan://example.org/page page.gmi --token secret
gopher known-hosts [--forget host:port]
```

Certificates are remembered in `~/.config/gopher/known_hosts`, identities live
in `~/.config/gopher/identities/`, and `GOPHER_PROXY` sets a default proxy.
Exit status: 0 success, 3 a non-success reply, 4 TLS/certificate, 5
connection/timeout, 6 protocol error, 7 too large, 64 usage.

## Limitations

- Guppy has been tested against the fixture server only. The public servers
  listed in its specification did not answer when this was written.
- Hosts get Punycode but not the full UTS #46 mapping, so unusual
  compatibility characters are encoded as typed.
- Guppy can't go through a SOCKS proxy (it uses UDP), and the proxy client
  only does SOCKS5 CONNECT.
- cl+ssl's certificate-date and subject helpers fail on OpenSSL 4, so the
  library reads those fields itself (`src/transport.lisp`). Identity creation
  needs OpenSSL 3 or later.
