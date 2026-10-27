;;;; client.lisp -- the public entry points.

(in-package #:gopher)

(defun follow-redirect-p (from to)
  "Redirects are followed automatically only within a scheme, plus Titan to
Gemini (an upload landing on its page).  Anything else -- gemini:// to
https://, gopher:// to telnet:// -- is the caller's decision."
  (let ((a (url-scheme from)) (b (url-scheme to)))
    (or (string= a b)
        (and (string= a "titan") (string= b "gemini")))))

(defun call-handler (url request)
  (let ((handler (or (find-scheme-handler (url-scheme url))
                     (error 'unsupported-scheme :url url :scheme (url-scheme url)))))
    (with-network-errors (request url)
      (prog1 (funcall handler url request)
        (check-cancelled request url)))))

(defun fetch (url &rest options
              &key (default-scheme "gopher")
                (timeout *default-timeout*) (max-size *default-max-size*)
                tls (verify :tofu) known-hosts client-certificate client-key
                on-progress handle sink query data mime-type token gopher-plus
                (follow-redirects t) (max-redirects *default-max-redirects*))
  "Fetch URL (a string or URL) and return a RESPONSE.

Statuses that are part of the protocol (input wanted, not found, client
certificate required ...) are returned as the response's status; conditions
are signalled only when there is no usable reply (SMALL-WEB-ERROR and its
subclasses).

  :DEFAULT-SCHEME      scheme for a URL typed without one (\"gopher\")
  :TIMEOUT             seconds for connecting and for each read
  :MAX-SIZE            largest body to hold in memory; NIL for no limit
  :TLS                 for gopher://: :NEVER (default), :TRY or :REQUIRE
  :VERIFY              :TOFU (default), :NONE, or (lambda (cert-info host port))
  :KNOWN-HOSTS         a KNOWN-HOSTS store (default *KNOWN-HOSTS*)
  :CLIENT-CERTIFICATE  PEM file of a client certificate (Gemini identities)
  :CLIENT-KEY          PEM file of its private key
  :ON-PROGRESS         (lambda (bytes-so-far total-or-nil))
  :HANDLE              a REQUEST-HANDLE; CANCEL-REQUEST on it aborts the fetch
  :SINK                a binary output stream; the body goes there, not memory
  :QUERY               user input: Gemini/Guppy query, Gopher search, Spartan data
  :DATA                upload body (string, octets or pathname): Titan, Spartan
  :MIME-TYPE, :TOKEN   Titan upload parameters
  :GOPHER-PLUS         T (Gopher+ item), \"!\" / \"$\" (attributes) or a view's MIME type
  :FOLLOW-REDIRECTS    follow same-scheme redirects (default T)
  :MAX-REDIRECTS       limit on redirects followed (default 5)"
  (declare (ignore options))
  (let ((request (%make-request :timeout timeout :max-size max-size :tls tls :verify verify
                                :known-hosts known-hosts
                                :client-certificate client-certificate :client-key client-key
                                :on-progress on-progress :handle handle :sink sink
                                :query query :data data :mime-type mime-type :token token
                                :gopher-plus gopher-plus
                                :follow-redirects follow-redirects :max-redirects max-redirects))
        (current (ensure-url url :default-scheme default-scheme))
        (chain '()))
    (loop
      (let ((response (call-handler current request)))
        (setf (response-redirects response) (reverse chain))
        (unless (and (response-redirect-p response) follow-redirects)
          (return response))
        (let ((target (handler-case (response-redirect-url response)
                        (url-parse-error () nil))))
          (when (or (null target) (not (follow-redirect-p current target)))
            (return response))
          (push (url-string current) chain)
          (when (> (length chain) max-redirects)
            (error 'redirect-error :url target :message "Too many redirects"))
          (when (member (url-string target) chain :test #'string=)
            (error 'redirect-error :url target :message "Redirect loop"))
          ;; Input and uploads belong to the first request only.
          (setf request (copy-request request))
          (setf (request-query request) nil
                (request-data request) nil
                current target))))))

(defun fetch-document (url &rest options)
  "Fetch URL and return its DOCUMENT (NIL if not a successful text response),
and the RESPONSE as a second value."
  (let ((response (apply #'fetch url options)))
    (values (response-document response) response)))

(defun upload (url data &rest options &key (mime-type "text/plain") token &allow-other-keys)
  "Upload DATA (string, octets or pathname) to URL.  gemini:// and titan://
URLs upload with Titan; spartan:// URLs send DATA as the request body.
Returns the RESPONSE."
  (let* ((url (ensure-url url))
         (url (if (string= (url-scheme url) "gemini") (make-titan-url url :mime-type mime-type) url)))
    (unless (member (url-scheme url) '("titan" "spartan") :test #'string=)
      (error 'unsupported-scheme :url url :scheme (url-scheme url)
                                 :message "Uploads need a titan://, gemini:// or spartan:// URL"))
    (apply #'fetch url :data data :mime-type mime-type :token token
           (alexandria:remove-from-plist options :mime-type :token))))
