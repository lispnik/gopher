;;;; test/gemini-tests.lisp

(in-package #:gopher/test)

(def-suite gemini :in gopher)
(in-suite gemini)

(defun gemini-fixture (stream)
  (let* ((line (read-request-line stream))
         (url (parse-url line))
         (path (url-path url)))
    (note *server* line)
    (flet ((path= (p) (string= path p)))
      (cond
        ((path= "/") (send stream (crlf "20 text/gemini; charset=utf-8") (format nil "# Home~%=> page.gmi A page~%")))
        ((path= "/plain") (send stream (crlf "20 text/plain") "just text"))
        ((path= "/nomime") (send stream (crlf "20") "=> x"))
        ((path= "/latin1") (send stream (crlf "20 text/plain; charset=iso-8859-1")
                                 (coerce #(99 97 102 233) '(vector (unsigned-byte 8)))))
        ((path= "/input") (if (url-query url)
                              (send stream (crlf "20 text/gemini") (format nil "You said ~A" (percent-decode (url-query url))))
                              (send stream (crlf "10 What is your name?"))))
        ((path= "/secret") (send stream (crlf "11 Password")))
        ((path= "/r1") (send stream (crlf "30 /r2")))
        ((path= "/r2") (send stream (crlf "31 r3")))
        ((path= "/r3") (send stream (crlf "20 text/gemini") "# arrived"))
        ((path= "/loop") (send stream (crlf "30 /loop2")))
        ((path= "/loop2") (send stream (crlf "30 /loop")))
        ((path= "/away") (send stream (crlf "30 https://example.org/")))
        ((path= "/missing") (send stream (crlf "51 Not here")))
        ((path= "/odd") (send stream (crlf "57 Unusual permanent failure")))
        ((path= "/garbage") (send stream (crlf "HELLO")))
        ((path= "/silent") nil)
        ((path= "/big") (send stream (crlf "20 application/octet-stream")
                              (make-array 100000 :element-type '(unsigned-byte 8) :initial-element 7)))
        ((path= "/abrupt") (send stream (crlf "20 text/plain") "cut off without close_notify")
         :abrupt)
        ((path= "/whoami")
         (let ((x509 (cl+ssl::ssl-stream-x509-certificate stream)))
           (if (or (null x509) (cffi:null-pointer-p x509))
               (send stream (crlf "60 Certificate required"))
               (send stream (crlf "20 text/plain")
                     (format nil "Hello ~A" (gopher::certificate-fingerprint
                                             (gopher::x509-certificate-info x509)))))))
        ((string= (url-scheme url) "titan")
         (let* ((size (parse-integer (cdr (assoc "size" (url-titan-parameters url) :test #'string=))))
                (body (read-n-octets stream size)))
           (note *server* (babel:octets-to-string body))
           (send stream (crlf (format nil "30 gemini://127.0.0.1:~D/uploaded" (fixture-server-port *server*))))))
        ((path= "/uploaded") (send stream (crlf "20 text/gemini") "# Thanks"))
        (t (send stream (crlf "51 Unknown")))))))

(defmacro with-gemini ((server) &body body)
  `(with-server (,server #'gemini-fixture :tls t)
     (let ((*known-hosts* (make-memory-known-hosts)))
       ,@body)))

(test header-parsing
  (is (equal '(20 "text/gemini") (multiple-value-list (gopher::parse-gemini-header "20 text/gemini" nil))))
  (is (equal '(20 "") (multiple-value-list (gopher::parse-gemini-header "20" nil))))
  (signals protocol-error (gopher::parse-gemini-header "2 x" nil))
  (signals protocol-error (gopher::parse-gemini-header "20text" nil))
  (signals protocol-error (gopher::parse-gemini-header "99 x" nil)))

(test status-keywords
  (is (eq :input (gemini-status-keyword 10)))
  (is (eq :not-found (gemini-status-keyword 51)))
  (is (eq :permanent-failure (gemini-status-keyword 57)))
  (is (eq :client-certificate-required (gemini-status-keyword 60)))
  (is (null (gemini-status-keyword 99))))

(test fetch-gemtext
  (with-gemini (s)
    (let* ((r (fetch (local-url "gemini" s "/")))
           (doc (response-document r)))
      (is (eq :success (response-status r)))
      (is (= 20 (response-status-code r)))
      (is (string= (format nil "gemini://127.0.0.1:~D/" (fixture-server-port s)) (first (server-log s)))
          "the request is the absolute URL")
      (is (string= "Home" (document-title doc)))
      (is (string= (local-url "gemini" s "/page.gmi") (line-url (first (document-links doc))))))))

(test fragment-is-not-sent
  (with-gemini (s)
    (fetch (local-url "gemini" s "/#section"))
    (is (not (find #\# (first (server-log s)))))))

(test mime-handling
  (with-gemini (s)
    (is (eq :text (document-kind (response-document (fetch (local-url "gemini" s "/plain"))))))
    (let ((r (fetch (local-url "gemini" s "/nomime"))))
      (is (string= "text/gemini; charset=utf-8" (response-mime-type r)))
      (is (eq :gemtext (document-kind (response-document r)))))
    (is (string= "café" (response-text (fetch (local-url "gemini" s "/latin1")))))))

(test input-and-query
  (with-gemini (s)
    (let ((r (fetch (local-url "gemini" s "/input"))))
      (is (eq :input (response-status r)))
      (is (string= "What is your name?" (response-meta r))))
    (is (response-sensitive-input-p (fetch (local-url "gemini" s "/secret"))))
    (let ((r (fetch (local-url "gemini" s "/input") :query "Ada Lovelace & co")))
      (is (string= "You said Ada Lovelace & co" (response-text r)))
      (is (search "/input?Ada%20Lovelace%20%26%20co" (car (last (server-log s))))))))

(test redirects
  (with-gemini (s)
    (let ((r (fetch (local-url "gemini" s "/r1"))))
      (is (eq :success (response-status r)))
      (is (string= (local-url "gemini" s "/r3") (url-string (response-url r))))
      (is (equal (list (local-url "gemini" s "/r1") (local-url "gemini" s "/r2"))
                 (response-redirects r))))
    (let ((r (fetch (local-url "gemini" s "/r1") :follow-redirects nil)))
      (is (eq :redirect (response-status r)))
      (is (string= (local-url "gemini" s "/r2") (url-string (response-redirect-url r)))))
    (signals redirect-error (fetch (local-url "gemini" s "/loop")))
    (signals redirect-error (fetch (local-url "gemini" s "/r1") :max-redirects 1))
    ;; Another scheme is the caller's decision.
    (let ((r (fetch (local-url "gemini" s "/away"))))
      (is (eq :redirect (response-status r)))
      (is (string= "https://example.org/" (url-string (response-redirect-url r)))))))

(test failures-are-responses
  (with-gemini (s)
    (let ((r (fetch (local-url "gemini" s "/missing"))))
      (is (eq :not-found (response-status r)))
      (is (eq :permanent-failure (response-category r)))
      (is (string= "Not here" (response-meta r)))
      (is (null (response-document r))))
    (is (eq :permanent-failure (response-status (fetch (local-url "gemini" s "/odd")))))))

(test protocol-errors
  (with-gemini (s)
    (signals protocol-error (fetch (local-url "gemini" s "/garbage")))
    (signals protocol-error (fetch (local-url "gemini" s "/silent")))
    (signals protocol-error (fetch (local-url "gemini" s (format nil "/~A" (make-string 1100 :initial-element #\a)))))))

(test size-limit-sink-and-progress
  (with-gemini (s)
    (signals response-too-large (fetch (local-url "gemini" s "/big") :max-size 1000))
    (let* ((calls 0)
           (sink (flexi-free-octet-sink))
           (r (fetch (local-url "gemini" s "/big") :sink (car sink) :max-size 10
                     :on-progress (lambda (n total) (declare (ignore total)) (setf calls n)))))
      (is (null (response-body r)) "the body went to the sink")
      (is (= 100000 (response-bytes-read r)))
      (is (= 100000 calls))
      (is (= 100000 (length (funcall (cdr sink))))))))

(defun flexi-free-octet-sink ()
  "A binary output stream and a function returning what was written."
  (let* ((path (temp-path "sink"))
         (out (open path :direction :output :element-type '(unsigned-byte 8) :if-exists :supersede)))
    (cons out (lambda ()
                (close out)
                (prog1 (alexandria:read-file-into-byte-vector path)
                  (delete-file path))))))

(test abrupt-close-keeps-the-body
  (with-gemini (s)
    (is (string= "cut off without close_notify"
                 (response-text (fetch (local-url "gemini" s "/abrupt")))))))

(test client-certificates
  (with-server (s #'gemini-fixture :tls t :request-client-cert t)
    (let ((*known-hosts* (make-memory-known-hosts))
          (url (local-url "gemini" s "/whoami")))
      (is (eq :client-certificate-required (response-status (fetch url))))
      (let ((r (fetch url :client-certificate (fixture "client-cert.pem")
                          :client-key (fixture "client-key.pem"))))
        (is (eq :success (response-status r)))
        (is (string= (format nil "Hello ~A" (certificate-fingerprint (certificate-info-from-file* "client-cert.pem")))
                     (response-text r)))))))

(test titan-upload
  (with-gemini (s)
    (let ((r (upload (local-url "gemini" s "/wiki/page") "new page text"
                     :mime-type "text/gemini" :token "secret")))
      (is (eq :success (response-status r)))
      (is (string= "# Thanks" (response-text r)))
      (destructuring-bind (request body &rest rest) (server-log s)
        (declare (ignore rest))
        (is (string= (format nil "titan://127.0.0.1:~D/wiki/page;mime=text/gemini;size=13;token=secret"
                             (fixture-server-port s))
                     request))
        (is (string= "new page text" body))))))
