;;;; test/gemtext-tests.lisp

(in-package #:gopher/test)

(def-suite gemtext :in gopher)
(in-suite gemtext)

(defparameter *sample-gemtext*
  (format nil "# Title~%## Sub~%### Subsub~%Plain line~%=> /abs Absolute~%=>rel.gmi~%=> gemini://other/x  Other host ~%* item~%> quoted~%```ascii art~% /\\~%/  \\~%```~%=: /search Search here~%~%last"))

(test parse-gemtext-line-kinds
  (let* ((doc (parse-gemtext *sample-gemtext* (parse-url "gemini://h/dir/page.gmi")))
         (lines (coerce (document-lines doc) 'list)))
    (is (eq :gemtext (document-kind doc)))
    (is (string= "Title" (document-title doc)))
    (is (equal '(:heading :heading :heading :text :link :link :link :list-item :quote
                 :preformatted :input-prompt :text :text)
               (mapcar #'line-kind lines)))
    (is (equal '(1 2 3) (mapcar #'line-level (subseq lines 0 3))))
    (destructuring-bind (abs rel other) (subseq lines 4 7)
      (is (string= "gemini://h/abs" (line-url abs)))
      (is (string= "Absolute" (line-text abs)))
      (is (string= "gemini://h/dir/rel.gmi" (line-url rel)))
      (is (string= "rel.gmi" (line-text rel)) "label defaults to the URL")
      (is (string= "gemini://other/x" (line-url other)))
      (is (string= "Other host" (line-text other))))
    (let ((pre (nth 9 lines)))
      (is (string= "ascii art" (line-alt pre)))
      (is (string= (format nil " /\\~%/  \\") (line-text pre))))
    (is (string= "gemini://h/search" (line-url (nth 10 lines))))
    (is (= 4 (length (document-links doc))))))

(test unclosed-preformatted-block
  (let ((doc (parse-gemtext (format nil "```~%a~%b"))))
    (is (= 1 (length (document-lines doc))))
    (is (string= (format nil "a~%b") (line-text (aref (document-lines doc) 0))))))

(test crlf-line-ends
  (let ((doc (parse-gemtext (format nil "# A~C~%=> x~C~%" #\Return #\Return) (parse-url "gemini://h/"))))
    (is (string= "A" (line-text (aref (document-lines doc) 0))))
    (is (string= "gemini://h/x" (line-url (aref (document-lines doc) 1))))))

(test empty-link-is-text
  (is (eq :text (line-kind (aref (document-lines (parse-gemtext "=>   ")) 0)))))
