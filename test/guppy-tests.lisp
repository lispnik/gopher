;;;; test/guppy-tests.lisp

(in-package #:gopher/test)

(def-suite guppy :in gopher)
(in-suite guppy)

(defmacro with-fast-retransmit (&body body)
  `(let ((gopher::*guppy-retransmit-interval* 0.3)) ,@body))

(test guppy-single-and-chunked
  (with-guppy-server (s :chunk-size 8)
    (let* ((r (fetch (local-url "guppy" s "/page") :timeout 5))
           (doc (response-document r)))
      (is (eq :success (response-status r)))
      (is (string= "text/gemini" (response-mime-type r)))
      (is (string= (format nil "# Title~%Body of /page~%=> /b second~%") (response-text r)))
      (is (string= (local-url "guppy" s "/b") (line-url (first (document-links doc)))))
      ;; Every data packet and the EOF were acknowledged.
      (let ((acks (mapcar #'second (remove :request (server-log s) :key #'first))))
        (is (equal acks (loop for i from 1000 repeat (length acks) collect i)))))))

(test guppy-statuses
  (with-guppy-server (s)
    (let ((r (fetch (local-url "guppy" s "/input") :timeout 5)))
      (is (eq :input (response-status r)))
      (is (string= "Your name" (response-meta r))))
    (is (string= (format nil "# Hello Ada~%")
                 (response-text (fetch (local-url "guppy" s "/input") :query "Ada" :timeout 5))))
    (let ((r (fetch (local-url "guppy" s "/error") :timeout 5)))
      (is (eq :permanent-failure (response-status r)))
      (is (string= "No such thing" (response-meta r))))
    (let ((r (fetch (local-url "guppy" s "/redirect") :timeout 5)))
      (is (eq :success (response-status r)))
      (is (search "Body of /a" (response-text r))))))

(test guppy-lost-packets
  (with-fast-retransmit
    (with-guppy-server (s :chunk-size 8 :drop '(1000 1002 1005))
      (is (string= (format nil "# Title~%Body of /x~%=> /b second~%")
                   (response-text (fetch (local-url "guppy" s "/x") :timeout 5)))))))

(test guppy-lost-request
  (with-fast-retransmit
    (with-guppy-server (s :drop-request t)
      (is (eq :success (response-status (fetch (local-url "guppy" s "/x") :timeout 5))))
      (is (= 2 (count :request (server-log s) :key #'first)) "the client re-sent its request"))))

(test guppy-out-of-order
  (with-guppy-server (s :chunk-size 8 :reorder t)
    (is (string= (format nil "# Title~%Body of /x~%=> /b second~%")
                 (response-text (fetch (local-url "guppy" s "/x") :timeout 5))))))

(test guppy-larger-document
  (with-guppy-server (s :chunk-size 512)
    (let ((r (fetch (local-url "guppy" s "/big") :timeout 5)))
      (is (= 200 (count #\Newline (response-text r)))))))

(test guppy-timeout
  ;; A socket that never answers: the client gives up after its timeout.
  (let ((silent (usocket:socket-connect nil nil :protocol :datagram :element-type '(unsigned-byte 8)
                                                :local-host "127.0.0.1" :local-port 0)))
    (unwind-protect
         (signals timeout-error
           (fetch (format nil "guppy://127.0.0.1:~D/" (usocket:get-local-port silent)) :timeout 1))
      (usocket:socket-close silent))))

(test guppy-closed-port
  ;; The ICMP port-unreachable reply surfaces as a refused connection.
  (let ((port (with-guppy-server (s) (fixture-server-port s))))
    (signals connection-error (fetch (format nil "guppy://127.0.0.1:~D/" port) :timeout 3))))
