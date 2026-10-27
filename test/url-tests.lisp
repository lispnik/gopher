;;;; test/url-tests.lisp

(in-package #:gopher/test)

(def-suite urls :in gopher)
(in-suite urls)

(test parse-gemini-url
  (let ((u (parse-url "gemini://Example.ORG:1966/a/b.gmi?x=1#frag")))
    (is (string= "gemini" (url-scheme u)))
    (is (string= "example.org" (url-host u)))
    (is (= 1966 (url-port u)))
    (is (string= "/a/b.gmi" (url-path u)))
    (is (string= "x=1" (url-query u)))
    (is (string= "frag" (url-fragment u)))
    (is (string= "gemini://example.org:1966/a/b.gmi?x=1#frag" (url-string u)))
    (is (string= "gemini://example.org:1966/a/b.gmi?x=1" (url-string u :fragment nil)))))

(test default-ports
  (is (= 70 (url-effective-port (parse-url "gopher://h/"))))
  (is (= 1965 (url-effective-port (parse-url "gemini://h/"))))
  (is (= 300 (url-effective-port (parse-url "spartan://h/"))))
  (is (= 1900 (url-effective-port (parse-url "nex://h/"))))
  (is (= 6775 (url-effective-port (parse-url "guppy://h/"))))
  (is (= 79 (url-effective-port (parse-url "finger://h/"))))
  (is (string= "gemini://h/" (url-string (parse-url "gemini://h:1965/")))))

(test default-scheme-and-whitespace
  (is (string= "gopher://floodgap.com/1/x"
               (url-string (parse-url "  floodgap.com/1/x " :default-scheme "gopher"))))
  (signals url-parse-error (parse-url "no-scheme-here"))
  (signals url-parse-error (parse-url "gemini://h:99999/"))
  (signals url-parse-error (parse-url "gemini://h:abc/")))

(test ipv6-host
  (let ((u (parse-url "gemini://[::1]:1966/x")))
    (is (string= "::1" (url-host u)))
    (is (= 1966 (url-port u)))
    (is (string= "gemini://[::1]:1966/x" (url-string u)))))

(test gopher-path-is-opaque
  ;; ? and # are literal parts of a Gopher selector.
  (let ((u (parse-url "gopher://h/0/what?is#this")))
    (is (eql #\0 (url-gopher-type u)))
    (is (string= "/what?is#this" (url-gopher-selector u)))
    (is (null (url-query u)))
    (is (null (url-fragment u)))))

(test gopher-search-and-plus-fields
  (let ((u (parse-url "gopher://h/7/v2/vs%09lisp%20machine%09+")))
    (is (eql #\7 (url-gopher-type u)))
    (is (string= "/v2/vs" (url-gopher-selector u)))
    (is (string= "lisp machine" (url-gopher-search u)))
    (is (string= "+" (url-gopher-plus u))))
  (let ((u (parse-url "gopher://h")))
    (is (eql #\1 (url-gopher-type u)))
    (is (string= "" (url-gopher-selector u)))))

(test make-gopher-url-round-trips
  (let* ((u (make-gopher-url "h" :port 7070 :type #\0 :selector "/a b/c#d%e" :search "x y"))
         (back (parse-url (url-string u))))
    (is (string= "gopher://h:7070/0/a%20b/c%23d%25e%09x%20y" (url-string u)))
    (is (string= "/a b/c#d%e" (url-gopher-selector back)))
    (is (string= "x y" (url-gopher-search back))))
  (is (string= "gopher://h/1" (url-string (make-gopher-url "h" :port 70)))))

(test merge-rfc3986-examples
  ;; RFC 3986 section 5.4.1, with a gemini base.
  (let ((base "gemini://a/b/c/d;p?q"))
    (loop for (ref expected) in '(("g" "gemini://a/b/c/g")
                                  ("./g" "gemini://a/b/c/g")
                                  ("g/" "gemini://a/b/c/g/")
                                  ("/g" "gemini://a/g")
                                  ("//g" "gemini://g")
                                  ("?y" "gemini://a/b/c/d;p?y")
                                  ("g?y" "gemini://a/b/c/g?y")
                                  ("#s" "gemini://a/b/c/d;p?q#s")
                                  ("g#s" "gemini://a/b/c/g#s")
                                  ("" "gemini://a/b/c/d;p?q")
                                  ("." "gemini://a/b/c/")
                                  ("./" "gemini://a/b/c/")
                                  (".." "gemini://a/b/")
                                  ("../g" "gemini://a/b/g")
                                  ("../.." "gemini://a/")
                                  ("../../g" "gemini://a/g")
                                  ("../../../g" "gemini://a/g")
                                  ("spartan://x/y" "spartan://x/y"))
          do (is (string= expected (url-string (merge-url ref base)))
                 "~S against ~S" ref base))))

(test merge-against-host-only-base
  (is (string= "gemini://h/x" (url-string (merge-url "x" "gemini://h")))))

(test titan-parameters
  (let ((u (parse-url "titan://h/wiki/page;mime=text/plain;size=12;token=s%20t")))
    (multiple-value-bind (params path) (url-titan-parameters u)
      (is (string= "/wiki/page" path))
      (is (string= "text/plain" (cdr (assoc "mime" params :test #'string=))))
      (is (string= "12" (cdr (assoc "size" params :test #'string=))))
      (is (string= "s t" (cdr (assoc "token" params :test #'string=))))))
  (is (string= "titan://h/p;mime=text/gemini;size=5;token=a%20b"
               (url-string (make-titan-url "gemini://h/p?q" :mime-type "text/gemini"
                                                            :size 5 :token "a b")))))

(test finger-userinfo
  (let ((u (parse-url "finger://alice@example.org")))
    (is (string= "alice" (url-userinfo u)))
    (is (string= "example.org" (url-host u)))))

(test percent-coding
  (is (string= "a%20b%2Fc" (percent-encode "a b/c" :safe "")))
  (is (string= "a b/c" (percent-decode "a%20b%2Fc")))
  (is (string= "caf%C3%A9" (percent-encode "café")))
  (is (string= "café" (percent-decode "caf%C3%A9")))
  ;; Not UTF-8: read as Latin-1, not an error.
  (is (string= "caf\é" (percent-decode "caf%E9")))
  ;; A malformed escape is left alone.
  (is (string= "100%" (percent-decode "100%"))))

(test url-with-query-encodes
  (is (string= "gemini://h/s?two%20words%26more"
               (url-string (url-with-query (parse-url "gemini://h/s?old#f") "two words&more")))))
