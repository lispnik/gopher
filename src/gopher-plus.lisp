;;;; gopher-plus.lisp -- Gopher+ responses and item attributes.
;;;;
;;;; A Gopher+ request adds a TAB field to the selector: `+' (the item,
;;;; possibly a particular view: `+text/plain'), `!' (its attributes) or `$'
;;;; (the attributes of every item in a directory).  The reply starts with a
;;;; length line:
;;;;   +N   N bytes follow          -N   an error of N bytes follows
;;;;   +-1  data ends with `.' line  -1  error, ends with `.' line
;;;;   +-2  data ends at close       -2  error, ends at close
;;;; Attributes are blocks: `+NAME:' starts one, lines starting with a space
;;;; continue it, and each `+INFO:' starts a new item.

(in-package #:gopher)

(defun parse-gopher-plus-length (line url)
  (let ((line (trim-ws line)))
    (unless (and (>= (length line) 2) (find (char line 0) "+-"))
      (error 'protocol-error :url url :message (format nil "Not a Gopher+ reply: ~S" line)))
    (let ((n (ignore-errors (parse-integer line :start 1))))
      (unless n
        (error 'protocol-error :url url :message (format nil "Bad Gopher+ length: ~S" line)))
      (values (char= (char line 0) #\+) n))))

(defun read-gopher-plus-response (conn request url type selector plus)
  (let* ((stream (connection-stream conn))
         (header (or (read-header-line stream :url url)
                     (error 'protocol-error :url url :message "Empty Gopher+ reply"))))
    (when (and (plusp (length header)) (not (find (char header 0) "+-")))
      ;; Not a Gopher+ server: it treated the TAB field as noise and sent the
      ;; item (or an error menu).  Fall back to plain handling.
      (let ((rest (read-body stream request url)))
        (return-from read-gopher-plus-response
          (gopher-plain-fallback conn url type selector header rest))))
    (multiple-value-bind (ok n) (parse-gopher-plus-length header url)
      (let* ((body (if (plusp n)
                       (read-body stream request url :total n)
                       (read-body stream request url)))
             (body (if (and body (= n -1)) (gopher-unstuff-text body) body))
             (view (and (> (length plus) 1) (char= (char plus 0) #\+) (subseq plus 1)))
             (mime (cond ((member plus '("!" "$") :test #'string=) "text/x-gopher-plus-attributes")
                         (view (first (split-string (trim-ws view) #\Space)))
                         (t (gopher-response-mime-type type selector)))))
        (if ok
            (make-response url :gopher :success :mime-type mime :meta mime :body body
                                                :connection conn)
            (make-response url :gopher :permanent-failure
                           :meta (trim-ws (decode-text (or body #())))
                           :mime-type "text/plain" :body body :connection conn))))))

(defun gopher-plain-fallback (conn url type selector first-line rest)
  (let* ((body (concatenate '(vector (unsigned-byte 8))
                            (encode-text first-line) #(13 10) (or rest #())))
         (mime (gopher-response-mime-type type selector))
         (doc (parse-gopher-menu (decode-text body) url))
         (err (gopher-error-text doc)))
    (make-response url :gopher (if err :not-found :success)
                   :meta (or err mime) :mime-type mime :body body :connection conn)))

;;; Attributes

(defstruct gopher-plus-record
  (info nil)          ; DOCUMENT-LINE for the item, from +INFO
  (blocks '()))       ; ((name . lines) ...) in order, name upcased without `+'/`:'

(defstruct gopher-plus-view
  (mime-type "" :type string)
  (language nil)
  (size nil))         ; as written, e.g. "<10k>"

(defun gopher-plus-record-attribute (record name)
  "The lines of block NAME (e.g. \"ABSTRACT\") of RECORD, or NIL."
  (cdr (assoc name (gopher-plus-record-blocks record) :test #'string-equal)))

(defun gopher-plus-record-admin (record)
  "The +ADMIN block as an alist of (\"Admin\" . \"...\"), (\"Mod-Date\" . \"...\") ..."
  (loop for line in (gopher-plus-record-attribute record "ADMIN")
        for colon = (position #\: line)
        when colon
          collect (cons (trim-ws (subseq line 0 colon)) (trim-ws (subseq line (1+ colon))))))

(defun gopher-plus-record-abstract (record)
  (alexandria:when-let ((lines (gopher-plus-record-attribute record "ABSTRACT")))
    (format nil "~{~A~^~%~}" lines)))

(defun gopher-plus-record-views (record)
  "The +VIEWS block as GOPHER-PLUS-VIEWs."
  (loop for line in (gopher-plus-record-attribute record "VIEWS")
        for colon = (position #\: line :from-end t)
        for head = (trim-ws (if colon (subseq line 0 colon) line))
        for parts = (remove "" (split-string head #\Space) :test #'string=)
        when parts
          collect (make-gopher-plus-view
                   :mime-type (first parts)
                   :language (second parts)
                   :size (and colon (let ((s (trim-ws (subseq line (1+ colon)))))
                                      (if (string= s "") nil s))))))

(defun parse-gopher-plus-attributes (text &optional base-url)
  "Parse Gopher+ attribute TEXT (the reply to `!' or `$') into a list of
GOPHER-PLUS-RECORDs."
  (let ((records '()) (current nil) (block nil))
    (flet ((finish-block ()
             (when (and current block)
               (setf (gopher-plus-record-blocks current)
                     (append (gopher-plus-record-blocks current)
                             (list (cons (car block) (reverse (cdr block))))))
               (setf block nil))))
      (dolist (line (split-lines text))
        (cond
          ((string= line ".") (return))
          ((and (plusp (length line)) (char= (char line 0) #\+))
           (let* ((colon (or (position #\: line) (length line)))
                  (name (string-upcase (subseq line 1 colon)))
                  (rest (if (< colon (length line))
                            (string-left-trim " " (subseq line (1+ colon)))
                            "")))
             (finish-block)
             (when (or (string= name "INFO") (null current))
               (setf current (make-gopher-plus-record))
               (push current records))
             (if (string= name "INFO")
                 (progn
                   (setf (gopher-plus-record-info current)
                         (and (plusp (length rest)) (parse-gopher-menu-line rest base-url)))
                   (setf block (list name)))
                 (setf block (if (string= rest "") (list name) (list name rest))))))
          ((and block (plusp (length line)) (char= (char line 0) #\Space))
           (push (subseq line 1) (cdr block)))
          ((and block (string/= line ""))
           (push line (cdr block)))))
      (finish-block))
    (nreverse records)))

(defun gopher-attributes (url &rest fetch-options &key directory &allow-other-keys)
  "Fetch the Gopher+ attributes of the item at URL, or with :DIRECTORY T of
every item in the menu at URL.  Returns a list of GOPHER-PLUS-RECORDs, and
the RESPONSE as a second value."
  (let* ((url (ensure-url url :default-scheme "gopher"))
         (response (apply #'fetch url :gopher-plus (if directory "$" "!")
                          (alexandria:remove-from-plist fetch-options :directory))))
    (values (if (response-success-p response)
                (parse-gopher-plus-attributes (or (response-text response) "") url)
                '())
            response)))
