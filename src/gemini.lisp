;;;; gemini.lisp -- Gemini.
;;;;
;;;; Request: the absolute URL and CRLF, at most 1024 bytes, over TLS (with
;;;; SNI).  Reply: a header `NN meta' CRLF, then a body for 2x.  Statuses that
;;;; are not success come back as RESPONSEs, not conditions: a browser shows
;;;; a prompt for 1x, follows 3x, shows an error page for 4x/5x and offers an
;;;; identity for 6x.

(in-package #:gopher)

(defparameter *gemini-statuses*
  '((10 . :input) (11 . :sensitive-input)
    (20 . :success)
    (30 . :redirect) (31 . :permanent-redirect)
    (40 . :temporary-failure) (41 . :server-unavailable) (42 . :cgi-error)
    (43 . :proxy-error) (44 . :slow-down)
    (50 . :permanent-failure) (51 . :not-found) (52 . :gone)
    (53 . :proxy-request-refused) (59 . :bad-request)
    (60 . :client-certificate-required) (61 . :certificate-not-authorized)
    (62 . :certificate-not-valid)))

(defun gemini-status-keyword (code)
  "The keyword for Gemini status CODE.  An unknown code within a known class
maps to the class's generic status, as the spec requires."
  (or (cdr (assoc code *gemini-statuses*))
      (case (floor code 10)
        (1 :input) (2 :success) (3 :redirect) (4 :temporary-failure)
        (5 :permanent-failure) (6 :client-certificate-required))))

(defun parse-gemini-header (line url)
  "Split a reply header into (values CODE META)."
  (unless (and line (>= (length line) 2)
               (digit-char-p (char line 0)) (digit-char-p (char line 1))
               (or (= (length line) 2) (whitespacep (char line 2))))
    (error 'protocol-error :url url :message (format nil "Bad response header: ~S" line)))
  (let ((code (parse-integer line :end 2))
        (meta (if (> (length line) 2) (trim-ws (subseq line 3)) "")))
    (unless (gemini-status-keyword code)
      (error 'protocol-error :url url :message (format nil "Unknown status ~D" code)))
    (values code meta)))

(defun read-gemini-response (conn request url protocol)
  (let* ((stream (connection-stream conn))
         (line (or (read-header-line stream :max 1100 :url url)
                   (error 'protocol-error :url url :message "Server closed without replying"))))
    (multiple-value-bind (code meta) (parse-gemini-header line url)
      (let ((status (gemini-status-keyword code)))
        (if (eq status :success)
            (let ((mime (if (string= meta "") "text/gemini; charset=utf-8" meta)))
              (multiple-value-bind (body count) (read-body stream request url)
                (make-response url protocol :success :code code :meta meta :mime-type mime
                                                     :body body :bytes-read count :connection conn)))
            (make-response url protocol status :code code :meta meta :connection conn))))))

(defun check-request-length (string url &optional (max 1024))
  (when (> (length (encode-text string)) max)
    (error 'protocol-error :url url :message (format nil "Request longer than ~D bytes" max))))

(define-scheme-handler "gemini" (url request)
  (let* ((url (if (request-query request) (url-with-query url (request-query request)) url))
         (line (url-string url :fragment nil)))
    (check-request-length line url)
    (with-connection (conn request url (url-host url) (url-effective-port url) :tls t)
      (send-line conn line)
      (read-gemini-response conn request url :gemini))))
