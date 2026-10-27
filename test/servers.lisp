;;;; test/servers.lisp -- in-process fixture servers.
;;;;
;;;; Every protocol is tested against a real socket on 127.0.0.1 and an
;;;; ephemeral port, so the client's own transport code is exercised and the
;;;; suite needs no network.  A TCP fixture is a function of one binary
;;;; stream: it reads the request and writes the reply.  Returning :ABRUPT
;;;; closes the socket without a TLS close_notify, as many Gemini servers do.

(in-package #:gopher/test)

(defstruct fixture-server socket thread port (stop nil) (log '()) (lock (bt:make-lock)))

(defun note (server thing)
  (bt:with-lock-held ((fixture-server-lock server))
    (push thing (fixture-server-log server))))

(defun server-log (server)
  "What the server recorded (usually request lines), oldest first."
  (bt:with-lock-held ((fixture-server-lock server))
    (reverse (fixture-server-log server))))

(defvar *server* nil "The fixture server running the current handler.")

(defun read-request-line (stream)
  "Read one line of octets and return it as a string without CR/LF."
  (let ((buf (make-array 64 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (loop for b = (read-byte stream nil nil)
          until (or (null b) (= b 10))
          do (vector-push-extend b buf))
    (when (and (plusp (length buf)) (= (aref buf (1- (length buf))) 13))
      (decf (fill-pointer buf)))
    (babel:octets-to-string (coerce buf '(simple-array (unsigned-byte 8) (*))) :encoding :utf-8)))

(defun read-n-octets (stream n)
  (let ((buf (make-array n :element-type '(unsigned-byte 8))))
    (let ((got (read-sequence buf stream)))
      (subseq buf 0 got))))

(defun send (stream &rest strings)
  "Write STRINGS to STREAM as UTF-8; ~R in a string is not special, use CRLF."
  (dolist (s strings)
    (write-sequence (if (stringp s) (babel:string-to-octets s :encoding :utf-8) s) stream))
  (force-output stream))

(defun crlf (&rest lines)
  (format nil "~{~A~C~C~}" (loop for l in lines append (list l #\Return #\Newline))))

(defvar *client-cert-context* nil)

(defun client-cert-context ()
  ;; A context that asks for (but does not demand) a client certificate and
  ;; trusts the fixture client certificate, so a handler can see it.
  (or *client-cert-context*
      (setf *client-cert-context*
            (cl+ssl:make-context :verify-mode cl+ssl:+ssl-verify-peer+
                                 :verify-location (list (namestring (fixture "client-cert.pem")))))))

(defun serve-connection (server client handler tls certificate key request-client-cert)
  (let ((*server* server) (result nil) (stream nil))
    (unwind-protect
         (handler-case
             (let ((raw (usocket:socket-stream client)))
               (setf stream
                     (if tls
                         (flet ((make () (cl+ssl:make-ssl-server-stream
                                          raw :certificate (namestring certificate)
                                              :key (namestring key))))
                           (if request-client-cert
                               (cl+ssl:with-global-context ((client-cert-context)) (make))
                               (make)))
                         raw))
               (setf result (funcall handler stream))
               (ignore-errors (force-output stream)))
           (error (e) (note server (list :error (princ-to-string e)))))
      (unless (or (eq result :abrupt) (null stream) (not tls))
        (ignore-errors (close stream)))
      (ignore-errors (usocket:socket-close client)))))

(defun start-server (handler &key tls (certificate (fixture "server-cert.pem"))
                                  (key (fixture "server-key.pem")) request-client-cert port)
  "Start a TCP fixture running HANDLER for each connection, in its own thread."
  (let* ((listen (usocket:socket-listen "127.0.0.1" (or port 0) :reuse-address t :backlog 16
                                                                :element-type '(unsigned-byte 8)))
         (server (make-fixture-server :socket listen :port (usocket:get-local-port listen))))
    (setf (fixture-server-thread server)
          (bt:make-thread
           (lambda ()
             (loop until (fixture-server-stop server)
                   do (when (usocket:wait-for-input listen :timeout 0.1 :ready-only t)
                        (let ((client (ignore-errors (usocket:socket-accept listen))))
                          (when client
                            (bt:make-thread (lambda ()
                                              (serve-connection server client handler tls
                                                                certificate key request-client-cert))
                                            :name "fixture connection")))))
             (ignore-errors (usocket:socket-close listen)))
           :name "fixture server"))
    server))

(defun stop-server (server)
  (setf (fixture-server-stop server) t)
  (ignore-errors (bt:join-thread (fixture-server-thread server))))

(defmacro with-server ((var handler &rest keys) &body body)
  "Run BODY with VAR bound to a running fixture server."
  `(let ((,var (start-server ,handler ,@keys)))
     (unwind-protect (progn ,@body)
       (stop-server ,var))))

(defun local-url (scheme server &optional (path "/"))
  (format nil "~A://127.0.0.1:~D~A" scheme (fixture-server-port server) path))

;;; Guppy over UDP: a real (if single-client) server with retransmission,
;;; plus knobs to drop or reorder packets.

(defstruct guppy-options
  (chunk-size 16)
  (drop '())          ; sequence numbers whose first transmission is "lost"
  (drop-request nil)  ; ignore the first request packet
  (reorder nil)       ; send all data packets at once, in reverse order
  (retransmit 0.15))

(defun guppy-fixture-reply (url-string)
  "What the fixture serves for URL-STRING: (values kind header-or-mime body)."
  (let* ((url (parse-url url-string))
         (path (url-path url))
         (query (url-query url)))
    (cond ((string= path "/input")
           (if query
               (values :ok "text/gemini" (format nil "# Hello ~A~%" (percent-decode query)))
               (values :status "1 Your name" nil)))
          ((string= path "/redirect") (values :status "3 /a" nil))
          ((string= path "/error") (values :status "4 No such thing" nil))
          ((string= path "/big")
           (values :ok "text/plain"
                   (with-output-to-string (s)
                     (dotimes (i 200) (format s "line ~D of a longer document~%" i)))))
          (t (values :ok "text/gemini" (format nil "# Title~%Body of ~A~%=> /b second~%" path))))))

(defun start-guppy-server (&optional (options (make-guppy-options)))
  (let* ((socket (usocket:socket-connect nil nil :protocol :datagram
                                                 :element-type '(unsigned-byte 8)
                                                 :local-host "127.0.0.1" :local-port 0))
         (server (make-fixture-server :socket socket :port (usocket:get-local-port socket))))
    (setf (fixture-server-thread server)
          (bt:make-thread (lambda () (guppy-server-loop server socket options))
                          :name "guppy fixture"))
    server))

(defun guppy-server-loop (server socket options)
  (let ((buffer (make-array 65536 :element-type '(unsigned-byte 8)))
        (pending (make-hash-table))   ; seq -> (octets . last-sent-time)
        (dropped '()) (peer-host nil) (peer-port nil) (requests-seen 0)
        (session nil))
    (flet ((send-to (octets)
             (usocket:socket-send socket octets (length octets) :host peer-host :port peer-port))
           (now () (/ (get-internal-real-time) internal-time-units-per-second)))
      (loop until (fixture-server-stop server)
            do (when (usocket:wait-for-input socket :timeout 0.05 :ready-only t)
                 (multiple-value-bind (buf len host port)
                     (handler-case (usocket:socket-receive socket buffer (length buffer))
                       (error () (values nil 0 nil nil)))
                   (declare (ignore buf))
                   (when (and host (plusp len))
                     (let* ((text (babel:octets-to-string (subseq buffer 0 len) :encoding :utf-8))
                            (line (string-right-trim '(#\Return #\Newline) text)))
                       (cond
                         ;; An ACK.
                         ((every #'digit-char-p line)
                          (note server (list :ack (parse-integer line)))
                          (remhash (parse-integer line) pending))
                         ;; A request.
                         (t
                          (incf requests-seen)
                          (note server (list :request line))
                          (cond
                            ((and (guppy-options-drop-request options) (= requests-seen 1)))
                            (session)  ; duplicate request in the session: ignore
                            (t
                             (setf session t peer-host host peer-port port)
                             (multiple-value-bind (kind header body) (guppy-fixture-reply line)
                               (if (eq kind :status)
                                   (progn (send-to (babel:string-to-octets (crlf header) :encoding :utf-8))
                                          (setf session nil))
                                   (let* ((octets (babel:string-to-octets body :encoding :utf-8))
                                          (size (guppy-options-chunk-size options))
                                          (first-seq 1000)
                                          (packets
                                            (loop for start from 0 below (max 1 (length octets)) by size
                                                  for seq from first-seq
                                                  collect (cons seq
                                                                (concatenate '(vector (unsigned-byte 8))
                                                                             (babel:string-to-octets
                                                                              (if (= seq first-seq)
                                                                                  (format nil "~D ~A~C~C" seq header #\Return #\Newline)
                                                                                  (format nil "~D~C~C" seq #\Return #\Newline))
                                                                              :encoding :utf-8)
                                                                             (subseq octets start (min (length octets) (+ start size)))))))
                                          (eof (+ first-seq (length packets))))
                                     (setf packets (append packets
                                                           (list (cons eof (babel:string-to-octets
                                                                            (format nil "~D~C~C" eof #\Return #\Newline)
                                                                            :encoding :utf-8)))))
                                     (when (guppy-options-reorder options)
                                       (setf packets (reverse packets)))
                                     (dolist (p packets)
                                       (if (and (member (car p) (guppy-options-drop options))
                                                (not (member (car p) dropped)))
                                           (progn (push (car p) dropped)
                                                  (setf (gethash (car p) pending) (cons (cdr p) 0)))
                                           (progn (send-to (cdr p))
                                                  (setf (gethash (car p) pending) (cons (cdr p) (now)))))))))))))))))
               ;; Retransmit anything unacknowledged.
               (maphash (lambda (seq entry)
                          (declare (ignore seq))
                          (when (> (- (now) (cdr entry)) (guppy-options-retransmit options))
                            (send-to (car entry))
                            (setf (cdr entry) (now))))
                        pending)
               (when (and session (zerop (hash-table-count pending)))
                 (setf session nil))))
    (ignore-errors (usocket:socket-close socket))))

(defmacro with-guppy-server ((var &rest option-keys) &body body)
  `(let ((,var (start-guppy-server (make-guppy-options ,@option-keys))))
     (unwind-protect (progn ,@body)
       (stop-server ,var))))
