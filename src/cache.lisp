;;;; cache.lisp -- a response cache and a back/forward history.
;;;;
;;;; Both are optional helpers for a browser.  The library never uses them
;;;; unless asked: FETCH consults a RESPONSE-CACHE only when given :CACHE.

(in-package #:gopher)

;;; Response cache: least recently used, bounded by entries and bytes, with
;;; an optional age limit.  Only successful responses with a body are kept,
;;; and never the result of an upload.

(defclass response-cache ()
  ((lock :initform (bt:make-lock "response cache") :reader cache-lock)
   (table :initform (make-hash-table :test 'equal) :reader cache-table) ; key -> entry
   (order :initform '() :accessor cache-order)                          ; keys, most recent first
   (bytes :initform 0 :accessor cache-bytes)
   (max-entries :initarg :max-entries :reader cache-max-entries)
   (max-bytes :initarg :max-bytes :reader cache-max-bytes)
   (max-age :initarg :max-age :reader cache-max-age)))

(defun make-response-cache (&key (max-entries 200) (max-bytes (* 32 1024 1024)) (max-age nil))
  "A cache of up to MAX-ENTRIES responses and MAX-BYTES of bodies.  With
MAX-AGE (seconds), older entries are treated as missing."
  (make-instance 'response-cache :max-entries max-entries :max-bytes max-bytes :max-age max-age))

(defstruct (cache-entry (:constructor make-cache-entry (response time)))
  response time)

(defun cache-key (url request)
  (format nil "~A~@[ q=~A~]~@[ +=~A~]" (url-string url :fragment nil)
          (request-query request) (request-gopher-plus request)))

(defun cacheable-request-p (request)
  (and (null (request-data request)) (null (request-sink request))))

(defun cache-touch (cache key)
  (setf (cache-order cache) (cons key (delete key (cache-order cache) :test #'string=))))

(defun cache-remove-key (cache key)
  (alexandria:when-let ((e (gethash key (cache-table cache))))
    (decf (cache-bytes cache) (length (response-body (cache-entry-response e))))
    (remhash key (cache-table cache))
    (setf (cache-order cache) (delete key (cache-order cache) :test #'string=))))

(defun cache-lookup (cache url &optional (request (%make-request)))
  "The cached RESPONSE for URL (as REQUEST would fetch it), or NIL."
  (let ((key (cache-key (ensure-url url) request)))
    (bt:with-lock-held ((cache-lock cache))
      (alexandria:when-let ((e (gethash key (cache-table cache))))
        (if (and (cache-max-age cache)
                 (> (- (get-universal-time) (cache-entry-time e)) (cache-max-age cache)))
            (progn (cache-remove-key cache key) nil)
            (progn (cache-touch cache key) (cache-entry-response e)))))))

(defun cache-store (cache url response &optional (request (%make-request)))
  "Remember RESPONSE for URL if it is worth caching.  Returns RESPONSE."
  (when (and (response-success-p response) (response-body response) (cacheable-request-p request)
             (or (null (cache-max-bytes cache))
                 (<= (length (response-body response)) (cache-max-bytes cache))))
    (let ((key (cache-key (ensure-url url) request)))
      (bt:with-lock-held ((cache-lock cache))
        (cache-remove-key cache key)
        (setf (gethash key (cache-table cache)) (make-cache-entry response (get-universal-time)))
        (incf (cache-bytes cache) (length (response-body response)))
        (cache-touch cache key)
        (loop while (or (> (hash-table-count (cache-table cache)) (cache-max-entries cache))
                        (and (cache-max-bytes cache) (> (cache-bytes cache) (cache-max-bytes cache))))
              do (cache-remove-key cache (car (last (cache-order cache))))))))
  response)

(defun cache-forget (cache url)
  "Drop every cached response for URL, whatever its query."
  (let ((prefix (url-string (ensure-url url) :fragment nil)))
    (bt:with-lock-held ((cache-lock cache))
      (dolist (key (alexandria:hash-table-keys (cache-table cache)))
        (when (or (string= key prefix) (alexandria:starts-with-subseq (concatenate 'string prefix " ") key))
          (cache-remove-key cache key))))))

(defun cache-clear (cache)
  (bt:with-lock-held ((cache-lock cache))
    (clrhash (cache-table cache))
    (setf (cache-order cache) '() (cache-bytes cache) 0)))

(defun cache-count (cache)
  (bt:with-lock-held ((cache-lock cache)) (hash-table-count (cache-table cache))))

;;; History: a list of visited URL strings and a position, like a browser tab.

(defstruct (history (:constructor make-history ()))
  (lock (bt:make-lock "history"))
  (entries (make-array 0 :adjustable t :fill-pointer 0))
  (position -1))

(defun history-visit (history url)
  "Record a visit to URL: forward entries are dropped.  Visiting the current
URL again changes nothing.  Returns the URL string."
  (let ((u (if (url-p url) (url-string url) url)))
    (bt:with-lock-held ((history-lock history))
      (let ((entries (history-entries history)) (pos (history-position history)))
        (unless (and (>= pos 0) (string= u (aref entries pos)))
          (setf (fill-pointer entries) (1+ pos))
          (vector-push-extend u entries)
          (setf (history-position history) (1- (length entries))))))
    u))

(defun history-current (history)
  (bt:with-lock-held ((history-lock history))
    (let ((pos (history-position history)))
      (and (>= pos 0) (aref (history-entries history) pos)))))

(defun history-back-p (history) (plusp (history-position history)))

(defun history-forward-p (history)
  (< (1+ (history-position history)) (length (history-entries history))))

(defun history-back (history)
  "Step back.  Returns the URL now current, or NIL if there is nothing behind."
  (bt:with-lock-held ((history-lock history))
    (when (plusp (history-position history))
      (aref (history-entries history) (decf (history-position history))))))

(defun history-forward (history)
  "Step forward.  Returns the URL now current, or NIL at the end."
  (bt:with-lock-held ((history-lock history))
    (when (< (1+ (history-position history)) (length (history-entries history)))
      (aref (history-entries history) (incf (history-position history))))))

(defun history-list (history)
  "All entries, oldest first, and the current index as a second value."
  (bt:with-lock-held ((history-lock history))
    (values (coerce (history-entries history) 'list) (history-position history))))
