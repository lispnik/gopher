;;;; test/gopher-plus-tests.lisp

(in-package #:gopher/test)

(def-suite gopher-plus :in gopher)
(in-suite gopher-plus)

(defparameter *attributes*
  (crlf (format nil "+INFO: 0About~C/about~C127.0.0.1~C70~C+" #\Tab #\Tab #\Tab #\Tab)
        "+ADMIN:"
        " Admin: Jane Doe <jane@example.org>"
        " Mod-Date: Mon Oct 27 10:00:00 2026 <20261027100000>"
        "+VIEWS:"
        " text/plain: <1k>"
        " application/pdf En_US: <24k>"
        "+ABSTRACT:"
        " All about this server."
        " Second line."
        "+INFO: 1Next item~C/next~C127.0.0.1~C70~C+"
        "+ADMIN:"
        " Admin: Someone"))

(test parse-attributes
  (let ((records (parse-gopher-plus-attributes *attributes*)))
    (is (= 2 (length records)))
    (let ((r (first records)))
      (is (string= "About" (line-text (gopher-plus-record-info r))))
      (is (equal '(("Admin" . "Jane Doe <jane@example.org>")
                   ("Mod-Date" . "Mon Oct 27 10:00:00 2026 <20261027100000>"))
                 (gopher-plus-record-admin r)))
      (let ((views (gopher-plus-record-views r)))
        (is (= 2 (length views)))
        (is (string= "text/plain" (gopher-plus-view-mime-type (first views))))
        (is (string= "<1k>" (gopher-plus-view-size (first views))))
        (is (string= "En_US" (gopher-plus-view-language (second views)))))
      (is (string= (format nil "All about this server.~%Second line.")
                   (gopher-plus-record-abstract r))))))

(defun gopher-plus-fixture (stream)
  (let* ((line (read-request-line stream))
         (fields (gopher::split-string line #\Tab))
         (selector (first fields))
         (flag (second fields)))
    (note *server* line)
    (cond
      ((string= selector "/broken")
       (send stream (crlf "--1" "1 Jane Doe <jane@example.org>" "No such item" ".")))
      ((equal flag "!")
       (send stream (crlf "+-1") *attributes* (crlf ".")))
      ((equal flag "+text/plain")
       (let ((body "exactly this"))
         (send stream (crlf (format nil "+~D" (length body))) body "trailing junk")))
      ((equal flag "+")
       (send stream (crlf "+-2") "until close"))
      (t (send stream (crlf "plain" "."))))))

(test fetch-attributes
  (with-server (s #'gopher-plus-fixture)
    (multiple-value-bind (records response) (gopher-attributes (local-url "gopher" s "/0/about"))
      (is (eq :success (response-status response)))
      (is (= 2 (length records)))
      (is (equal (list (format nil "/about~C!" #\Tab)) (server-log s))))))

(test fetch-gopher-plus-lengths
  (with-server (s #'gopher-plus-fixture)
    (is (string= "exactly this"
                 (response-text (fetch (local-url "gopher" s "/0/about") :gopher-plus "text/plain"))))
    (is (string= "until close"
                 (response-text (fetch (local-url "gopher" s "/0/about") :gopher-plus t))))))

(test gopher-plus-error
  (with-server (s #'gopher-plus-fixture)
    (let ((r (fetch (local-url "gopher" s "/0/broken") :gopher-plus "!")))
      (is (eq :permanent-failure (response-status r)))
      (is (search "No such item" (response-meta r))))))

(test non-gopher-plus-server
  (with-server (s #'gopher-fixture)
    ;; A plain server ignores the extra field and sends an error menu.
    (multiple-value-bind (records response) (gopher-attributes (local-url "gopher" s "/0/nothing"))
      (is (null records))
      (is (eq :not-found (response-status response))))))
