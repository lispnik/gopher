;;;; docs/generate.lisp -- write docs/API.md from the exported symbols.
;;;;
;;;;   sbcl --non-interactive --load docs/generate.lisp     (or: make docs)
;;;;
;;;; Grouped by source file, in load order, so the reference follows the
;;;; architecture.  Prints the exports that have no docstring.

(require :sb-introspect)
(asdf:load-system :gopher)

(defpackage #:gopher/docs (:use #:cl))
(in-package #:gopher/docs)

(defun definition-file (symbol)
  (let ((source (or (and (fboundp symbol)
                         (ignore-errors (sb-introspect:find-definition-source (fdefinition symbol))))
                    (first (ignore-errors (sb-introspect:find-definition-sources-by-name symbol :structure)))
                    (first (ignore-errors (sb-introspect:find-definition-sources-by-name symbol :class)))
                    (first (ignore-errors (sb-introspect:find-definition-sources-by-name symbol :condition)))
                    (first (ignore-errors (sb-introspect:find-definition-sources-by-name symbol :variable))))))
    (and source (sb-introspect:definition-source-pathname source)
         (pathname-name (sb-introspect:definition-source-pathname source)))))

(defun kind-and-doc (symbol)
  "List of (kind lambda-list doc) for each thing SYMBOL names."
  (let ((out '()))
    (cond ((macro-function symbol)
           (push (list "macro" (sb-introspect:function-lambda-list symbol) (documentation symbol 'function)) out))
          ((typep (and (fboundp symbol) (fdefinition symbol)) 'generic-function)
           (push (list "generic function" (sb-introspect:function-lambda-list symbol)
                       (documentation symbol 'function)) out))
          ((fboundp symbol)
           (push (list "function" (sb-introspect:function-lambda-list symbol) (documentation symbol 'function)) out)))
    (when (boundp symbol)
      (push (list "variable" nil (documentation symbol 'variable)) out))
    (let ((class (find-class symbol nil)))
      (when class
        (push (list (cond ((typep class 'structure-class) "structure")
                          ((subtypep class 'condition) "condition")
                          (t "class"))
                    nil (or (documentation symbol 'type) (documentation class t)))
              out)))
    (nreverse out)))

(defparameter *file-order*
  (mapcar (lambda (c) (asdf:component-name c))
          (asdf:component-children (asdf:find-component :gopher "src"))))

(defun generate (&optional (path (asdf:system-relative-pathname :gopher "docs/API.md")))
  (let ((by-file (make-hash-table :test 'equal)) (undocumented '()))
    (do-external-symbols (s :gopher)
      (push s (gethash (or (definition-file s) "other") by-file)))
    (with-open-file (out path :direction :output :if-exists :supersede :external-format :utf-8)
      (format out "# gopher API reference~%~%Generated from docstrings by `make docs`; ~
                   do not edit by hand.  Sections follow the source files in load order.~%")
      (dolist (file (append *file-order* '("other")))
        (let ((symbols (sort (gethash file by-file) #'string< :key #'symbol-name)))
          (when symbols
            (format out "~%## ~A~%" file)
            (dolist (s symbols)
              (let ((entries (kind-and-doc s)))
                (if (null entries)
                    (format out "~%### `~(~A~)`~%~%*Accessor or restart name.*~%" s)
                    (loop for (kind lambda-list doc) in entries
                          do (format out "~%### `~(~A~)` — ~A~%" s kind)
                             (when (member kind '("function" "generic function" "macro") :test #'string=)
                               (format out "~%```lisp~%(~(~A~)~{ ~(~A~)~})~%```~%"
                                       s (mapcar (lambda (x) (if (consp x) (car x) x)) lambda-list)))
                             (if doc
                                 (format out "~%~A~%" doc)
                                 (pushnew s undocumented)))))))))
      (format t "~&Wrote ~A~%" path)
      (when undocumented
        (format t "~D exports without a docstring:~%~{  ~(~A~)~%~}"
                (length undocumented) (sort undocumented #'string< :key #'symbol-name))))))

(generate)
