# JR-100 for Analogue Pocket (openFPGA)
#
# make build     compile the bitstream in the Quartus container
# make package   stage the SD-card layout under build/package/
# make install   copy build/package/ onto the Pocket SD (POCKET_SD)
# make dist      zip the staged package into dist/
# make clean     remove build artefacts
#
# SPDX-License-Identifier: GPL-2.0-or-later

CORE_ID     ?= zabaglione.JR100
PLATFORM_ID ?= jr100
POCKET_SD   ?= /Volumes/POCKET
REVISION    ?= ap_core

BUILD_DIR   := build
PACKAGE_DIR := $(BUILD_DIR)/package
CORE_DIR    := $(PACKAGE_DIR)/Cores/$(CORE_ID)
BITSTREAM   := $(BUILD_DIR)/bitstream.rbf_r

VERSION := $(shell git describe --tags --always --match 'v*' 2>/dev/null || echo dev)
ZIP     := dist/$(CORE_ID)-$(VERSION).zip

.DEFAULT_GOAL := build
.PHONY: build package install dist clean

build:
	scripts/build_core.sh $(REVISION)

$(BITSTREAM):
	$(MAKE) build

package: $(BITSTREAM)
	rm -rf $(PACKAGE_DIR)
	mkdir -p $(CORE_DIR) $(PACKAGE_DIR)/Platforms/_images $(PACKAGE_DIR)/Assets
	cp src/pocket/Cores/$(CORE_ID)/*.json $(CORE_DIR)/
	cp $(BITSTREAM) $(CORE_DIR)/bitstream.rbf_r
	cp src/pocket/Platforms/$(PLATFORM_ID).json $(PACKAGE_DIR)/Platforms/
	@# Platform artwork is optional; its encoding is still unresolved (see docs/PLAN.md)
	@if [ -f src/pocket/Platforms/_images/$(PLATFORM_ID).bin ]; then \
		cp src/pocket/Platforms/_images/$(PLATFORM_ID).bin $(PACKAGE_DIR)/Platforms/_images/; \
	else \
		echo "note: no platform artwork ($(PLATFORM_ID).bin), packaging without it"; \
	fi
	@if [ -d src/pocket/Assets ]; then cp -R src/pocket/Assets/. $(PACKAGE_DIR)/Assets/; fi
	@echo "staged: $(PACKAGE_DIR)"

install: package
	@test -d "$(POCKET_SD)" || { \
		echo "error: $(POCKET_SD) not mounted."; \
		echo "  Enable Tools > Developer > USB SD Access on the Pocket,"; \
		echo "  or insert the microSD, then set POCKET_SD=/Volumes/<name>."; \
		exit 1; }
	cp -R $(PACKAGE_DIR)/. "$(POCKET_SD)/"
	@echo "installed to $(POCKET_SD)"

dist: package
	mkdir -p dist
	rm -f $(ZIP)
	cd $(PACKAGE_DIR) && zip -qr ../../$(ZIP) .
	@echo "packaged: $(ZIP)"

clean:
	rm -rf $(BUILD_DIR) dist
