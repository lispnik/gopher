;;;; parsers.lisp -- line-at-a-time document parsers, and body streaming.
;;;;
;;;; Every text format is parsed by a LINE-PARSER that takes one source line
;;;; at a time and returns the DOCUMENT-LINEs it completes.  The same parser
;;;; builds a whole DOCUMENT (PARSE-GEMTEXT and friends) and feeds a browser
;;;; while a page is still downloading (FETCH's :ON-LINES), so the streamed
;;;; lines are exactly the lines of the finished document.  The only lag is a
;;;; gemtext preformatted block, which is delivered when its closing ``` arrives.

(in-package #:gopher)

(defclass line-parser ()
  ((base-url :initarg :base-url :initform nil :reader parser-base-url)
   (title :initform nil :accessor parser-title)))

(defgeneric parser-feed (parser line)
  (:documentation "Consume one source LINE (no line end).  Returns the list of
DOCUMENT-LINEs it completes."))

(defgeneric parser-finish (parser)
  (:documentation "End of input.  Returns any DOCUMENT-LINEs still pending.")
  (:method ((p line-parser)) '()))

(defgeneric parser-document-kind (parser))

;;; text/gemini

(defclass gemtext-parser (line-parser)
  ((pre :initform nil :accessor pre)            ; list of lines while in a block
   (in-pre :initform nil :accessor in-pre)
   (pre-alt :initform nil :accessor pre-alt)))

(defmethod parser-document-kind ((p gemtext-parser)) :gemtext)

(defun close-pre-block (p)
  (prog1 (make-document-line :kind :preformatted :alt (pre-alt p)
                             :text (format nil "~{~A~^~%~}" (reverse (pre p))))
    (setf (pre p) nil (in-pre p) nil (pre-alt p) nil)))

(defmethod parser-feed ((p gemtext-parser) l)
  (let ((base (parser-base-url p)))
    (cond
      ((alexandria:starts-with-subseq "```" l)
       (if (in-pre p)
           (list (close-pre-block p))
           (progn (setf (in-pre p) t
                        (pre-alt p) (let ((a (trim-ws (subseq l 3)))) (if (string= a "") nil a)))
                  '())))
      ((in-pre p) (push l (pre p)) '())
      ((alexandria:starts-with-subseq "=>" l) (list (parse-link-line (subseq l 2) base :link)))
      ((alexandria:starts-with-subseq "=:" l) (list (parse-link-line (subseq l 2) base :input-prompt)))
      ((alexandria:starts-with-subseq "###" l)
       (list (make-document-line :kind :heading :level 3 :text (trim-ws (subseq l 3)))))
      ((alexandria:starts-with-subseq "##" l)
       (list (make-document-line :kind :heading :level 2 :text (trim-ws (subseq l 2)))))
      ((alexandria:starts-with-subseq "#" l)
       (let ((h (trim-ws (subseq l 1))))
         (unless (parser-title p) (setf (parser-title p) h))
         (list (make-document-line :kind :heading :level 1 :text h))))
      ((alexandria:starts-with-subseq "* " l)
       (list (make-document-line :kind :list-item :text (trim-ws (subseq l 2)))))
      ((alexandria:starts-with-subseq ">" l)
       (list (make-document-line :kind :quote :text (trim-ws (subseq l 1)))))
      (t (list (make-document-line :kind :text :text l))))))

(defmethod parser-finish ((p gemtext-parser))
  ;; An unclosed block runs to the end of the document.
  (if (in-pre p) (list (close-pre-block p)) '()))

;;; Gopher menus

(defclass gopher-menu-parser (line-parser)
  ((done :initform nil :accessor done)
   (blank :initform 0 :accessor blank)))       ; blank lines held back

(defmethod parser-document-kind ((p gopher-menu-parser)) :menu)

(defmethod parser-feed ((p gopher-menu-parser) l)
  (cond ((done p) '())
        ((string= l ".") (setf (done p) t) '())
        ;; Hold blank lines until something follows, so trailing ones vanish.
        ((string= l "") (incf (blank p)) '())
        (t (let ((held (loop repeat (blank p) collect (make-document-line :kind :text :text ""))))
             (setf (blank p) 0)
             (append held (list (parse-gopher-menu-line l (parser-base-url p))))))))

;;; Nex directories

(defclass nex-directory-parser (line-parser) ())

(defmethod parser-document-kind ((p nex-directory-parser)) :nex-directory)

(defmethod parser-feed ((p nex-directory-parser) l)
  (list (if (alexandria:starts-with-subseq "=>" l)
            (parse-link-line (subseq l 2) (parser-base-url p) :link)
            (make-document-line :kind :text :text l))))

;;; Plain text: one :PREFORMATTED line per source line.  As a Gopher text
;;; item it also stops at the `.' line and un-stuffs `..'.

(defclass plain-text-parser (line-parser)
  ((gopher-text :initarg :gopher-text :initform nil :reader gopher-text)
   (done :initform nil :accessor done)))

(defmethod parser-document-kind ((p plain-text-parser)) :text)

(defmethod parser-feed ((p plain-text-parser) l)
  (cond ((done p) '())
        ((and (gopher-text p) (string= l ".")) (setf (done p) t) '())
        (t (list (make-document-line
                  :kind :preformatted
                  :text (if (and (gopher-text p) (alexandria:starts-with-subseq ".." l))
                            (subseq l 1)
                            l))))))

;;; Choosing and running a parser

(defun make-line-parser (mime-type base-url &key gopher-text)
  "A LINE-PARSER for MIME-TYPE, or NIL if it is not a text type."
  (let ((mime (parse-mime-type mime-type)))
    (cond ((null mime) nil)
          ((string= mime "application/gopher-menu")
           (make-instance 'gopher-menu-parser :base-url base-url))
          ((string= mime "text/gemini") (make-instance 'gemtext-parser :base-url base-url))
          ((string= mime "text/x-nex-directory")
           (make-instance 'nex-directory-parser :base-url base-url))
          ((text-mime-type-p mime)
           (make-instance 'plain-text-parser :base-url base-url :gopher-text gopher-text))
          (t nil))))

(defun parse-text-with (parser text)
  "Run PARSER over all of TEXT and return the DOCUMENT."
  (parse-lines-with parser (split-lines text)))

(defun parse-octets-with (parser octets &key charset)
  "Run PARSER over OCTETS, a body, decoded line by line (see DECODE-LINE):
the same lines the body streamer delivers."
  (parse-lines-with parser (mapcar (lambda (l) (decode-line l :charset charset))
                                   (octet-lines octets))))

(defun parse-lines-with (parser raw)
  "Run PARSER over RAW, the lines of a document, and return the DOCUMENT."
  (let ((lines '()))
    ;; A final line end doesn't start an empty last line.
    (when (and raw (string= (car (last raw)) "")) (setf raw (butlast raw)))
    (dolist (l raw)
      (dolist (d (parser-feed parser l)) (push d lines)))
    (dolist (d (parser-finish parser)) (push d lines))
    (make-document :kind (parser-document-kind parser)
                   :lines (coerce (nreverse lines) 'vector)
                   :title (parser-title parser))))

(defun parse-gemtext (text &optional base-url)
  "Parse gemtext TEXT into a DOCUMENT.  Links are resolved against BASE-URL.
`=:' input-prompt lines (Spartan) are recognised too."
  (parse-text-with (make-instance 'gemtext-parser :base-url base-url) text))

(defun parse-gopher-menu (text &optional base-url)
  "Parse a Gopher menu into a DOCUMENT of kind :MENU.  Tolerates a missing
`.' terminator, bare LF line ends, and lines that are not menu lines."
  (parse-text-with (make-instance 'gopher-menu-parser :base-url base-url) text))

(defun parse-nex-directory (text &optional base-url)
  "A Nex directory listing as a DOCUMENT: `=> ' lines are links, the rest text."
  (parse-text-with (make-instance 'nex-directory-parser :base-url base-url) text))

(defun parse-plain-text (text)
  "A plain-text DOCUMENT: one :PREFORMATTED line per line of TEXT."
  (parse-text-with (make-instance 'plain-text-parser) text))

;;; Streaming a body as it arrives

(defstruct (body-streamer (:constructor %make-body-streamer))
  on-data on-lines parser charset
  (pending (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))

(defun make-body-streamer (request url parse-as)
  "A BODY-STREAMER for READ-BODY, or NIL when the request wants no streaming."
  (let ((on-data (request-on-data request))
        (on-lines (request-on-lines request)))
    (when (or on-data on-lines)
      (let* ((mime (if (consp parse-as) (car parse-as) parse-as))
             (parser (and on-lines mime
                          (make-line-parser mime url :gopher-text (and (consp parse-as)
                                                                       (eq (cdr parse-as) :gopher-text))))))
        (make-%body-streamer on-data (and parser on-lines) parser (mime-charset mime))))))

(defun make-%body-streamer (on-data on-lines parser charset)
  (%make-body-streamer :on-data on-data :on-lines on-lines :parser parser :charset charset))

(defun deliver-lines (streamer source-lines)
  (let ((out '()))
    (dolist (l source-lines)
      (dolist (d (parser-feed (body-streamer-parser streamer) l)) (push d out)))
    (when out (funcall (body-streamer-on-lines streamer) (nreverse out)))))

(defun stream-body-chunk (streamer octets end)
  (alexandria:when-let ((f (body-streamer-on-data streamer)))
    (funcall f (subseq octets 0 end)))
  (when (body-streamer-parser streamer)
    (let ((pending (body-streamer-pending streamer)))
      (loop for i below end do (vector-push-extend (aref octets i) pending))
      ;; Decode only up to the last LF: it never occurs inside a multi-byte
      ;; UTF-8 sequence, so no character is split.
      (alexandria:when-let ((lf (position 10 pending :from-end t)))
        (let ((complete (subseq pending 0 (1+ lf)))
              (rest (subseq pending (1+ lf))))
          (setf (fill-pointer pending) 0)
          (loop for b across rest do (vector-push-extend b pending))
          (deliver-lines streamer
                         (mapcar (lambda (l) (decode-line l :charset (body-streamer-charset streamer)))
                                 (butlast (octet-lines complete)))))))))

(defun finish-body-streamer (streamer)
  (alexandria:when-let ((parser (body-streamer-parser streamer)))
    (let ((pending (body-streamer-pending streamer)))
      (when (plusp (length pending))
        (let ((line (decode-line pending :charset (body-streamer-charset streamer))))
          ;; As in PARSE-LINES-WITH: what follows the last line end is a
          ;; line only if there is something in it.
          (when (plusp (length line))
            (deliver-lines streamer (list line))))
        (setf (fill-pointer pending) 0)))
    (alexandria:when-let ((last (parser-finish parser)))
      (funcall (body-streamer-on-lines streamer) last))))
