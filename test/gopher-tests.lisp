;;;; test/gopher-tests.lisp

(in-package #:gopher/test)

(def-suite gopher-protocol :in gopher)
(in-suite gopher-protocol)

(defparameter *menu*
  (crlf (format nil "iWelcome!~Cfake~C(NULL)~C0" #\Tab #\Tab #\Tab)
        (format nil "1Software~C/software~Cexample.org~C70" #\Tab #\Tab #\Tab)
        (format nil "0About this server~C/about.txt~Cexample.org~C7070~C+" #\Tab #\Tab #\Tab #\Tab)
        (format nil "7Search~C/search~Cexample.org~C70" #\Tab #\Tab #\Tab)
        (format nil "hWeb site~CURL:https://example.org/~Cexample.org~C70" #\Tab #\Tab #\Tab)
        (format nil "8Old BBS~Cguest~Cbbs.example.org~C23" #\Tab #\Tab #\Tab)
        (format nil "3Oops~C~Cerror.host~C1" #\Tab #\Tab #\Tab)
        "this line is not a menu line"
        (format nil "IA picture~C/pics/cat.jpg~Cexample.org~C70" #\Tab #\Tab #\Tab)
        "."
        "ignored after terminator"))

(test parse-menu
  (let* ((doc (parse-gopher-menu *menu* (parse-url "gopher://example.org/")))
         (lines (coerce (document-lines doc) 'list)))
    (is (eq :menu (document-kind doc)))
    (is (= 9 (length lines)))
    (is (equal '(:text :link :link :link :link :link :error :text :link) (mapcar #'line-kind lines)))
    (is (string= "Welcome!" (line-text (first lines))))
    (is (eq :info (line-item-kind (first lines))))
    (is (string= "gopher://example.org/1/software" (line-url (second lines))))
    (is (eq :menu (line-item-kind (second lines))))
    (is (string= "gopher://example.org:7070/0/about.txt" (line-url (third lines))))
    (is-true (line-gopher-plus-p (third lines)))
    (is-false (line-gopher-plus-ask-p (third lines)))
    (is (eq :search (line-item-kind (fourth lines))))
    (is (string= "https://example.org/" (line-url (fifth lines))))
    (is (string= "telnet://guest@bbs.example.org" (line-url (sixth lines))))
    (is (string= "this line is not a menu line" (line-text (eighth lines))))
    (is (eq :image (line-item-kind (ninth lines))))))

(test gopher-plus-form-items-are-marked
  (let ((line (gopher::parse-gopher-menu-line (format nil "0Survey~C/survey~Chost~C70~C?" #\Tab #\Tab #\Tab #\Tab)
                                      (parse-url "gopher://host/"))))
    (is-true (line-gopher-plus-p line))
    (is-true (line-gopher-plus-ask-p line))))

(test parse-menu-tolerates-lf-and-no-terminator
  (let ((doc (parse-gopher-menu (format nil "1A~C/a~Ch~C70~%1B~C/b~Ch~C70~%" #\Tab #\Tab #\Tab #\Tab #\Tab #\Tab))))
    (is (= 2 (length (document-links doc))))))

(test gophers-links-stay-on-tls-for-same-server
  (let ((doc (parse-gopher-menu (crlf (format nil "1Here~C/x~Ch~C70" #\Tab #\Tab #\Tab)
                                      (format nil "1There~C/y~Cother~C70" #\Tab #\Tab #\Tab))
                                (parse-url "gophers://h/"))))
    (is (equal '("gophers://h/1/x" "gopher://other/1/y") (mapcar #'line-url (document-links doc))))))

(test unstuff-text
  (flet ((u (s) (babel:octets-to-string (gopher-unstuff-text (babel:string-to-octets s)))))
    (is (string= (crlf "hello" "world") (u (crlf "hello" "world" "."))))
    (is (string= (crlf ".dotted" "x") (u (crlf "..dotted" "x" "."))))
    (is (string= (format nil "a~%") (u (format nil "a~%.~%"))))
    (is (string= (crlf "no terminator") (u (crlf "no terminator"))))
    (is (string= "" (u (crlf "."))))))

(test item-types
  (is (eq :menu (gopher-item-kind #\1)))
  (is (eq :unknown (gopher-item-kind #\Z)))
  (is (string= "image/gif" (gopher-item-mime-type #\g)))
  (is (string= "image/jpeg" (gopher-item-mime-type #\I "/x/cat.jpeg")))
  (is (string= "application/octet-stream" (gopher-item-mime-type #\9 "/bin/file"))))

(test request-lines
  (is (string= "/sel" (gopher::build-gopher-request "/sel" nil nil)))
  (is (string= (format nil "/s~Cq" #\Tab) (gopher::build-gopher-request "/s" "q" nil)))
  (is (string= (format nil "/s~C!" #\Tab) (gopher::build-gopher-request "/s" nil "!")))
  (is (string= (format nil "/s~Cq~C+" #\Tab #\Tab) (gopher::build-gopher-request "/s" "q" "+"))))

;;; Against a fixture server

(defun gopher-fixture (stream)
  (let ((line (read-request-line stream)))
    (note *server* line)
    (let* ((tab (position #\Tab line))
           (selector (subseq line 0 tab))
           (search (and tab (subseq line (1+ tab)))))
      (cond
        ((string= selector "")
         (send stream (crlf (format nil "iHello~C~Cx~C0" #\Tab #\Tab #\Tab)
                            (format nil "0Doc~C/doc~C127.0.0.1~C70" #\Tab #\Tab #\Tab)
                            ".")))
        ((string= selector "/doc")
         (send stream (crlf "First line" "..starts with a dot" ".")))
        ((string= selector "/search")
         (send stream (crlf (format nil "0Result for ~A~C/r~C127.0.0.1~C70" search #\Tab #\Tab #\Tab) ".")))
        ((string= selector "/bin")
         (send stream (coerce #(0 1 2 255 46 13 10) '(vector (unsigned-byte 8)))))
        (t (send stream (crlf (format nil "3'~A' does not exist~C~Cerror.host~C1" selector #\Tab #\Tab #\Tab) ".")))))))

(test fetch-menu
  (with-server (s #'gopher-fixture)
    (let* ((r (fetch (local-url "gopher" s "/")))
           (doc (response-document r)))
      (is (eq :success (response-status r)))
      (is (eq :gopher (response-protocol r)))
      (is (equal '("") (server-log s)))
      (is (eq :menu (document-kind doc)))
      (is (= 1 (length (document-links doc)))))))

(test fetch-text-is-unstuffed
  (with-server (s #'gopher-fixture)
    (let ((r (fetch (local-url "gopher" s "/0/doc"))))
      (is (string= "text/plain" (response-mime-type r)))
      (is (string= (crlf "First line" ".starts with a dot") (response-text r)))
      (is (eq :text (document-kind (response-document r)))))))

(test fetch-search
  (with-server (s #'gopher-fixture)
    (let ((r (fetch (local-url "gopher" s "/7/search") :query "lisp")))
      (is (equal (list (format nil "/search~Clisp" #\Tab)) (server-log s)))
      (is (search "Result for lisp" (line-text (first (document-links (response-document r)))))))
    ;; The search string can also come from the URL.
    (let ((r (fetch (local-url "gopher" s "/7/search%09cobol"))))
      (is (search "cobol" (response-text r))))))

(test search-without-query-asks-for-input
  (let ((r (fetch "gopher://127.0.0.1:1/7/search")))   ; no connection is made
    (is (eq :input (response-status r)))
    (is-true (response-input-p r))))

(test fetch-binary-untouched
  (with-server (s #'gopher-fixture)
    (let ((r (fetch (local-url "gopher" s "/9/bin"))))
      (is (equalp #(0 1 2 255 46 13 10) (response-body r)))
      (is (null (response-document r))))))

(test fetch-binary-to-a-sink-counts-its-bytes
  ;; The body goes to the sink, so the count is all that says how much came.
  (with-server (s #'gopher-fixture)
    (let* ((sink (flexi-free-octet-sink))
           (r (fetch (local-url "gopher" s "/9/bin") :sink (car sink))))
      (is (null (response-body r)))
      (is (= 7 (response-bytes-read r)))
      (is (equalp #(0 1 2 255 46 13 10) (funcall (cdr sink)))))))

(test fetch-error-menu-is-not-found
  (with-server (s #'gopher-fixture)
    (let ((r (fetch (local-url "gopher" s "/1/missing"))))
      (is (eq :not-found (response-status r)))
      (is (search "does not exist" (response-meta r))))
    (let ((r (fetch (local-url "gopher" s "/0/missing"))))
      (is (eq :not-found (response-status r))))))

(test html-and-telnet-items-redirect-elsewhere
  (let ((r (fetch "gopher://127.0.0.1:1/hURL:https://example.org/")))
    (is (eq :redirect (response-status r)))
    (is (string= "https://example.org/" (url-string (response-redirect-url r)))))
  (let ((r (fetch "gopher://bbs.example.org:2323/8guest")))
    (is (eq :redirect (response-status r)))
    (is (string= "telnet://guest@bbs.example.org:2323" (response-meta r)))))

(test gophers-over-tls
  (with-server (s #'gopher-fixture :tls t)
    (let ((r (fetch (local-url "gophers" s "/") :known-hosts (make-memory-known-hosts))))
      (is (eq :success (response-status r)))
      (is (eq :new (response-trust r)))
      (is-true (certificate-info-p (response-certificate r))))))

(test gopher-tls-try-falls-back-to-plain
  (with-server (s #'gopher-fixture)
    (let ((r (fetch (local-url "gopher" s "/0/doc") :tls :try :timeout 5)))
      (is (eq :success (response-status r)))
      (is (null (response-certificate r))))))

(defun start-silent-tls-server ()
  "A server on one port that answers a TLS handshake and then hangs up without
a byte, and answers plain Gopher with the fixture: what gopher.quux.org does.
A connection's first byte tells them apart (22 begins a TLS handshake).
Returns the listening socket and its thread."
  (let* ((listen (usocket:socket-listen "127.0.0.1" 0 :reuse-address t
                                                     :element-type '(unsigned-byte 8)))
         (thread
           (bt:make-thread
            (lambda ()
              (loop
                (let ((client (ignore-errors (usocket:socket-accept listen))))
                  (unless client (return))
                  (ignore-errors
                   (let ((first (make-array 1 :element-type '(unsigned-byte 8))))
                     (sb-bsd-sockets:socket-receive (usocket:socket client) first 1 :peek t)
                     (if (= 22 (aref first 0))
                         (close (cl+ssl:make-ssl-server-stream
                                 (usocket:socket-stream client)
                                 :certificate (namestring (fixture "server-cert.pem"))
                                 :key (namestring (fixture "server-key.pem"))))
                         ;; The fixture notes each request on the server running it.
                         (let ((*server* (make-fixture-server)))
                           (gopher-fixture (usocket:socket-stream client))
                           (force-output (usocket:socket-stream client))))))
                  (ignore-errors (usocket:socket-close client)))))
            :name "silent tls server")))
    (values listen thread)))

(test gopher-tls-try-falls-back-when-tls-is-silent
  (multiple-value-bind (listen thread) (start-silent-tls-server)
    (unwind-protect
         (let* ((port (usocket:get-local-port listen))
                (r (fetch (format nil "gopher://127.0.0.1:~D/0/doc" port)
                          :tls :try :timeout 5 :known-hosts (make-memory-known-hosts))))
           (is (eq :success (response-status r)))
           (is (plusp (response-bytes-read r)) "the plain answer, not the silent TLS one")
           (is (null (response-certificate r)))
           (is (eq :plain (gopher-tls-status "127.0.0.1" port)))
           ;; A Gopher+ request, whose reply begins with a header line: the
           ;; silence is an EOF in the middle of TLS, and that falls back too.
           (forget-gopher-tls-status "127.0.0.1" port)
           (let ((plus (fetch (format nil "gopher://127.0.0.1:~D/0/doc" port)
                              :tls :try :gopher-plus "!" :timeout 5
                              :known-hosts (make-memory-known-hosts))))
             (is (null (response-certificate plus)))
             (is (eq :plain (gopher-tls-status "127.0.0.1" port)))))
      (usocket:socket-close listen)
      (ignore-errors (bt:join-thread thread)))))

(test gopher-tls-try-uses-tls-when-offered
  (with-server (s #'gopher-fixture :tls t)
    (let ((r (fetch (local-url "gopher" s "/0/doc") :tls :try
                                                    :known-hosts (make-memory-known-hosts))))
      (is (eq :success (response-status r)))
      (is-true (response-certificate r)))))
