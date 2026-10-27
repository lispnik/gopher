;;;; test/encoding-tests.lisp

(in-package #:gopher/test)

(def-suite encoding :in gopher)
(in-suite encoding)

(defun octets (&rest bytes) (coerce bytes '(vector (unsigned-byte 8))))

(test decode-utf-8-and-fallback
  (is (string= "café" (decode-text (babel:string-to-octets "café" :encoding :utf-8))))
  (is (string= "caf\é" (decode-text (octets 99 97 102 #xE9))))
  (is (string= "abc" (decode-text (octets #xEF #xBB #xBF 97 98 99))) "BOM stripped"))

(test decode-declared-charset
  (is (string= "é" (decode-text (octets #xE9) :charset "ISO-8859-1")))
  ;; A declared charset that does not fit falls back rather than failing.
  (is (string= "é" (decode-text (octets #xC3 #xA9) :charset "bogus-charset"))))

(test mime-types
  (multiple-value-bind (type params) (parse-mime-type "Text/Gemini; charset=UTF-8; lang=en")
    (is (string= "text/gemini" type))
    (is (string= "UTF-8" (cdr (assoc "charset" params :test #'string=))))
    (is (string= "en" (cdr (assoc "lang" params :test #'string=)))))
  (is (string= "utf-8" (mime-charset "text/plain; charset=\"utf-8\"")))
  (is (null (mime-charset "text/plain"))))

(test guess-mime-types
  (is (string= "image/png" (guess-mime-type "/pics/cat.PNG")))
  (is (string= "text/gemini" (guess-mime-type "index.gmi")))
  (is (string= "application/octet-stream" (guess-mime-type "/dir.d/file")))
  (is (string= "text/plain" (guess-mime-type "README" :default "text/plain"))))
