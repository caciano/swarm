# testbed/Makefile — the deployment
#
# Two moments, and they are not the same thing (doc/model-d-architecture.md §2):
# `provision` is enrolment and happens once; `auth` is an authentication and
# happens every time. `test` is both, followed by `clean`.

include ../make/common.mk
COMPOSE := docker compose -f docker-compose.yml

METHOD  ?= did
ROUNDS  ?= 1
TARGETS ?=
OUT     ?=

.PHONY: identus-up provision eap-up auth isolation test logs down clean

identus-up: ## start the Cloud Agents alone (compose profile: identus)
	$(COMPOSE) --profile identus up -d --wait

provision: ## enrolment: agents, DIDs, schema, credential, keys
	./provision.sh

eap-up: ## start the EAP layer (compose profile: eap)
	$(COMPOSE) --profile eap up -d --wait

auth: ## authenticate; METHOD=did|tls|md5 ROUNDS=N
	./auth.sh --method $(METHOD) --rounds $(ROUNDS)

isolation: ## assert the device reaches nothing but the authenticator
	./isolation.sh

logs: ## read logs; TARGETS="supplicant verifier" OUT=dir
	./logs.sh $(TARGETS) $(if $(OUT),--out $(OUT),)

# A failure here stops make with the deployment still up, which is the point:
# ./logs.sh all is only useful while the containers exist.
# Isolation comes before the authentication on purpose. An authentication that
# succeeds over a path that should not exist still succeeds, and reading the
# result afterwards tells you nothing about which one it was.
test: ## provision, prove the isolation, authenticate, clean up
	$(COMPOSE) --profile eap build
	./provision.sh
	./isolation.sh
	./auth.sh --method $(METHOD)
	./clean.sh

down: ## stop the deployment, keep the provisioning
	./clean.sh --keep-volumes --keep-artifacts

clean: ## remove containers, volumes and everything generated
	./clean.sh
