/*
 * gopher.h -- C interface to the gopher small-web client library.
 *
 * libgopher.dylib embeds the SBCL runtime; the Lisp code lives in a core
 * file (gopher.core) that gopher_init loads.  Every string passed in or
 * returned is NUL-terminated UTF-8.  Results are JSON documents allocated
 * with malloc: release them with gopher_free (or free).
 *
 * All functions except gopher_init may be called from any thread,
 * concurrently.  A fetch blocks the calling thread until it completes, so
 * call it off the main thread and use gopher_cancel to abort it.
 */
#ifndef GOPHER_H
#define GOPHER_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Start the Lisp runtime from the core file at CORE_PATH.  Call once,
 * before anything else, preferably from the main thread.  Returns 0 on
 * success, -1 on failure.  Calling it again after success returns 0 and
 * does nothing.  A core that cannot be loaded makes the runtime exit the
 * process (SBCL has no way to report that failure to the caller).
 */
int gopher_init(const char *core_path);

/*
 * Fetch URL.  OPTIONS_JSON is a JSON object (or NULL for none):
 *
 *   timeout                 seconds to connect and per read (default 30)
 *   connect_timeout         seconds to connect (default: timeout)
 *   read_timeout            seconds per read (default: timeout)
 *   deadline                seconds for the whole fetch, redirects included
 *   proxy                   "socks5://[user:pass@]host:port" (e.g. Tor);
 *                           not usable with guppy://
 *   max_size                largest body in bytes; null for no limit
 *   tls                     "never" | "try" | "require"  (gopher:// only)
 *   verify                  "tofu" (default) | "none"
 *   known_hosts             path of the trusted-certificate file
 *                           (default: an in-memory store for the process)
 *   accept_new_certificate  true: trust a changed certificate and continue
 *   client_certificate      PEM file; client_key: its private key PEM file
 *   query                   input: Gemini/Guppy query, Gopher search, Spartan data
 *   data / data_base64      upload body (Titan, Spartan), text or base64
 *   mime_type, token        Titan upload parameters
 *   gopher_plus             "+", "!", "$" or a Gopher+ view MIME type
 *   gopher_plus_answers     answers to a Gopher+ +ASK form: an array whose
 *                           entries are strings, or arrays of strings (AskL)
 *   default_scheme          scheme for a URL typed without one ("gopher")
 *   follow_redirects        default true;  max_redirects  default 5
 *   request_id              integer naming this fetch for gopher_cancel
 *
 * Returns a malloc'd JSON object; NULL only before gopher_init.  On success:
 *
 *   { "ok": true, "status": "success", "category": "success",
 *     "status_code": 20, "meta": "...", "mime_type": "text/gemini",
 *     "protocol": "gemini", "url": "...", "redirect_url": null,
 *     "redirects": [...], "bytes": 1234, "trust": "new",
 *     "certificate": { "fingerprint": "sha256:...", "not_before": <unix>,
 *                      "not_after": <unix>, "common_names": [...] },
 *     "document": { "kind": "gemtext", "title": "...",
 *                   "lines": [ { "kind": "link", "text": "...", "url": "...",
 *                                "level": null, "alt": null,
 *                                "item_type": null, "item_kind": null,
 *                                "gopher_plus": null }, ... ] },
 *     "body_base64": null }
 *
 * "document" is set for text responses; otherwise "body_base64" holds the
 * body.  A server's "no" (status "input", "not-found", a "redirect" to
 * another scheme, ...) is still "ok": true.  With no usable reply:
 *
 *   { "ok": false, "error": { "type": "connection-error", "message": "..." } }
 *
 * Error types include connection-error, timeout-error, tls-error,
 * certificate-mismatch (with host, port, expected_fingerprint and
 * presented_fingerprint), protocol-error, response-too-large,
 * redirect-error, request-cancelled, unsupported-scheme, url-parse-error
 * and json-error (bad options).
 */
char *gopher_fetch(const char *url, const char *options_json);

/*
 * Called with each batch of document lines as a page downloads.
 * LINES_JSON is a JSON array of line objects (the same shape as
 * "document"."lines").  It is only valid during the call: copy it.  The
 * callback runs on the thread that called gopher_fetch_streaming.
 */
typedef void (*gopher_lines_callback)(void *context, const char *lines_json);

/*
 * Like gopher_fetch, but CALLBACK (may be NULL) receives the document's
 * lines while the body is still arriving, so a browser can draw a slow page
 * progressively.  The lines delivered are exactly the final document's
 * lines; the returned JSON is the same as gopher_fetch's.
 */
char *gopher_fetch_streaming(const char *url, const char *options_json,
                             gopher_lines_callback callback, void *context);

/*
 * Create a Gemini identity: a self-signed client certificate written to
 * CERTIFICATE_PATH and its private key to KEY_PATH (mode 0600), both PEM.
 * OPTIONS_JSON: { "common_name": "...", "days": 3650,
 *                 "key_type": "ec" | "rsa" | "ed25519" }.
 * Returns { "ok": true, "fingerprint": "sha256:...", "not_after": <unix> }
 * or an error object.  Use the files as client_certificate / client_key.
 */
char *gopher_make_identity(const char *certificate_path, const char *key_path,
                           const char *options_json);

/*
 * Cancel the fetch started with "request_id": ID.  Returns 1 if that id
 * was in use, 0 if not (a fetch that later starts with that id is
 * cancelled at once), -1 on internal error or before gopher_init.
 * The cancelled fetch returns an error of type "request-cancelled".
 */
int gopher_cancel(long id);

/* Free a string returned by gopher_fetch.  NULL is allowed. */
void gopher_free(char *string);

/* The library version, e.g. "0.1.0".  Owned by the library; do not free. */
const char *gopher_version(void);

#ifdef __cplusplus
}
#endif

#endif /* GOPHER_H */
