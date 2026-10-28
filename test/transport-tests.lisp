;;;; test/transport-tests.lisp -- failures, timeouts, cancellation.

(in-package #:gopher/test)

(def-suite transport :in gopher)
(in-suite transport)

(defun stall-fixture (stream)
  (read-request-line stream)
  (sleep 10))

(defun closed-port ()
  (with-server (s (lambda (stream) (declare (ignore stream)))) (fixture-server-port s)))

(test connection-refused
  (signals connection-error (fetch (format nil "gopher://127.0.0.1:~D/" (closed-port)) :timeout 2)))

(test read-timeout
  (with-server (s #'stall-fixture)
    (let ((start (get-internal-real-time)))
      (signals timeout-error (fetch (local-url "gopher" s "/") :timeout 1))
      (is (< (/ (- (get-internal-real-time) start) internal-time-units-per-second) 5)))))

(test tls-read-timeout
  (with-server (s #'stall-fixture :tls t)
    (signals timeout-error (fetch (local-url "gemini" s "/") :timeout 1
                                                             :known-hosts (make-memory-known-hosts)))))

(test cancel-from-another-thread
  (with-server (s #'stall-fixture)
    (let* ((handle (make-request-handle))
           (result nil)
           (thread (bt:make-thread
                    (lambda ()
                      (setf result
                            (handler-case (fetch (local-url "gopher" s "/") :timeout 20 :handle handle)
                              (request-cancelled () :cancelled)
                              (error (e) e)))))))
      (sleep 0.3)
      (cancel-request handle)
      (bt:join-thread thread)
      (is (eq :cancelled result))
      (is-true (request-handle-cancelled-p handle)))))

(test cancelled-handle-stops-before-connecting
  (let ((handle (make-request-handle)))
    (cancel-request handle)
    (signals request-cancelled (fetch "gopher://127.0.0.1:1/" :handle handle))))

(test unsupported-scheme-signals
  (signals unsupported-scheme (fetch "https://example.org/"))
  (signals unsupported-scheme (upload "gopher://h/" "data")))

(test registry-lists-schemes
  (is (equal '("finger" "gemini" "gopher" "gophers" "guppy" "nex" "spartan" "titan")
             (supported-schemes))))

(test tls-handshake-against-plain-server
  (with-server (s (lambda (stream) (read-request-line stream) (send stream "not tls")))
    (signals tls-error (fetch (local-url "gemini" s "/") :timeout 3
                                                         :known-hosts (make-memory-known-hosts)))))

(test render-document-numbers-links
  (let* ((doc (parse-gemtext (format nil "# T~%=> gemini://a/ A~%text~%=> gemini://b/ B~%")))
         (out (make-string-output-stream))
         (links (render-document doc :stream out)))
    (is (equalp #("gemini://a/" "gemini://b/") links))
    (is (search "[2] B <gemini://b/>" (get-output-stream-string out)))))

(test the-client-context-offers-the-usual-signature-algorithms
  ;; OpenSSL 4.1's own list made tlgs.one refuse the handshake (decode_error).
  ;; A list OpenSSL refuses only warns, so a warning here means it was refused.
  (gopher::forget-client-context)
  (let ((warned nil))
    (handler-bind ((warning (lambda (w) (setf warned w) (muffle-warning w))))
      (is (not (cffi:null-pointer-p (gopher::client-context)))))
    (is (null warned)))
  (is (eq (gopher::client-context) (gopher::client-context)) "made once")
  (is (member 'gopher::forget-client-context sb-ext:*save-hooks*)
      "forgotten before an image is saved"))
