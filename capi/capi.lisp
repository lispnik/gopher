;;;; capi/capi.lisp -- the C ABI: JSON in, JSON out.
;;;;
;;;; A Swift (or any C) host links capi/build/libgopher.dylib and calls the
;;;; functions in capi/gopher.h.  Those C functions call through function
;;;; pointers that SBCL fills in when the core starts: SAVE-CORE saves the
;;;; image with :CALLABLE-EXPORTS, so instead of running a toplevel the core
;;;; reinitialises itself and writes each DEFINE-ALIEN-CALLABLE's address into
;;;; the C global of the same name (gopher_lisp_fetch, ...), then
;;;; initialize_lisp returns to C.
;;;;
;;;; Every argument and result is a NUL-terminated UTF-8 string.  Results are
;;;; allocated with malloc (MAKE-ALIEN) and the host frees them with free(),
;;;; which gopher_free wraps.  No Lisp condition ever unwinds into C: every
;;;; callable catches everything and reports it as JSON.  Callables may be
;;;; entered from any foreign thread; SBCL attaches the thread on entry.

(defpackage #:gopher/capi
  (:use #:cl)
  (:export #:save-core #:fetch-json #:cancel-request-id
           #:parse-json #:write-json #:json-string
           #:base64-encode #:base64-decode))

(in-package #:gopher/capi)

(defparameter *version* "0.1.0")

;;; JSON
;;;
;;; Decoding: objects -> alists of (string . value), arrays -> lists,
;;; true -> T, false -> :FALSE, null -> :NULL.
;;; Encoding: (:OBJECT (key . value) ...), vectors and lists (other than
;;; :OBJECT forms) -> arrays, strings, integers, reals, T -> true,
;;; :FALSE / NIL -> false, :NULL -> null.

(define-condition json-error (error)
  ((message :initarg :message :reader json-error-message))
  (:report (lambda (c s) (format s "Bad JSON: ~A" (json-error-message c)))))

(defun parse-json (string)
  (let ((pos 0) (n (length string)))
    (labels ((fail (fmt &rest args)
               (error 'json-error :message (format nil "~? at offset ~D" fmt args pos)))
             (peek () (and (< pos n) (char string pos)))
             (skip-ws ()
               (loop while (and (< pos n) (member (char string pos) '(#\Space #\Tab #\Newline #\Return)))
                     do (incf pos)))
             (expect (c)
               (skip-ws)
               (unless (eql (peek) c) (fail "expected ~S" c))
               (incf pos))
             (literal (word value)
               (if (and (<= (+ pos (length word)) n) (string= word string :start2 pos :end2 (+ pos (length word))))
                   (progn (incf pos (length word)) value)
                   (fail "unexpected token")))
             (hex4 ()
               (when (> (+ pos 4) n) (fail "short \\u escape"))
               (prog1 (or (parse-integer string :start pos :end (+ pos 4) :radix 16 :junk-allowed t)
                          (fail "bad \\u escape"))
                 (incf pos 4)))
             (read-string ()
               (incf pos)                ; opening quote
               (with-output-to-string (out)
                 (loop
                   (when (>= pos n) (fail "unterminated string"))
                   (let ((c (char string pos)))
                     (incf pos)
                     (cond
                       ((char= c #\") (return))
                       ((char= c #\\)
                        (when (>= pos n) (fail "unterminated escape"))
                        (let ((e (char string pos)))
                          (incf pos)
                          (case e
                            (#\" (write-char #\" out)) (#\\ (write-char #\\ out)) (#\/ (write-char #\/ out))
                            (#\b (write-char #\Backspace out)) (#\f (write-char #\Page out))
                            (#\n (write-char #\Newline out)) (#\r (write-char #\Return out))
                            (#\t (write-char #\Tab out))
                            (#\u (let ((code (hex4)))
                                   ;; A surrogate pair encodes one character above U+FFFF.
                                   (when (and (<= #xD800 code #xDBFF)
                                              (< (+ pos 1) n) (char= (char string pos) #\\)
                                              (char= (char string (1+ pos)) #\u))
                                     (incf pos 2)
                                     (let ((low (hex4)))
                                       (setf code (+ #x10000 (ash (- code #xD800) 10) (- low #xDC00)))))
                                   (write-char (code-char code) out)))
                            (t (fail "bad escape \\~C" e)))))
                       (t (write-char c out)))))))
             (read-number ()
               (let ((start pos))
                 (loop while (and (< pos n) (find (char string pos) "+-0123456789.eE")) do (incf pos))
                 (let ((text (subseq string start pos)))
                   (or (and (every (lambda (c) (or (digit-char-p c) (char= c #\-))) text)
                            (ignore-errors (parse-integer text)))
                       (let ((*read-default-float-format* 'double-float))
                         (handler-case (let ((v (let ((*read-eval* nil)) (read-from-string text))))
                                         (if (realp v) v (fail "bad number")))
                           (error () (fail "bad number"))))))))
             (read-value ()
               (skip-ws)
               (case (peek)
                 ((nil) (fail "unexpected end"))
                 (#\{ (incf pos)
                  (skip-ws)
                  (if (eql (peek) #\})
                      (progn (incf pos) '())
                      (loop collect (progn (skip-ws)
                                           (unless (eql (peek) #\") (fail "expected a key"))
                                           (let ((k (read-string)))
                                             (expect #\:)
                                             (cons k (read-value))))
                            do (skip-ws)
                            until (eql (peek) #\})
                            do (expect #\,)
                            finally (incf pos))))
                 (#\[ (incf pos)
                  (skip-ws)
                  (if (eql (peek) #\])
                      (progn (incf pos) '())
                      (loop collect (read-value)
                            do (skip-ws)
                            until (eql (peek) #\])
                            do (expect #\,)
                            finally (incf pos))))
                 (#\" (read-string))
                 (#\t (literal "true" t))
                 (#\f (literal "false" :false))
                 (#\n (literal "null" :null))
                 (t (read-number)))))
      (prog1 (read-value)
        (skip-ws)
        (when (< pos n) (fail "trailing characters"))))))

(defun write-json-string (string out)
  (write-char #\" out)
  (loop for c across string
        for code = (char-code c)
        do (case c
             (#\" (write-string "\\\"" out))
             (#\\ (write-string "\\\\" out))
             (#\Newline (write-string "\\n" out))
             (#\Return (write-string "\\r" out))
             (#\Tab (write-string "\\t" out))
             (t (if (< code 32)
                    (format out "\\u~4,'0X" code)
                    (write-char c out)))))
  (write-char #\" out))

(defun write-json (value out)
  (cond
    ((eq value t) (write-string "true" out))
    ((or (null value) (eq value :false)) (write-string "false" out))
    ((eq value :null) (write-string "null" out))
    ((stringp value) (write-json-string value out))
    ((integerp value) (format out "~D" value))
    ((realp value) (format out "~F" (coerce value 'double-float)))
    ((and (consp value) (eq (car value) :object))
     (write-char #\{ out)
     (loop for (pair . more) on (cdr value)
           do (write-json-string (string (car pair)) out)
              (write-char #\: out)
              (write-json (cdr pair) out)
              (when more (write-char #\, out)))
     (write-char #\} out))
    ((or (listp value) (vectorp value))
     (write-char #\[ out)
     (let ((first t))
       (map nil (lambda (v)
                  (unless first (write-char #\, out))
                  (setf first nil)
                  (write-json v out))
            value))
     (write-char #\] out))
    ((symbolp value) (write-json-string (string-downcase (symbol-name value)) out))
    ((characterp value) (write-json-string (string value) out))
    (t (write-json-string (princ-to-string value) out))))

(defun json-string (value)
  (with-output-to-string (out) (write-json value out)))

(defun obj (&rest pairs)
  "Build a JSON object from alternating keys and values; NIL values become null."
  (cons :object (loop for (k v) on pairs by #'cddr
                      collect (cons k (if (null v) :null v)))))

;;; Base64

(defparameter +base64+ "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

(defun base64-encode (octets)
  (with-output-to-string (out)
    (loop for i from 0 below (length octets) by 3
          for b0 = (aref octets i)
          for b1 = (if (< (+ i 1) (length octets)) (aref octets (+ i 1)) nil)
          for b2 = (if (< (+ i 2) (length octets)) (aref octets (+ i 2)) nil)
          for n = (logior (ash b0 16) (ash (or b1 0) 8) (or b2 0))
          do (write-char (char +base64+ (ldb (byte 6 18) n)) out)
             (write-char (char +base64+ (ldb (byte 6 12) n)) out)
             (write-char (if b1 (char +base64+ (ldb (byte 6 6) n)) #\=) out)
             (write-char (if b2 (char +base64+ (ldb (byte 6 0) n)) #\=) out))))

(defun base64-decode (string)
  (let ((out (make-array (* 3 (ceiling (length string) 4)) :element-type '(unsigned-byte 8)
                                                         :fill-pointer 0))
        (acc 0) (bits 0))
    (loop for c across string
          for v = (position c +base64+)
          do (cond (v (setf acc (logior (ash acc 6) v)) (incf bits 6)
                      (when (>= bits 8)
                        (decf bits 8)
                        (vector-push (ldb (byte 8 bits) acc) out)
                        (setf acc (ldb (byte bits 0) acc))))
                   ((char= c #\=) (return))
                   ((member c '(#\Space #\Newline #\Return #\Tab)))
                   (t (error 'json-error :message "bad base64"))))
    (coerce out '(simple-array (unsigned-byte 8) (*)))))

;;; Options

(defun option (options name)
  "The value of NAME in the decoded OPTIONS object; false and null are NIL."
  (let ((v (cdr (assoc name options :test #'string=))))
    (if (member v '(:false :null)) nil v)))

(defun option-present-p (options name)
  (assoc name options :test #'string=))

(defvar *stores-lock* (bt:make-lock "capi known-hosts"))
(defvar *stores* (make-hash-table :test 'equal)
  "One FILE-KNOWN-HOSTS per path, so concurrent fetches share its lock.")

(defun file-store (path)
  (bt:with-lock-held (*stores-lock*)
    (let ((key (namestring (merge-pathnames path))))
      (or (gethash key *stores*)
          (setf (gethash key *stores*) (gopher:make-file-known-hosts key))))))

(defun keyword-option (value allowed name)
  (when value
    (or (find value allowed :test #'string-equal)
        (error 'json-error :message (format nil "~A must be one of ~{~(~A~)~^, ~}" name allowed)))))

(defun fetch-arguments (options handle)
  "Translate the decoded OPTIONS object into keyword arguments for FETCH."
  (unless (listp options) (error 'json-error :message "options must be an object"))
  (let ((args '()))
    (macrolet ((arg (key value) `(let ((v ,value)) (when v (push v args) (push ,key args)))))
      (arg :timeout (option options "timeout"))
      (when (option-present-p options "max_size")
        (push (option options "max_size") args) (push :max-size args))
      (arg :tls (let ((v (keyword-option (option options "tls") '(:never :try :require) "tls")))
                  (and v (intern (string-upcase v) :keyword))))
      (arg :verify (let ((v (keyword-option (option options "verify") '(:tofu :none) "verify")))
                     (and v (intern (string-upcase v) :keyword))))
      (arg :known-hosts (let ((p (option options "known_hosts"))) (and p (file-store p))))
      (arg :client-certificate (option options "client_certificate"))
      (arg :client-key (option options "client_key"))
      (arg :query (option options "query"))
      (arg :data (or (option options "data")
                     (let ((b (option options "data_base64"))) (and b (base64-decode b)))))
      (arg :mime-type (option options "mime_type"))
      (arg :token (option options "token"))
      (arg :gopher-plus (option options "gopher_plus"))
      (arg :default-scheme (option options "default_scheme"))
      (when (option-present-p options "follow_redirects")
        (push (and (option options "follow_redirects") t) args) (push :follow-redirects args))
      (arg :max-redirects (option options "max_redirects"))
      (arg :handle handle))
    args))

;;; Cancellation: request_id -> REQUEST-HANDLE.  A cancel that arrives before
;;; its fetch has started leaves a cancelled handle, which that fetch then
;;; picks up and stops on at once.

(defvar *requests-lock* (bt:make-lock "capi requests"))
(defvar *requests* (make-hash-table))

(defun handle-for-id (id)
  (bt:with-lock-held (*requests-lock*)
    (or (gethash id *requests*)
        (setf (gethash id *requests*) (gopher:make-request-handle)))))

(defun release-id (id)
  (bt:with-lock-held (*requests-lock*)
    (remhash id *requests*)))

(defun cancel-request-id (id)
  "Cancel the fetch running with request_id ID.  Returns T if one was
running (or already registered), NIL if the ID was unknown, in which case a
later fetch with that ID is cancelled as soon as it starts."
  (let ((known (bt:with-lock-held (*requests-lock*) (nth-value 1 (gethash id *requests*)))))
    (gopher:cancel-request (handle-for-id id))
    known))

;;; Results

(defun unix-time (universal-time)
  (and universal-time (- universal-time #.(encode-universal-time 0 0 0 1 1 1970 0))))

(defun line-json (line)
  (obj "kind" (string-downcase (symbol-name (gopher:line-kind line)))
       "text" (gopher:line-text line)
       "url" (gopher:line-url line)
       "level" (gopher:line-level line)
       "alt" (gopher:line-alt line)
       "item_type" (and (gopher:line-item-type line) (string (gopher:line-item-type line)))
       "item_kind" (and (gopher:line-item-kind line)
                        (string-downcase (symbol-name (gopher:line-item-kind line))))
       "gopher_plus" (and (gopher:line-gopher-plus-p line) t)))

(defun keyword-json (k) (and k (string-downcase (symbol-name k))))

(defun response-json (response)
  (let* ((document (gopher:response-document response))
         (cert (gopher:response-certificate response))
         (body (gopher:response-body response)))
    (obj "ok" t
         "status" (keyword-json (gopher:response-status response))
         "category" (keyword-json (gopher:response-category response))
         "status_code" (gopher:response-status-code response)
         "meta" (gopher:response-meta response)
         "mime_type" (gopher:response-mime-type response)
         "protocol" (keyword-json (gopher:response-protocol response))
         "url" (gopher:url-string (gopher:response-url response))
         "redirect_url" (let ((u (ignore-errors (gopher:response-redirect-url response))))
                          (and u (gopher:url-string u)))
         "redirects" (or (gopher:response-redirects response) #())
         "bytes" (gopher:response-bytes-read response)
         "trust" (keyword-json (gopher:response-trust response))
         "certificate" (and cert
                            (obj "fingerprint" (gopher:certificate-fingerprint cert)
                                 "not_before" (unix-time (gopher:certificate-not-before cert))
                                 "not_after" (unix-time (gopher:certificate-not-after cert))
                                 "common_names" (or (gopher:certificate-common-names cert) #())))
         "document" (and document
                         (obj "kind" (keyword-json (gopher:document-kind document))
                              "title" (gopher:document-title document)
                              "lines" (map 'vector #'line-json (gopher:document-lines document))))
         "body_base64" (and body (not document) (base64-encode body)))))

(defun error-type-name (condition)
  (string-downcase (symbol-name (type-of condition))))

(defun error-json (condition)
  (obj "ok" :false
       "error"
       (append
        (obj "type" (error-type-name condition)
             "message" (or (ignore-errors (princ-to-string condition)) "error"))
        (when (typep condition 'gopher:certificate-mismatch)
          (list (cons "host" (gopher:mismatch-host condition))
                (cons "port" (gopher:mismatch-port condition))
                (cons "expected_fingerprint"
                      (gopher:known-host-fingerprint (gopher:mismatch-expected condition)))
                (cons "presented_fingerprint"
                      (gopher:certificate-fingerprint (gopher:mismatch-certificate condition))))))))

(defun fetch-json (url options-json)
  "Fetch URL with OPTIONS-JSON (a JSON object string, or NIL) and return the
result as a JSON string.  Never signals."
  (handler-case
      (let* ((options (if (or (null options-json) (string= options-json "")) '()
                          (parse-json options-json)))
             (id (option options "request_id"))
             (accept (option options "accept_new_certificate")))
        (unless (and (stringp url) (plusp (length url)))
          (error 'json-error :message "url is required"))
        (when (and id (not (integerp id)))
          (error 'json-error :message "request_id must be an integer"))
        (unwind-protect
             (let ((args (fetch-arguments options (and id (handle-for-id id)))))
               (json-string
                (response-json
                 (handler-bind ((gopher:certificate-mismatch
                                  (lambda (c) (when accept (gopher:accept-new-certificate c)))))
                   (apply #'gopher:fetch url args)))))
          (when id (release-id id))))
    (serious-condition (c) (json-string (error-json c)))))

;;; Foreign strings

(defun sap-string (sap)
  "The NUL-terminated UTF-8 string at SAP, or NIL for a null pointer."
  (unless (zerop (sb-sys:sap-int sap))
    (let ((n (loop for i from 0 while (/= 0 (sb-sys:sap-ref-8 sap i)) finally (return i))))
      (let ((octets (make-array n :element-type '(unsigned-byte 8))))
        (dotimes (i n) (setf (aref octets i) (sb-sys:sap-ref-8 sap i)))
        (gopher:decode-text octets)))))

(defun malloc-string (string)
  "STRING as a malloc'd NUL-terminated UTF-8 C string; the caller frees it."
  (let* ((octets (babel:string-to-octets string :encoding :utf-8))
         (n (length octets))
         (sap (sb-alien:alien-sap (sb-alien:make-alien (sb-alien:unsigned 8) (1+ n)))))
    (dotimes (i n) (setf (sb-sys:sap-ref-8 sap i) (aref octets i)))
    (setf (sb-sys:sap-ref-8 sap n) 0)
    sap))

(defmacro guarded (&body body)
  "Run BODY so that nothing unwinds into C."
  `(handler-case (progn ,@body)
     (serious-condition (c)
       (malloc-string (json-string (error-json c))))))

;;; The callables.  Their C names are the symbol names with `-' -> `_'.

(sb-alien:define-alien-callable gopher-lisp-fetch sb-alien:system-area-pointer
    ((url sb-alien:system-area-pointer) (options sb-alien:system-area-pointer))
  (guarded (malloc-string (fetch-json (sap-string url) (sap-string options)))))

(sb-alien:define-alien-callable gopher-lisp-cancel sb-alien:int
    ((id sb-alien:long))
  (handler-case (if (cancel-request-id id) 1 0)
    (serious-condition () -1)))

(sb-alien:define-alien-callable gopher-lisp-version sb-alien:system-area-pointer ()
  (guarded (malloc-string *version*)))

(defparameter *callable-exports* '(gopher-lisp-fetch gopher-lisp-cancel gopher-lisp-version))

(defun save-core (path)
  "Save the image to PATH as a core for libgopher.dylib.  Does not return."
  (ensure-directories-exist path)
  (sb-ext:save-lisp-and-die path :callable-exports *callable-exports*))
