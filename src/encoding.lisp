;;;; encoding.lisp -- bytes to text, MIME types.
;;;;
;;;; Old Gopherspace is full of Latin-1 and CP437 text served with no
;;;; declared charset, so decoding never fails.  A declared charset babel knows
;;;; is used first, then UTF-8, then Latin-1, which maps every byte.

(in-package #:gopher)

(defun strip-bom (octets)
  (if (and (>= (length octets) 3)
           (= (aref octets 0) #xEF) (= (aref octets 1) #xBB) (= (aref octets 2) #xBF))
      (subseq octets 3)
      octets))

(defun charset-keyword (charset)
  (let ((name (string-upcase (string-trim " \"'" charset))))
    (cond ((member name '("UTF8" "UTF-8") :test #'string=) :utf-8)
          ((member name '("LATIN1" "LATIN-1" "ISO-8859-1" "ISO8859-1") :test #'string=) :latin-1)
          ((member name '("US-ASCII" "ASCII") :test #'string=) :ascii)
          ((member name '("WINDOWS-1252" "CP1252") :test #'string=) :cp1252)
          (t (let ((kw (find-symbol name :keyword)))
               (and kw (ignore-errors (babel-encodings:get-character-encoding kw)) kw))))))

(defun decode-text (octets &key charset)
  "Decode OCTETS into a string.  CHARSET (a string such as \"iso-8859-1\")
is tried first when babel knows it, then UTF-8, then Latin-1."
  (let ((octets (strip-bom (coerce octets '(simple-array (unsigned-byte 8) (*)))))
        (declared (and charset (charset-keyword charset))))
    (or (and declared
             (ignore-errors (babel:octets-to-string octets :encoding declared :errorp t)))
        (ignore-errors (babel:octets-to-string octets :encoding :utf-8 :errorp t))
        (babel:octets-to-string octets :encoding :latin-1))))

(defun octet-lines (octets)
  "OCTETS split at each LF, as octet vectors without it.  The last is what
follows the last LF: empty when OCTETS ends with one."
  (let ((octets (coerce octets '(simple-array (unsigned-byte 8) (*)))))
    (loop with start = 0
          for lf = (position 10 octets :start start)
          collect (subseq octets start lf)
          while lf
          do (setf start (1+ lf)))))

(defun decode-line (octets &key charset)
  "One line of text, decoded as DECODE-TEXT decodes, without a final CR.
Decoding line by line means a document mixing UTF-8 with Latin-1 (old
Gopher holes are full of them) has each line read as well as it can be,
rather than all of it as Latin-1 for one stray byte."
  (string-right-trim '(#\Return) (decode-text octets :charset charset)))

(defun encode-text (string)
  (babel:string-to-octets string :encoding :utf-8))

(defun parse-mime-type (string)
  "Split a MIME type such as \"text/gemini; charset=utf-8; lang=en\" into
(values \"text/gemini\" ((\"charset\" . \"utf-8\") (\"lang\" . \"en\")))."
  (if (null string)
      (values nil '())
      (let ((parts (split-string string #\;)))
        (values (string-downcase (string-trim " " (first parts)))
                (loop for p in (rest parts)
                      for eq = (position #\= p)
                      when eq
                        collect (cons (string-downcase (string-trim " " (subseq p 0 eq)))
                                      (string-trim " \"" (subseq p (1+ eq)))))))))

(defun mime-charset (mime-type)
  "The charset parameter of MIME-TYPE, or NIL."
  (cdr (assoc "charset" (nth-value 1 (parse-mime-type mime-type)) :test #'string=)))

(defparameter *extension-mime-types*
  '(("txt" . "text/plain") ("text" . "text/plain") ("md" . "text/markdown")
    ("gmi" . "text/gemini") ("gemini" . "text/gemini")
    ("htm" . "text/html") ("html" . "text/html") ("xml" . "application/xml")
    ("css" . "text/css") ("csv" . "text/csv") ("json" . "application/json")
    ("rss" . "application/rss+xml") ("atom" . "application/atom+xml")
    ("gif" . "image/gif") ("png" . "image/png") ("jpg" . "image/jpeg")
    ("jpeg" . "image/jpeg") ("webp" . "image/webp") ("svg" . "image/svg+xml")
    ("bmp" . "image/bmp") ("ico" . "image/x-icon") ("tif" . "image/tiff") ("tiff" . "image/tiff")
    ("mp3" . "audio/mpeg") ("ogg" . "audio/ogg") ("oga" . "audio/ogg") ("opus" . "audio/opus")
    ("flac" . "audio/flac") ("wav" . "audio/wav") ("mid" . "audio/midi")
    ("mp4" . "video/mp4") ("webm" . "video/webm") ("mkv" . "video/x-matroska")
    ("pdf" . "application/pdf") ("ps" . "application/postscript")
    ("rtf" . "application/rtf") ("zip" . "application/zip") ("gz" . "application/gzip")
    ("tgz" . "application/gzip") ("tar" . "application/x-tar") ("bz2" . "application/x-bzip2")
    ("xz" . "application/x-xz") ("epub" . "application/epub+zip"))
  "Fallback MIME types by file extension, for protocols that send none.")

(defun guess-mime-type (path &key (default "application/octet-stream"))
  "Guess a MIME type from PATH's extension, otherwise DEFAULT."
  (let* ((path (or path ""))
         (slash (or (position #\/ path :from-end t) -1))
         (dot (position #\. path :from-end t)))
    (or (and dot (> dot slash)
             (cdr (assoc (subseq path (1+ dot)) *extension-mime-types* :test #'string-equal)))
        default)))
