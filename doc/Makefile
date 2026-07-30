# doc/Makefile — documentation build targets

include ../make/common.mk

PUML := $(wildcard *.puml)
PNG  := $(PUML:.puml=.png)

.PHONY: all diagrams security ban clean

all: diagrams

diagrams: $(PNG)

%.png: %.puml
	plantuml -tpng $<

clean:
	rm -f *.png *.svg *.pdf
