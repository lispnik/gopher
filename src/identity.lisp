;;;; identity.lisp -- making client certificates ("identities") for Gemini.
;;;;
;;;; A Gemini identity is a self-signed certificate and its private key.
;;;; MAKE-IDENTITY creates one with OpenSSL (3.0 or later; cl+ssl has already
;;;; loaded libcrypto) and writes both as PEM files, ready for FETCH's
;;;; :CLIENT-CERTIFICATE and :CLIENT-KEY.  Only fixed-argument OpenSSL
;;;; functions are called: variadic ones such as EVP_PKEY_Q_keygen would be
;;;; passed wrongly under the Darwin arm64 calling convention.

(in-package #:gopher)

(defmacro check-ossl (form what)
  `(let ((result ,form))
     (when (if (integerp result) (<= result 0) (cffi:null-pointer-p result))
       (error 'tls-error :message (format nil "OpenSSL failed to ~A" ,what)))
     result))

(defun generate-key (key-type bits)
  (let ((ctx (check-ossl (cffi:foreign-funcall "EVP_PKEY_CTX_new_from_name"
                                               :pointer (cffi:null-pointer)
                                               :string (ecase key-type
                                                         (:ec "EC") (:rsa "RSA") (:ed25519 "ED25519"))
                                               :pointer (cffi:null-pointer) :pointer)
                         "create a key context")))
    (unwind-protect
         (progn
           (check-ossl (cffi:foreign-funcall "EVP_PKEY_keygen_init" :pointer ctx :int) "start key generation")
           (case key-type
             (:ec (check-ossl (cffi:foreign-funcall "EVP_PKEY_CTX_set_group_name"
                                                    :pointer ctx :string "P-256" :int)
                              "choose the P-256 curve"))
             (:rsa (check-ossl (cffi:foreign-funcall "EVP_PKEY_CTX_set_rsa_keygen_bits"
                                                     :pointer ctx :int bits :int)
                               "set the RSA key size")))
           (cffi:with-foreign-object (out :pointer)
             (setf (cffi:mem-ref out :pointer) (cffi:null-pointer))
             (check-ossl (cffi:foreign-funcall "EVP_PKEY_keygen" :pointer ctx :pointer out :int)
                         "generate a key")
             (cffi:mem-ref out :pointer)))
      (cffi:foreign-funcall "EVP_PKEY_CTX_free" :pointer ctx :void))))

(defun bio-to-string (writer)
  "Call WRITER on a fresh memory BIO and return what it wrote."
  (let ((bio (check-ossl (cffi:foreign-funcall "BIO_new" :pointer
                                               (cffi:foreign-funcall "BIO_s_mem" :pointer)
                                               :pointer)
                         "make a memory buffer")))
    (unwind-protect
         (progn
           (funcall writer bio)
           (cffi:with-foreign-object (data :pointer)
             ;; BIO_get_mem_data is the macro BIO_ctrl(b, BIO_CTRL_INFO, 0, pp).
             (let ((len (cffi:foreign-funcall "BIO_ctrl" :pointer bio :int 3 :long 0 :pointer data :long)))
               (cffi:foreign-string-to-lisp (cffi:mem-ref data :pointer) :count len))))
      (cffi:foreign-funcall "BIO_free" :pointer bio :int))))

(defun random-serial ()
  (1+ (random (expt 2 62) (make-random-state t))))

(defun make-self-signed (pkey key-type common-name days)
  (let ((x509 (check-ossl (cffi:foreign-funcall "X509_new" :pointer) "make a certificate")))
    (handler-bind ((error (lambda (e) (declare (ignore e))
                            (cffi:foreign-funcall "X509_free" :pointer x509 :void))))
      (check-ossl (cffi:foreign-funcall "X509_set_version" :pointer x509 :long 2 :int) "set the version")
      (check-ossl (cffi:foreign-funcall "ASN1_INTEGER_set"
                                        :pointer (cffi:foreign-funcall "X509_get_serialNumber"
                                                                       :pointer x509 :pointer)
                                        :long (random-serial) :int)
                  "set the serial number")
      (check-ossl (cffi:foreign-funcall "X509_time_adj_ex"
                                        :pointer (cffi:foreign-funcall "X509_getm_notBefore" :pointer x509 :pointer)
                                        :int 0 :long 0 :pointer (cffi:null-pointer) :pointer)
                  "set the start date")
      (check-ossl (cffi:foreign-funcall "X509_time_adj_ex"
                                        :pointer (cffi:foreign-funcall "X509_getm_notAfter" :pointer x509 :pointer)
                                        :int days :long 0 :pointer (cffi:null-pointer) :pointer)
                  "set the expiry date")
      (check-ossl (cffi:foreign-funcall "X509_set_pubkey" :pointer x509 :pointer pkey :int) "set the key")
      (let ((name (cffi:foreign-funcall "X509_get_subject_name" :pointer x509 :pointer)))
        (cffi:with-foreign-string (cn common-name :encoding :utf-8)
          ;; MBSTRING_UTF8 = 0x1000; len -1, loc -1, set 0
          (check-ossl (cffi:foreign-funcall "X509_NAME_add_entry_by_txt"
                                            :pointer name :string "CN" :int #x1000
                                            :pointer cn :int -1 :int -1 :int 0 :int)
                      "set the common name"))
        (check-ossl (cffi:foreign-funcall "X509_set_issuer_name" :pointer x509 :pointer name :int)
                    "set the issuer"))
      (check-ossl (cffi:foreign-funcall "X509_sign" :pointer x509 :pointer pkey
                                        :pointer (if (eq key-type :ed25519)
                                                     (cffi:null-pointer)  ; Ed25519 has its own digest
                                                     (cffi:foreign-funcall "EVP_sha256" :pointer))
                                        :int)
                  "sign the certificate")
      x509)))

(defun write-private-file (path text)
  (with-open-file (out path :direction :output :if-exists :supersede :external-format :utf-8)
    (write-string text out))
  (sb-posix:chmod path #o600)
  path)

(defun make-identity (certificate-path key-path
                      &key (common-name "gemini identity") (days 3650) (key-type :ec) (bits 2048))
  "Create a self-signed client certificate and private key and write them as
PEM to CERTIFICATE-PATH and KEY-PATH (the key with mode 0600).  KEY-TYPE is
:EC (P-256, the default), :RSA (BITS long) or :ED25519; not every Gemini
server accepts Ed25519.  Returns the certificate's CERTIFICATE-INFO."
  (cl+ssl::ensure-initialized)
  (let ((pkey (generate-key key-type bits)) (x509 nil))
    (unwind-protect
         (progn
           (setf x509 (make-self-signed pkey key-type common-name days))
           (let ((cert-pem (bio-to-string
                            (lambda (bio)
                              (check-ossl (cffi:foreign-funcall "PEM_write_bio_X509" :pointer bio :pointer x509 :int)
                                          "write the certificate"))))
                 (key-pem (bio-to-string
                           (lambda (bio)
                             (check-ossl (cffi:foreign-funcall "PEM_write_bio_PrivateKey"
                                                               :pointer bio :pointer pkey
                                                               :pointer (cffi:null-pointer)
                                                               :pointer (cffi:null-pointer) :int 0
                                                               :pointer (cffi:null-pointer)
                                                               :pointer (cffi:null-pointer) :int)
                                         "write the key")))))
             (ensure-directories-exist certificate-path)
             (ensure-directories-exist key-path)
             (write-private-file key-path key-pem)
             (with-open-file (out certificate-path :direction :output :if-exists :supersede)
               (write-string cert-pem out))
             (x509-certificate-info x509)))
      (when x509 (cffi:foreign-funcall "X509_free" :pointer x509 :void))
      (cffi:foreign-funcall "EVP_PKEY_free" :pointer pkey :void))))
