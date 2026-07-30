# common.mk — shared variables, included by all Makefiles

COMMON_MK := $(abspath $(lastword $(MAKEFILE_LIST)))
TOP := $(abspath $(dir $(COMMON_MK))/..)
STAMPS := $(TOP)/.stamps
TP := $(TOP)/third_party

SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
MAKEFLAGS += --no-print-directory
.DELETE_ON_ERROR:
.DEFAULT_GOAL := help

$(STAMPS):
	mkdir -p $@

.PHONY: help
help:
	@grep -hE '^[a-z0-9_-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*## /\t/'
