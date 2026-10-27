;;;; test/feature-tests.lisp -- IDNA, streaming, proxies, deadlines, cache,
;;;; history, identities, Gopher+ forms and server introspection.

(in-package #:gopher/test)

(def-suite features :in gopher)
(in-suite features)

;;; IDNA

(test punycode-rfc3492-samples
  (loop for (unicode ascii) in '(("bücher" "bcher-kva")
                                 ("münchen" "mnchen-3ya")
                                 ("例え" "r8jz45g")
                                 ("ليهمابتكلموشعربي؟" "egbpdaj6bu4bxfgehfvwxn"))
        do (is (string= ascii (punycode-encode unicode)))
           (is (string= unicode (punycode-decode ascii)))))

(test hosts-are-stored-in-ascii
  (let ((u (parse-url "gemini://Bücher.example/päth")))
    (is (string= "xn--bcher-kva.example" (url-host u)))
    (is (string= "bücher.example" (url-display-host u)))
    (is (string= "gemini://bücher.example/päth" (url-display-string u))))
  (is (string= "xn--bcher-kva.example" (url-host (parse-url "gemini://b%C3%BCcher.example/"))))
  (is (string= "example.org" (host-to-ascii "EXAMPLE.org")))
  (is (string= "xn--r8jz45g.jp" (host-to-ascii "例え。jp")) "ideographic full stop"))

;;; Streaming

(defun slow-gemtext-fixture (stream)
  (read-request-line stream)
  (send stream (crlf "20 text/gemini"))
  (dolist (part (list (format nil "# Title~%=> /a A link~%Partial")
                      (format nil " line~%```alt~%pre 1~%")
                      (format nil "pre 2~%```~%")
                      "caf"
                      (babel:string-to-octets (format nil "é~%no newline at end") :encoding :utf-8)))
    (send stream part)
    (sleep 0.05)))

(test on-lines-matches-the-document
  (with-server (s #'slow-gemtext-fixture :tls t)
    (let* ((batches '())
           (chunks 0)
           (r (fetch (local-url "gemini" s "/") :known-hosts (make-memory-known-hosts)
                     :on-lines (lambda (lines) (push lines batches))
                     :on-data (lambda (octets) (declare (ignore octets)) (incf chunks))))
           (streamed (apply #'append (reverse batches))))
      (is (> (length batches) 2) "lines arrived in several batches")
      (is (>= chunks 3) "data arrived in several chunks")
      (is (equalp (coerce (document-lines (response-document r)) 'list) streamed))
      (is (equal '(:heading :link :text :preformatted :text :text) (mapcar #'line-kind streamed)))
      (is (string= "Partial line" (line-text (third streamed))))
      (is (string= "café" (line-text (fifth streamed))) "a UTF-8 character split across chunks"))))

(test streaming-gopher-menu-and-text
  (with-server (s #'gopher-fixture)
    (let ((got '()))
      (fetch (local-url "gopher" s "/") :on-lines (lambda (ls) (setf got (append got ls))))
      (is (equal '(:text :link) (mapcar #'line-kind got))))
    (let ((got '()))
      (fetch (local-url "gopher" s "/0/doc") :on-lines (lambda (ls) (setf got (append got ls))))
      (is (equal '("First line" ".starts with a dot") (mapcar #'line-text got))
          "terminator dropped and dots un-stuffed while streaming"))))

(test streaming-guppy
  (with-guppy-server (s :chunk-size 8 :reorder t)
    (let* ((got '())
           (r (fetch (local-url "guppy" s "/x") :timeout 5
                     :on-lines (lambda (ls) (setf got (append got ls))))))
      (is (equalp (coerce (document-lines (response-document r)) 'list) got)))))

(defun spartan-trickle-fixture (stream)
  (read-request-line stream)
  (send stream (crlf "2 text/gemini") (format nil "# First~%"))
  ;; Wait until the client has shown the first line before sending more.
  (loop repeat 100 until (getf (car (server-log *server*)) :seen) do (sleep 0.02))
  (send stream (format nil "second~%")))

(test plain-tcp-streams-before-close
  (with-server (s #'spartan-trickle-fixture)
    (let ((got '()))
      (fetch (local-url "spartan" s "/") :timeout 5
             :on-lines (lambda (ls)
                         (setf got (append got ls))
                         (note s (list :seen t))))
      (is (equal '("First" "second") (mapcar #'line-text got))))))

;;; Timeouts and deadlines

(defun trickle-fixture (stream)
  ;; A byte every 0.3 s: never idle long enough for a read timeout.
  (read-request-line stream)
  (send stream (crlf "20 text/plain"))
  (dotimes (i 40) (send stream "x") (sleep 0.3)))

(test deadline-bounds-the-whole-request
  (with-server (s #'trickle-fixture :tls t)
    (let ((start (get-internal-real-time)))
      (signals timeout-error (fetch (local-url "gemini" s "/") :read-timeout 5 :deadline 1.5
                                    :known-hosts (make-memory-known-hosts)))
      (is (< (/ (- (get-internal-real-time) start) internal-time-units-per-second) 4)))))

(test separate-read-timeout
  (with-server (s #'stall-fixture)
    (signals timeout-error (fetch (local-url "gopher" s "/") :connect-timeout 5 :read-timeout 1))))

;;; SOCKS5

(test socks5-proxy
  (with-server (target #'gopher-fixture)
    (with-server (proxy (socks-fixture))
      (let ((r (fetch (local-url "gopher" target "/0/doc")
                      :proxy (format nil "socks5://127.0.0.1:~D" (fixture-server-port proxy)))))
        (is (eq :success (response-status r)))
        (is (search "First line" (response-text r)))
        (is (equal (list :connect "127.0.0.1" (fixture-server-port target))
                   (first (server-log proxy))))))))

(test socks5-proxy-with-tls-and-auth
  (with-server (target #'gemini-fixture :tls t)
    (with-server (proxy (socks-fixture :user "u" :password "p w"))
      (let ((r (fetch (local-url "gemini" target "/") :known-hosts (make-memory-known-hosts)
                      :proxy (format nil "socks5://u:p%20w@127.0.0.1:~D" (fixture-server-port proxy)))))
        (is (eq :success (response-status r)))
        (is (eq :new (response-trust r)))
        (is (equal '(:auth "u" "p w") (first (server-log proxy))))))))

(test socks5-failures
  (with-server (proxy (socks-fixture :user "u" :password "p"))
    (let ((p (format nil "socks5://127.0.0.1:~D" (fixture-server-port proxy))))
      (signals connection-error (fetch "gopher://refuse.invalid/" :proxy p))
      (signals connection-error (fetch "gopher://refuse.invalid/"
                                       :proxy (format nil "socks5://u:wrong@127.0.0.1:~D"
                                                      (fixture-server-port proxy))))))
  (with-server (proxy (socks-fixture))
    (signals connection-error (fetch "gopher://refuse.invalid/"
                                     :proxy (format nil "socks5://127.0.0.1:~D" (fixture-server-port proxy)))))
  (signals connection-error (fetch "guppy://example.org/" :proxy "socks5://127.0.0.1:9")))

;;; Cache and history

(test response-cache
  (with-server (s #'gopher-fixture)
    (let ((cache (make-response-cache :max-entries 2))
          (url (local-url "gopher" s "/0/doc")))
      (let ((a (fetch url :cache cache))
            (b (fetch url :cache cache)))
        (is (eq a b) "second fetch answered from the cache")
        (is (= 1 (length (server-log s)))))
      (fetch (local-url "gopher" s "/7/search") :query "a" :cache cache)
      (fetch (local-url "gopher" s "/7/search") :query "b" :cache cache)
      (is (= 2 (cache-count cache)) "least recently used entry evicted")
      (is (null (cache-lookup cache url)))
      (fetch (local-url "gopher" s "/1/missing") :cache cache)
      (is (= 2 (cache-count cache)) "failures are not cached")
      (cache-clear cache)
      (is (zerop (cache-count cache))))))

(test cache-max-age
  (let ((cache (make-response-cache :max-age 0))
        (r (make-instance 'response :url (parse-url "gopher://h/") :protocol :gopher :status :success
                                    :body (babel:string-to-octets "x"))))
    (cache-store cache "gopher://h/" r)
    (sleep 1.1)
    (is (null (cache-lookup cache "gopher://h/")))))

(test history
  (let ((h (make-history)))
    (is (null (history-current h)))
    (history-visit h "gemini://a/")
    (history-visit h "gemini://b/")
    (history-visit h "gemini://b/")
    (history-visit h "gemini://c/")
    (is (string= "gemini://b/" (history-back h)))
    (is (string= "gemini://a/" (history-back h)))
    (is (null (history-back h)))
    (is-true (history-forward-p h))
    (is (string= "gemini://b/" (history-forward h)))
    (history-visit h "gemini://d/")
    (is-false (history-forward-p h) "visiting drops the forward entries")
    (is (equal '("gemini://a/" "gemini://b/" "gemini://d/") (history-list h)))))

;;; Identities

(test make-identity-works-as-client-certificate
  (dolist (type '(:ec :rsa :ed25519))
    (let ((cert (temp-path "id.crt")) (key (temp-path "id.key")))
      (unwind-protect
           (let ((info (make-identity cert key :common-name "Tester" :days 10 :key-type type)))
             (is (equal '("Tester") (certificate-common-names info)))
             (is (< 9 (/ (- (certificate-not-after info) (get-universal-time)) 86400) 11))
             (is (string= (certificate-fingerprint info)
                          (certificate-fingerprint (certificate-info-from-file cert))))
             (is (= #o600 (logand #o777 (sb-posix:stat-mode (sb-posix:stat key)))))
             ;; The pair is usable: the server sees exactly this certificate.
             (with-server (s #'gemini-fixture :tls t :request-client-cert :any)
               (let ((r (fetch (local-url "gemini" s "/whoami") :known-hosts (make-memory-known-hosts)
                               :client-certificate cert :client-key key)))
                 (is (string= (format nil "Hello ~A" (certificate-fingerprint info)) (response-text r))
                     "~A identity" type))))
        (ignore-errors (delete-file cert))
        (ignore-errors (delete-file key))))))

;;; Gopher+ forms and introspection

(defun ask-fixture (stream)
  (let* ((line (read-request-line stream))
         (fields (gopher::split-string line #\Tab)))
    (note *server* line)
    (cond ((equal (second fields) "!")
           (send stream (crlf "+-1"
                              (format nil "+INFO: 0Survey~C/survey~C127.0.0.1~C70~C?" #\Tab #\Tab #\Tab #\Tab)
                              "+ASK:"
                              (format nil " Ask: Your name?~CAnonymous" #\Tab)
                              " AskP: Password?"
                              (format nil " Choose: Colour?~Cred~Cgreen" #\Tab #\Tab)
                              " AskL: Comments?"
                              " Note: Thanks!"
                              ".")))
          ((equal (third fields) "1")
           (let ((answers (loop for l = (read-request-line stream) until (string= l ".") collect l)))
             (note *server* answers)
             (send stream (crlf "+-2") (format nil "~{~A~^|~}" answers))))
          (t (send stream (crlf "plain" "."))))))

(test gopher-plus-ask-forms
  (with-server (s #'ask-fixture)
    (let* ((url (local-url "gopher" s "/0/survey"))
           (record (first (gopher-attributes url)))
           (questions (gopher-plus-record-questions record)))
      (is (equal '(:ask :ask-password :choose :ask-long :note) (mapcar #'gopher-plus-question-kind questions)))
      (is (string= "Your name?" (gopher-plus-question-prompt (first questions))))
      (is (equal '("Anonymous") (gopher-plus-question-choices (first questions))))
      (is (equal '("red" "green") (gopher-plus-question-choices (third questions))))
      (let ((r (gopher-plus-submit url (list "Ada" "secret" "green" (list "line one" "line two")))))
        (is (eq :success (response-status r)))
        (is (string= (format nil "/survey~C+~C1" #\Tab #\Tab) (second (server-log s))))
        (is (equal '("+-1" "Ada" "secret" "green" "2" "line one" "line two") (third (server-log s))))))))

(test gopher-plus-server-detection
  (with-server (s #'gopher-plus-fixture)
    (is-true (gopher-plus-server-p (local-url "gopher" s "/0/about"))))
  (with-server (s #'gopher-fixture)
    (is-false (gopher-plus-server-p (local-url "gopher" s "/"))))
  (is-false (gopher-plus-server-p (format nil "gopher://127.0.0.1:~D/" (closed-port)) :timeout 2)))

(test gopher-tls-status-is-reported
  (forget-gopher-tls-status)
  (with-server (plain #'gopher-fixture)
    (with-server (tls #'gopher-fixture :tls t)
      (is (null (gopher-tls-status "127.0.0.1" (fixture-server-port plain))))
      (fetch (local-url "gopher" plain "/") :tls :try)
      (fetch (local-url "gopher" tls "/") :tls :try :known-hosts (make-memory-known-hosts))
      (is (eq :plain (gopher-tls-status "127.0.0.1" (fixture-server-port plain))))
      (is (eq :tls (gopher-tls-status "127.0.0.1" (fixture-server-port tls))))
      (forget-gopher-tls-status "127.0.0.1" (fixture-server-port tls))
      (is (null (gopher-tls-status "127.0.0.1" (fixture-server-port tls)))))))

;;; CLI additions

(test cli-identity-and-streaming
  (let ((home (merge-pathnames (format nil "gopher-xdg-~D/" (random 1000000)) (uiop:temporary-directory)))
        (old (uiop:getenv "XDG_CONFIG_HOME")))
    (setf (uiop:getenv "XDG_CONFIG_HOME") (namestring home))
    (unwind-protect
         (progn
           (multiple-value-bind (status out) (run-cli "identity" "create" "me" "--days" "5")
             (is (eql 0 status))
             (is (search "fingerprint: sha256:" out)))
           (is (eql 1 (run-cli "identity" "create" "me")) "won't overwrite")
           (multiple-value-bind (status out) (run-cli "identity" "list")
             (is (eql 0 status))
             (is (search "me  sha256:" out)))
           (with-server (s #'gemini-fixture :tls t :request-client-cert :any)
             (multiple-value-bind (status out)
                 (run-cli "get" "--identity" "me" (local-url "gemini" s "/whoami"))
               (is (eql 0 status))
               (is (search "Hello sha256:" out))))
           (with-server (s #'gopher-fixture)
             (multiple-value-bind (status out) (run-cli "get" (local-url "gopher" s "/"))
               (is (eql 0 status))
               (is (= 1 (count-matches "Hello" out)) "streamed once, not printed twice"))))
      (if old (setf (uiop:getenv "XDG_CONFIG_HOME") old) (sb-posix:unsetenv "XDG_CONFIG_HOME"))
      (uiop:delete-directory-tree home :validate t :if-does-not-exist :ignore))))

(defun count-matches (needle haystack)
  (loop with start = 0 for pos = (search needle haystack :start2 start)
        while pos count t do (setf start (1+ pos))))
