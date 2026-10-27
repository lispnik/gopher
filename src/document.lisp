;;;; document.lisp -- the one document model every protocol produces.
;;;;
;;;; A browser built on this library renders DOCUMENTs and never needs to know
;;;; the protocol.  Gopher menus, gemtext, Nex directories and plain text all
;;;; become a vector of DOCUMENT-LINEs:
;;;;
;;;;   :text          a line of text (Gopher info lines included)
;;;;   :link          a link: LINE-URL plus LINE-TEXT as the label; Gopher
;;;;                  items also carry LINE-ITEM-TYPE / LINE-ITEM-KIND, so a UI
;;;;                  can pick an icon or treat search and telnet items specially
;;;;   :input-prompt  a link that asks for input before following (Spartan =:)
;;;;   :heading       LINE-LEVEL 1-3
;;;;   :list-item     a bulleted item
;;;;   :quote         a quoted line
;;;;   :preformatted  a whole preformatted block; LINE-ALT is its alt text.
;;;;                  Plain-text documents are one :preformatted block.
;;;;   :error         a Gopher error item (type 3)

(in-package #:gopher)

(defstruct (document-line (:conc-name line-))
  (kind :text :type keyword)
  (text "" :type string)
  (url nil)              ; absolute URL string for links
  (level nil)            ; heading level
  (alt nil)              ; preformatted alt text
  (item-type nil)        ; Gopher item type character
  (item-kind nil)        ; Gopher item classification keyword
  (gopher-plus-p nil)    ; Gopher+ item (has attributes)
  (host nil)             ; Gopher items: the raw menu fields
  (port nil)
  (selector nil))

(defstruct document
  (kind :text :type keyword)   ; :menu :gemtext :nex-directory :text
  (lines #() :type vector)
  (title nil))

(defun document-links (document)
  "The link and input-prompt lines of DOCUMENT, in order."
  (coerce (remove-if-not (lambda (l) (member (line-kind l) '(:link :input-prompt)))
                         (document-lines document))
          'list))

;;; Status

(defun status-category (status)
  "The broad class of a status keyword.  Browsers branch on this."
  (case status
    ((:success) :success)
    ((:input :sensitive-input) :input)
    ((:redirect :permanent-redirect) :redirect)
    ((:temporary-failure :server-unavailable :cgi-error :proxy-error :slow-down :server-error)
     :temporary-failure)
    ((:client-certificate-required :certificate-not-authorized :certificate-not-valid)
     :client-certificate)
    (t :permanent-failure)))

;;; Response

(defclass response ()
  ((url :initarg :url :reader response-url
        :documentation "The URL that produced this response (after redirects).")
   (protocol :initarg :protocol :reader response-protocol
             :documentation "A keyword: :gopher :gemini :titan :spartan :nex :guppy :finger.")
   (status :initarg :status :reader response-status
           :documentation "A keyword such as :SUCCESS, :INPUT, :REDIRECT, :NOT-FOUND.")
   (status-code :initarg :status-code :initform nil :reader response-status-code
                :documentation "The protocol's own status number, when it has one.")
   (meta :initarg :meta :initform "" :reader response-meta
         :documentation "Gemini-style meta: the MIME type, prompt, redirect target or error text.")
   (mime-type :initarg :mime-type :initform nil :reader response-mime-type)
   (body :initarg :body :initform nil :reader response-body
         :documentation "The body octets, or NIL (no body, or written to a :SINK).")
   (bytes-read :initarg :bytes-read :initform 0 :reader response-bytes-read)
   (certificate :initarg :certificate :initform nil :reader response-certificate
                :documentation "The server's CERTIFICATE-INFO, for TLS responses.")
   (trust :initarg :trust :initform nil :reader response-trust
          :documentation "How the certificate was trusted: :NEW :TRUSTED :CHANGED :EXPIRED-REPLACED :UNVERIFIED.")
   (redirects :initarg :redirects :initform '() :accessor response-redirects
              :documentation "URL strings that redirected to this one, oldest first.")
   (document :initform nil)))

(defmethod print-object ((r response) stream)
  (print-unreadable-object (r stream :type t)
    (format stream "~A ~S ~A" (response-status r) (response-meta r) (url-string (response-url r)))))

(defun make-response (url protocol status &key code (meta "") mime-type body (bytes-read (length body))
                                            connection)
  (make-instance 'response :url url :protocol protocol :status status :status-code code
                           :meta (or meta "") :mime-type mime-type :body body
                           :bytes-read (or bytes-read 0)
                           :certificate (and connection (connection-certificate connection))
                           :trust (and connection (connection-trust connection))))

(defun response-category (response)
  (status-category (response-status response)))

(defun response-success-p (response) (eq (response-category response) :success))
(defun response-input-p (response) (eq (response-category response) :input))
(defun response-sensitive-input-p (response) (eq (response-status response) :sensitive-input))
(defun response-redirect-p (response) (eq (response-category response) :redirect))

(defun response-redirect-url (response)
  "For a redirect, the target resolved against the response's URL."
  (when (response-redirect-p response)
    (merge-url (response-meta response) (response-url response))))

(defun response-text (response)
  "The body decoded as text, using the MIME type's charset when there is one."
  (alexandria:when-let ((body (response-body response)))
    (decode-text body :charset (mime-charset (response-mime-type response)))))

(defun response-document (response)
  "The body parsed into a DOCUMENT, or NIL for an unsuccessful or non-text
response.  Parsed once, on first call."
  (or (slot-value response 'document)
      (setf (slot-value response 'document)
            (and (response-success-p response)
                 (response-body response)
                 (parse-body (response-mime-type response) (response-text-for-parse response)
                             (response-url response))))))

(defun response-text-for-parse (response)
  (let ((mime (parse-mime-type (response-mime-type response))))
    (when (text-mime-type-p mime)
      (response-text response))))

(defun text-mime-type-p (mime)
  (and mime
       (or (alexandria:starts-with-subseq "text/" mime)
           (member mime '("application/gopher-menu" "application/json" "application/xml")
                   :test #'string=))))

(defun parse-body (mime-type text base-url)
  (when text
    (let ((mime (parse-mime-type mime-type)))
      (cond ((string= mime "application/gopher-menu") (parse-gopher-menu text base-url))
            ((string= mime "text/gemini") (parse-gemtext text base-url))
            ((string= mime "text/x-nex-directory") (parse-nex-directory text base-url))
            (t (parse-plain-text text))))))

(defun save-response (response pathname &key (if-exists :supersede))
  "Write RESPONSE's body to PATHNAME.  Returns PATHNAME."
  (with-open-file (out pathname :direction :output :element-type '(unsigned-byte 8)
                                :if-exists if-exists)
    (write-sequence (or (response-body response) #()) out))
  pathname)
