;;;; guppy.lisp -- Guppy (v0.4), small-web over UDP, port 6775.
;;;;
;;;; The request is one packet: URL CRLF.  The first reply packet is one of
;;;;   `1 prompt'   input wanted       `3 url'   redirect
;;;;   `4 message'  error              `SEQ mime' CRLF data   success
;;;; Success is followed by continuation packets `SEQ' CRLF data, each SEQ
;;;; one more than the last; an empty continuation is end-of-file.  Sequence
;;;; numbers are >= 6, so a single digit 1, 3 or 4 is a status.  The client
;;;; ACKs every data packet by echoing `SEQ' CRLF, keeps out-of-order packets,
;;;; and resends the request (or its last ACK) while the server is silent.

(in-package #:gopher)

(defparameter *guppy-retransmit-interval* 1.0
  "Seconds of silence before resending the request or the latest ACK.")

(defun guppy-header (packet length)
  "Split PACKET into (values HEADER-STRING DATA-START), or NIL without CRLF."
  (let ((cr (loop for i from 0 below (1- length)
                  when (and (= (aref packet i) 13) (= (aref packet (1+ i)) 10))
                    return i)))
    (when cr
      (values (decode-text (subseq packet 0 cr)) (+ cr 2)))))

(defun guppy-send (socket string)
  (let ((octets (encode-text (concatenate 'string string (coerce '(#\Return #\Newline) 'string)))))
    (usocket:socket-send socket octets (length octets))))

(define-scheme-handler "guppy" (url request)
  (let* ((url (if (request-query request) (url-with-query url (request-query request)) url))
         (line (url-string url :fragment nil)))
    (check-request-length line url 2046)
    (let ((socket (usocket:socket-connect (url-host url) (url-effective-port url)
                                          :protocol :datagram
                                          :element-type '(unsigned-byte 8))))
      (unwind-protect (guppy-exchange socket url request line)
        (ignore-errors (usocket:socket-close socket))))))

(defun guppy-exchange (socket url request line)
  (let* ((buffer (make-array 65536 :element-type '(unsigned-byte 8)))
         (chunks (make-hash-table))       ; seq -> octets
         (first-seq nil) (eof-seq nil) (mime nil)
         (last-ack nil)
         (received 0)
         (timeout (or (request-timeout request) *default-timeout*))
         (last-heard (get-internal-real-time))
         (last-sent (get-internal-real-time)))
    (flet ((elapsed (since) (/ (- (get-internal-real-time) since) internal-time-units-per-second))
           (complete-p ()
             (and first-seq eof-seq
                  (loop for s from first-seq below eof-seq always (gethash s chunks)))))
      (guppy-send socket line)
      (loop
        (check-cancelled request url)
        (when (complete-p) (return))
        (when (> (elapsed last-heard) timeout)
          (error 'timeout-error :url url :message "Timed out"))
        (if (null (usocket:wait-for-input socket :timeout 0.2 :ready-only t))
            (when (> (elapsed last-sent) *guppy-retransmit-interval*)
              (guppy-send socket (if last-ack (format nil "~D" last-ack) line))
              (setf last-sent (get-internal-real-time)))
            (multiple-value-bind (buf length) (usocket:socket-receive socket buffer (length buffer))
              (declare (ignore buf))
              (setf last-heard (get-internal-real-time))
              (multiple-value-bind (header data-start) (guppy-header buffer length)
                (unless header
                  (error 'protocol-error :url url :message "Packet without a header"))
                (let* ((space (position #\Space header))
                       (number (ignore-errors (parse-integer header :end space)))
                       (rest (if space (subseq header (1+ space)) "")))
                  (unless number
                    (error 'protocol-error :url url :message (format nil "Bad packet header: ~S" header)))
                  (cond
                    ;; Status packets end the exchange; only before any data.
                    ((and (null first-seq) space (member number '(1 3 4)))
                     (return-from guppy-exchange
                       (make-response url :guppy (ecase number (1 :input) (3 :redirect) (4 :permanent-failure))
                                      :code number :meta (trim-ws rest))))
                    ((< number 6)
                     (error 'protocol-error :url url :message (format nil "Bad sequence number ~D" number)))
                    (t
                     (when space            ; success packet: SEQ MIME
                       (setf first-seq number mime (trim-ws rest)))
                     (unless (gethash number chunks)
                       (let ((data (subseq buffer data-start length)))
                         (if (and (zerop (length data)) (not space))
                             (setf eof-seq number
                                   (gethash number chunks) data)
                             (progn
                               (incf received (length data))
                               (when (and (request-max-size request)
                                          (> received (request-max-size request)))
                                 (error 'response-too-large :url url :limit (request-max-size request)
                                                            :message "Response too large"))
                               (setf (gethash number chunks) data)
                               (alexandria:when-let ((p (request-on-progress request)))
                                 (funcall p received nil))))))
                     (guppy-send socket (format nil "~D" number))
                     (setf last-ack number
                           last-sent (get-internal-real-time)))))))))
      (let ((body (let ((out (make-array received :element-type '(unsigned-byte 8))) (pos 0))
                    (loop for s from first-seq below eof-seq
                          for chunk = (gethash s chunks)
                          do (replace out chunk :start1 pos)
                             (incf pos (length chunk)))
                    out))
            (mime (if (string= mime "") "text/gemini; charset=utf-8" mime)))
        (if (request-sink request)
            (progn (write-sequence body (request-sink request))
                   (finish-output (request-sink request))
                   (make-response url :guppy :success :meta mime :mime-type mime
                                                      :bytes-read (length body)))
            (make-response url :guppy :success :meta mime :mime-type mime :body body))))))
