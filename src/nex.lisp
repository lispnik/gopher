;;;; nex.lisp -- Nex.
;;;;
;;;; Plain TCP, port 1900.  The client sends the path without its leading `/'
;;;; and a line end; the server sends the document and closes.  There is no
;;;; status and no MIME type.  An empty path or one ending in `/' is a
;;;; directory: plain text whose `=> URL' lines are links.  Anything else is
;;;; typed by its extension, and no extension means plain text.

(in-package #:gopher)

(defun nex-directory-path-p (path)
  (or (string= path "") (string= path "/") (char= (char path (1- (length path))) #\/)))

(defun nex-mime-type (path)
  (cond ((nex-directory-path-p path) "text/x-nex-directory")
        ((let ((slash (or (position #\/ path :from-end t) -1)))
           (not (position #\. path :start (1+ slash))))
         "text/plain")
        (t (guess-mime-type path))))

(define-scheme-handler "nex" (url request)
  (let* ((path (percent-decode (url-path url)))
         (selector (string-left-trim "/" path))
         (mime (nex-mime-type path)))
    (with-connection (conn request url (url-host url) (url-effective-port url))
      (send-line conn selector)
      (multiple-value-bind (body count) (read-body (connection-stream conn) request url :parse-as mime)
        (make-response url :nex :success :meta mime :mime-type mime
                                         :body body :bytes-read count)))))
