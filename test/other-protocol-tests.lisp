;;;; test/other-protocol-tests.lisp -- Spartan, Nex, Finger.

(in-package #:gopher/test)

(def-suite other-protocols :in gopher)
(in-suite other-protocols)

(defun spartan-fixture (stream)
  (let* ((line (read-request-line stream))
         (parts (gopher::split-string line #\Space))
         (path (second parts))
         (length (parse-integer (third parts)))
         (data (babel:octets-to-string (read-n-octets stream length))))
    (note *server* (list line data))
    (cond ((string= path "/") (send stream (crlf "2 text/gemini") (format nil "# Spartan~%=: /echo Say something~%")))
          ((string= path "/echo") (send stream (crlf "2 text/plain") (format nil "got ~D: ~A" length data)))
          ((string= path "/old") (send stream (crlf "3 /")))
          ((string= path "/bad") (send stream (crlf "4 Bad request")))
          ((string= path "/down") (send stream (crlf "5 Server error")))
          (t (send stream (crlf "4 Not found"))))))

(test spartan-basics
  (with-server (s #'spartan-fixture)
    (let* ((r (fetch (local-url "spartan" s "")))
           (prompt (first (document-links (response-document r)))))
      (is (eq :success (response-status r)))
      (is (equal '(("127.0.0.1 / 0" "")) (server-log s)))
      (is (eq :input-prompt (line-kind prompt)))
      (is (string= (local-url "spartan" s "/echo") (line-url prompt))))))

(test spartan-data
  (with-server (s #'spartan-fixture)
    (is (string= "got 5: hello" (response-text (fetch (local-url "spartan" s "/echo") :query "hello"))))
    (is (string= "got 4: a b?" (response-text (fetch (local-url "spartan" s "/echo?a%20b%3F")))))
    (is (string= "got 7: uploads" (response-text (upload (local-url "spartan" s "/echo") "uploads"))))))

(test spartan-statuses
  (with-server (s #'spartan-fixture)
    (let ((r (fetch (local-url "spartan" s "/old"))))
      (is (eq :success (response-status r)))
      (is (equal (list (local-url "spartan" s "/old")) (response-redirects r))))
    (is (eq :bad-request (response-status (fetch (local-url "spartan" s "/bad")))))
    (let ((r (fetch (local-url "spartan" s "/down"))))
      (is (eq :server-error (response-status r)))
      (is (eq :temporary-failure (response-category r))))))

(defun nex-fixture (stream)
  (let ((line (read-request-line stream)))
    (note *server* line)
    (cond ((or (string= line "") (string= line "docs/"))
           (send stream (format nil "Welcome to nex~%=> docs/ Documents~%=> notes.txt~%=> nex://elsewhere/ Far away~%")))
          ((string= line "notes.txt") (send stream "Some notes"))
          ((string= line "pic.png") (send stream (coerce #(137 80 78 71) '(vector (unsigned-byte 8)))))
          (t (send stream "no such file")))))

(test nex-directory-and-files
  (with-server (s #'nex-fixture)
    (let* ((r (fetch (local-url "nex" s "/")))
           (doc (response-document r)))
      (is (string= "text/x-nex-directory" (response-mime-type r)))
      (is (eq :nex-directory (document-kind doc)))
      (is (equal (list (local-url "nex" s "/docs/") (local-url "nex" s "/notes.txt") "nex://elsewhere/")
                 (mapcar #'line-url (document-links doc))))
      (is (string= "Welcome to nex" (line-text (aref (document-lines doc) 0)))))
    (let ((r (fetch (local-url "nex" s "/notes.txt"))))
      (is (string= "text/plain" (response-mime-type r)))
      (is (string= "Some notes" (response-text r))))
    (is (string= "image/png" (response-mime-type (fetch (local-url "nex" s "/pic.png")))))
    (is (equal '("" "notes.txt" "pic.png") (server-log s)) "paths are sent without the leading slash")))

(defun finger-fixture (stream)
  (let ((line (read-request-line stream)))
    (note *server* line)
    (send stream (if (string= line "") "alice bob" (format nil "Login: ~A" line)))))

(test finger
  (with-server (s #'finger-fixture)
    (is (string= "alice bob" (response-text (fetch (local-url "finger" s "")))))
    (is (string= "Login: alice" (response-text (fetch (local-url "finger" s "/alice")))))
    (is (string= "Login: bob"
                 (response-text (fetch (format nil "finger://bob@127.0.0.1:~D" (fixture-server-port s))))))
    (is (string= "Login: /W carol" (response-text (fetch (local-url "finger" s "/%2FW%20carol")))))
    (is (equal '("" "alice" "bob" "/W carol") (server-log s)))))
