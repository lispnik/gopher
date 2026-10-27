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

(defun parse-nex-directory (text &optional base-url)
  "A Nex directory listing as a DOCUMENT: `=> ' lines are links, the rest text."
  (make-document
   :kind :nex-directory
   :lines (coerce (loop for l in (let ((ls (split-lines text)))
                                   (if (and ls (string= (car (last ls)) "")) (butlast ls) ls))
                        collect (if (alexandria:starts-with-subseq "=>" l)
                                    (parse-link-line (subseq l 2) base-url :link)
                                    (make-document-line :kind :text :text l)))
                  'vector)))

(define-scheme-handler "nex" (url request)
  (let* ((path (percent-decode (url-path url)))
         (selector (string-left-trim "/" path))
         (mime (nex-mime-type path)))
    (with-connection (conn request url (url-host url) (url-effective-port url))
      (send-line conn selector)
      (multiple-value-bind (body count) (read-body (connection-stream conn) request url)
        (make-response url :nex :success :meta mime :mime-type mime
                                         :body body :bytes-read count)))))
