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

(defun parse-gemtext (text &optional base-url)
  "Parse gemtext TEXT into a DOCUMENT.  Links are resolved against BASE-URL.
`=:' input-prompt lines (Spartan) are recognised too."
  (let ((lines '()) (pre nil) (pre-alt nil) (title nil)
        (raw (split-lines text)))
    ;; A trailing newline doesn't start an empty last line.
    (when (and raw (string= (car (last raw)) "")) (setf raw (butlast raw)))
    (dolist (l raw)
      (cond
        ((alexandria:starts-with-subseq "```" l)
         (if pre
             (progn (push (make-document-line :kind :preformatted :alt pre-alt
                                              :text (format nil "~{~A~^~%~}" (reverse (cdr pre))))
                          lines)
                    (setf pre nil pre-alt nil))
             (setf pre (list :open)
                   pre-alt (let ((a (trim-ws (subseq l 3)))) (if (string= a "") nil a)))))
        (pre (push l (cdr pre)))
        ((alexandria:starts-with-subseq "=>" l)
         (push (parse-link-line (subseq l 2) base-url :link) lines))
        ((alexandria:starts-with-subseq "=:" l)
         (push (parse-link-line (subseq l 2) base-url :input-prompt) lines))
        ((alexandria:starts-with-subseq "###" l)
         (push (make-document-line :kind :heading :level 3 :text (trim-ws (subseq l 3))) lines))
        ((alexandria:starts-with-subseq "##" l)
         (push (make-document-line :kind :heading :level 2 :text (trim-ws (subseq l 2))) lines))
        ((alexandria:starts-with-subseq "#" l)
         (let ((h (trim-ws (subseq l 1))))
           (unless title (setf title h))
           (push (make-document-line :kind :heading :level 1 :text h) lines)))
        ((alexandria:starts-with-subseq "* " l)
         (push (make-document-line :kind :list-item :text (trim-ws (subseq l 2))) lines))
        ((alexandria:starts-with-subseq ">" l)
         (push (make-document-line :kind :quote :text (trim-ws (subseq l 1))) lines))
        (t (push (make-document-line :kind :text :text l) lines))))
    ;; An unclosed block runs to the end of the document.
    (when pre
      (push (make-document-line :kind :preformatted :alt pre-alt
                                :text (format nil "~{~A~^~%~}" (reverse (cdr pre))))
            lines))
    (make-document :kind :gemtext :lines (coerce (nreverse lines) 'vector) :title title)))
