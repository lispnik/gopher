;;;; test/cli-tests.lisp -- bin/gopher's commands, run in-process.

(in-package #:gopher/test)

(def-suite cli :in gopher)
(in-suite cli)

(defun run-cli (&rest args)
  "Run the CLI with ARGS.  Returns (values exit-status stdout stderr)."
  (let* ((out (make-string-output-stream))
         (err (make-string-output-stream))
         (status (catch 'exit
                   (let ((*standard-output* out)
                         (*error-output* err)
                         (gopher/cli:*exit-hook* (lambda (code) (throw 'exit code))))
                     (clingon:run (gopher/cli:top-level-command) args)))))
    (values status (get-output-stream-string out) (get-output-stream-string err))))

(test cli-get-gopher
  (with-server (s #'gopher-fixture)
    (multiple-value-bind (status out) (run-cli "get" (local-url "gopher" s "/"))
      (is (eql 0 status))
      (is (search "Hello" out))
      (is (search "[1] (TXT) Doc" out)))))

(test cli-get-with-query-and-output
  (with-server (s #'gopher-fixture)
    (let ((path (temp-path "out.txt")))
      (unwind-protect
           (multiple-value-bind (status) (run-cli "get" "-q" "forth" "-o" (namestring path)
                                                  (local-url "gopher" s "/7/search"))
             (is (eql 0 status))
             (is (search "Result for forth" (alexandria:read-file-into-string path))))
        (ignore-errors (delete-file path))))))

(test cli-gemini-statuses-and-tofu
  (with-server (s #'gemini-fixture :tls t)
    (let ((kh (temp-path "known_hosts")))
      (unwind-protect
           (progn
             (multiple-value-bind (status out err)
                 (run-cli "get" "-v" "--known-hosts" (namestring kh) (local-url "gemini" s "/"))
               (is (eql 0 status))
               (is (search "# Home" out))
               (is (search "(new)" err)))
             (multiple-value-bind (status out) (run-cli "known-hosts" "--known-hosts" (namestring kh))
               (is (eql 0 status))
               (is (search (format nil "127.0.0.1:~D sha256:" (fixture-server-port s)) out)))
             (multiple-value-bind (status out err)
                 (run-cli "get" "--known-hosts" (namestring kh) (local-url "gemini" s "/input"))
               (declare (ignore out))
               (is (eql 3 status))
               (is (search "What is your name?" err)))
             (is (eql 3 (run-cli "get" "--known-hosts" (namestring kh) (local-url "gemini" s "/missing")))))
        (ignore-errors (delete-file kh))))))

(test cli-changed-certificate
  (with-changed-certificate
   (lambda (url store port)
     (declare (ignore store))
     (let ((kh (temp-path "known_hosts")))
       (unwind-protect
            (progn
              (store-known-host (make-file-known-hosts kh)
                                (make-known-host :host "127.0.0.1" :port port :fingerprint "sha256:00"))
              (multiple-value-bind (status out err) (run-cli "get" "--known-hosts" (namestring kh) url)
                (declare (ignore out))
                (is (eql 4 status))
                (is (search "--accept-new-cert" err)))
              (is (eql 0 (run-cli "get" "--accept-new-cert" "--known-hosts" (namestring kh) url)))
              (is (eql 0 (run-cli "get" "--known-hosts" (namestring kh) url))))
         (ignore-errors (delete-file kh)))))))

(test cli-connection-failure
  (is (eql 5 (run-cli "get" "--timeout" "2" (format nil "gopher://127.0.0.1:~D/" (closed-port))))))

(test cli-upload
  (with-server (s #'spartan-fixture)
    (let ((file (temp-path "upload.txt")))
      (unwind-protect
           (progn
             (alexandria:write-string-into-file "abc" file)
             (multiple-value-bind (status out) (run-cli "upload" (local-url "spartan" s "/echo") (namestring file))
               (is (eql 0 status))
               (is (search "got 3: abc" out))))
        (ignore-errors (delete-file file))))))

(test cli-info
  (with-server (s #'gopher-plus-fixture)
    (multiple-value-bind (status out) (run-cli "info" (local-url "gopher" s "/0/about"))
      (is (eql 0 status))
      (is (search "Admin: Jane Doe" out))
      (is (search "application/pdf En_US <24k>" out)))))
