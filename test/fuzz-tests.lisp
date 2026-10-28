;;;; test/fuzz-tests.lisp -- random and mutated input, against properties that
;;;; must hold for any input.
;;;;
;;;; `make test' runs a few hundred iterations from a fixed seed, so a run is
;;;; quick and repeatable.  `make fuzz' runs many more:
;;;;
;;;;   make fuzz                                   # 20,000 iterations, seed 1
;;;;   make fuzz FUZZ_ITERATIONS=200000 FUZZ_SEED=7
;;;;
;;;; A failure names the property and the smallest input that broke it.  The
;;;; properties:
;;;;
;;;;   - Nothing signals anything but a SMALL-WEB-ERROR, whatever it is given:
;;;;     URLs, Punycode, hosts, text, MIME types, menus, gemtext, Nex
;;;;     directories, Gopher+ attributes and lengths, Gemini headers.
;;;;   - A URL printed and parsed again prints the same.
;;;;   - Percent-encoding and Punycode decode back to what was encoded.
;;;;   - A document streamed in random chunks is the document parsed whole.
;;;;   - Against servers sending mutated replies and noise, cut short or after
;;;;     a stall: a fetch signals nothing but a SMALL-WEB-ERROR, finishes
;;;;     within its deadline, and streams the lines its document has.
;;;;
;;;; Each bug these found has a plain test of its own as well, at the end.

(in-package #:gopher/test)

(def-suite fuzz :in gopher :description "Random input against invariants.")
(in-suite fuzz)

(defun fuzz-setting (name default)
  (let ((value (uiop:getenv name)))
    (or (and value (ignore-errors (parse-integer value))) default)))

(defvar *fuzz-random* (sb-ext:seed-random-state 1))

(defun rnd (n) (random n *fuzz-random*))
(defun pick (sequence) (elt sequence (rnd (length sequence))))
(defun chance (p) (< (random 1.0 *fuzz-random*) p))

;;; Inputs -----------------------------------------------------------------------------

(defparameter +fuzz-characters+
  (concatenate 'string
               (list #\Tab #\Return #\Linefeed #\Space #\. #\+ #\- #\! #\$ #\? #\# #\% #\:
                     #\/ #\@ #\[ #\] #\= #\> #\* #\` #\; #\, #\\ #\" #\' #\~ #\Nul)
               "0123456789abcdefABCDEF"
               (map 'string #'code-char '(#x7f #xa0 #xe9 #x2028 #x200b #x202e #xfeff
                                          #x1f600 #x10ffff #xd7ff #x3000 #xfffd)))
  "Characters that mean something to some parser here, and some that mean
something to Unicode.")

(defun random-character ()
  (if (chance 0.6)
      (char +fuzz-characters+ (rnd (length +fuzz-characters+)))
      (code-char (+ 32 (rnd 95)))))

(defun random-string (max)
  (let ((s (make-string (rnd (1+ max)))))
    (dotimes (i (length s) s) (setf (char s i) (random-character)))))

(defun random-octets (max)
  (let ((v (make-array (rnd (1+ max)) :element-type '(unsigned-byte 8))))
    (dotimes (i (length v) v)
      (setf (aref v i) (if (chance 0.5)
                           (pick #(9 10 13 46 43 45 32 48 49 105 51 58 63 192 224 240 128 191 255 0))
                           (rnd 256))))))

(defun mutate (string)
  "STRING with a few random edits: characters inserted, deleted, duplicated,
replaced, the end cut off, and fragments that mean something to URLs."
  (let ((s (coerce string '(simple-array character (*)))))
    (dotimes (k (1+ (rnd 4)) s)
      (let ((n (length s)))
        (setf s
              (case (rnd 7)
                (0 (let ((i (rnd (1+ n))))
                     (concatenate 'string (subseq s 0 i) (string (random-character)) (subseq s i))))
                (1 (if (zerop n) s
                       (let* ((i (rnd n)) (j (min n (+ i 1 (rnd 8)))))
                         (concatenate 'string (subseq s 0 i) (subseq s j)))))
                (2 (if (zerop n) s
                       (let* ((i (rnd n)) (j (min n (+ i 1 (rnd 20)))))
                         (concatenate 'string (subseq s 0 j) (subseq s i)))))
                (3 (subseq s 0 (rnd (1+ n))))
                (4 (let ((i (rnd (1+ n))))
                     (concatenate 'string (subseq s 0 i) (random-string 6) (subseq s i))))
                (5 (if (zerop n) s
                       (let ((c (copy-seq s))) (setf (char c (rnd n)) (random-character)) c)))
                (t (let ((i (rnd (1+ n))))
                     (concatenate 'string (subseq s 0 i)
                                  (pick '("%" "%0" "%zz" "%09" "://" ":-1" ":99999999999"
                                          "[::1]" "xn--" "xn--a" ".."))
                                  (subseq s i))))))))))

(defparameter +url-seeds+
  '("gopher://gopher.floodgap.com/1/world" "gopher://host:7070/7/v2/vs%09lisp%09+"
    "gophers://h/0/a.txt" "gemini://geminiprotocol.net/docs/?q=a#frag"
    "titan://h/p;mime=text/plain;size=3;token=x" "spartan://mozz.us/" "nex://nightfall.city/a/"
    "guppy://h:6775/x" "finger://h/user" "gemini://xn--bcher-kva.example/"
    "gemini://bücher.example/ä?ö" "gemini://[::1]:1965/" "//h/x" "../a/./b/../c" "?q" "#f"
    "relative/path" "/abs" "gemini://u:p@h/" "about:start" "gopher://h/1/%2541"
    "gemini://h/a%20b" "file:///etc/passwd" "GEMINI://H.EXAMPLE/"))

(defparameter +menu-seed+
  (crlf (format nil "iWelcome~C~Cerror.host~C1" #\Tab #\Tab #\Tab)
        (format nil "1Menu~C/m~Chost~C70" #\Tab #\Tab #\Tab)
        (format nil "0Text~C/t.txt~Chost~C7070~C+" #\Tab #\Tab #\Tab #\Tab)
        (format nil "7Search~C/s~Chost~C70~C?" #\Tab #\Tab #\Tab #\Tab)
        (format nil "hWeb~CURL:https://example.com/~Chost~C70" #\Tab #\Tab #\Tab)
        (format nil "8Telnet~Cuser~Cbbs.host~C23" #\Tab #\Tab #\Tab)
        (format nil "3Error~C~Cerror.host~C1" #\Tab #\Tab #\Tab)
        "not a menu line" "."))

(defparameter +gemtext-seed+
  (format nil "# H1~%## H2~%### H3~%text~%=> /a A~%=>gemini://h/b~%=: /i prompt~%* item~%> quote~%```alt~%pre => not link~%```~%=> ~%=>~%"))

(defparameter +gopher-plus-seed+
  (crlf "+-1" (format nil "+INFO: 0About~C/about~Chost~C70~C+" #\Tab #\Tab #\Tab #\Tab)
        "+ABSTRACT:" " An abstract." "+ADMIN:" " Admin: A <a@b>" " Mod-Date: <20260101000000>"
        "+VIEWS:" " text/plain: <1k>" " text/plain Fr_FR: <2k>" " application/pdf" "+ASK:"
        (format nil " Ask: Name?~CAnon" #\Tab) " AskP: Pw?" (format nil " Choose: C?~Ca~Cb" #\Tab #\Tab)
        " AskL: Lines?" " AskF: File?" " Note: n" "."))

(defun random-text (seed)
  (if (zerop (rnd 3)) (random-string 300) (mutate seed)))

;;; Properties -----------------------------------------------------------------------------

(defvar *fuzz-failures* (make-hash-table :test #'equal)
  "Property -> (input . detail), the smallest input that broke it.")

(defun fuzz-failure (property input detail)
  (let ((old (gethash property *fuzz-failures*)))
    (when (or (null old)
              (< (length (prin1-to-string input)) (length (prin1-to-string (car old)))))
      (setf (gethash property *fuzz-failures*) (cons input detail)))))

(defmacro with-property ((name input) &body body)
  "Run BODY.  A SMALL-WEB-ERROR is an answer; any other error breaks NAME."
  `(let ((%input ,input))
     (handler-case (progn ,@body)
       (small-web-error () nil)
       (error (e) (fuzz-failure ,name %input (format nil "~A: ~A" (type-of e) e))))))

(defun holds (name input ok detail)
  (unless ok (fuzz-failure name input detail)))

(defun line-signature (line)
  (list (line-kind line) (line-text line) (line-url line) (line-level line) (line-alt line)
        (line-item-type line)))

(defun streamed-signatures (octets mime base)
  "The lines of OCTETS as the body streamer delivers them, fed in random chunks."
  (let* ((out '())
         (request (gopher::%make-request
                   :on-lines (lambda (lines) (setf out (append out (coerce lines 'list))))))
         (streamer (gopher::make-body-streamer request base mime))
         (i 0))
    (loop while (< i (length octets))
          do (let ((n (min (- (length octets) i) (1+ (rnd 40)))))
               (gopher::stream-body-chunk streamer (subseq octets i (+ i n)) n)
               (incf i n)))
    (gopher::finish-body-streamer streamer)
    (mapcar #'line-signature out)))

(defun fuzz-pure-once ()
  (let ((base (parse-url "gemini://example.org/dir/page")))
    ;; URLs.
    (let ((s (if (chance 0.3) (random-string 40) (mutate (pick +url-seeds+)))))
      (with-property ("parse-url" s)
        (let* ((u (parse-url s :default-scheme "gopher"))
               (s2 (url-string u))
               (s3 (url-string (parse-url s2))))
          (holds "url-string round trip" s (string= s2 s3) (format nil "~S -> ~S -> ~S" s s2 s3))
          (url-display-string u)
          (when (member (url-scheme u) '("gopher" "gophers") :test #'string=)
            (url-gopher-type u) (url-gopher-selector u) (url-gopher-search u) (url-gopher-plus u))))
      (with-property ("merge-url" s)
        (let ((m (merge-url s base)))
          (holds "a merged URL parses" s (parse-url (url-string m)) (url-string m)))))
    ;; Percent-encoding, Punycode, hosts.
    (let ((s (random-string 30)))
      (with-property ("percent round trip" s)
        (holds "percent round trip" s (string= s (percent-decode (percent-encode s :safe "")))
               (percent-encode s :safe "")))
      (with-property ("percent-decode" s) (percent-decode s)))
    (let ((label (random-string 12)))
      (with-property ("punycode round trip" label)
        (let ((encoded (punycode-encode label)))
          (holds "punycode round trip" label (string= label (punycode-decode encoded)) encoded)))
      (with-property ("punycode-decode" label)
        (punycode-decode (remove-if-not (lambda (c) (< (char-code c) 128)) label)))
      (with-property ("hosts" label) (host-to-unicode (host-to-ascii label))))
    ;; Text and MIME types.
    (let ((octets (random-octets 200))
          (charset (pick '(nil "utf-8" "UTF-8" "latin-1" "iso-8859-1" "us-ascii" "utf-16" "bogus" ""))))
      (with-property ("decode-text" (list octets charset)) (decode-text octets :charset charset)))
    (let ((m (mutate (pick '("text/gemini; charset=utf-8" "text/plain;charset=\"latin-1\""
                             "image/png" "application/octet-stream; a=b; c")))))
      (with-property ("MIME types" m) (parse-mime-type m) (mime-charset m)))
    ;; Documents, whole and streamed.
    (loop for (kind seed mime doc-base)
            in (list (list "menu" +menu-seed+ "application/gopher-menu" (parse-url "gopher://example.org/1/"))
                     (list "gemtext" +gemtext-seed+ "text/gemini" base)
                     (list "nex" (format nil "=> a/ A~%text~%=> ../b~%") "text/x-nex-directory"
                           (parse-url "nex://h/d/"))
                     (list "plain text" +menu-seed+ "text/plain" base))
          do (let* ((text (random-text seed))
                    (octets (if (chance 0.2)
                                (concatenate '(vector (unsigned-byte 8))
                                             (babel:string-to-octets text :encoding :utf-8)
                                             (random-octets 10))
                                (babel:string-to-octets text :encoding :utf-8))))
               (with-property ((format nil "parse ~A" kind) octets)
                 (let ((whole (map 'list #'line-signature
                                   (document-lines (gopher::parse-body-octets mime octets doc-base))))
                       (streamed (streamed-signatures octets mime doc-base)))
                   (holds (format nil "streamed ~A = whole" kind) octets (equal whole streamed)
                          (let ((i (mismatch whole streamed :test #'equal)))
                            (format nil "line ~A: whole ~S, streamed ~S"
                                    i (and i (nth i whole)) (and i (nth i streamed)))))))))
    ;; Gopher+ attributes and lengths, Gemini headers, Gopher text.
    (let ((text (random-text +gopher-plus-seed+)))
      (with-property ("Gopher+ attributes" text)
        (dolist (r (parse-gopher-plus-attributes text (parse-url "gopher://h/0/x")))
          (gopher-plus-record-views r) (gopher-plus-record-admin r)
          (gopher-plus-record-abstract r) (gopher-plus-record-questions r)))
      (with-property ("Gopher+ length" text)
        (gopher::parse-gopher-plus-length (subseq text 0 (min 12 (length text))) base)))
    (let ((line (if (chance 0.5)
                    (random-string 20)
                    (mutate (pick '("20 text/gemini" "31 gemini://h/" "10 Prompt" "51" "60 who?"))))))
      (with-property ("Gemini header" line) (gopher::parse-gemini-header line base)))
    (let ((octets (random-octets 100)))
      (with-property ("Gopher text" octets) (gopher-unstuff-text octets)))))

;;; Hostile servers ----------------------------------------------------------------------

(defvar *hostile-reply* nil
  "What the hostile server sends next: octets, :SILENT (nothing) or :STALL.")

(defun hostile-handler (stream)
  (ignore-errors (read-request-line stream))
  (let ((reply *hostile-reply*))
    (case reply
      (:silent nil)
      (:stall (sleep 4))
      (t (ignore-errors (write-sequence reply stream) (force-output stream))
         (when (chance 0.05) (sleep 4))))))

(defun hostile-reply (kind)
  (if (chance 0.08)
      (pick '(:silent :stall))
      (let ((text
              (unless (chance 0.2)
                (ecase kind
                  (:gemini (mutate (format nil "~A~A~A"
                                           (pick '("20 text/gemini" "20 text/plain; charset=latin-1"
                                                   "20 image/png" "20" "10 Name?" "11 Pw" "30 /next"
                                                   "31 gemini://127.0.0.1/" "44 slow" "51 gone"
                                                   "60 who" "62 bad cert" "99 what" "2 x"))
                                           (pick (list (crlf "") (string #\Newline) ""))
                                           (if (chance 0.5) +gemtext-seed+ (random-string 200)))))
                  (:gopher (mutate (pick (list +menu-seed+ (crlf "text" "..dot" "." "after")
                                               (crlf "3Error" ".") ""))))
                  (:gopher+ (mutate (pick (list +gopher-plus-seed+ (crlf "+-2" "body")
                                                (crlf "+5" "12345") (crlf "+999" "short")
                                                (crlf "--1" "error") (crlf "-2" "x") "+" "+-1"))))
                  (:spartan (mutate (pick (list (format nil "2 text/gemini~C~C~A" #\Return #\Linefeed
                                                        +gemtext-seed+)
                                                (crlf "3 /else") (crlf "4 no") (crlf "5 broken") "2"))))
                  ((:nex :finger) (mutate (pick (list +gemtext-seed+ "plain text" ""))))))))
        (if text
            (let ((octets (babel:string-to-octets text :encoding :utf-8)))
              (if (chance 0.3) (concatenate '(vector (unsigned-byte 8)) octets (random-octets 20)) octets))
            (random-octets 400)))))

(defun hostile-fetch (kind server path &rest options)
  (let* ((scheme (ecase kind (:gemini "gemini") ((:gopher :gopher+) "gopher") (:spartan "spartan")
                   (:nex "nex") (:finger "finger")))
         (url (local-url scheme server path))
         (streamed '())
         (started (get-internal-real-time)))
    (setf *hostile-reply* (hostile-reply kind))
    (with-property ((format nil "fetch ~(~A~)" kind) (list url *hostile-reply*))
      (let* ((r (apply #'fetch url :timeout 2 :deadline 6 :follow-redirects nil
                       :known-hosts (make-memory-known-hosts)
                       :on-lines (lambda (lines) (setf streamed (append streamed (coerce lines 'list))))
                       options))
             (doc (response-document r)))
        (holds (format nil "fetch ~(~A~): streamed = document" kind) (list url *hostile-reply*)
               (or (null doc)
                   (equal (map 'list #'line-text (document-lines doc)) (mapcar #'line-text streamed)))
               (format nil "document ~D lines, streamed ~D"
                       (and doc (length (document-lines doc))) (length streamed)))
        (response-text r) (response-category r) (ignore-errors (response-redirect-url r))))
    (let ((seconds (/ (- (get-internal-real-time) started) internal-time-units-per-second)))
      (holds (format nil "fetch ~(~A~) within its deadline" kind) (list url *hostile-reply*)
             (< seconds 7.5) (format nil "took ~,1F seconds" seconds)))))

(defun fuzz-servers-once (plain tls)
  (hostile-fetch :gemini tls (pick '("/" "/a.gmi" "/?q")))
  (hostile-fetch :gopher plain (pick '("/1/" "/0/t.txt" "/9/b.bin" "/7/s%09q" "/I/i.png")))
  (hostile-fetch :gopher+ plain "/0/about" :gopher-plus (pick '(t "!" "$" "text/plain")))
  (hostile-fetch :spartan plain "/")
  (hostile-fetch :nex plain (pick '("/" "/a.txt")))
  (hostile-fetch :finger plain "/user"))

(defun report-fuzz-failures ()
  "Fail a check for each broken property, saying what broke it."
  (maphash (lambda (property failure)
             (fail "~A~%  input: ~S~%  ~A" property (car failure) (cdr failure)))
           *fuzz-failures*))

(test fuzz-pure-code
  (let ((*fuzz-random* (sb-ext:seed-random-state (fuzz-setting "FUZZ_SEED" 1)))
        (*fuzz-failures* (make-hash-table :test #'equal)))
    (dotimes (i (fuzz-setting "FUZZ_ITERATIONS" 300))
      (fuzz-pure-once))
    (report-fuzz-failures)
    (is (zerop (hash-table-count *fuzz-failures*)))))

(test fuzz-against-hostile-servers
  (let ((*fuzz-random* (sb-ext:seed-random-state (fuzz-setting "FUZZ_SEED" 1)))
        (*fuzz-failures* (make-hash-table :test #'equal)))
    ;; The handler runs on the server's threads, which see the global value.
    (with-server (plain #'hostile-handler)
      (with-server (tls #'hostile-handler :tls t)
        (dotimes (i (max 1 (floor (fuzz-setting "FUZZ_ITERATIONS" 300) 30)))
          (fuzz-servers-once plain tls))))
    (report-fuzz-failures)
    (is (zerop (hash-table-count *fuzz-failures*)))))

;;; What the fuzzing found, each as a plain test -----------------------------------------------

(test a-host-cannot-hold-a-tab
  ;; "%09" as an address made a URL whose host was a tab.
  (signals url-parse-error (parse-url "%09" :default-scheme "gopher"))
  (signals url-parse-error (parse-url "gemini://a%20b/")))

(test bad-punycode-is-a-url-error
  ;; It was a SIMPLE-ERROR, which no caller expects.
  (signals url-parse-error (punycode-decode "1"))
  (signals url-parse-error (punycode-decode "99999999"))
  (is (string= "xn--1.example" (host-to-unicode "xn--1.example"))))

(test percent-decoding-keeps-a-byte-order-mark
  (is (string= (string (code-char #xfeff)) (percent-decode "%EF%BB%BF"))))

(test urls-print-as-they-parse
  ;; A rootless path after an empty authority became the host.
  (is (string= "nex:E" (url-string (parse-url "nex:E"))))
  ;; A path beginning // lost the empty authority that kept it a path.
  (is (string= "file:////" (url-string (parse-url "file:////"))))
  (is (string= "file:////" (url-string (parse-url (url-string (parse-url "file:////")))))))

(test documents-decode-line-by-line
  ;; One Latin-1 line no longer makes every line Latin-1, streamed or whole.
  (let* ((octets (concatenate '(vector (unsigned-byte 8))
                              (babel:string-to-octets (format nil "ünïcode~%") :encoding :utf-8)
                              #(108 97 116 105 110 233 10)))
         (doc (gopher::parse-body-octets "text/plain" octets nil)))
    (is (equal '("ünïcode" "latiné") (map 'list #'line-text (document-lines doc))))))

(test a-final-carriage-return-is-no-line
  (let ((out '()))
    (let ((streamer (gopher::make-body-streamer
                     (gopher::%make-request :on-lines (lambda (l) (setf out (append out (coerce l 'list)))))
                     nil "text/plain")))
      (gopher::stream-body-chunk streamer (coerce #(97 10 13) '(vector (unsigned-byte 8))) 3)
      (gopher::finish-body-streamer streamer))
    (is (equal '("a") (mapcar #'line-text out)))))

(test gopher-text-ends-at-its-first-dot-line
  (is (equalp (babel:string-to-octets (crlf "3") :encoding :utf-8)
              (gopher-unstuff-text (babel:string-to-octets (crlf "3" "." "after" ".")
                                                           :encoding :utf-8)))))

(test a-plain-reply-to-a-gopher-plus-request-streams
  (with-server (s (lambda (stream) (read-request-line stream) (send stream (crlf "plain text" "."))))
    (let* ((streamed '())
           (r (fetch (local-url "gopher" s "/0/x") :gopher-plus t :timeout 5
                     :on-lines (lambda (lines) (setf streamed (append streamed (coerce lines 'list)))))))
      (is (equal '("plain text") (map 'list #'line-text (document-lines (response-document r)))))
      (is (equal '("plain text") (mapcar #'line-text streamed))))))

;;; A hostile Guppy server ------------------------------------------------------------------
;;;
;;; Guppy is UDP: the page is put together from numbered packets, and the server
;;; decides the numbers.  This server answers each request with a script of
;;; packets drawn at random -- a valid exchange, then reordered, duplicated,
;;; cut, given an end before its beginning, data outside the page, status
;;; packets in the middle, bad headers, noise.  The data it sends never holds a
;;; zero byte, so a zero in a page is padding nobody sent.

(defvar *guppy-script* '() "The packets, octet vectors, the server sends next.")

(defun guppy-packet (header &optional (data #()))
  (concatenate '(vector (unsigned-byte 8))
               (babel:string-to-octets (format nil "~A~C~C" header #\Return #\Linefeed) :encoding :utf-8)
               data))

(defun guppy-script ()
  "Packets for one exchange: valid, then mutated."
  (let* ((first (+ 6 (rnd 2000)))
         (text (substitute #\a #\Nul (random-text (if (chance 0.5) +gemtext-seed+ +menu-seed+))))
         (octets (babel:string-to-octets text :encoding :utf-8))
         (size (+ 1 (rnd 40)))
         (chunks (loop for start from 0 below (max 1 (length octets)) by size
                       collect (subseq octets start (min (length octets) (+ start size)))))
         (eof (+ first (length chunks)))
         (packets (append (loop for chunk in chunks
                                for seq from first
                                collect (guppy-packet (if (= seq first)
                                                          (format nil "~D ~A" seq (pick '("text/gemini" "text/plain" "" "text/gemini; charset=latin-1")))
                                                          (format nil "~D" seq))
                                                      chunk))
                          (list (guppy-packet (format nil "~D" eof))))))
    (dotimes (k (rnd 4))
      (setf packets
            (case (rnd 10)
              (0 (sort (copy-list packets) #'< :key (lambda (p) (declare (ignore p)) (rnd 1000))))
              (1 (append packets (list (pick packets))))
              (2 (remove (pick packets) packets :count 1))
              ;; An end at or before the beginning.
              (3 (append packets (list (guppy-packet (format nil "~D" (- first (rnd 3)))))))
              ;; Data before the beginning, or past the end.
              (4 (append packets (list (guppy-packet (format nil "~D" (+ first (if (chance 0.5) -1 (+ 1 (length chunks))))) #(120 121 122)))))
              ;; A status packet in the middle.
              (5 (append packets (list (guppy-packet (format nil "~D ~A" (pick '(1 3 4)) (random-string 10))))))
              ;; Headers that are not.
              (6 (append packets (list (pick (list (random-octets 30) (guppy-packet (random-string 8))
                                                   (guppy-packet (format nil "~D" (rnd 6)))
                                                   (guppy-packet "99999999999999999999"))))))
              ;; The whole exchange is a status.
              (7 (list (guppy-packet (format nil "~D ~A" (pick '(1 3 4)) (random-string 12)))))
              ;; A second "success" header.
              (8 (append packets (list (guppy-packet (format nil "~D text/plain" (+ first 1)) #(65)))))
              (t packets))))
    packets))

(defun start-hostile-guppy ()
  (let* ((socket (usocket:socket-connect nil nil :protocol :datagram :element-type '(unsigned-byte 8)
                                                 :local-host "127.0.0.1" :local-port 0))
         (server (make-fixture-server :socket socket :port (usocket:get-local-port socket))))
    (setf (fixture-server-thread server)
          (bt:make-thread
           (lambda ()
             (let ((buffer (make-array 65536 :element-type '(unsigned-byte 8))))
               (loop until (fixture-server-stop server)
                     do (when (usocket:wait-for-input socket :timeout 0.05 :ready-only t)
                          (multiple-value-bind (buf length host port)
                              (handler-case (usocket:socket-receive socket buffer (length buffer))
                                (error () (values nil 0 nil nil)))
                            (declare (ignore buf))
                            ;; A request (not a bare ACK number): send the script.
                            (when (and host (plusp length)
                                       (notevery (lambda (b) (or (<= 48 b 57) (= b 13) (= b 10)))
                                                 (subseq buffer 0 length)))
                              (dolist (packet *guppy-script*)
                                (ignore-errors
                                 (usocket:socket-send socket packet (length packet)
                                                      :host host :port port)))))))))
           :name "hostile guppy"))
    server))

(defun hostile-guppy-fetch (server)
  (setf *guppy-script* (guppy-script))
  (let ((url (format nil "guppy://127.0.0.1:~D/" (fixture-server-port server)))
        (streamed '())
        (started (get-internal-real-time)))
    (with-property ("fetch guppy" *guppy-script*)
      (let* ((r (fetch url :timeout 2 :deadline 6
                           :on-lines (lambda (lines) (setf streamed (append streamed (coerce lines 'list))))))
             (body (response-body r))
             (doc (response-document r)))
        (holds "guppy: the page holds only what was sent" *guppy-script*
               (not (and body (find 0 body)))
               (format nil "~D bytes, ~D of them zero" (length body) (count 0 body)))
        (holds "fetch guppy: streamed = document" *guppy-script*
               (or (null doc)
                   (equal (map 'list #'line-text (document-lines doc)) (mapcar #'line-text streamed)))
               (format nil "document ~D lines, streamed ~D"
                       (and doc (length (document-lines doc))) (length streamed)))))
    (let ((seconds (/ (- (get-internal-real-time) started) internal-time-units-per-second)))
      (holds "fetch guppy within its deadline" *guppy-script* (< seconds 7.5)
             (format nil "took ~,1F seconds" seconds)))))

(test fuzz-against-a-hostile-guppy-server
  (let ((*fuzz-random* (sb-ext:seed-random-state (fuzz-setting "FUZZ_SEED" 1)))
        (*fuzz-failures* (make-hash-table :test #'equal))
        (server (start-hostile-guppy)))
    (unwind-protect
         (dotimes (i (max 1 (floor (fuzz-setting "FUZZ_ITERATIONS" 300) 10)))
           (hostile-guppy-fetch server))
      (stop-server server))
    (report-fuzz-failures)
    (is (zerop (hash-table-count *fuzz-failures*)))))

(defun guppy-exchange-with (packets)
  "Fetch from a Guppy server that answers with PACKETS."
  ;; Set, not bound: the server's thread reads the global value.
  (setf *guppy-script* packets)
  (let ((server (start-hostile-guppy)))
    (unwind-protect
         (fetch (format nil "guppy://127.0.0.1:~D/" (fixture-server-port server)) :timeout 2)
      (stop-server server))))

(test a-guppy-page-is-only-its-packets
  ;; A data packet past the end made the page longer by zeros.
  (let ((r (guppy-exchange-with (list (guppy-packet "10 text/plain" (babel:string-to-octets "ab"))
                                      (guppy-packet "11" (babel:string-to-octets "cd"))
                                      (guppy-packet "13" (babel:string-to-octets "xyz"))
                                      (guppy-packet "12")))))
    (is (equalp (babel:string-to-octets "abcd") (response-body r)))))

(test a-guppy-page-cannot-end-before-it-begins
  (signals protocol-error
    (guppy-exchange-with (list (guppy-packet "10 text/plain" (babel:string-to-octets "ab"))
                               (guppy-packet "9")))))
