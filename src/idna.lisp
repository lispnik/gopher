;;;; idna.lisp -- international domain names (Punycode, RFC 3492).
;;;;
;;;; PARSE-URL stores hosts in ASCII ("xn--" labels), which is what goes into
;;;; DNS, TLS SNI and request lines; URL-DISPLAY-HOST turns them back into
;;;; Unicode for an address bar.  Labels are lowercased (CHAR-DOWNCASE)
;;;; but the full UTS #46 mapping is not applied: unusual compatibility
;;;; characters are encoded as given.

(in-package #:gopher)

(defconstant +puny-base+ 36)
(defconstant +puny-tmin+ 1)
(defconstant +puny-tmax+ 26)
(defconstant +puny-skew+ 38)
(defconstant +puny-damp+ 700)
(defconstant +puny-initial-bias+ 72)
(defconstant +puny-initial-n+ 128)

(defun puny-adapt (delta numpoints firsttime)
  (setf delta (if firsttime (floor delta +puny-damp+) (floor delta 2)))
  (incf delta (floor delta numpoints))
  (let ((k 0))
    (loop while (> delta (floor (* (- +puny-base+ +puny-tmin+) +puny-tmax+) 2))
          do (setf delta (floor delta (- +puny-base+ +puny-tmin+)))
             (incf k +puny-base+))
    (+ k (floor (* (1+ (- +puny-base+ +puny-tmin+)) delta) (+ delta +puny-skew+)))))

(defun puny-digit (d)
  (code-char (if (< d 26) (+ d 97) (+ (- d 26) 48))))

(defun puny-digit-value (c)
  (cond ((char<= #\a (char-downcase c) #\z) (- (char-code (char-downcase c)) 97))
        ((char<= #\0 c #\9) (+ 26 (- (char-code c) 48)))
        (t nil)))

(defun puny-threshold (k bias)
  (cond ((<= k bias) +puny-tmin+)
        ((>= k (+ bias +puny-tmax+)) +puny-tmax+)
        (t (- k bias))))

(defun punycode-encode (string)
  "Encode STRING with Punycode (without the \"xn--\" prefix)."
  (let* ((codes (map 'list #'char-code string))
         (out (make-string-output-stream))
         (n +puny-initial-n+) (delta 0) (bias +puny-initial-bias+)
         (basic (count-if (lambda (c) (< c 128)) codes))
         (h basic))
    (dolist (c codes) (when (< c 128) (write-char (code-char c) out)))
    (when (plusp basic) (write-char #\- out))
    (loop while (< h (length codes))
          do (let ((m (reduce #'min (remove-if (lambda (c) (< c n)) codes))))
               (incf delta (* (- m n) (1+ h)))
               (setf n m)
               (dolist (c codes)
                 (when (< c n) (incf delta))
                 (when (= c n)
                   (let ((q delta))
                     (loop for k from +puny-base+ by +puny-base+
                           for tt = (puny-threshold k bias)
                           until (< q tt)
                           do (write-char (puny-digit (+ tt (mod (- q tt) (- +puny-base+ tt)))) out)
                              (setf q (floor (- q tt) (- +puny-base+ tt))))
                     (write-char (puny-digit q) out)
                     (setf bias (puny-adapt delta (1+ h) (= h basic))
                           delta 0)
                     (incf h))))
               (incf delta)
               (incf n)))
    (get-output-stream-string out)))

(defun punycode-decode (string)
  "Decode a Punycode STRING (without \"xn--\").  Signals URL-PARSE-ERROR if
it is malformed or decodes to something that is not a character."
  (let* ((dash (position #\- string :from-end t))
         (output (coerce (if dash (subseq string 0 dash) "") 'list))
         (i 0) (n +puny-initial-n+) (bias +puny-initial-bias+)
         (pos (if dash (1+ dash) 0)))
    (loop while (< pos (length string))
          do (let ((oldi i) (w 1))
               (loop for k from +puny-base+ by +puny-base+
                     do (let ((digit (and (< pos (length string))
                                          (puny-digit-value (char string pos)))))
                          (unless digit
                            (error 'url-parse-error :url string
                                                    :message (format nil "Bad Punycode ~S" string)))
                          (incf pos)
                          (incf i (* digit w))
                          (let ((tt (puny-threshold k bias)))
                            (when (< digit tt) (return))
                            (setf w (* w (- +puny-base+ tt))))))
               (let ((len (1+ (length output))))
                 (setf bias (puny-adapt (- i oldi) len (zerop oldi)))
                 (incf n (floor i len))
                 (setf i (mod i len))
                 ;; Past the last character, or a surrogate: no such letter.
                 (when (or (> n #x10FFFF) (<= #xD800 n #xDFFF))
                   (error 'url-parse-error :url string
                                           :message (format nil "Bad Punycode ~S" string)))
                 (setf output (append (subseq output 0 i) (list (code-char n)) (nthcdr i output)))
                 (incf i))))
    (coerce output 'string)))

(defun host-to-ascii (host)
  "HOST with each non-ASCII label Punycode-encoded and prefixed with xn--."
  (if (every (lambda (c) (< (char-code c) 128)) host)
      (string-downcase host)
      (format nil "~{~A~^.~}"
              (mapcar (lambda (label)
                        (let ((label (string-downcase label)))
                          (if (every (lambda (c) (< (char-code c) 128)) label)
                              label
                              (concatenate 'string "xn--" (punycode-encode label)))))
                      ;; Ideographic and fullwidth full stops separate labels too.
                      (split-string (substitute-if #\. (lambda (c) (member c '(#\U+3002 #\U+FF0E #\U+FF61)))
                                                   host)
                                    #\.)))))

(defun host-to-unicode (host)
  "HOST with xn-- labels decoded.  Malformed labels are left as they are."
  (format nil "~{~A~^.~}"
          (mapcar (lambda (label)
                    (if (alexandria:starts-with-subseq "xn--" label :test #'char-equal)
                        (handler-case (punycode-decode (subseq label 4))
                          (error () label))
                        label))
                  (split-string host #\.))))
