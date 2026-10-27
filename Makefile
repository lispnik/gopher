# Makefile for gopher.
#
# Targets:
#   make test    load the test system and run the FiveAM suite (default)
#   make build   build the bin/gopher executable
#   make deps    restore ocicl-vendored dependencies
#   make docs    regenerate docs/API.md from the docstrings
#   make certs   regenerate the self-signed certificates the TLS fixtures use
#   make clean   remove compiled fasls, including the ASDF cache for this tree
#
# GOPHER_LIVE_TESTS=1 additionally runs the suite that talks to real servers.

LISP ?= sbcl
BIN  := bin/gopher
FIX  := test/fixtures

.PHONY: all test build deps docs certs clean

all: test

# RUN-TESTS returns the status; fiveam:run! alone would exit 0 on failure.
test:
	$(LISP) --non-interactive \
	  --eval '(asdf:load-system :gopher/test)' \
	  --eval '(uiop:quit (if (gopher/test:run-tests) 0 1))'

build:
	$(LISP) --non-interactive --eval '(asdf:make :gopher/cli)'
	@echo "built $(BIN)"

deps:
	ocicl install

docs:
	$(LISP) --non-interactive --load docs/generate.lisp

# Two unrelated self-signed certificates: the TOFU tests serve one, then the
# other, from the same host:port to provoke a fingerprint mismatch.
certs:
	for n in server other client; do \
	  openssl req -x509 -newkey rsa:2048 -nodes -days 36500 \
	    -subj "/CN=localhost" -keyout $(FIX)/$$n-key.pem -out $(FIX)/$$n-cert.pem; \
	done

clean:
	rm -f $(BIN)
	rm -rf *.fasl src/*.fasl test/*.fasl
	rm -rf $(HOME)/.cache/common-lisp/*/$(CURDIR)
