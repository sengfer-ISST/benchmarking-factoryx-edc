# Convenience wrapper around orchestration/run.sh.
# Override the connector:  make smoke CONNECTOR=factoryx
CONNECTOR ?= factoryx
CANONICAL_DIR ?=

.PHONY: help smoke steady saturation concurrency soak payload matrix verify-parity

help:
	@echo "Targets (CONNECTOR=$(CONNECTOR)):"
	@echo "  make smoke         correctness gate + single-user baseline"
	@echo "  make steady        steady-state operating point (open model)"
	@echo "  make saturation    scalability knee (open model, ramping arrival rate)"
	@echo "  make concurrency   concurrency sweep (closed model, ramping VUs)"
	@echo "  make soak          endurance / leak watch"
	@echo "  make payload       data-plane throughput vs payload size"
	@echo "  make matrix        all core scenarios x reps, randomized"
	@echo "  make verify-parity CANONICAL_DIR=<path>   (drift check for non-canonical repos)"

smoke:
	./orchestration/run.sh $(CONNECTOR) smoke
steady:
	./orchestration/run.sh $(CONNECTOR) steady
saturation:
	./orchestration/run.sh $(CONNECTOR) saturation-open
concurrency:
	./orchestration/run.sh $(CONNECTOR) concurrency-closed
soak:
	./orchestration/run.sh $(CONNECTOR) soak
payload:
	./orchestration/run.sh $(CONNECTOR) payload-sweep
matrix:
	./orchestration/run-matrix.sh $(CONNECTOR)
verify-parity:
	./tools/verify-parity.sh $(CANONICAL_DIR)
