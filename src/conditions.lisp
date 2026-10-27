;;;; conditions.lisp -- every failure the library reports.
;;;;
;;;; A protocol-level "no" from a server (Gemini 51, a Gopher error item, a
;;;; Spartan 4) is NOT signalled: it is a RESPONSE with that status, because a
;;;; browser shows it as a page.  Conditions are for when there is no usable
;;;; response at all.

(in-package #:gopher)

;; Defined later (tofu.lisp, transport.lisp); only the report uses them.
(declaim (notinline known-host-fingerprint certificate-fingerprint))

(define-condition small-web-error (error)
  ((url :initarg :url :initform nil :reader error-url)
   (message :initarg :message :initform nil :reader error-message))
  (:report (lambda (c s)
             (format s "~@[~A~]~@[ (~A)~]"
                     (or (error-message c) (type-of c))
                     (let ((u (error-url c)))
                       (if (or (null u) (stringp u)) u (url-string u))))))
  (:documentation "Root of every condition this library signals."))

(define-condition url-parse-error (small-web-error) ()
  (:documentation "A string could not be parsed as a URL."))

(define-condition connection-error (small-web-error) ()
  (:documentation "Could not connect, or the connection failed mid-request."))

(define-condition timeout-error (connection-error) ()
  (:documentation "Connecting or waiting for data took longer than the timeout."))

(define-condition tls-error (connection-error) ()
  (:documentation "The TLS handshake or a TLS read/write failed."))

(define-condition protocol-error (small-web-error) ()
  (:documentation "The server's reply does not follow the protocol."))

(define-condition response-too-large (small-web-error)
  ((limit :initarg :limit :reader error-limit))
  (:documentation "The body exceeded the MAX-SIZE given to FETCH."))

(define-condition unsupported-scheme (small-web-error)
  ((scheme :initarg :scheme :reader error-scheme))
  (:report (lambda (c s)
             (format s "No handler for the ~S scheme" (error-scheme c))))
  (:documentation "FETCH was given a URL whose scheme has no registered handler."))

(define-condition redirect-error (small-web-error) ()
  (:documentation "Too many redirects, or a redirect loop."))

(define-condition request-cancelled (small-web-error) ()
  (:report "The request was cancelled")
  (:documentation "CANCEL-REQUEST was called on the request's handle."))

(define-condition certificate-mismatch (tls-error)
  ((host :initarg :host :reader mismatch-host)
   (port :initarg :port :reader mismatch-port)
   (expected :initarg :expected :reader mismatch-expected
             :documentation "The KNOWN-HOST entry that was on record.")
   (certificate :initarg :certificate :reader mismatch-certificate
                :documentation "The CERTIFICATE-INFO the server presented."))
  (:report (lambda (c s)
             (format s "The certificate for ~A:~D changed.~%  on record: ~A~%  presented: ~A"
                     (mismatch-host c) (mismatch-port c)
                     (known-host-fingerprint (mismatch-expected c))
                     (certificate-fingerprint (mismatch-certificate c)))))
  (:documentation
   "Trust-on-first-use: the host presented a certificate different from the
unexpired one on record.  Restarts: ACCEPT-NEW-CERTIFICATE records the new one
and continues; REJECT-CERTIFICATE aborts with this error."))

(defun accept-new-certificate (&optional condition)
  "Invoke the ACCEPT-NEW-CERTIFICATE restart for a CERTIFICATE-MISMATCH."
  (let ((r (find-restart 'accept-new-certificate condition)))
    (when r (invoke-restart r))))

(defun reject-certificate (&optional condition)
  "Invoke the REJECT-CERTIFICATE restart for a CERTIFICATE-MISMATCH."
  (let ((r (find-restart 'reject-certificate condition)))
    (when r (invoke-restart r))))
