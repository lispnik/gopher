;;;; transport.lisp -- TCP and TLS connections, reading, timeouts, cancellation.
;;;;
;;;; TLS goes through cl+ssl with :UNWRAP-STREAM-P NIL.  With that, OpenSSL
;;;; reads through the Lisp socket stream, whose per-read timeout usocket set.
;;;; Unwrapped, SSL_read would block on the raw fd and the timeout would not
;;;; apply.  Certificates are never checked against a CA here.  Small-web
;;;; servers mostly use self-signed certificates, and trust is decided by TOFU
;;;; (tofu.lisp) after the handshake and before any request bytes are sent.

(in-package #:gopher)

(defvar *default-timeout* 30
  "Seconds to wait for a connection, and for each read, before giving up.")

(defvar *default-max-size* (* 64 1024 1024)
  "Largest body FETCH will hold in memory, in bytes.  NIL means no limit.")

(defvar *default-max-redirects* 5)

(defvar *default-proxy* nil
  "A SOCKS5 proxy URL (\"socks5://[user:pass@]host:port\") FETCH uses when no
:PROXY is given, or NIL.  Host names are resolved by the proxy, so this
works for Tor (socks5://127.0.0.1:9050) and .onion addresses.")

;;; The options of one request, passed to every protocol handler.

(defstruct (request (:constructor %make-request))
  (timeout *default-timeout*)
  (connect-timeout nil)     ; seconds to connect; NIL means TIMEOUT
  (read-timeout nil)        ; seconds per read; NIL means TIMEOUT
  (deadline nil)            ; absolute INTERNAL-REAL-TIME for the whole fetch, or NIL
  (proxy nil)               ; URL of a SOCKS5 proxy, or NIL
  (on-data nil)             ; (lambda (octets)) for each chunk of body as it arrives
  (on-lines nil)            ; (lambda (document-lines)) as complete lines are parsed
  (max-size *default-max-size*)
  (tls nil)                 ; :never :try :require, NIL for the scheme default
  (verify :tofu)            ; :tofu, :none, or a function of a CERTIFICATE-INFO
  (known-hosts nil)
  (client-certificate nil)  ; PEM file
  (client-key nil)          ; PEM file
  (on-progress nil)         ; (lambda (bytes-so-far total-or-nil))
  (cancel-handle nil)       ; REQUEST-HANDLE, for cancellation
  (sink nil)                ; binary output stream that receives the body
  (query nil)               ; user input: Gemini/Guppy query, Gopher search, Spartan data
  (data nil)                ; upload body (octets or string), Titan and Spartan
  (mime-type nil)           ; upload MIME type
  (token nil)               ; Titan token
  (gopher-plus nil)         ; Gopher+ request suffix: T, "!", "$", or a view MIME type
  (gopher-plus-answers nil) ; list of strings answering a +ASK form
  (gopher-plus-file nil)    ; octets sent after the answers (a ChooseF file)
  (follow-redirects t)
  (max-redirects *default-max-redirects*))

;;; Cancellation

(defstruct (request-handle (:constructor make-request-handle ()))
  "Pass one to FETCH as :HANDLE, then call CANCEL-REQUEST on it from another
thread.  FETCH then signals REQUEST-CANCELLED."
  (lock (bt:make-lock "gopher request"))
  (sockets '())
  (cancelled-p nil))

(defun cancel-request (handle)
  "Cancel the request HANDLE was given to.  Safe to call from any thread, and
more than once.  Shutting the socket down wakes a reader blocked on it."
  (bt:with-lock-held ((request-handle-lock handle))
    (setf (request-handle-cancelled-p handle) t)
    (dolist (s (request-handle-sockets handle))
      (ignore-errors (usocket:socket-shutdown s :io))))
  t)

(defun register-socket (request socket)
  (alexandria:when-let ((h (request-cancel-handle request)))
    (bt:with-lock-held ((request-handle-lock h))
      (push socket (request-handle-sockets h))
      (when (request-handle-cancelled-p h)
        (ignore-errors (usocket:socket-shutdown socket :io))))))

(defun unregister-socket (request socket)
  (alexandria:when-let ((h (request-cancel-handle request)))
    (bt:with-lock-held ((request-handle-lock h))
      (setf (request-handle-sockets h) (remove socket (request-handle-sockets h))))))

(defun cancelled-p (request)
  (alexandria:when-let ((h (request-cancel-handle request)))
    (request-handle-cancelled-p h)))

(defun check-cancelled (request url)
  (when (cancelled-p request)
    (error 'request-cancelled :url url))
  (check-deadline request url))

;;; Timeouts

(defun request-connect-timeout* (request)
  (or (request-connect-timeout request) (request-timeout request)))

(defun request-read-timeout* (request)
  (or (request-read-timeout request) (request-timeout request)))

(defun deadline-remaining (request)
  "Seconds left before the request's deadline, or NIL if it has none."
  (alexandria:when-let ((d (request-deadline request)))
    (/ (- d (get-internal-real-time)) internal-time-units-per-second)))

(defun check-deadline (request url)
  (let ((left (deadline-remaining request)))
    (when (and left (<= left 0))
      (error 'timeout-error :url url :message "Deadline exceeded"))))

(defun shortest-timeout (request timeout)
  "TIMEOUT, cut down to what is left before the deadline."
  (let ((left (deadline-remaining request)))
    (cond ((null left) timeout)
          ((null timeout) (max 0.01 left))
          (t (max 0.01 (min timeout left))))))

;;; Error translation

(defun call-with-network-errors (request url thunk)
  ;; HANDLER-BIND, not HANDLER-CASE: the library's own conditions must reach
  ;; the caller without unwinding, so that CERTIFICATE-MISMATCH's restarts
  ;; still apply.  Foreign conditions are translated where they are signalled.
  (flet ((translator (type &optional message)
           (lambda (condition)
             (if (cancelled-p request)
                 (error 'request-cancelled :url url)
                 (error type :url url
                             :message (or message
                                          (substitute #\Space #\Newline
                                                      (princ-to-string condition))))))))
    (handler-bind
        ((usocket:timeout-error (translator 'timeout-error "Timed out"))
         (sb-sys:io-timeout (translator 'timeout-error "Timed out"))
         (sb-sys:deadline-timeout (translator 'timeout-error "Timed out"))
         (sb-ext:timeout (translator 'timeout-error "Timed out"))
         (usocket:ns-error (translator 'connection-error "Could not resolve host"))
         (usocket:connection-refused-error (translator 'connection-error "Connection refused"))
         (usocket:socket-error (translator 'connection-error))
         ;; cl+ssl's Lisp BIO catches the socket's IO-TIMEOUT itself and
         ;; re-signals it as an SSL error; its message names the original.
         (cl+ssl::ssl-error (lambda (c)
                              (funcall (translator (if (search "IO-TIMEOUT" (princ-to-string c))
                                                       'timeout-error
                                                       'tls-error)
                                                   (when (search "IO-TIMEOUT" (princ-to-string c))
                                                     "Timed out"))
                                       c)))
         (stream-error (translator 'connection-error))
         (sb-bsd-sockets:socket-error (translator 'connection-error)))
      (funcall thunk))))

(defmacro with-network-errors ((request url) &body body)
  "Run BODY, translating socket, TLS and timeout conditions into this
library's conditions, and any failure after CANCEL-REQUEST into
REQUEST-CANCELLED."
  `(call-with-network-errors ,request ,url (lambda () ,@body)))

;;; Certificates

(defstruct certificate-info
  "What a server's TLS certificate says, as plain data."
  (fingerprint "" :type string)   ; "sha256:<hex>"
  (not-before nil)                ; universal time
  (not-after nil)                 ; universal time
  (common-names '())
  (dns-names '())
  (pem nil))

(defun certificate-fingerprint (info) (certificate-info-fingerprint info))
(defun certificate-not-before (info) (certificate-info-not-before info))
(defun certificate-not-after (info) (certificate-info-not-after info))
(defun certificate-common-names (info) (certificate-info-common-names info))
(defun certificate-dns-names (info) (certificate-info-dns-names info))

(defun certificate-expired-p (info &optional (now (get-universal-time)))
  (let ((after (certificate-info-not-after info)))
    (and after (> now after))))

(defun octets-hex (octets)
  (with-output-to-string (s)
    (loop for b across octets do (format s "~(~2,'0x~)" b))))

;; cl+ssl's CERTIFICATE-NOT-AFTER-TIME and CERTIFICATE-SUBJECT-COMMON-NAMES
;; call ASN1_STRING_data, which OpenSSL 4 removed.  These use calls every
;; OpenSSL since 1.1.1 has; cl+ssl's versions remain the fallback.

(defun asn1-time-universal-time (asn1-time)
  (unless (cffi:null-pointer-p asn1-time)
    ;; struct tm starts with nine ints: sec min hour mday mon year ...
    (cffi:with-foreign-object (tm :int 16)
      (when (= 1 (cffi:foreign-funcall "ASN1_TIME_to_tm" :pointer asn1-time :pointer tm :int))
        (flet ((field (i) (cffi:mem-aref tm :int i)))
          (encode-universal-time (field 0) (field 1) (field 2) (field 3)
                                 (1+ (field 4)) (+ 1900 (field 5)) 0))))))

(defun x509-validity (x509)
  (values
   (or (ignore-errors (asn1-time-universal-time
                       (cffi:foreign-funcall "X509_get0_notBefore" :pointer x509 :pointer)))
       (ignore-errors (cl+ssl::certificate-not-before-time x509)))
   (or (ignore-errors (asn1-time-universal-time
                       (cffi:foreign-funcall "X509_get0_notAfter" :pointer x509 :pointer)))
       (ignore-errors (cl+ssl::certificate-not-after-time x509)))))

(defun x509-subject-common-names (x509)
  (or (ignore-errors
       (let* ((name (cffi:foreign-funcall "X509_get_subject_name" :pointer x509 :pointer))
              (ptr (cffi:foreign-funcall "X509_NAME_oneline" :pointer name :pointer (cffi:null-pointer)
                                                             :int 0 :pointer)))
         (unless (cffi:null-pointer-p ptr)
           ;; "/C=US/O=Example/CN=example.org"
           (let ((text (cffi:foreign-string-to-lisp ptr)))
             (cffi:foreign-funcall "CRYPTO_free" :pointer ptr :string "gopher" :int 0 :void)
             (loop for part in (split-string text #\/)
                   when (alexandria:starts-with-subseq "CN=" part)
                     collect (subseq part 3))))))
      (ignore-errors (cl+ssl::certificate-subject-common-names x509))))

(defun x509-certificate-info (x509)
  (multiple-value-bind (not-before not-after) (x509-validity x509)
    (make-certificate-info
     :fingerprint (concatenate 'string "sha256:"
                               (octets-hex (cl+ssl:certificate-fingerprint x509 :sha256)))
     :not-before not-before
     :not-after not-after
     :common-names (x509-subject-common-names x509)
     :dns-names (ignore-errors (cl+ssl::certificate-dns-alt-names x509))
     :pem (ignore-errors (cl+ssl::certificate-pem x509)))))

(defun certificate-info-from-file (pathname)
  "CERTIFICATE-INFO for the PEM certificate in PATHNAME."
  (let ((x509 (cl+ssl::x509-cert-from-pem (alexandria:read-file-into-string pathname))))
    (when (cffi:null-pointer-p x509)
      (error 'tls-error :message (format nil "Cannot read a certificate from ~A" pathname)))
    (unwind-protect (x509-certificate-info x509)
      (cl+ssl::x509-free x509))))

;;; Connections

(defstruct connection
  socket
  stream
  (certificate nil)   ; CERTIFICATE-INFO when TLS
  (trust nil))        ; :new :trusted :changed :expired-replaced :unverified, when TLS

(defun ip-literal-p (host)
  (or (find #\: host)
      (every (lambda (c) (or (digit-char-p c) (char= c #\.))) host)))

(defun tcp-connect (request host port)
  (usocket:socket-connect host port
                          :element-type '(unsigned-byte 8)
                          :connection-timeout (shortest-timeout request (request-connect-timeout* request))
                          :read-timeout (shortest-timeout request (request-read-timeout* request))
                          :nodelay t))

;;; SOCKS5 (RFC 1928, username/password auth RFC 1929).  The target host name
;;; is sent to the proxy, which resolves it.

(defparameter *socks-replies*
  '((1 . "general SOCKS server failure") (2 . "connection not allowed by ruleset")
    (3 . "network unreachable") (4 . "host unreachable") (5 . "connection refused")
    (6 . "TTL expired") (7 . "command not supported") (8 . "address type not supported")))

(defun socks-read (stream n url)
  (let* ((buf (make-array n :element-type '(unsigned-byte 8)))
         (got (read-sequence buf stream)))
    (unless (= got n)
      (error 'connection-error :url url :message "SOCKS proxy closed the connection"))
    buf))

(defun socks-connect (request url proxy host port)
  "Connect to HOST:PORT through the SOCKS5 PROXY (a URL).  Returns the socket,
whose stream is now a tunnel to the target."
  (unless (member (url-scheme proxy) '("socks5" "socks5h") :test #'string=)
    (error 'connection-error :url url
                             :message (format nil "Unsupported proxy scheme ~S" (url-scheme proxy))))
  (let* ((socket (tcp-connect request (url-host proxy) (or (url-port proxy) 1080)))
         (stream (usocket:socket-stream socket))
         (ok nil))
    (register-socket request socket)
    (unwind-protect
         (flet ((out (&rest parts)
                  (dolist (p parts)
                    (if (integerp p) (write-byte p stream) (write-sequence p stream)))
                  (force-output stream)))
           (let* ((userinfo (url-userinfo proxy))
                  (colon (and userinfo (position #\: userinfo)))
                  (user (and userinfo (encode-text (percent-decode (subseq userinfo 0 colon)))))
                  (pass (and userinfo (encode-text (if colon (percent-decode (subseq userinfo (1+ colon))) "")))))
             (if user (out 5 2 0 2) (out 5 1 0))
             (let ((reply (socks-read stream 2 url)))
               (case (aref reply 1)
                 (0)
                 (2 (unless user
                      (error 'connection-error :url url :message "SOCKS proxy wants a password"))
                  (out 1 (length user) user (length pass) pass)
                  (unless (zerop (aref (socks-read stream 2 url) 1))
                    (error 'connection-error :url url :message "SOCKS proxy rejected the credentials")))
                 (t (error 'connection-error :url url :message "SOCKS proxy offered no usable authentication"))))
             (let ((name (encode-text host)))
               (out 5 1 0 3 (length name) name (ldb (byte 8 8) port) (ldb (byte 8 0) port)))
             (let* ((head (socks-read stream 4 url))
                    (rep (aref head 1)))
               (unless (zerop rep)
                 (error 'connection-error :url url
                                          :message (format nil "SOCKS proxy: ~A"
                                                           (or (cdr (assoc rep *socks-replies*))
                                                               (format nil "error ~D" rep)))))
               ;; Skip the bound address and port.
               (socks-read stream (+ 2 (ecase (aref head 3)
                                         (1 4) (4 16) (3 (aref (socks-read stream 1 url) 0))))
                           url))
             (setf ok t)
             socket))
      (unless ok
        (unregister-socket request socket)
        (ignore-errors (usocket:socket-close socket))))))

;;; The TLS context.  OpenSSL 4.1 offers by default signature algorithms some
;;; servers cannot parse: they answer the handshake with a decode_error alert
;;; (tlgs.one did, while TLS 1.2, or TLS 1.3 offering the usual list, worked).
;;; So the client offers the usual list.  The context is made when first
;;; needed and forgotten before an image is saved: a pointer from the build is
;;; garbage in the saved image.

(defparameter +client-sigalgs+
  (format nil "~{~A~^:~}"
          '("ECDSA+SHA256" "ECDSA+SHA384" "ECDSA+SHA512" "ed25519" "ed448"
            "rsa_pss_pss_sha256" "rsa_pss_pss_sha384" "rsa_pss_pss_sha512"
            "rsa_pss_rsae_sha256" "rsa_pss_rsae_sha384" "rsa_pss_rsae_sha512"
            "RSA+SHA256" "RSA+SHA384" "RSA+SHA512"))
  "The signature algorithms a client handshake offers.")

(defconstant +ssl-ctrl-set-sigalgs-list+ 98)

(defvar *client-context* nil)
(defvar *client-context-lock* (bt:make-lock "gopher tls context"))

(defun client-context ()
  "The SSL_CTX every client connection is made in."
  (bt:with-lock-held (*client-context-lock*)
    (or *client-context*
        (let ((context (cl+ssl:make-context :verify-mode cl+ssl:+ssl-verify-none+
                                            :verify-location nil)))
          (unless (= 1 (cffi:foreign-funcall "SSL_CTX_ctrl" :pointer context
                                             :int +ssl-ctrl-set-sigalgs-list+ :long 0
                                             :string +client-sigalgs+ :long))
            (warn "OpenSSL refused the signature algorithm list; using its own."))
          (setf *client-context* context)))))

(defun forget-client-context ()
  (setf *client-context* nil))

(pushnew 'forget-client-context sb-ext:*save-hooks*)

(defun open-connection (request url host port &key tls)
  "Connect to HOST:PORT, through the request's proxy if it has one.  With TLS
true, also run the TLS handshake and the TOFU check for that host.  Returns a
CONNECTION whose stream reads and writes octets."
  (check-cancelled request url)
  (let ((socket (if (request-proxy request)
                    (socks-connect request url (request-proxy request) host port)
                    (tcp-connect request host port))))
    (unless (request-proxy request) (register-socket request socket))
    ;; Clean up on a non-local exit only.  Not HANDLER-BIND: a TOFU mismatch
    ;; is signalled with restarts, and accepting it continues on this socket.
    (let ((ok nil))
     (unwind-protect
      (multiple-value-prog1
       (let ((stream (usocket:socket-stream socket)))
        (if (not tls)
            (make-connection :socket socket :stream stream)
            (let* ((ssl (cl+ssl:with-global-context ((client-context))
                          (cl+ssl:make-ssl-client-stream
                           stream
                           :unwrap-stream-p nil
                           :hostname (unless (ip-literal-p host) host)
                           :verify nil
                           :certificate (and (request-client-certificate request)
                                             (namestring (request-client-certificate request)))
                           :key (and (request-client-key request)
                                     (namestring (request-client-key request))))))
                   (x509 (cl+ssl::ssl-stream-x509-certificate ssl))
                   (info (if (or (null x509) (cffi:null-pointer-p x509))
                             (error 'tls-error :url url :message "Server sent no certificate")
                             (unwind-protect (x509-certificate-info x509)
                               (cl+ssl::x509-free x509))))
                   (trust (verify-server-certificate request url host port info)))
              (make-connection :socket socket :stream ssl
                               :certificate info :trust trust))))
       (setf ok t))
      (unless ok
        (unregister-socket request socket)
        (ignore-errors (usocket:socket-close socket)))))))

(defun close-connection (request connection)
  (when connection
    (ignore-errors (close (connection-stream connection)))
    (unregister-socket request (connection-socket connection))
    (ignore-errors (usocket:socket-close (connection-socket connection)))))

(defmacro with-connection ((var request url host port &rest keys) &body body)
  `(let ((,var (open-connection ,request ,url ,host ,port ,@keys)))
     (unwind-protect (progn ,@body)
       (close-connection ,request ,var))))

;;; Reading and writing

(defun write-octets (stream data)
  (let ((octets (etypecase data
                  (string (encode-text data))
                  (vector data))))
    (write-sequence octets stream)))

(defun send-line (connection string)
  "Send STRING followed by CRLF, then flush."
  (let ((stream (connection-stream connection)))
    (write-octets stream string)
    (write-octets stream #.(coerce #(13 10) '(vector (unsigned-byte 8))))
    (force-output stream)))

(defun read-header-line (stream &key (max 2048) url)
  "Read up to LF and return the line without CR/LF, decoded as UTF-8.
Returns NIL on EOF before any byte.  Signals PROTOCOL-ERROR past MAX bytes."
  (let ((buf (make-array 128 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (loop for b = (read-byte stream nil nil)
          do (cond ((null b)
                    (return (if (zerop (length buf)) nil (finish-line buf))))
                   ((= b 10) (return (finish-line buf)))
                   ((>= (length buf) max)
                    (error 'protocol-error :url url :message "Response header too long"))
                   (t (vector-push-extend b buf))))))

(defun finish-line (buf)
  (let ((end (if (and (plusp (length buf)) (= (aref buf (1- (length buf))) 13))
                 (1- (length buf))
                 (length buf))))
    (decode-text (subseq buf 0 end))))

(defun ssl-read-chunk (stream buffer end)
  ;; One SSL_read.  cl+ssl's READ-SEQUENCE loops until the buffer is full, so
  ;; an abrupt close part-way through would lose the bytes it had read.  Many
  ;; Gemini servers close without a TLS close_notify, which OpenSSL reports as
  ;; an error; that is treated as EOF.
  (let ((buf (cl+ssl::ssl-stream-input-buffer stream))
        (handle (cl+ssl::ssl-stream-handle stream)))
    (handler-case
        (let ((n (cffi:with-pointer-to-vector-data (ptr buf)
                   (cl+ssl::ensure-ssl-funcall stream #'plusp #'cl+ssl::ssl-read handle ptr
                                               (min end (cl+ssl::buffer-length buf))))))
          (cl+ssl::s/b-replace buffer buf :end1 n)
          n)
      (cl+ssl::ssl-error () 0))))

(defun fd-read-some (stream buffer end)
  ;; READ-SEQUENCE (and READ-N-BYTES) on an fd-stream wait for the whole
  ;; buffer.  Block for one byte instead, then take only what the stream has
  ;; already buffered, which cannot block.
  (let ((b (read-byte stream nil nil)))
    (if (null b)
        0
        (let* ((ibuf (sb-impl::fd-stream-ibuf stream))
               (avail (if ibuf (- (sb-impl::buffer-tail ibuf) (sb-impl::buffer-head ibuf)) 0))
               (n (min avail (1- end))))
          (setf (aref buffer 0) b)
          (when (plusp n) (read-sequence buffer stream :start 1 :end (1+ n)))
          (1+ n)))))

(defun read-chunk (stream buffer end)
  "Read at least one byte into BUFFER (up to END) and return the count, or 0
at EOF.  Returns as soon as some bytes are available, so streaming callers
see data as it arrives rather than when a buffer fills."
  (cond ((typep stream 'cl+ssl::ssl-stream)
         (ssl-read-chunk stream buffer end))
        ((typep stream 'sb-sys:fd-stream)
         (fd-read-some stream buffer end))
        (t (read-sequence buffer stream :end end))))

(defun read-body (stream request url &key (initial nil) (total nil) parse-as)
  "Read STREAM to EOF.  Returns the octets, or NIL when the request has a SINK
(the bytes went there instead), and the byte count as a second value.
Enforces MAX-SIZE, reports progress and honours cancellation.  Each chunk goes
to the request's ON-DATA; when it has ON-LINES and PARSE-AS (a MIME type,
or (MIME-TYPE . :GOPHER-TEXT) for a Gopher text item) names a text type,
complete lines are parsed and delivered as they arrive."
  (let* ((streamer (make-body-streamer request url parse-as))
         (sink (request-sink request))
         (max (request-max-size request))
         (progress (request-on-progress request))
         (out (unless sink
                (make-array (max 4096 (length initial)) :element-type '(unsigned-byte 8)
                                                        :adjustable t :fill-pointer 0)))
         (buffer (make-array 16384 :element-type '(unsigned-byte 8)))
         (count 0))
    (flet ((emit (octets end)
             (incf count end)
             (when (and max (not sink) (> count max))
               (error 'response-too-large :url url :limit max
                                          :message (format nil "Response exceeds ~D bytes" max)))
             (if sink
                 (write-sequence octets sink :end end)
                 (let ((start (fill-pointer out)))
                   (when (< (array-dimension out 0) (+ start end))
                     (setf out (adjust-array out (max (* 2 (array-dimension out 0)) (+ start end)))))
                   (setf (fill-pointer out) (+ start end))
                   (replace out octets :start1 start :end2 end)))
             (when streamer (stream-body-chunk streamer octets end))
             (when progress (funcall progress count total))))
      (when (and initial (plusp (length initial)))
        (emit initial (length initial)))
      (loop
        (check-cancelled request url)
        (when (and total (>= count total)) (return))
        (let ((n (read-chunk stream buffer (if total
                                               (min (length buffer) (- total count))
                                               (length buffer)))))
          (when (zerop n) (return))
          (emit buffer n)))
      ;; CANCEL-REQUEST shuts the socket down, which reads as a clean EOF.
      (check-cancelled request url)
      (when streamer (finish-body-streamer streamer))
      (when sink (finish-output sink))
      (values (and out (coerce out '(simple-array (unsigned-byte 8) (*)))) count))))
