# gopher API reference

Generated from docstrings by `make docs`; do not edit by hand.  Sections follow the source files in load order.

## conditions

### `accept-new-certificate` — function

```lisp
(accept-new-certificate &optional condition)
```

Invoke the ACCEPT-NEW-CERTIFICATE restart for a CERTIFICATE-MISMATCH.

### `certificate-mismatch` — condition

Trust-on-first-use: the host presented a certificate different from the
unexpired one on record.  Restarts: ACCEPT-NEW-CERTIFICATE records the new one
and continues; REJECT-CERTIFICATE aborts with this error.

### `connection-error` — condition

Could not connect, or the connection failed mid-request.

### `empty-response` — condition

The server closed the connection without sending anything,
where the protocol needs at least a header line.

### `protocol-error` — condition

The server's reply does not follow the protocol.

### `redirect-error` — condition

Too many redirects, or a redirect loop.

### `reject-certificate` — function

```lisp
(reject-certificate &optional condition)
```

Invoke the REJECT-CERTIFICATE restart for a CERTIFICATE-MISMATCH.

### `request-cancelled` — condition

CANCEL-REQUEST was called on the request's handle.

### `response-too-large` — condition

The body exceeded the MAX-SIZE given to FETCH.

### `small-web-error` — condition

Root of every condition this library signals.

### `timeout-error` — condition

Connecting or waiting for data took longer than the timeout.

### `tls-error` — condition

The TLS handshake or a TLS read/write failed.

### `unsupported-scheme` — condition

FETCH was given a URL whose scheme has no registered handler.

### `url-parse-error` — condition

A string could not be parsed as a URL.

## url

### `copy-url` — function

```lisp
(copy-url instance)
```

A fresh copy of a URL.

### `default-port` — function

```lisp
(default-port scheme)
```

The well-known port for SCHEME (a string), or NIL.

### `ensure-url` — function

```lisp
(ensure-url thing &key default-scheme)
```

THING if it is a URL, otherwise THING parsed as one.

### `make-gopher-url` — function

```lisp
(make-gopher-url host &key port type selector search gopher-plus scheme)
```

A Gopher URL for an item on HOST.

### `make-titan-url` — function

```lisp
(make-titan-url url &key mime-type size token)
```

A Titan upload URL for URL's host and path (URL may be gemini:// or
titan://), carrying MIME-TYPE, SIZE and TOKEN.

### `make-url` — function

```lisp
(make-url &key scheme userinfo host port path query fragment)
```

Make a URL.  SCHEME and HOST are lowercased.  PATH, QUERY and FRAGMENT must
already be percent-encoded.

### `merge-url` — function

```lisp
(merge-url reference base)
```

Resolve REFERENCE (a string or URL) against BASE, as a browser resolves a
link.  Returns a new URL.

### `parse-url` — function

```lisp
(parse-url string &key default-scheme)
```

Parse STRING into a URL.  If STRING has no scheme and DEFAULT-SCHEME is
given, it is read as `DEFAULT-SCHEME://STRING', so "example.org/x" works as
input from a browser's address bar.  Signals URL-PARSE-ERROR.

### `percent-decode` — function

```lisp
(percent-decode string)
```

Decode %XX escapes in STRING.  The resulting bytes are read as UTF-8, and
as Latin-1 if they are not valid UTF-8.

### `percent-encode` — function

```lisp
(percent-encode string &key safe)
```

Percent-encode STRING as UTF-8.  Unreserved characters and the characters
in SAFE are left alone.

### `url` — structure

A parsed URL.  Make one with PARSE-URL or MAKE-URL.

### `url-display-host` — function

```lisp
(url-display-host url)
```

URL's host for showing to a person: xn-- labels decoded to Unicode.

### `url-display-string` — function

```lisp
(url-display-string url)
```

URL as a string for an address bar: the host in Unicode, and the path and
query percent-decoded where that yields readable text.

### `url-effective-port` — function

```lisp
(url-effective-port url)
```

URL's explicit port, otherwise its scheme's default port.

### `url-fragment` — function

```lisp
(url-fragment instance)
```

The fragment without `#', or NIL.  Never sent to a server.

### `url-gopher-plus` — function

```lisp
(url-gopher-plus url)
```

The decoded Gopher+ string of a Gopher URL, or NIL.

### `url-gopher-search` — function

```lisp
(url-gopher-search url)
```

The decoded search string of a Gopher URL, or NIL.

### `url-gopher-selector` — function

```lisp
(url-gopher-selector url)
```

The decoded selector of a Gopher URL.

### `url-gopher-type` — function

```lisp
(url-gopher-type url)
```

The item type character of a Gopher URL (#\1 when the path is empty).

### `url-host` — function

```lisp
(url-host instance)
```

The host, lowercased; international names in their xn-- ASCII form.

### `url-p` — function

```lisp
(url-p object)
```

True if the object is a URL.

### `url-path` — function

```lisp
(url-path instance)
```

The path, percent-encoded as written.  For Gopher: /<type><selector>.

### `url-port` — function

```lisp
(url-port instance)
```

The explicit port, or NIL for the scheme's default (see URL-EFFECTIVE-PORT).

### `url-query` — function

```lisp
(url-query instance)
```

The query without `?', percent-encoded, or NIL.  Always NIL for Gopher.

### `url-scheme` — function

```lisp
(url-scheme instance)
```

The scheme, lowercased: "gopher", "gemini" ...

### `url-string` — function

```lisp
(url-string url &key fragment)
```

URL as a string.  The scheme's default port is left out.  With :FRAGMENT
NIL, the fragment is left out too, as it must be in a request.

### `url-titan-parameters` — function

```lisp
(url-titan-parameters url)
```

Titan parameters in URL's path as an alist of (name . value) strings, and
the path without them as a second value.

### `url-userinfo` — function

```lisp
(url-userinfo instance)
```

The user part before `@', percent-encoded, or NIL.

### `url-with-query` — function

```lisp
(url-with-query url query)
```

A copy of URL whose query is QUERY.  QUERY is percent-encoded here.

## idna

### `host-to-ascii` — function

```lisp
(host-to-ascii host)
```

HOST with each non-ASCII label Punycode-encoded and prefixed with xn--.

### `host-to-unicode` — function

```lisp
(host-to-unicode host)
```

HOST with xn-- labels decoded.  Malformed labels are left as they are.

### `punycode-decode` — function

```lisp
(punycode-decode string)
```

Decode a Punycode STRING (without "xn--").  Signals URL-PARSE-ERROR if
it is malformed or decodes to something that is not a character.

### `punycode-encode` — function

```lisp
(punycode-encode string)
```

Encode STRING with Punycode (without the "xn--" prefix).

## encoding

### `decode-text` — function

```lisp
(decode-text octets &key charset)
```

Decode OCTETS into a string.  CHARSET (a string such as "iso-8859-1")
is tried first when babel knows it, then UTF-8, then Latin-1.

### `guess-mime-type` — function

```lisp
(guess-mime-type path &key default)
```

Guess a MIME type from PATH's extension, otherwise DEFAULT.

### `mime-charset` — function

```lisp
(mime-charset mime-type)
```

The charset parameter of MIME-TYPE, or NIL.

### `parse-mime-type` — function

```lisp
(parse-mime-type string)
```

Split a MIME type such as "text/gemini; charset=utf-8; lang=en" into
(values "text/gemini" (("charset" . "utf-8") ("lang" . "en"))).

## transport

### `*default-max-redirects*` — variable

How many redirects FETCH follows by default.

### `*default-max-size*` — variable

Largest body FETCH will hold in memory, in bytes.  NIL means no limit.

### `*default-proxy*` — variable

A SOCKS5 proxy URL ("socks5://[user:pass@]host:port") FETCH uses when no
:PROXY is given, or NIL.  Host names are resolved by the proxy, so this
works for Tor (socks5://127.0.0.1:9050) and .onion addresses.

### `*default-timeout*` — variable

Seconds to wait for a connection, and for each read, before giving up.

### `cancel-request` — function

```lisp
(cancel-request handle)
```

Cancel the request HANDLE was given to.  Safe to call from any thread, and
more than once.  Shutting the socket down wakes a reader blocked on it.

### `certificate-common-names` — function

```lisp
(certificate-common-names info)
```

The subject's CN values.

### `certificate-dns-names` — function

```lisp
(certificate-dns-names info)
```

The DNS subjectAltName entries (may be empty).

### `certificate-expired-p` — function

```lisp
(certificate-expired-p info &optional now)
```

True if the certificate's not-after time has passed.

### `certificate-fingerprint` — function

```lisp
(certificate-fingerprint info)
```

SHA-256 fingerprint as "sha256:<64 hex digits>".

### `certificate-info` — structure

What a server's TLS certificate says, as plain data.

### `certificate-info-from-file` — function

```lisp
(certificate-info-from-file pathname)
```

CERTIFICATE-INFO for the PEM certificate in PATHNAME.

### `certificate-info-p` — function

```lisp
(certificate-info-p object)
```

True if the object is a CERTIFICATE-INFO.

### `certificate-not-after` — function

```lisp
(certificate-not-after info)
```

Universal time at which the certificate expires, or NIL.

### `certificate-not-before` — function

```lisp
(certificate-not-before info)
```

Universal time from which the certificate is valid, or NIL.

### `make-request-handle` — function

```lisp
(make-request-handle)
```

A handle to pass as FETCH's :HANDLE so CANCEL-REQUEST can stop the fetch.

### `request-handle` — structure

Lets another thread cancel a FETCH; see CANCEL-REQUEST.

### `request-handle-cancelled-p` — function

```lisp
(request-handle-cancelled-p instance)
```

True once CANCEL-REQUEST has been called on the handle.

## tofu

### `*known-hosts*` — variable

The store FETCH uses when no :KNOWN-HOSTS is given.

### `file-known-hosts` — class

Known hosts loaded from, and saved to, a text file.

### `forget-known-host` — generic function

```lisp
(forget-known-host store host port)
```

Remove the entry for HOST:PORT.

### `known-host` — structure

A trusted certificate fingerprint for one host:port.

### `known-host-expires` — function

```lisp
(known-host-expires instance)
```

Universal time the trusted certificate expires, or NIL.

### `known-host-fingerprint` — function

```lisp
(known-host-fingerprint instance)
```

Trusted certificate fingerprint, "sha256:...".

### `known-host-first-seen` — function

```lisp
(known-host-first-seen instance)
```

Universal time the entry was recorded.

### `known-host-host` — function

```lisp
(known-host-host instance)
```

Host name of a KNOWN-HOST entry.

### `known-host-p` — function

```lisp
(known-host-p object)
```

True if the object is a KNOWN-HOST.

### `known-host-port` — function

```lisp
(known-host-port instance)
```

Port of a KNOWN-HOST entry.

### `known-hosts` — class

Abstract store of trusted certificate fingerprints.

### `list-known-hosts` — generic function

```lisp
(list-known-hosts store)
```

Every KNOWN-HOST entry in STORE.

### `lookup-known-host` — generic function

```lisp
(lookup-known-host store host port)
```

The KNOWN-HOST entry for HOST:PORT, or NIL.

### `make-file-known-hosts` — function

```lisp
(make-file-known-hosts pathname)
```

A known-hosts store loaded from and saved to PATHNAME.

### `make-known-host` — function

```lisp
(make-known-host &key (host host) (port port) (fingerprint fingerprint) (expires
                                                                         expires) (first-seen
                                                                                   first-seen))
```

Make a KNOWN-HOST entry: :HOST :PORT :FINGERPRINT :EXPIRES :FIRST-SEEN.

### `make-memory-known-hosts` — function

```lisp
(make-memory-known-hosts)
```

A known-hosts store that lives only in memory.

### `memory-known-hosts` — class

Known hosts kept in memory only.

### `store-known-host` — generic function

```lisp
(store-known-host store entry)
```

Record ENTRY, replacing any entry for its host and port.

## document

### `document` — structure

A parsed page: kind, title and a vector of DOCUMENT-LINEs.

### `document-kind` — function

```lisp
(document-kind instance)
```

What the document was parsed from: :MENU :GEMTEXT :NEX-DIRECTORY or :TEXT.

### `document-line` — structure

One line of a DOCUMENT; see LINE-KIND.

### `document-line-p` — function

```lisp
(document-line-p object)
```

True if the object is a DOCUMENT-LINE.

### `document-lines` — function

```lisp
(document-lines instance)
```

Vector of DOCUMENT-LINEs, in order.

### `document-links` — function

```lisp
(document-links document)
```

The link and input-prompt lines of DOCUMENT, in order.

### `document-p` — function

```lisp
(document-p object)
```

True if the object is a DOCUMENT.

### `document-title` — function

```lisp
(document-title instance)
```

The first level-1 heading of a gemtext document, or NIL.

### `line-alt` — function

```lisp
(line-alt instance)
```

Alt text of a gemtext preformatted block, or NIL.

### `line-gopher-plus-ask-p` — function

```lisp
(line-gopher-plus-ask-p instance)
```

True if the menu marked the item with `?': a Gopher+ item
with a +ASK form to answer before fetching it (see GOPHER-PLUS-SUBMIT).

### `line-gopher-plus-p` — function

```lisp
(line-gopher-plus-p instance)
```

True if the menu marked the item as Gopher+.

### `line-host` — function

```lisp
(line-host instance)
```

Gopher items: the host field of the menu line.

### `line-item-kind` — function

```lisp
(line-item-kind instance)
```

Gopher item classification keyword, see GOPHER-ITEM-KIND.

### `line-item-type` — function

```lisp
(line-item-type instance)
```

Gopher item type character, for lines from a menu.

### `line-kind` — function

```lisp
(line-kind instance)
```

One of :TEXT :LINK :INPUT-PROMPT :HEADING :LIST-ITEM :QUOTE :PREFORMATTED :ERROR.

### `line-level` — function

```lisp
(line-level instance)
```

Heading level 1-3, for :HEADING lines.

### `line-port` — function

```lisp
(line-port instance)
```

Gopher items: the port field of the menu line.

### `line-selector` — function

```lisp
(line-selector instance)
```

Gopher items: the selector field of the menu line.

### `line-text` — function

```lisp
(line-text instance)
```

The line's text; for links, the label.

### `line-url` — function

```lisp
(line-url instance)
```

For links and prompts, the absolute URL as a string.

### `make-document-line` — function

```lisp
(make-document-line &key (kind kind) (text text) (url url) (level level) (alt
                                                                          alt) (item-type
                                                                                item-type) (item-kind
                                                                                            item-kind) (gopher-plus-p
                                                                                                        gopher-plus-p) (gopher-plus-ask-p
                                                                                                                        gopher-plus-ask-p) (host
                                                                                                                                            host) (port
                                                                                                                                                   port) (selector
                                                                                                                                                          selector))
```

Make a DOCUMENT-LINE.  Keys: :KIND :TEXT :URL :LEVEL :ALT :ITEM-TYPE :ITEM-KIND :GOPHER-PLUS-P :HOST :PORT :SELECTOR.

### `response` — class

Everything a FETCH returned: status, meta, body, certificate.

### `response-category` — function

```lisp
(response-category response)
```

The status reduced to :SUCCESS :INPUT :REDIRECT :TEMPORARY-FAILURE :PERMANENT-FAILURE or :CLIENT-CERTIFICATE.

### `response-document` — function

```lisp
(response-document response)
```

The body parsed into a DOCUMENT, or NIL for an unsuccessful or non-text
response.  Parsed once, on first call.

### `response-input-p` — function

```lisp
(response-input-p response)
```

True if the server asked for input (:INPUT or :SENSITIVE-INPUT).

### `response-redirect-p` — function

```lisp
(response-redirect-p response)
```

True for a redirect response.

### `response-redirect-url` — function

```lisp
(response-redirect-url response)
```

For a redirect, the target resolved against the response's URL.

### `response-sensitive-input-p` — function

```lisp
(response-sensitive-input-p response)
```

True if the server asked for sensitive input such as a password.

### `response-success-p` — function

```lisp
(response-success-p response)
```

True for a :SUCCESS response.

### `response-text` — function

```lisp
(response-text response)
```

The body decoded as text, using the MIME type's charset when there is one.

### `save-response` — function

```lisp
(save-response response pathname &key if-exists)
```

Write RESPONSE's body to PATHNAME.  Returns PATHNAME.

## registry

### `find-scheme-handler` — function

```lisp
(find-scheme-handler scheme)
```

The handler function for a scheme string, or NIL.

### `supported-schemes` — function

```lisp
(supported-schemes)
```

Every scheme FETCH can handle, sorted.

## gopher

### `forget-gopher-tls-status` — function

```lisp
(forget-gopher-tls-status &optional host port)
```

Forget what :TLS :TRY learned about HOST:PORT, or about every server.

### `gopher-item-description` — function

```lisp
(gopher-item-description type)
```

A short English description of a Gopher item type.

### `gopher-item-kind` — function

```lisp
(gopher-item-kind type)
```

Classify item TYPE (a character): :MENU :TEXT :SEARCH :BINARY :IMAGE
:SOUND :VIDEO :DOCUMENT :HTML :TELNET :INFO :ERROR :CSO :MIRROR :CALENDAR,
or :UNKNOWN.

### `gopher-item-mime-type` — function

```lisp
(gopher-item-mime-type type &optional selector)
```

The MIME type to assume for an item of TYPE.  The SELECTOR's extension is
consulted when the type itself does not say (I, s, ;, d, 9, ...).

### `gopher-tls-status` — function

```lisp
(gopher-tls-status host &optional port)
```

What :TLS :TRY found at HOST:PORT: :TLS, :PLAIN, or NIL if never tried.

### `gopher-unstuff-text` — function

```lisp
(gopher-unstuff-text octets)
```

OCTETS, a Gopher text item, up to its `.' terminator line, with lines that
begin with `..' un-stuffed.  Returns new octets.  The text ends at the first
line that is only `.' (RFC 1436): whatever a server sends after it is not
part of the item.  This is what the streaming parser does too.

## gopher-plus

### `gopher-attributes` — function

```lisp
(gopher-attributes url &rest fetch-options &key directory &allow-other-keys)
```

Fetch the Gopher+ attributes of the item at URL, or with :DIRECTORY T of
every item in the menu at URL.  Returns a list of GOPHER-PLUS-RECORDs, and
the RESPONSE as a second value.

### `gopher-plus-question` — structure

One question of a Gopher+ +ASK form.

### `gopher-plus-question-choices` — function

```lisp
(gopher-plus-question-choices instance)
```

Default answer (:ASK) or the options (:SELECT, :CHOOSE).

### `gopher-plus-question-kind` — function

```lisp
(gopher-plus-question-kind instance)
```

One of :ASK :ASK-PASSWORD :ASK-LONG :ASK-FILE :SELECT :CHOOSE :CHOOSE-FILE :NOTE.

### `gopher-plus-question-p` — function

```lisp
(gopher-plus-question-p object)
```

True if the object is a GOPHER-PLUS-QUESTION.

### `gopher-plus-question-prompt` — function

```lisp
(gopher-plus-question-prompt instance)
```

The question text.

### `gopher-plus-record` — structure

One item's Gopher+ attributes.

### `gopher-plus-record-abstract` — function

```lisp
(gopher-plus-record-abstract record)
```

The +ABSTRACT block as one string, or NIL.

### `gopher-plus-record-admin` — function

```lisp
(gopher-plus-record-admin record)
```

The +ADMIN block as an alist of ("Admin" . "..."), ("Mod-Date" . "...") ...

### `gopher-plus-record-attribute` — function

```lisp
(gopher-plus-record-attribute record name)
```

The lines of block NAME (e.g. "ABSTRACT") of RECORD, or NIL.

### `gopher-plus-record-blocks` — function

```lisp
(gopher-plus-record-blocks instance)
```

All attribute blocks as ((NAME . LINES) ...).

### `gopher-plus-record-info` — function

```lisp
(gopher-plus-record-info instance)
```

The item's +INFO line as a DOCUMENT-LINE.

### `gopher-plus-record-p` — function

```lisp
(gopher-plus-record-p object)
```

True if the object is a GOPHER-PLUS-RECORD.

### `gopher-plus-record-questions` — function

```lisp
(gopher-plus-record-questions record)
```

The +ASK block of RECORD as GOPHER-PLUS-QUESTIONs, in order.

### `gopher-plus-record-views` — function

```lisp
(gopher-plus-record-views record)
```

The +VIEWS block as GOPHER-PLUS-VIEWs.

### `gopher-plus-server-p` — function

```lisp
(gopher-plus-server-p url &rest fetch-options)
```

True if the server at URL answers a Gopher+ attribute request for the
item URL names (the root menu if URL has no path).

### `gopher-plus-submit` — function

```lisp
(gopher-plus-submit url answers &rest fetch-options)
```

Answer the +ASK form of the item at URL.  ANSWERS has one entry per
question that is not a Note (a string, or a list of strings for an AskL
question).  A ChooseF question's file goes in FETCH-OPTIONS as
:GOPHER-PLUS-FILE (a pathname or octets).  Returns the server's RESPONSE.

### `gopher-plus-view` — structure

One entry of a +VIEWS block.

### `gopher-plus-view-language` — function

```lisp
(gopher-plus-view-language instance)
```

Language of a view, e.g. "En_US", or NIL.

### `gopher-plus-view-mime-type` — function

```lisp
(gopher-plus-view-mime-type instance)
```

MIME type of a Gopher+ view.

### `gopher-plus-view-p` — function

```lisp
(gopher-plus-view-p object)
```

True if the object is a GOPHER-PLUS-VIEW.

### `gopher-plus-view-size` — function

```lisp
(gopher-plus-view-size instance)
```

The size as the server wrote it, e.g. "<10k>", or NIL.

### `parse-gopher-plus-attributes` — function

```lisp
(parse-gopher-plus-attributes text &optional base-url)
```

Parse Gopher+ attribute TEXT (the reply to `!' or `$') into a list of
GOPHER-PLUS-RECORDs.

## gemini

### `gemini-status-keyword` — function

```lisp
(gemini-status-keyword code)
```

The keyword for Gemini status CODE.  An unknown code within a known class
maps to the class's generic status, as the spec requires.

## parsers

### `line-parser` — class

Parses a text format one line at a time; see MAKE-LINE-PARSER.

### `make-line-parser` — function

```lisp
(make-line-parser mime-type base-url &key gopher-text)
```

A LINE-PARSER for MIME-TYPE, or NIL if it is not a text type.

### `parse-gemtext` — function

```lisp
(parse-gemtext text &optional base-url)
```

Parse gemtext TEXT into a DOCUMENT.  Links are resolved against BASE-URL.
`=:' input-prompt lines (Spartan) are recognised too.

### `parse-gopher-menu` — function

```lisp
(parse-gopher-menu text &optional base-url)
```

Parse a Gopher menu into a DOCUMENT of kind :MENU.  Tolerates a missing
`.' terminator, bare LF line ends, and lines that are not menu lines.

### `parse-nex-directory` — function

```lisp
(parse-nex-directory text &optional base-url)
```

A Nex directory listing as a DOCUMENT: `=> ' lines are links, the rest text.

### `parse-plain-text` — function

```lisp
(parse-plain-text text)
```

A plain-text DOCUMENT: one :PREFORMATTED line per line of TEXT.

### `parse-text-with` — function

```lisp
(parse-text-with parser text)
```

Run PARSER over all of TEXT and return the DOCUMENT.

### `parser-feed` — generic function

```lisp
(parser-feed parser line)
```

Consume one source LINE (no line end).  Returns the list of
DOCUMENT-LINEs it completes.

### `parser-finish` — generic function

```lisp
(parser-finish parser)
```

End of input.  Returns any DOCUMENT-LINEs still pending.

## identity

### `make-identity` — function

```lisp
(make-identity certificate-path key-path &key common-name days key-type bits)
```

Create a self-signed client certificate and private key and write them as
PEM to CERTIFICATE-PATH and KEY-PATH (the key with mode 0600).  KEY-TYPE is
:EC (P-256, the default), :RSA (BITS long) or :ED25519; not every Gemini
server accepts Ed25519.  Returns the certificate's CERTIFICATE-INFO.

## cache

### `cache-clear` — function

```lisp
(cache-clear cache)
```

Empty the cache.

### `cache-count` — function

```lisp
(cache-count cache)
```

Number of responses in the cache.

### `cache-forget` — function

```lisp
(cache-forget cache url)
```

Drop every cached response for URL, whatever its query.

### `cache-lookup` — function

```lisp
(cache-lookup cache url &optional request)
```

The cached RESPONSE for URL (as REQUEST would fetch it), or NIL.

### `cache-store` — function

```lisp
(cache-store cache url response &optional request)
```

Remember RESPONSE for URL if it is worth caching.  Returns RESPONSE.

### `history` — structure

A back/forward list of visited URLs.

### `history-back` — function

```lisp
(history-back history)
```

Step back.  Returns the URL now current, or NIL if there is nothing behind.

### `history-back-p` — function

```lisp
(history-back-p history)
```

True if HISTORY-BACK would move.

### `history-current` — function

```lisp
(history-current history)
```

The current URL string, or NIL before the first visit.

### `history-forward` — function

```lisp
(history-forward history)
```

Step forward.  Returns the URL now current, or NIL at the end.

### `history-forward-p` — function

```lisp
(history-forward-p history)
```

True if HISTORY-FORWARD would move.

### `history-list` — function

```lisp
(history-list history)
```

All entries, oldest first, and the current index as a second value.

### `history-visit` — function

```lisp
(history-visit history url)
```

Record a visit to URL: forward entries are dropped.  Visiting the current
URL again changes nothing.  Returns the URL string.

### `make-history` — function

```lisp
(make-history)
```

An empty back/forward history.

### `make-response-cache` — function

```lisp
(make-response-cache &key max-entries max-bytes max-age)
```

A cache of up to MAX-ENTRIES responses and MAX-BYTES of bodies.  With
MAX-AGE (seconds), older entries are treated as missing.

### `response-cache` — class

A size-bounded LRU cache of responses; see MAKE-RESPONSE-CACHE.

## client

### `fetch` — function

```lisp
(fetch url &rest options &key default-scheme timeout connect-timeout read-timeout deadline max-size proxy tls verify known-hosts client-certificate client-key on-progress on-data on-lines handle sink cache query data mime-type token gopher-plus gopher-plus-answers gopher-plus-file follow-redirects max-redirects)
```

Fetch URL (a string or URL) and return a RESPONSE.

Statuses that are part of the protocol (input wanted, not found, client
certificate required ...) are returned as the response's status; conditions
are signalled only when there is no usable reply (SMALL-WEB-ERROR and its
subclasses).

  :DEFAULT-SCHEME      scheme for a URL typed without one ("gopher")
  :TIMEOUT             seconds for connecting and for each read
  :CONNECT-TIMEOUT     seconds to connect (default: TIMEOUT)
  :READ-TIMEOUT        seconds to wait for each read (default: TIMEOUT)
  :DEADLINE            seconds for the whole fetch, redirects included
  :MAX-SIZE            largest body to hold in memory; NIL for no limit
  :PROXY               SOCKS5 proxy URL, e.g. "socks5://127.0.0.1:9050" (Tor)
  :TLS                 for gopher://: :NEVER (default), :TRY or :REQUIRE
  :VERIFY              :TOFU (default), :NONE, or (lambda (cert-info host port))
  :KNOWN-HOSTS         a KNOWN-HOSTS store (default *KNOWN-HOSTS*)
  :CLIENT-CERTIFICATE  PEM file of a client certificate (Gemini identities)
  :CLIENT-KEY          PEM file of its private key
  :ON-PROGRESS         (lambda (bytes-so-far total-or-nil))
  :ON-DATA             (lambda (octets)) for each chunk of the body as it arrives
  :ON-LINES            (lambda (document-lines)) as lines of a text body are parsed;
                       the same lines RESPONSE-DOCUMENT later returns
  :CACHE               a RESPONSE-CACHE to answer from and fill
  :HANDLE              a REQUEST-HANDLE; CANCEL-REQUEST on it aborts the fetch
  :SINK                a binary output stream; the body goes there, not memory
  :QUERY               user input: Gemini/Guppy query, Gopher search, Spartan data
  :DATA                upload body (string, octets or pathname): Titan, Spartan
  :MIME-TYPE, :TOKEN   Titan upload parameters
  :GOPHER-PLUS         T (Gopher+ item), "!" / "$" (attributes) or a view's MIME type
  :GOPHER-PLUS-ANSWERS answers to a Gopher+ +ASK form, one string per question
  :GOPHER-PLUS-FILE    a file (pathname or octets) sent after those answers,
                       for a ChooseF question
  :FOLLOW-REDIRECTS    follow same-scheme redirects (default T)
  :MAX-REDIRECTS       limit on redirects followed (default 5)

### `fetch-document` — function

```lisp
(fetch-document url &rest options)
```

Fetch URL and return its DOCUMENT (NIL if not a successful text response),
and the RESPONSE as a second value.

### `upload` — function

```lisp
(upload url data &rest options &key mime-type token &allow-other-keys)
```

Upload DATA (string, octets or pathname) to URL.  gemini:// and titan://
URLs upload with Titan; spartan:// URLs send DATA as the request body.
Returns the RESPONSE.

## render

### `render-document` — function

```lisp
(render-document document &key stream show-urls)
```

Write DOCUMENT to STREAM as text.  Links are numbered from 1.  Returns the
link URLs as a vector, so link N is (aref result (1- N)).

### `render-response` — function

```lisp
(render-response response &key stream show-urls)
```

Render RESPONSE: its document if it has one, its text for other text, or a
one-line summary for binary bodies and non-success statuses.  Returns the
link vector (empty if there is no document).

## other

### `error-limit` — generic function

```lisp
(error-limit condition)
```

The MAX-SIZE that was exceeded.

### `error-message` — generic function

```lisp
(error-message condition)
```

A human-readable description of the failure.

### `error-scheme` — generic function

```lisp
(error-scheme condition)
```

The scheme that has no handler.

### `error-url` — generic function

```lisp
(error-url condition)
```

The URL (or string) the failing request was for, or NIL.

### `known-hosts-pathname` — generic function

```lisp
(known-hosts-pathname object)
```

The file a FILE-KNOWN-HOSTS store uses.

### `mismatch-certificate` — generic function

```lisp
(mismatch-certificate condition)
```

The CERTIFICATE-INFO the server presented.

### `mismatch-expected` — generic function

```lisp
(mismatch-expected condition)
```

The KNOWN-HOST entry on record.

### `mismatch-host` — generic function

```lisp
(mismatch-host condition)
```

Host whose certificate changed.

### `mismatch-port` — generic function

```lisp
(mismatch-port condition)
```

Port whose certificate changed.

### `response-body` — generic function

```lisp
(response-body object)
```

The body as octets, or NIL (no body, or it went to a :SINK).

### `response-bytes-read` — generic function

```lisp
(response-bytes-read object)
```

How many body bytes were received.

### `response-certificate` — generic function

```lisp
(response-certificate object)
```

The server's CERTIFICATE-INFO, for TLS responses.

### `response-meta` — generic function

```lisp
(response-meta object)
```

Gemini-style meta: MIME type, prompt, redirect target or error text.

### `response-mime-type` — generic function

```lisp
(response-mime-type object)
```

The body's MIME type (with parameters), or NIL.

### `response-protocol` — generic function

```lisp
(response-protocol object)
```

Keyword: :GOPHER :GEMINI :TITAN :SPARTAN :NEX :GUPPY or :FINGER.

### `response-redirects` — generic function

```lisp
(response-redirects object)
```

URL strings that redirected to this response, oldest first.

### `response-status` — generic function

```lisp
(response-status object)
```

Status keyword: :SUCCESS :INPUT :SENSITIVE-INPUT :REDIRECT :NOT-FOUND ...

### `response-status-code` — generic function

```lisp
(response-status-code object)
```

The protocol's own status number (e.g. Gemini's 51), or NIL.

### `response-trust` — generic function

```lisp
(response-trust object)
```

How the certificate was trusted: :NEW :TRUSTED :CHANGED :EXPIRED-REPLACED :UNVERIFIED, or NIL.

### `response-url` — generic function

```lisp
(response-url object)
```

The URL that produced the response (after redirects).
