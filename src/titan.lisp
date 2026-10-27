;;;; titan.lisp -- Titan, the upload companion to Gemini.
;;;;
;;;; Request: titan://host/path;mime=TYPE;size=N;token=T CRLF, then exactly N
;;;; bytes, over TLS on the Gemini port.  The reply is a Gemini reply, usually
;;;; a 30 redirect to the gemini:// page that now shows the upload.

(in-package #:gopher)

(defun upload-octets (data)
  (etypecase data
    (null (make-array 0 :element-type '(unsigned-byte 8)))
    (string (encode-text data))
    (vector (coerce data '(simple-array (unsigned-byte 8) (*))))
    (pathname (alexandria:read-file-into-byte-vector data))))

(define-scheme-handler "titan" (url request)
  (let* ((octets (upload-octets (request-data request)))
         (params (url-titan-parameters url))
         (url (make-titan-url url
                              :mime-type (or (request-mime-type request)
                                             (cdr (assoc "mime" params :test #'string=))
                                             "text/plain")
                              :size (length octets)
                              :token (or (request-token request)
                                         (cdr (assoc "token" params :test #'string=)))))
         (line (url-string url :fragment nil)))
    (check-request-length line url)
    (with-connection (conn request url (url-host url) (url-effective-port url) :tls t)
      (let ((stream (connection-stream conn)))
        (write-octets stream line)
        (write-octets stream #.(coerce #(13 10) '(vector (unsigned-byte 8))))
        (write-sequence octets stream)
        (force-output stream))
      (read-gemini-response conn request url :titan))))
