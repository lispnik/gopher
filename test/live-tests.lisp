;;;; test/live-tests.lisp -- against real servers; only with GOPHER_LIVE_TESTS=1.

(in-package #:gopher/test)

(def-suite live :in gopher)
(in-suite live)

(defun live-p () (uiop:getenv "GOPHER_LIVE_TESTS"))

(defmacro live-test (name &body body)
  `(test ,name
     (if (live-p)
         (let ((*known-hosts* (make-memory-known-hosts)))
           ,@body)
         (skip "set GOPHER_LIVE_TESTS=1 to run"))))

(live-test live-floodgap
  (let ((r (fetch "gopher://gopher.floodgap.com/" :timeout 20)))
    (is (eq :success (response-status r)))
    (is (plusp (length (document-links (response-document r)))))))

(live-test live-gemini
  (let ((r (fetch "gemini://geminiprotocol.net/" :timeout 20)))
    (is (eq :success (response-status r)))
    (is (eq :new (response-trust r)))
    (is (certificate-not-after (response-certificate r)))))

(live-test live-spartan
  (is (eq :success (response-status (fetch "spartan://mozz.us/" :timeout 20)))))

(live-test live-nex
  (is (eq :success (response-status (fetch "nex://nightfall.city/" :timeout 20)))))

(live-test live-finger
  (is (eq :success (response-status (fetch "finger://happynetbox.com/" :timeout 20)))))
