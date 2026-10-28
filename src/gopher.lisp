;;;; gopher.lisp -- Gopher (RFC 1436) and Gopher over TLS.
;;;;
;;;; Gopher over TLS has no separate port.  Servers that support it (e.g.
;;;; Gophernicus, geomyidae) detect a TLS ClientHello on the ordinary port.
;;;; So `gophers://' always uses TLS.  `gopher://' with :TLS :TRY attempts
;;;; TLS and falls back to plain text, and remembers which worked for each
;;;; host:port.  Plain `gopher://' with no :TLS option is plain text.

(in-package #:gopher)

(defparameter *gopher-item-types*
  ;; char kind description mime-type
  '((#\0 :text "Text file" "text/plain")
    (#\1 :menu "Menu" "application/gopher-menu")
    (#\2 :cso "CSO phone-book server" "text/plain")
    (#\3 :error "Error" nil)
    (#\4 :binary "BinHex file" "application/mac-binhex40")
    (#\5 :binary "DOS binary" "application/octet-stream")
    (#\6 :binary "uuencoded file" "text/x-uuencode")
    (#\7 :search "Search" "application/gopher-menu")
    (#\8 :telnet "Telnet session" nil)
    (#\9 :binary "Binary file" "application/octet-stream")
    (#\+ :mirror "Mirror server" "application/gopher-menu")
    (#\g :image "GIF image" "image/gif")
    (#\I :image "Image" nil)
    (#\T :telnet "TN3270 session" nil)
    (#\: :image "Bitmap image" "image/bmp")
    (#\; :video "Movie" nil)
    (#\< :sound "Sound" nil)
    (#\d :document "Document" nil)
    (#\h :html "HTML page" "text/html")
    (#\i :info "Informational message" nil)
    (#\p :image "PNG image" "image/png")
    (#\r :document "RTF document" "application/rtf")
    (#\s :sound "Sound" nil)
    (#\P :document "PDF document" "application/pdf")
    (#\X :document "XML document" "application/xml")
    (#\c :calendar "Calendar" "text/calendar")
    (#\M :document "MIME message" "message/rfc822"))
  "Known Gopher item types, including common non-RFC ones.")

(defun gopher-item-entry (type) (assoc type *gopher-item-types*))

(defun gopher-item-kind (type)
  "Classify item TYPE (a character): :MENU :TEXT :SEARCH :BINARY :IMAGE
:SOUND :VIDEO :DOCUMENT :HTML :TELNET :INFO :ERROR :CSO :MIRROR :CALENDAR,
or :UNKNOWN."
  (or (second (gopher-item-entry type)) :unknown))

(defun gopher-item-description (type)
  (or (third (gopher-item-entry type)) "Unknown item type"))

(defun gopher-item-mime-type (type &optional selector)
  "The MIME type to assume for an item of TYPE.  The SELECTOR's extension is
consulted when the type itself does not say (I, s, ;, d, 9, ...)."
  (or (fourth (gopher-item-entry type))
      (guess-mime-type selector)))

;;; Menus

(defun parse-gopher-menu-line (line base-url)
  (when (string= line "") (return-from parse-gopher-menu-line
                            (make-document-line :kind :text :text "")))
  (let* ((type (char line 0))
         (fields (split-string (subseq line 1) #\Tab))
         (display (first fields)))
    (when (< (length fields) 3)
      ;; Not a menu line at all: plenty of servers emit bare text.
      (return-from parse-gopher-menu-line
        (make-document-line :kind :text :text (if (char= type #\i) (subseq line 1) line))))
    (let* ((selector (second fields))
           (host (trim-ws (third fields)))
           (port-field (trim-ws (or (fourth fields) "")))
           (port (or (ignore-errors (parse-integer port-field :junk-allowed t)) 70))
           (plus (fifth fields))
           (plus-p (and plus (plusp (length plus)) (find (char plus 0) "+?")))
           (kind (gopher-item-kind type)))
      (flet ((item (line-kind &optional url)
               (make-document-line :kind line-kind :text display :url url
                                   :item-type type :item-kind kind
                                   :gopher-plus-p (and plus-p t)
                                   :gopher-plus-ask-p (eql plus-p #\?)
                                   :host host :port port :selector selector)))
        (case kind
          (:info (item :text))
          (:error (item :error))
          (:telnet
           (item :link (format nil "~:[telnet~;tn3270~]://~@[~A@~]~A~@[:~D~]"
                               (char= type #\T)
                               (and (plusp (length selector)) (percent-encode selector :safe ""))
                               host (and (/= port 23) (plusp port) port))))
          (t
           (if (and (eq kind :html) (alexandria:starts-with-subseq "URL:" selector))
               (item :link (subseq selector 4))
               (item :link (url-string
                            (make-gopher-url host :port port :type type :selector selector
                                                  :scheme (gopher-link-scheme base-url host port)))))))))))

(defun gopher-link-scheme (base-url host port)
  ;; Stay on TLS for links back to the same server we reached over TLS.
  (if (and base-url (string= (url-scheme base-url) "gophers")
           (string-equal (url-host base-url) host)
           (eql (url-effective-port base-url) port))
      "gophers"
      "gopher"))


;;; Text items: the `.' terminator line and dot-stuffing

(defun gopher-unstuff-text (octets)
  "OCTETS, a Gopher text item, up to its `.' terminator line, with lines that
begin with `..' un-stuffed.  Returns new octets.  The text ends at the first
line that is only `.' (RFC 1436): whatever a server sends after it is not
part of the item.  This is what the streaming parser does too."
  (let* ((n (length octets))
         (end (loop with start = 0
                    while (< start n)
                    do (let* ((lf (position 10 octets :start start))
                              (stop (or lf n))
                              (content-end (if (and (> stop start) (= 13 (aref octets (1- stop))))
                                               (1- stop)
                                               stop)))
                         (when (and (= (- content-end start) 1) (= 46 (aref octets start)))
                           (return start))
                         (setf start (if lf (1+ lf) n)))
                    finally (return n)))
         (out (make-array end :element-type '(unsigned-byte 8) :fill-pointer 0)))
    (loop with line-start = t
          for i from 0 below end
          for b = (aref octets i)
          do (unless (and line-start (= b 46) (< (1+ i) end) (= (aref octets (1+ i)) 46))
               (vector-push b out))
             (setf line-start (= b 10)))
    (coerce out '(simple-array (unsigned-byte 8) (*)))))

(defun gopher-error-text (document)
  "If DOCUMENT is a server error reply -- error items, maybe info lines, no
links -- the error text, else NIL."
  (let ((lines (coerce (document-lines document) 'list)))
    (when (and (some (lambda (l) (eq (line-kind l) :error)) lines)
               (notany (lambda (l) (eq (line-kind l) :link)) lines))
      (line-text (find :error lines :key #'line-kind)))))

(defun looks-like-gopher-error-p (octets)
  ;; "3Some error\tselector\thost\tport" at the start of a text item.
  (and (plusp (length octets)) (= (aref octets 0) 51)
       (let ((nl (or (position 10 octets) (length octets))))
         (>= (count 9 octets :end nl) 3))))

;;; TLS mode selection

(defvar *gopher-tls-hosts* (make-hash-table :test 'equal)
  "host:port -> T or NIL: whether TLS worked there under :TLS :TRY.")
(defvar *gopher-tls-lock* (bt:make-lock "gopher tls cache"))

(defun gopher-tls-mode (url request)
  (cond ((string= (url-scheme url) "gophers") :require)
        (t (or (request-tls request) :never))))

(defun open-gopher-connection (request url host port)
  (ecase (gopher-tls-mode url request)
    (:never (open-connection request url host port))
    (:require (open-connection request url host port :tls t))
    (:try
     (let* ((key (host-key host port))
            (known (bt:with-lock-held (*gopher-tls-lock*)
                     (multiple-value-list (gethash key *gopher-tls-hosts*)))))
       (if (and (second known) (not (first known)))
           (open-connection request url host port)
           (handler-case
               (prog1 (open-connection request url host port :tls t)
                 (bt:with-lock-held (*gopher-tls-lock*)
                   (setf (gethash key *gopher-tls-hosts*) t)))
             ;; A TOFU mismatch is not "server has no TLS": let it through.
             (certificate-mismatch (e) (error e))
             ((or tls-error connection-error stream-error cl+ssl::ssl-error) ()
               (bt:with-lock-held (*gopher-tls-lock*)
                 (setf (gethash key *gopher-tls-hosts*) nil))
               (open-connection request url host port))))))))

;;; What has been learned about servers

(defun gopher-tls-status (host &optional (port 70))
  "What :TLS :TRY found at HOST:PORT: :TLS, :PLAIN, or NIL if never tried."
  (bt:with-lock-held (*gopher-tls-lock*)
    (multiple-value-bind (value found) (gethash (host-key (host-to-ascii host) port) *gopher-tls-hosts*)
      (and found (if value :tls :plain)))))

(defun forget-gopher-tls-status (&optional host (port 70))
  "Forget what :TLS :TRY learned about HOST:PORT, or about every server."
  (bt:with-lock-held (*gopher-tls-lock*)
    (if host
        (remhash (host-key (host-to-ascii host) port) *gopher-tls-hosts*)
        (clrhash *gopher-tls-hosts*))))

;;; The handler

(defun build-gopher-request (selector search plus)
  (format nil "~A~@[~C~A~]~@[~C~A~]"
          selector
          (and (or search plus) #\Tab) (or search plus)
          (and search plus #\Tab) (and search plus)))

(defun gopher-plus-suffix (request url)
  (let ((p (or (request-gopher-plus request) (url-gopher-plus url))))
    (cond ((null p) nil)
          ((eq p t) "+")
          ((member p '("!" "$" "+") :test #'equal) p)
          ((stringp p) (if (alexandria:starts-with-subseq "+" p) p (concatenate 'string "+" p))))))

(define-scheme-handler ("gopher" "gophers") (url request)
  (let* ((type (url-gopher-type url))
         (kind (gopher-item-kind type))
         (selector (url-gopher-selector url))
         (search (or (request-query request) (url-gopher-search url)))
         (answers (request-gopher-plus-answers request))
         (plus (or (gopher-plus-suffix request url) (and answers "+")))
         (host (url-host url))
         (port (url-effective-port url)))
    (cond
      ;; Not fetchable over Gopher: hand the caller the URL to open elsewhere.
      ((eq kind :telnet)
       (make-response url :gopher :redirect
                      :meta (line-url (parse-gopher-menu-line
                                       (format nil "~C~C~A~C~A~C~D" type #\Tab selector #\Tab host #\Tab port)
                                       url))))
      ((and (eq kind :html) (alexandria:starts-with-subseq "URL:" selector))
       (make-response url :gopher :redirect :meta (subseq selector 4)))
      ((and (eq kind :search) (null search) (null plus))
       (make-response url :gopher :input :meta "Search"))
      (t
       (flet ((exchange ()
                (let ((conn (open-gopher-connection request url host port)))
                  (unwind-protect
                       (progn
                         (if answers
                             (send-gopher-plus-answers conn selector plus answers
                                                        (request-gopher-plus-file request))
                             (send-line conn (build-gopher-request selector (and (eq kind :search) search) plus)))
                         (if plus
                             (read-gopher-plus-response conn request url type selector plus)
                             (read-gopher-response conn request url type selector)))
                    (close-connection request conn)))))
         ;; Some servers complete a TLS handshake on the Gopher port and then
         ;; hang up without a byte (a TLS front end for something else).  Under
         ;; :TRY that is not a server that speaks Gopher over TLS: remember it
         ;; as plain and ask again.  The hang-up shows as an empty body, or --
         ;; when a Gopher+ reply's header line was expected -- as a TLS error.
         (if (eq (gopher-tls-mode url request) :try)
             (flet ((plain-again ()
                      (bt:with-lock-held (*gopher-tls-lock*)
                        (setf (gethash (host-key host port) *gopher-tls-hosts*) nil))
                      (exchange)))
               (let ((response (handler-case (exchange)
                                 ((or tls-error cl+ssl::ssl-error empty-response) (e)
                                   (if (eq (gopher-tls-status host port) :tls)
                                       :silent
                                       (error e))))))
                 (cond ((eq response :silent) (plain-again))
                       ((and (response-certificate response)
                             (zerop (response-bytes-read response)))
                        (plain-again))
                       (t response))))
             (exchange)))))))

(defun gopher-response-mime-type (type selector)
  (or (gopher-item-mime-type type selector) "application/octet-stream"))

(defun read-gopher-response (conn request url type selector &key initial)
  "Read a plain Gopher reply.  INITIAL is octets of it already read (the line
a Gopher+ request read before finding it was not Gopher+)."
  (let* ((kind (gopher-item-kind type))
         (textual (member kind '(:menu :text :search :mirror :cso)))
         (mime (gopher-response-mime-type type selector))
         (body nil)
         (count 0))
    ;; COUNT is what came over the wire.  With a :SINK the body is NIL, and
    ;; the count is the only record of how much was written there.
    (setf (values body count)
          (read-body (connection-stream conn) request url :initial initial
                     :parse-as (if (eq kind :text) (cons mime :gopher-text) mime)))
    (when (and body textual (not (eq kind :menu)) (not (eq kind :search)) (not (eq kind :mirror)))
      (setf body (gopher-unstuff-text body)))
    (let ((response (make-response url :gopher :success :mime-type mime :meta mime
                                                        :body body :bytes-read count
                                                        :connection conn)))
      ;; Servers answer a bad selector with an error menu, for any item type.
      (when (and body (or (member kind '(:menu :search :mirror))
                          (and textual (looks-like-gopher-error-p body))))
        (let* ((doc (parse-gopher-menu (decode-text body) url))
               (err (gopher-error-text doc)))
          (when err
            (return-from read-gopher-response
              (make-response url :gopher :not-found :meta err :mime-type mime
                                                    :body body :connection conn)))))
      response)))
