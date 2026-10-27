;;;; test/package.lisp

(defpackage #:gopher/test
  (:use #:cl #:fiveam #:gopher)
  (:export #:run-tests))

(in-package #:gopher/test)

(def-suite gopher :description "All gopher library tests.")

(defun run-tests ()
  "Run every suite.  Returns T if all checks passed.  (FIVEAM:RUN! prints
failures but its value is no use to a script.)"
  (let ((results (run 'gopher)))
    (explain! results)
    (results-status results)))

(defparameter *fixtures*
  (asdf:system-relative-pathname :gopher "test/fixtures/"))

(defun fixture (name) (merge-pathnames name *fixtures*))
