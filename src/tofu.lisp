;;;; tofu.lisp -- trust on first use for TLS certificates.
;;;;
;;;; The first certificate seen for host:port is recorded.  Later connections
;;;; must present the same one, until the recorded one expires.  A different,
;;;; unexpired certificate signals CERTIFICATE-MISMATCH with restarts, so a
;;;; browser can ask the user and then continue the same request.
;;;;
;;;; The store is a protocol (LOOKUP-KNOWN-HOST, STORE-KNOWN-HOST,
;;;; FORGET-KNOWN-HOST, LIST-KNOWN-HOSTS).  There is an in-memory store and
;;;; a file-backed one.  An application can subclass KNOWN-HOSTS to keep
;;;; entries elsewhere, such as the macOS keychain.

(in-package #:gopher)

(defstruct known-host
  (host "" :type string)
  (port 0 :type integer)
  (fingerprint "" :type string)
  (expires nil)                     ; universal time the certificate expires, or NIL
  (first-seen (get-universal-time)))

(defclass known-hosts ()
  ((lock :initform (bt:make-recursive-lock "known-hosts") :reader known-hosts-lock))
  (:documentation "Abstract store of trusted certificate fingerprints."))

(defgeneric lookup-known-host (store host port)
  (:documentation "The KNOWN-HOST entry for HOST:PORT, or NIL."))

(defgeneric store-known-host (store entry)
  (:documentation "Record ENTRY, replacing any entry for its host and port."))

(defgeneric forget-known-host (store host port)
  (:documentation "Remove the entry for HOST:PORT."))

(defgeneric list-known-hosts (store)
  (:documentation "Every KNOWN-HOST entry in STORE."))

(defclass memory-known-hosts (known-hosts)
  ((table :initform (make-hash-table :test 'equal) :reader known-hosts-table))
  (:documentation "Known hosts kept in memory only."))

(defun make-memory-known-hosts ()
  (make-instance 'memory-known-hosts))

(defun host-key (host port)
  (format nil "~(~A~):~D" host port))

(defmethod lookup-known-host ((store memory-known-hosts) host port)
  (bt:with-recursive-lock-held ((known-hosts-lock store))
    (gethash (host-key host port) (known-hosts-table store))))

(defmethod store-known-host ((store memory-known-hosts) entry)
  (bt:with-recursive-lock-held ((known-hosts-lock store))
    (setf (gethash (host-key (known-host-host entry) (known-host-port entry))
                   (known-hosts-table store))
          entry)))

(defmethod forget-known-host ((store memory-known-hosts) host port)
  (bt:with-recursive-lock-held ((known-hosts-lock store))
    (remhash (host-key host port) (known-hosts-table store))))

(defmethod list-known-hosts ((store memory-known-hosts))
  (bt:with-recursive-lock-held ((known-hosts-lock store))
    (sort (alexandria:hash-table-values (known-hosts-table store))
          #'string< :key (lambda (e) (host-key (known-host-host e) (known-host-port e))))))

;;; A file, one entry per line:   host port fingerprint expires first-seen
;;; (times are universal times; `-' for an unknown expiry).

(defclass file-known-hosts (memory-known-hosts)
  ((pathname :initarg :pathname :reader known-hosts-pathname)
   (loaded :initform nil))
  (:documentation "Known hosts loaded from, and saved to, a text file."))

(defun make-file-known-hosts (pathname)
  (make-instance 'file-known-hosts :pathname (pathname pathname)))

(defun ensure-loaded (store)
  (with-slots (loaded pathname) store
    (unless loaded
      (setf loaded t)
      (with-open-file (in pathname :if-does-not-exist nil :external-format :utf-8)
        (when in
          (loop for line = (read-line in nil)
                while line
                do (let ((fields (remove "" (split-string (string-trim '(#\Return) line) #\Space)
                                         :test #'string=)))
                     (when (and (>= (length fields) 3)
                                (not (char= (char (first fields) 0) #\#)))
                       (flet ((num (s) (and s (every #'digit-char-p s) (parse-integer s))))
                         (call-next-store-method
                          store
                          (make-known-host :host (first fields)
                                           :port (or (num (second fields)) 0)
                                           :fingerprint (third fields)
                                           :expires (num (fourth fields))
                                           :first-seen (or (num (fifth fields))
                                                           (get-universal-time)))))))))))))

(defun call-next-store-method (store entry)
  (setf (gethash (host-key (known-host-host entry) (known-host-port entry))
                 (known-hosts-table store))
        entry))

(defun save-known-hosts (store)
  ;; The temporary file keeps the target's type: RENAME-FILE merges the new
  ;; name with the old one, so a ".tmp" type would survive the rename.
  (let* ((path (known-hosts-pathname store))
         (tmp (make-pathname :name (format nil "~A.tmp" (pathname-name path)) :defaults path)))
    (ensure-directories-exist path)
    (with-open-file (out tmp :direction :output :if-exists :supersede :external-format :utf-8)
      (format out "# gopher known hosts: host port fingerprint expires first-seen~%")
      (dolist (e (list-known-hosts store))
        (format out "~A ~D ~A ~:[-~;~:*~D~] ~D~%"
                (known-host-host e) (known-host-port e) (known-host-fingerprint e)
                (known-host-expires e) (known-host-first-seen e))))
    (rename-file tmp path)))

(defmethod lookup-known-host :before ((store file-known-hosts) host port)
  (declare (ignore host port))
  (bt:with-recursive-lock-held ((known-hosts-lock store)) (ensure-loaded store)))

(defmethod list-known-hosts :before ((store file-known-hosts))
  (bt:with-recursive-lock-held ((known-hosts-lock store)) (ensure-loaded store)))

(defmethod store-known-host :around ((store file-known-hosts) entry)
  (bt:with-recursive-lock-held ((known-hosts-lock store))
    (ensure-loaded store)
    (prog1 (call-next-method)
      (save-known-hosts store))))

(defmethod forget-known-host :around ((store file-known-hosts) host port)
  (bt:with-recursive-lock-held ((known-hosts-lock store))
    (ensure-loaded store)
    (prog1 (call-next-method)
      (save-known-hosts store))))

(defvar *known-hosts* (make-memory-known-hosts)
  "The store FETCH uses when no :KNOWN-HOSTS is given.")

(defun record-certificate (store host port info)
  (store-known-host store (make-known-host :host (string-downcase host) :port port
                                           :fingerprint (certificate-fingerprint info)
                                           :expires (certificate-not-after info))))

(defun verify-server-certificate (request url host port info)
  "Decide whether to trust INFO for HOST:PORT.  Returns how it was trusted:
:NEW (first visit, now recorded), :TRUSTED (matches the record),
:EXPIRED-REPLACED (record had expired, replaced), :CHANGED (mismatch the
caller accepted), or :UNVERIFIED (verification off).  Signals
CERTIFICATE-MISMATCH or TLS-ERROR otherwise."
  (let ((verify (request-verify request)))
    (cond
      ((eq verify :none) :unverified)
      ((functionp verify)
       (if (funcall verify info host port)
           :trusted
           (error 'tls-error :url url :message "Certificate rejected")))
      (t
       (let* ((store (or (request-known-hosts request) *known-hosts*))
              (entry (lookup-known-host store host port)))
         (cond
           ((null entry)
            (record-certificate store host port info)
            :new)
           ((string-equal (known-host-fingerprint entry) (certificate-fingerprint info))
            :trusted)
           ((and (known-host-expires entry) (> (get-universal-time) (known-host-expires entry)))
            (record-certificate store host port info)
            :expired-replaced)
           (t
            (restart-case
                (error 'certificate-mismatch :url url :host host :port port
                                             :expected entry :certificate info
                                             :message "Certificate changed")
              (accept-new-certificate ()
                :report "Trust the new certificate and continue."
                (record-certificate store host port info)
                :changed)
              (reject-certificate ()
                :report "Do not trust the new certificate."
                (error 'tls-error :url url :message "Changed certificate rejected"))))))))))
