;;;; test/tofu-tests.lisp

(in-package #:gopher/test)

(def-suite tofu :in gopher)
(in-suite tofu)

(defun gemini-ok (stream)
  (note *server* (read-request-line stream))
  (send stream (crlf "20 text/gemini") "# ok"))

(defun temp-path (name)
  (merge-pathnames (format nil "gopher-test-~A-~A" (random 1000000) name) (uiop:temporary-directory)))

(test memory-store
  (let ((store (make-memory-known-hosts)))
    (store-known-host store (make-known-host :host "h" :port 1965 :fingerprint "sha256:aa"))
    (is (string= "sha256:aa" (known-host-fingerprint (lookup-known-host store "H" 1965))))
    (is (null (lookup-known-host store "h" 1966)))
    (forget-known-host store "h" 1965)
    (is (null (list-known-hosts store)))))

(test file-store-persists
  (let ((path (temp-path "known_hosts")))
    (unwind-protect
         (progn
           (let ((store (make-file-known-hosts path)))
             (store-known-host store (make-known-host :host "a.example" :port 1965
                                                      :fingerprint "sha256:01" :expires 4000000000))
             (store-known-host store (make-known-host :host "b.example" :port 70 :fingerprint "sha256:02")))
           (let* ((again (make-file-known-hosts path))
                  (a (lookup-known-host again "a.example" 1965)))
             (is (= 2 (length (list-known-hosts again))))
             (is (string= "sha256:01" (known-host-fingerprint a)))
             (is (= 4000000000 (known-host-expires a)))
             (is (null (known-host-expires (lookup-known-host again "b.example" 70))))
             (forget-known-host again "b.example" 70))
           (is (= 1 (length (list-known-hosts (make-file-known-hosts path))))))
      (ignore-errors (delete-file path)))))

(test first-use-then-trusted
  (let ((store (make-memory-known-hosts)))
    (with-server (s #'gemini-ok :tls t)
      (let ((url (local-url "gemini" s "/")))
        (is (eq :new (response-trust (fetch url :known-hosts store))))
        (is (eq :trusted (response-trust (fetch url :known-hosts store))))
        (is (string= (certificate-fingerprint (certificate-info-from-file* "server-cert.pem"))
                     (known-host-fingerprint
                      (lookup-known-host store "127.0.0.1" (fixture-server-port s)))))))))

(defun certificate-info-from-file* (name)
  (gopher::certificate-info-from-file (fixture name)))

(defun with-changed-certificate (fn)
  "Trust the server certificate for a port, then serve the other one there."
  (let ((store (make-memory-known-hosts)))
    (with-server (s #'gemini-ok :tls t)
      (fetch (local-url "gemini" s "/") :known-hosts store)
      (let ((port (fixture-server-port s)))
        (stop-server s)
        (with-server (s2 #'gemini-ok :tls t :port port
                                     :certificate (fixture "other-cert.pem")
                                     :key (fixture "other-key.pem"))
          (funcall fn (local-url "gemini" s2 "/") store port))))))

(test changed-certificate-signals
  (with-changed-certificate
   (lambda (url store port)
     (declare (ignore port))
     (signals certificate-mismatch (fetch url :known-hosts store))
     (signals tls-error (handler-bind ((certificate-mismatch #'reject-certificate))
                          (fetch url :known-hosts store))))))

(test accept-changed-certificate-continues
  (with-changed-certificate
   (lambda (url store port)
     (let ((r (handler-bind ((certificate-mismatch #'accept-new-certificate))
                (fetch url :known-hosts store))))
       (is (eq :success (response-status r)))
       (is (eq :changed (response-trust r)))
       (is (string= (certificate-fingerprint (certificate-info-from-file* "other-cert.pem"))
                    (known-host-fingerprint (lookup-known-host store "127.0.0.1" port))))
       (is (eq :trusted (response-trust (fetch url :known-hosts store))))))))

(test expired-record-is-replaced
  (with-server (s #'gemini-ok :tls t)
    (let ((store (make-memory-known-hosts)))
      (store-known-host store (make-known-host :host "127.0.0.1" :port (fixture-server-port s)
                                               :fingerprint "sha256:old" :expires 100))
      (is (eq :expired-replaced (response-trust (fetch (local-url "gemini" s "/") :known-hosts store)))))))

(test verify-none-and-custom
  (with-server (s #'gemini-ok :tls t)
    (let ((url (local-url "gemini" s "/")))
      (is (eq :unverified (response-trust (fetch url :verify :none))))
      (is (eq :trusted (response-trust (fetch url :verify (lambda (cert host port)
                                                           (declare (ignore host port))
                                                           (certificate-info-p cert))))))
      (signals tls-error (fetch url :verify (constantly nil))))))

(test certificate-details
  (let ((c (certificate-info-from-file* "server-cert.pem")))
    (is (alexandria:starts-with-subseq "sha256:" (certificate-fingerprint c)))
    (is (= (+ 7 64) (length (certificate-fingerprint c))))
    (is (equal '("localhost") (certificate-common-names c)))
    (is (< (certificate-not-before c) (get-universal-time) (certificate-not-after c)))
    (is-false (certificate-expired-p c))))
