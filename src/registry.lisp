;;;; registry.lisp -- which function fetches which URL scheme.
;;;;
;;;; FETCH only looks up a handler here; adding a protocol is one
;;;; DEFINE-SCHEME-HANDLER form.  A handler receives the URL and the REQUEST
;;;; (the options) and returns a RESPONSE.  It runs inside WITH-NETWORK-ERRORS.

(in-package #:gopher)

(defvar *scheme-handlers* (make-hash-table :test 'equalp))

(defmacro define-scheme-handler (schemes (url-var request-var) &body body)
  "Define the handler for SCHEMES (a string or list of strings)."
  (let ((fn (gensym "HANDLER")))
    `(let ((,fn (lambda (,url-var ,request-var)
                  (declare (ignorable ,request-var))
                  ,@body)))
       (dolist (s (alexandria:ensure-list ',schemes))
         (setf (gethash s *scheme-handlers*) ,fn)))))

(defun find-scheme-handler (scheme)
  (gethash scheme *scheme-handlers*))

(defun supported-schemes ()
  (sort (alexandria:hash-table-keys *scheme-handlers*) #'string<))
