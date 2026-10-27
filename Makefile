# Makefile for gopher.
#
# Targets:
#   make test    load the test system and run the FiveAM suite (default)
#   make build   build the bin/gopher executable
#   make deps    restore ocicl-vendored dependencies
#   make certs   regenerate the self-signed certificates the TLS fixtures use
#   make clean   remove compiled fasls, including the ASDF cache for this tree
#   make capi    build capi/build/libgopher.dylib and capi/build/gopher.core
#   make capi-test  build and run the C test program against them
#
# GOPHER_LIVE_TESTS=1 additionally runs the suite that talks to real servers.

LISP ?= sbcl
BIN  := bin/gopher
FIX  := test/fixtures

.PHONY: all test build deps certs clean capi capi-test

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

# Two unrelated self-signed certificates: the TOFU tests serve one, then the
# other, from the same host:port to provoke a fingerprint mismatch.
certs:
	for n in server other client; do \
	  openssl req -x509 -newkey rsa:2048 -nodes -days 36500 \
	    -subj "/CN=localhost" -keyout $(FIX)/$$n-key.pem -out $(FIX)/$$n-cert.pem; \
	done

# The C ABI.  libsbcl.a is SBCL's runtime as a static library (SBCL built
# with --with-sb-linkable-runtime); its main.o is left out so the dylib does
# not export a second main.  The core must come from the same SBCL build.
CAPI     := capi/build
SBCL_LIB ?= $(shell $(LISP) --noinform --non-interactive --no-userinit --no-sysinit \
              --eval '(princ (namestring (sb-int:sbcl-homedir-pathname)))')
CC       ?= cc
CAPI_CFLAGS := -O2 -Wall -arch arm64 -fno-omit-frame-pointer

capi: $(CAPI)/libgopher.dylib $(CAPI)/gopher.core

$(CAPI)/gopher.core: gopher.asd src/*.lisp capi/capi.lisp
	@mkdir -p $(CAPI)
	$(LISP) --non-interactive \
	  --eval '(asdf:load-system :gopher/capi)' \
	  --eval '(gopher/capi:save-core "$(CAPI)/gopher.core")'

$(CAPI)/libgopher.dylib: capi/host.c capi/gopher.h
	@mkdir -p $(CAPI)/objs
	cd $(CAPI)/objs && ar x $(SBCL_LIB)libsbcl.a && rm -f main.o __.SYMDEF*
	$(CC) $(CAPI_CFLAGS) -dynamiclib -o $@ -install_name @rpath/libgopher.dylib \
	  capi/host.c $(CAPI)/objs/*.o -lpthread -lm -ldl

$(CAPI)/test: capi/test.c capi/gopher.h $(CAPI)/libgopher.dylib
	$(CC) $(CAPI_CFLAGS) -o $@ capi/test.c -Icapi -L$(CAPI) -lgopher -Wl,-rpath,@executable_path

capi-test: capi $(CAPI)/test
	capi/run-test.sh

clean:
	rm -rf $(CAPI)
	rm -f $(BIN)
	rm -rf *.fasl src/*.fasl test/*.fasl
	rm -rf $(HOME)/.cache/common-lisp/*/$(CURDIR)
