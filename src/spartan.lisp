;;;; spartan.lisp -- Spartan.
;;;;
;;;; Plain TCP, port 300.  Request: `host path content-length' CRLF, then that
;;;; many bytes of data (user input or an upload).  Reply: `2 mime' then the
;;;; body, `3 /path' (a redirect on the same host), `4 message' (client error)
;;;; or `5 message' (server error).

(in-package #:gopher)

(define-scheme-handler "spartan" (url request)
  (let* ((data (cond ((request-data request) (upload-octets (request-data request)))
                     ((request-query request) (encode-text (request-query request)))
                     ((url-query url) (percent-decode-octets (url-query url)))
                     (t (upload-octets nil))))
         (path (if (string= (url-path url) "") "/" (url-path url)))
         (line (format nil "~A ~A ~D" (url-host url) path (length data))))
    (with-connection (conn request url (url-host url) (url-effective-port url))
      (let ((stream (connection-stream conn)))
        (write-octets stream line)
        (write-octets stream #.(coerce #(13 10) '(vector (unsigned-byte 8))))
        (write-sequence data stream)
        (force-output stream)
        (let* ((header (or (read-header-line stream :max 2048 :url url)
                           (error 'protocol-error :url url :message "Server closed without replying")))
               (code (and (plusp (length header)) (digit-char-p (char header 0))))
               (meta (if (> (length header) 1) (trim-ws (subseq header 1)) "")))
          (case code
            (2 (let ((mime (if (string= meta "") "text/gemini; charset=utf-8" meta)))
                 (multiple-value-bind (body count) (read-body stream request url)
                   (make-response url :spartan :success :code 2 :meta meta :mime-type mime
                                                        :body body :bytes-read count))))
            (3 (make-response url :spartan :redirect :code 3 :meta meta))
            (4 (make-response url :spartan :bad-request :code 4 :meta meta))
            (5 (make-response url :spartan :server-error :code 5 :meta meta))
            (t (error 'protocol-error :url url
                                      :message (format nil "Bad response header: ~S" header)))))))))
