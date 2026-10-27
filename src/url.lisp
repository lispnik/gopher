;;;; url.lisp -- a URL parser that knows the small-web schemes.
;;;;
;;;; A general URL library is the wrong tool here.  A Gopher URL's path is an
;;;; item type plus a selector that is an opaque byte string: `?' and `#' in it
;;;; are literal, and `%09' separates the selector from a search string and a
;;;; Gopher+ string (RFC 4266).  So for gopher:// and gophers:// everything
;;;; after the authority is the path.  Every other scheme gets RFC 3986
;;;; splitting.  The path and query are kept exactly as written
;;;; (percent-encoded), because Gemini, Titan and Guppy send the URL as typed.

(in-package #:gopher)

(defparameter *default-ports*
  '(("gopher" . 70) ("gophers" . 70)
    ("gemini" . 1965) ("titan" . 1965)
    ("spartan" . 300) ("nex" . 1900)
    ("guppy" . 6775) ("finger" . 79))
  "Well-known port for each scheme.")

(defun default-port (scheme)
  "The well-known port for SCHEME (a string), or NIL."
  (cdr (assoc scheme *default-ports* :test #'string-equal)))

(defun opaque-path-scheme-p (scheme)
  (member scheme '("gopher" "gophers") :test #'string-equal))

(defstruct (url (:constructor %make-url))
  (scheme "" :type string)
  (userinfo nil)
  (host "" :type string)
  (port nil)
  (path "" :type string)
  (query nil)
  (fragment nil))

(defun make-url (&key (scheme "gemini") userinfo (host "") port (path "") query fragment)
  "Make a URL.  SCHEME and HOST are lowercased.  PATH, QUERY and FRAGMENT must
already be percent-encoded."
  (%make-url :scheme (string-downcase scheme) :userinfo userinfo
             :host (if (find #\: host) (string-downcase host) (host-to-ascii host))
             :port port :path path
             :query query :fragment fragment))

(defmethod print-object ((u url) stream)
  (print-unreadable-object (u stream :type t)
    (write-string (url-string u) stream)))

(defun url-effective-port (url)
  "URL's explicit port, otherwise its scheme's default port."
  (or (url-port url) (default-port (url-scheme url))))

;;; Percent-encoding

(defun hex-digit-value (char)
  (digit-char-p char 16))

(defun percent-decode-octets (string)
  "Decode %XX escapes in STRING into a vector of octets.  The rest of STRING is
UTF-8 encoded.  A malformed escape is left as written."
  (let ((out (make-array (length string) :element-type '(unsigned-byte 8)
                                         :adjustable t :fill-pointer 0))
        (i 0) (n (length string)))
    (loop while (< i n)
          do (let ((c (char string i)))
               (if (and (char= c #\%) (< (+ i 2) n)
                        (hex-digit-value (char string (+ i 1)))
                        (hex-digit-value (char string (+ i 2))))
                   (progn
                     (vector-push-extend (+ (* 16 (hex-digit-value (char string (+ i 1))))
                                            (hex-digit-value (char string (+ i 2))))
                                         out)
                     (incf i 3))
                   (progn
                     (loop for b across (babel:string-to-octets (string c) :encoding :utf-8)
                           do (vector-push-extend b out))
                     (incf i)))))
    (coerce out '(simple-array (unsigned-byte 8) (*)))))

(defun percent-decode (string)
  "Decode %XX escapes in STRING.  The resulting bytes are read as UTF-8, and
as Latin-1 if they are not valid UTF-8."
  (if (find #\% string)
      (decode-text (percent-decode-octets string))
      string))

(defparameter +unreserved+
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

(defun percent-encode (string &key (safe "/"))
  "Percent-encode STRING as UTF-8.  Unreserved characters and the characters
in SAFE are left alone."
  (with-output-to-string (s)
    (loop for c across string
          do (if (or (find c +unreserved+) (find c safe))
                 (write-char c s)
                 (loop for b across (babel:string-to-octets (string c) :encoding :utf-8)
                       do (format s "%~2,'0X" b))))))

;;; Parsing

(defun scheme-end (string)
  "Index of the `:' that ends STRING's scheme, or NIL if STRING has none."
  (when (and (plusp (length string)) (alpha-char-p (char string 0)))
    (loop for i from 1 below (length string)
          for c = (char string i)
          do (cond ((char= c #\:) (return i))
                   ((not (or (alphanumericp c) (find c "+-."))) (return nil))))))

(defun split-components (string)
  "Split a URL or relative reference into (values SCHEME AUTHORITY PATH QUERY
FRAGMENT), as in RFC 3986 appendix B.  A component that is absent is NIL;
AUTHORITY is \"\" for `scheme:///path'.  PATH is always a string."
  (let* ((colon (scheme-end string))
         (scheme (when colon (string-downcase (subseq string 0 colon))))
         (rest (if colon (subseq string (1+ colon)) string))
         authority)
    (when (and (>= (length rest) 2) (string= "//" rest :end2 2))
      (let ((end (or (position-if (lambda (c) (find c "/?#")) rest :start 2)
                     (length rest))))
        (setf authority (subseq rest 2 end)
              rest (subseq rest end))))
    (if (and scheme (opaque-path-scheme-p scheme))
        (values scheme authority rest nil nil)
        (let* ((hash (position #\# rest))
               (fragment (when hash (subseq rest (1+ hash))))
               (rest (if hash (subseq rest 0 hash) rest))
               (q (position #\? rest))
               (query (when q (subseq rest (1+ q))))
               (path (if q (subseq rest 0 q) rest)))
          (values scheme authority path query fragment)))))

(defun split-authority (authority original)
  "Split AUTHORITY into (values USERINFO HOST PORT)."
  (let* ((at (position #\@ authority :from-end t))
         (userinfo (when at (subseq authority 0 at)))
         (hostport (if at (subseq authority (1+ at)) authority))
         host port-string)
    (if (and (plusp (length hostport)) (char= (char hostport 0) #\[))
        (let ((close (position #\] hostport)))
          (unless close
            (error 'url-parse-error :url original :message "Unterminated IPv6 address"))
          (setf host (subseq hostport 1 close))
          (let ((after (subseq hostport (1+ close))))
            (when (and (plusp (length after)) (char= (char after 0) #\:))
              (setf port-string (subseq after 1)))))
        (let ((colon (position #\: hostport :from-end t)))
          (setf host (if colon (subseq hostport 0 colon) hostport)
                port-string (when colon (subseq hostport (1+ colon))))))
    (values userinfo
            (if (find #\: host) (string-downcase host) (host-to-ascii (percent-decode host)))
            (cond ((or (null port-string) (string= port-string "")) nil)
                  ((every #'digit-char-p port-string)
                   (let ((p (parse-integer port-string)))
                     (unless (<= 0 p 65535)
                       (error 'url-parse-error :url original :message "Port out of range"))
                     p))
                  (t (error 'url-parse-error :url original
                                             :message (format nil "Bad port ~S" port-string)))))))

(defun parse-url (string &key default-scheme)
  "Parse STRING into a URL.  If STRING has no scheme and DEFAULT-SCHEME is
given, it is read as `DEFAULT-SCHEME://STRING', so \"example.org/x\" works as
input from a browser's address bar.  Signals URL-PARSE-ERROR."
  (let ((string (string-trim '(#\Space #\Tab #\Return #\Newline) string)))
    (when (and (null (scheme-end string)) default-scheme)
      (setf string (concatenate 'string default-scheme
                                (if (and (>= (length string) 2) (string= "//" string :end2 2))
                                    ":" "://")
                                string)))
    (multiple-value-bind (scheme authority path query fragment) (split-components string)
      (unless scheme
        (error 'url-parse-error :url string :message "URL has no scheme"))
      (multiple-value-bind (userinfo host port)
          (if authority (split-authority authority string) (values nil "" nil))
        (%make-url :scheme scheme :userinfo userinfo :host host :port port
                   :path path :query query :fragment fragment)))))

(defun ensure-url (thing &key default-scheme)
  "THING if it is a URL, otherwise THING parsed as one."
  (etypecase thing
    (url thing)
    (string (parse-url thing :default-scheme default-scheme))))

(defun url-string (url &key (fragment t))
  "URL as a string.  The scheme's default port is left out.  With :FRAGMENT
NIL, the fragment is left out too, as it must be in a request."
  (with-output-to-string (s)
    (format s "~A:" (url-scheme url))
    (when (or (plusp (length (url-host url))) (url-userinfo url)
              (default-port (url-scheme url)))
      (write-string "//" s)
      (when (url-userinfo url) (format s "~A@" (url-userinfo url)))
      (if (find #\: (url-host url))
          (format s "[~A]" (url-host url))
          (write-string (url-host url) s))
      (when (and (url-port url)
                 (not (eql (url-port url) (default-port (url-scheme url)))))
        (format s ":~D" (url-port url))))
    (write-string (url-path url) s)
    (when (url-query url) (format s "?~A" (url-query url)))
    (when (and fragment (url-fragment url)) (format s "#~A" (url-fragment url)))))

(defun url-display-host (url)
  "URL's host for showing to a person: xn-- labels decoded to Unicode."
  (host-to-unicode (url-host url)))

(defun url-display-string (url)
  "URL as a string for an address bar: the host in Unicode, and the path and
query percent-decoded where that yields readable text."
  (let ((copy (copy-url url)))
    (setf (url-host copy) (url-display-host url))
    (let ((s (url-string copy)))
      (handler-case (let ((d (percent-decode s)))
                      ;; Keep escapes that would change the meaning.
                      (if (find-if (lambda (c) (or (char< c #\Space) (member c '(#\Tab #\Newline)))) d)
                          s d))
        (error () s)))))

(defun url-with-query (url query)
  "A copy of URL whose query is QUERY.  QUERY is percent-encoded here."
  (let ((new (copy-url url)))
    (setf (url-query new) (and query (percent-encode query :safe "")))
    (setf (url-fragment new) nil)
    new))

;;; Resolving relative references (RFC 3986 section 5.2)

(defun remove-dot-segments (path)
  (let ((input path) (output '()))
    (loop while (plusp (length input))
          do (cond ((alexandria:starts-with-subseq "../" input) (setf input (subseq input 3)))
                   ((alexandria:starts-with-subseq "./" input) (setf input (subseq input 2)))
                   ((alexandria:starts-with-subseq "/./" input) (setf input (subseq input 2)))
                   ((string= input "/.") (setf input "/"))
                   ((alexandria:starts-with-subseq "/../" input)
                    (setf input (subseq input 3)) (pop output))
                   ((string= input "/..") (setf input "/") (pop output))
                   ((or (string= input ".") (string= input "..")) (setf input ""))
                   (t (let* ((start (if (char= (char input 0) #\/) 1 0))
                             (end (or (position #\/ input :start start) (length input))))
                        (push (subseq input 0 end) output)
                        (setf input (subseq input end))))))
    (apply #'concatenate 'string (reverse output))))

(defun merge-paths (base reference)
  (if (and (plusp (length (url-host base))) (string= (url-path base) ""))
      (concatenate 'string "/" reference)
      (let ((slash (position #\/ (url-path base) :from-end t)))
        (if slash
            (concatenate 'string (subseq (url-path base) 0 (1+ slash)) reference)
            reference))))

(defun merge-url (reference base)
  "Resolve REFERENCE (a string or URL) against BASE, as a browser resolves a
link.  Returns a new URL."
  (let ((base (ensure-url base)))
    (when (url-p reference)
      (return-from merge-url reference))
    (let ((reference (string-trim '(#\Space #\Tab) reference)))
      (multiple-value-bind (scheme authority path query fragment) (split-components reference)
        (cond
          (scheme (parse-url reference))
          (authority
           (parse-url (concatenate 'string (url-scheme base) ":" reference)))
          ((opaque-path-scheme-p (url-scheme base))
           ;; Gopher has no relative references, but a menu could still
           ;; hold "/1/foo"; treat it as a path on the same server.
           (let ((new (copy-url base)))
             (setf (url-path new) (if (string= path "") (url-path base) path))
             new))
          (t
           (let ((new (copy-url base)))
             (setf (url-fragment new) fragment)
             (cond ((string= path "")
                    (when query (setf (url-query new) query)))
                   (t
                    (setf (url-path new)
                          (remove-dot-segments
                           (if (char= (char path 0) #\/) path (merge-paths base path)))
                          (url-query new) query)))
             new)))))))

;;; Gopher URLs (RFC 4266):  gopher://host:port/<type><selector>%09<search>%09<gopher+>

(defun gopher-path-parts (url)
  (let* ((path (url-path url))
         (path (if (and (plusp (length path)) (char= (char path 0) #\/)) (subseq path 1) path)))
    (if (string= path "")
        (values #\1 "" nil nil)
        (let* ((type (char path 0))
               (decoded (percent-decode (subseq path 1)))
               (tab1 (position #\Tab decoded))
               (tab2 (and tab1 (position #\Tab decoded :start (1+ tab1)))))
          (values type
                  (subseq decoded 0 tab1)
                  (and tab1 (subseq decoded (1+ tab1) tab2))
                  (and tab2 (subseq decoded (1+ tab2))))))))

(defun url-gopher-type (url)
  "The item type character of a Gopher URL (#\\1 when the path is empty)."
  (nth-value 0 (gopher-path-parts url)))

(defun url-gopher-selector (url)
  "The decoded selector of a Gopher URL."
  (nth-value 1 (gopher-path-parts url)))

(defun url-gopher-search (url)
  "The decoded search string of a Gopher URL, or NIL."
  (nth-value 2 (gopher-path-parts url)))

(defun url-gopher-plus (url)
  "The decoded Gopher+ string of a Gopher URL, or NIL."
  (nth-value 3 (gopher-path-parts url)))

(defparameter +selector-safe+ "/:@!$&'()*+,;=?"
  "Characters left literal in an encoded selector.  `#' and `%' are encoded:
other software would read them as a fragment or an escape.")

(defun make-gopher-url (host &key port (type #\1) (selector "") search gopher-plus (scheme "gopher"))
  "A Gopher URL for an item on HOST."
  (make-url :scheme scheme :host host
            :port (if (eql port (default-port scheme)) nil port)
            :path (with-output-to-string (s)
                    (format s "/~C~A" type (percent-encode selector :safe +selector-safe+))
                    (when (or search gopher-plus)
                      (format s "%09~A" (percent-encode (or search "") :safe +selector-safe+)))
                    (when gopher-plus
                      (format s "%09~A" (percent-encode gopher-plus :safe +selector-safe+))))))

;;; Titan URLs:  titan://host/path;mime=text/plain;size=123;token=secret

(defun url-titan-parameters (url)
  "Titan parameters in URL's path as an alist of (name . value) strings, and
the path without them as a second value."
  (let* ((path (url-path url))
         (semi (position #\; path)))
    (if (null semi)
        (values '() path)
        (values (loop for part in (split-string (subseq path (1+ semi)) #\;)
                      for eq = (position #\= part)
                      when (plusp (length part))
                        collect (cons (string-downcase (subseq part 0 eq))
                                      (if eq (percent-decode (subseq part (1+ eq))) "")))
                (subseq path 0 semi)))))

(defun make-titan-url (url &key (mime-type "text/plain") size token)
  "A Titan upload URL for URL's host and path (URL may be gemini:// or
titan://), carrying MIME-TYPE, SIZE and TOKEN."
  (let* ((url (ensure-url url))
         (base-path (nth-value 1 (url-titan-parameters url)))
         (new (copy-url url)))
    (setf (url-scheme new) "titan"
          (url-query new) nil
          (url-fragment new) nil
          (url-path new)
          (with-output-to-string (s)
            (write-string (if (string= base-path "") "/" base-path) s)
            (format s ";mime=~A" (percent-encode mime-type :safe "/+"))
            (when size (format s ";size=~D" size))
            (when token (format s ";token=~A" (percent-encode token :safe "")))))
    new))

(defun split-string (string char)
  (loop with start = 0
        for pos = (position char string :start start)
        collect (subseq string start pos)
        while pos
        do (setf start (1+ pos))))
