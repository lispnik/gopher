;;;; finger.lisp -- Finger (RFC 1288).
;;;;
;;;; finger://host/user or finger://user@host.  The query line is the user
;;;; (empty lists everyone), or `/W user' for verbose output when the URL's
;;;; user starts with `/W'.  The reply is plain text.

(in-package #:gopher)

(define-scheme-handler "finger" (url request)
  (let* ((user (or (and (url-userinfo url) (percent-decode (url-userinfo url)))
                   ;; Only the path's own slash: "/%2FW%20bob" is "/W bob".
                   (percent-decode (let ((p (url-path url)))
                                     (if (alexandria:starts-with-subseq "/" p) (subseq p 1) p)))))
         (user (or (request-query request) user)))
    (with-connection (conn request url (url-host url) (url-effective-port url))
      (send-line conn user)
      (multiple-value-bind (body count) (read-body (connection-stream conn) request url
                                                   :parse-as "text/plain")
        (make-response url :finger :success :meta "text/plain" :mime-type "text/plain"
                                            :body body :bytes-read count)))))
