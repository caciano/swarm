# swarm/Makefile — top-level orchestration
#
# Everything below delegates to testbed/. The two that matter:
#
#   make provision   enrolment — agents up, DIDs, schema, credential (once)
#   make auth        an authentication against what provisioning left behind
#   make isolation   assert the device reaches nothing but the authenticator
#   make test        all of it, then clean up
#
# See doc/model-d-architecture.md §2 for why those are two different things.

include make/common.mk

.PHONY: submodules build identus-up provision eap-up auth isolation test logs down clean distclean help

submodules: ## init/update git submodules
	git -C $(TOP) submodule update --init --recursive
	@# SSL: git config http.https://santorini...:3000/.sslVerify false (one-time)

build: submodules ## compile hostap locally (development; the image builds on its own)
	$(MAKE) -C third_party build

identus-up: ## start the Cloud Agents alone (compose profile: identus)
	$(MAKE) -C testbed identus-up

provision: ## enrolment: agents, DIDs, schema, credential, keys
	$(MAKE) -C testbed provision

eap-up: ## start the EAP layer (compose profile: eap)
	$(MAKE) -C testbed eap-up

auth: ## authenticate; METHOD=did|tls|md5 ROUNDS=N
	$(MAKE) -C testbed auth

isolation: ## assert the device reaches nothing but the authenticator
	$(MAKE) -C testbed isolation

test: submodules ## provision, prove the isolation, authenticate, clean up
	$(MAKE) -C testbed test

logs: ## read logs; TARGETS="supplicant verifier" OUT=dir
	$(MAKE) -C testbed logs

down: ## stop the deployment, keep the provisioning
	$(MAKE) -C testbed down

clean: ## remove containers, volumes, generated files and build stamps
	$(MAKE) -C testbed clean
	rm -rf $(STAMPS)

distclean: clean ## clean, then deinitialise the submodules
	git -C $(TOP) submodule deinit -f --all
