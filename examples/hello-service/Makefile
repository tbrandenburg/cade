SHELL := /bin/bash
PYTHON := python3

.PHONY: build test run clean

## build: Verify the toolchain can byte-compile the service (proves the
## workspace's Python installation works without extra setup).
build:
	@$(PYTHON) -m py_compile hello.py test_hello.py
	@echo "build: OK"

## test: Run the unit test suite.
test:
	@$(PYTHON) -m unittest discover -s . -p "test_*.py" -v

## run: Run the example service.
run:
	@$(PYTHON) hello.py

## clean: Remove build artifacts.
clean:
	@rm -rf __pycache__ *.pyc
