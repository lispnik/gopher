;;;; cli.lisp -- bin/gopher, a command-line driver for the library.
;;;;
;;;;   gopher get URL          fetch and render (or save with -o)
;;;;   gopher info URL         Gopher+ attributes of an item or a menu
;;;;   gopher upload URL FILE  Titan or Spartan upload
;;;;   gopher known-hosts      list or forget trusted certificates
;;;;
;;;; Exit status: 0 success; 3 the server answered with something other than
;;;; success (input wanted, error, an unfollowed redirect); 4 TLS or
;;;; certificate problem; 5 connection failure or timeout; 6 protocol error;
;;;; 7 response too large; 1 anything else.  64 is clingon's usage error.

(defpackage #:gopher/cli
  (:use #:cl)
  (:export #:main #:top-level-command #:*exit-hook*))

(in-package #:gopher/cli)

(defvar *exit-hook* #'clingon:exit
  "Called with the exit status.  Tests rebind it to avoid quitting the image.")

(defun finish (code) (funcall *exit-hook* code))

(defun default-known-hosts-path ()
  (uiop:xdg-config-home "gopher" "known_hosts"))

(defun known-hosts-store (cmd)
  (gopher:make-file-known-hosts (or (clingon:getopt cmd :known-hosts) (default-known-hosts-path))))

;;; Options

(defun network-options ()
  (list
   (clingon:make-option :integer :long-name "timeout" :key :timeout :initial-value 30
                                 :description "seconds to wait to connect and for each read")
   (clingon:make-option :enum :long-name "tls" :key :tls
                              :items '(("never" . :never) ("try" . :try) ("require" . :require))
                              :description "TLS for gopher:// URLs: never, try or require")
   (clingon:make-option :filepath :long-name "known-hosts" :key :known-hosts
                                  :description "trusted-certificate file (default ~/.config/gopher/known_hosts)")
   (clingon:make-option :flag :long-name "accept-new-cert" :key :accept-new-cert
                              :description "trust a host's changed certificate")
   (clingon:make-option :flag :short-name #\k :long-name "insecure" :key :insecure
                              :description "do not check certificates at all")
   (clingon:make-option :filepath :long-name "client-cert" :key :client-cert
                                  :description "PEM client certificate (Gemini identity)")
   (clingon:make-option :filepath :long-name "client-key" :key :client-key
                                  :description "PEM private key for --client-cert")
   (clingon:make-option :integer :long-name "max-redirects" :key :max-redirects :initial-value 5
                                 :description "redirects to follow")
   (clingon:make-option :integer :long-name "max-size" :key :max-size
                                 :initial-value gopher:*default-max-size*
                                 :description "largest response to accept, in bytes")
   (clingon:make-option :flag :short-name #\v :long-name "verbose" :key :verbose
                              :description "print status, MIME type and certificate on stderr")))

(defun fetch-arguments (cmd)
  (list :timeout (clingon:getopt cmd :timeout)
        :tls (clingon:getopt cmd :tls)
        :verify (if (clingon:getopt cmd :insecure) :none :tofu)
        :known-hosts (known-hosts-store cmd)
        :client-certificate (clingon:getopt cmd :client-cert)
        :client-key (clingon:getopt cmd :client-key)
        :max-redirects (clingon:getopt cmd :max-redirects)
        :max-size (clingon:getopt cmd :max-size)))

(defun single-url (cmd)
  (let ((args (clingon:command-arguments cmd)))
    (unless args
      (format *error-output* "~&gopher: a URL is required~%")
      (finish 64))
    (first args)))

;;; Errors

(defun call-reporting-errors (cmd thunk)
  "Run THUNK, turning library conditions into a message and an exit status."
  (flet ((fail (code fmt &rest args)
           (format *error-output* "~&gopher: ~?~%" fmt args)
           (finish code)))
    (handler-case
        (handler-bind ((gopher:certificate-mismatch
                         (lambda (c)
                           (when (clingon:getopt cmd :accept-new-cert)
                             (gopher:accept-new-certificate c)))))
          (funcall thunk))
      (gopher:certificate-mismatch (e)
        (fail 4 "~A~%Run again with --accept-new-cert to trust the new certificate." e))
      (gopher:tls-error (e) (fail 4 "~A" e))
      (gopher:connection-error (e) (fail 5 "~A" e))
      (gopher:protocol-error (e) (fail 6 "~A" e))
      (gopher:response-too-large (e) (fail 7 "~A" e))
      (gopher:small-web-error (e) (fail 1 "~A" e))
      ;; Output piped into `head' and closed early: not an error.
      (stream-error (e)
        (if (stdout-stream-p (stream-error-stream e))
            (finish 0)
            (fail 1 "~A" e)))
      (error (e) (fail 1 "~A" e)))))

(defun stdout-stream-p (stream)
  (and (typep stream 'sb-sys:fd-stream) (= 1 (sb-sys:fd-stream-fd stream))))

(defmacro reporting-errors ((cmd) &body body)
  `(call-reporting-errors ,cmd (lambda () ,@body)))

(defun describe-response (response)
  (format *error-output* "~&~A~@[ ~D~] ~A~%" (gopher:response-status response)
          (gopher:response-status-code response) (gopher:response-meta response))
  (dolist (r (gopher:response-redirects response))
    (format *error-output* "  via ~A~%" r))
  (format *error-output* "  url: ~A~%" (gopher:url-string (gopher:response-url response)))
  (alexandria:when-let ((cert (gopher:response-certificate response)))
    (format *error-output* "  certificate: ~A (~(~A~))~%"
            (gopher:certificate-fingerprint cert) (gopher:response-trust response))))

(defun write-binary-stdout (octets)
  (let ((out (sb-sys:make-fd-stream 1 :output t :element-type '(unsigned-byte 8)
                                      :buffering :full)))
    (write-sequence octets out)
    (finish-output out)))

(defun report-status (response)
  "Print a non-success response.  Returns the exit status."
  (case (gopher:response-category response)
    (:input
     (format *error-output* "~&~:[Input~;Sensitive input~] requested: ~A~%Supply it with -q.~%"
             (gopher:response-sensitive-input-p response) (gopher:response-meta response)))
    (:redirect
     (format *error-output* "~&Redirect (not followed): ~A~%"
             (or (ignore-errors (gopher:url-string (gopher:response-redirect-url response)))
                 (gopher:response-meta response))))
    (:client-certificate
     (format *error-output* "~&Client certificate required: ~A~%Use --client-cert and --client-key.~%"
             (gopher:response-meta response)))
    (t (format *error-output* "~&~(~A~)~@[ (~D)~]: ~A~%" (gopher:response-status response)
               (gopher:response-status-code response) (gopher:response-meta response))))
  3)

(defun print-response (response cmd)
  "Render, print raw, or save RESPONSE.  Returns the exit status."
  (when (clingon:getopt cmd :verbose) (describe-response response))
  (cond
    ((not (gopher:response-success-p response)) (report-status response))
    ((clingon:getopt cmd :output)
     (gopher:save-response response (clingon:getopt cmd :output))
     (format *error-output* "~&Saved ~D bytes to ~A~%" (gopher:response-bytes-read response)
             (clingon:getopt cmd :output))
     0)
    ((clingon:getopt cmd :raw)
     (if (gopher:response-document response)
         (write-string (gopher:response-text response))
         (write-binary-stdout (gopher:response-body response)))
     0)
    (t (gopher:render-response response :show-urls (not (clingon:getopt cmd :no-urls)))
       0)))

;;; get

(defun get-handler (cmd)
  (finish
   (reporting-errors (cmd)
     (let ((response (apply #'gopher:fetch (single-url cmd)
                            :query (clingon:getopt cmd :query)
                            :gopher-plus (clingon:getopt cmd :view)
                            (fetch-arguments cmd))))
       (print-response response cmd)))))

(defun get-command ()
  (clingon:make-command
   :name "get"
   :description "fetch a URL and print it (gopher, gophers, gemini, spartan, nex, guppy, finger)"
   :usage "[options] URL"
   :options (append
             (list
              (clingon:make-option :string :short-name #\q :long-name "query" :key :query
                                           :description "input for a search, prompt or form")
              (clingon:make-option :filepath :short-name #\o :long-name "output" :key :output
                                             :description "save the body to a file")
              (clingon:make-option :flag :short-name #\r :long-name "raw" :key :raw
                                         :description "print the body as received")
              (clingon:make-option :flag :long-name "no-urls" :key :no-urls
                                         :description "do not print link URLs")
              (clingon:make-option :string :long-name "view" :key :view
                                           :description "Gopher+ view to request, e.g. text/plain"))
             (network-options))
   :handler #'get-handler))

;;; info

(defun print-record (record)
  (let ((info (gopher:gopher-plus-record-info record)))
    (when info
      (format t "~&~A~@[  <~A>~]~%" (gopher:line-text info) (gopher:line-url info))))
  (loop for (key . value) in (gopher:gopher-plus-record-admin record)
        do (format t "  ~A: ~A~%" key value))
  (alexandria:when-let ((views (gopher:gopher-plus-record-views record)))
    (format t "  Views:~%")
    (dolist (v views)
      (format t "    ~A~@[ ~A~]~@[ ~A~]~%" (gopher:gopher-plus-view-mime-type v)
              (gopher:gopher-plus-view-language v) (gopher:gopher-plus-view-size v))))
  (alexandria:when-let ((abstract (gopher:gopher-plus-record-abstract record)))
    (format t "  Abstract:~%~{    ~A~%~}" (gopher::split-string abstract #\Newline)))
  (loop for (name . lines) in (gopher:gopher-plus-record-blocks record)
        unless (member name '("INFO" "ADMIN" "VIEWS" "ABSTRACT") :test #'string=)
          do (format t "  ~A:~%~{    ~A~%~}" name lines)))

(defun info-handler (cmd)
  (finish
   (reporting-errors (cmd)
     (multiple-value-bind (records response)
         (apply #'gopher:gopher-attributes (single-url cmd)
                :directory (clingon:getopt cmd :directory)
                (fetch-arguments cmd))
       (cond ((not (gopher:response-success-p response)) (report-status response))
             ((null records)
              (format *error-output* "~&No Gopher+ attributes (is this a Gopher+ server?)~%")
              3)
             (t (mapc #'print-record records) 0))))))

(defun info-command ()
  (clingon:make-command
   :name "info"
   :description "show the Gopher+ attributes of an item, or of every item in a menu"
   :usage "[options] URL"
   :options (cons (clingon:make-option :flag :short-name #\d :long-name "directory" :key :directory
                                             :description "attributes of every item in the menu")
                  (network-options))
   :handler #'info-handler))

;;; upload

(defun upload-handler (cmd)
  (finish
   (reporting-errors (cmd)
     (destructuring-bind (&optional url file &rest ignore) (clingon:command-arguments cmd)
       (declare (ignore ignore))
       (unless (and url file)
         (format *error-output* "~&gopher: upload needs a URL and a FILE~%")
         (finish 64))
       (let ((response (apply #'gopher:upload url (pathname file)
                              :mime-type (or (clingon:getopt cmd :mime-type)
                                             (gopher:guess-mime-type file :default "text/plain"))
                              :token (clingon:getopt cmd :token)
                              (fetch-arguments cmd))))
         (print-response response cmd))))))

(defun upload-command ()
  (clingon:make-command
   :name "upload"
   :description "upload a file with Titan (titan:// or gemini:// URL) or Spartan"
   :usage "[options] URL FILE"
   :options (append
             (list (clingon:make-option :string :short-name #\m :long-name "mime-type" :key :mime-type
                                                :description "MIME type (default from the file name)")
                   (clingon:make-option :string :short-name #\t :long-name "token" :key :token
                                                :description "Titan token"))
             (network-options))
   :handler #'upload-handler))

;;; known-hosts

(defun known-hosts-handler (cmd)
  (let ((store (known-hosts-store cmd)))
    (alexandria:when-let ((forget (clingon:getopt cmd :forget)))
      (let* ((colon (position #\: forget :from-end t))
             (host (if colon (subseq forget 0 colon) forget))
             (port (if colon (parse-integer (subseq forget (1+ colon)) :junk-allowed t) 1965)))
        (gopher:forget-known-host store host (or port 1965))
        (format t "Forgot ~A:~D~%" host port)
        (finish 0)))
    (dolist (e (gopher:list-known-hosts store))
      (format t "~A:~D ~A~@[ expires ~A~]~%" (gopher:known-host-host e) (gopher:known-host-port e)
              (gopher:known-host-fingerprint e)
              (alexandria:when-let ((u (gopher:known-host-expires e)))
                (multiple-value-bind (s m h d mo y) (decode-universal-time u 0)
                  (declare (ignore s m h))
                  (format nil "~D-~2,'0D-~2,'0D" y mo d)))))
    (finish 0)))

(defun known-hosts-command ()
  (clingon:make-command
   :name "known-hosts"
   :description "list trusted certificates, or forget one"
   :options (list (clingon:make-option :filepath :long-name "known-hosts" :key :known-hosts
                                                 :description "trusted-certificate file")
                  (clingon:make-option :string :long-name "forget" :key :forget
                                               :description "forget HOST[:PORT] (port defaults to 1965)"))
   :handler #'known-hosts-handler))

;;; Top level

(defun top-level-command ()
  (clingon:make-command
   :name "gopher"
   :version "0.1.0"
   :description "a client for Gopher, Gemini, Spartan, Nex, Guppy, Finger and Titan"
   :authors '("Matthew Kennedy <burnsidemk@gmail.com>")
   :license "MIT"
   :sub-commands (list (get-command) (info-command) (upload-command) (known-hosts-command))
   :handler (lambda (cmd) (clingon:print-usage cmd t))))

(defun main ()
  (clingon:run (top-level-command)))
