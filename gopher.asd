;;;; gopher.asd
;;;;
;;;; Three systems.  #:gopher is a client library for Gopher and the small-web
;;;; protocols around it -- Gopher+, Gopher over TLS, Gemini, Titan, Spartan,
;;;; Nex, Guppy and Finger -- which returns every response in one document
;;;; model, so a browser renders one thing whatever the protocol.
;;;; #:gopher/cli builds bin/gopher, a command-line driver, with ASDF's
;;;; program-op -- `make build', or (asdf:make :gopher/cli).
;;;; #:gopher/test is the FiveAM suite.  Every protocol has an in-process
;;;; fixture server, so the suite is hermetic; the suite that talks to real
;;;; servers is skipped unless GOPHER_LIVE_TESTS is set.

(asdf:defsystem #:gopher
  :description "A Common Lisp client library for Gopher, Gemini and other small-web protocols."
  :author "Matthew Kennedy <burnsidemk@gmail.com>"
  :maintainer "Matthew Kennedy <burnsidemk@gmail.com>"
  :mailto "burnsidemk@gmail.com"
  :license "MIT"
  :version "0.1.0"
  :serial t
  :depends-on (#:usocket #:cl+ssl #:babel #:alexandria #:bordeaux-threads #:sb-posix)
  :components ((:module "src"
                :serial t
                :components ((:file "package")
                             (:file "conditions")
                             (:file "url")
                             (:file "idna")
                             (:file "encoding")
                             (:file "transport")
                             (:file "tofu")
                             (:file "document")
                             (:file "registry")
                             (:file "gemtext")
                             (:file "gopher")
                             (:file "gopher-plus")
                             (:file "gemini")
                             (:file "titan")
                             (:file "spartan")
                             (:file "nex")
                             (:file "parsers")
                             (:file "guppy")
                             (:file "finger")
                             (:file "identity")
                             (:file "cache")
                             (:file "client")
                             (:file "render")
                             (:file "docstrings"))))
  :in-order-to ((test-op (test-op #:gopher/test))))

(asdf:defsystem #:gopher/cli
  :description "gopher, a command-line driver for the gopher library."
  :author "Matthew Kennedy <burnsidemk@gmail.com>"
  :maintainer "Matthew Kennedy <burnsidemk@gmail.com>"
  :mailto "burnsidemk@gmail.com"
  :license "MIT"
  :version "0.1.0"
  :depends-on (#:gopher #:clingon)
  :components ((:module "src"
                :components ((:file "cli"))))
  :build-operation "program-op"
  :build-pathname "bin/gopher"
  :entry-point "gopher/cli:main")

(asdf:defsystem #:gopher/test
  :description "Tests for gopher."
  :author "Matthew Kennedy <burnsidemk@gmail.com>"
  :maintainer "Matthew Kennedy <burnsidemk@gmail.com>"
  :mailto "burnsidemk@gmail.com"
  :license "MIT"
  :version "0.1.0"
  :serial t
  :depends-on (#:gopher #:gopher/cli #:fiveam #:usocket #:cl+ssl #:bordeaux-threads #:sb-posix)
  :components ((:module "test"
                :serial t
                :components ((:file "package")
                             (:file "servers")
                             (:file "url-tests")
                             (:file "encoding-tests")
                             (:file "gemtext-tests")
                             (:file "gopher-tests")
                             (:file "gopher-plus-tests")
                             (:file "tofu-tests")
                             (:file "gemini-tests")
                             (:file "other-protocol-tests")
                             (:file "guppy-tests")
                             (:file "transport-tests")
                             (:file "cli-tests")
                             (:file "feature-tests")
                             (:file "live-tests"))))
  ;; ASDF ignores what a TEST-OP perform method returns, so a failing suite
  ;; must signal or `asdf:test-system' would report success.
  :perform (test-op (o c)
             (declare (ignore o c))
             (unless (uiop:symbol-call :gopher/test '#:run-tests)
               (error "The gopher test suite failed."))))
