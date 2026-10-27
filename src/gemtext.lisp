;;;; gemtext.lisp -- text/gemini, shared by Gemini, Spartan and Guppy.

(in-package #:gopher)

(defun whitespacep (c) (member c '(#\Space #\Tab)))

(defun trim-ws (s) (string-trim '(#\Space #\Tab) s))

(defun resolve-link (target base-url)
  "TARGET resolved against BASE-URL as a string.  A target that will not
parse is returned unchanged rather than dropped."
  (if base-url
      (handler-case (url-string (merge-url target base-url))
        (url-parse-error () target))
      target))

(defun parse-link-line (rest base-url kind)
  (let* ((rest (string-left-trim '(#\Space #\Tab) rest))
         (end (or (position-if #'whitespacep rest) (length rest)))
         (target (subseq rest 0 end))
         (label (trim-ws (subseq rest end))))
    (if (string= target "")
        (make-document-line :kind :text :text "")
        (make-document-line :kind kind :url (resolve-link target base-url)
                            :text (if (string= label "") target label)))))

(defun split-lines (text)
  (mapcar (lambda (l) (string-right-trim '(#\Return) l)) (split-string text #\Newline)))

