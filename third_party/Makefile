# third_party/Makefile — submodule management and hostap build
#
# Only hostap is built from source. Cloud Agents use stock Docker images.

include ../make/common.mk

.PHONY: submodules build

submodules:
	git -C $(TOP) submodule update --init --recursive

# Local hostap build (the Docker image builds independently via Dockerfile)
build: $(STAMPS)/build-hostap

$(STAMPS)/build-hostap: $(TP)/hostap/.git | $(STAMPS)
	[ -f $(TP)/hostap/hostapd/.config ] || { \
	  cp $(TP)/hostap/hostapd/defconfig $(TP)/hostap/hostapd/.config; \
	  cat ../testbed/build/hostapd.extra.config >> $(TP)/hostap/hostapd/.config; }
	[ -f $(TP)/hostap/wpa_supplicant/.config ] || { \
	  cp $(TP)/hostap/wpa_supplicant/defconfig $(TP)/hostap/wpa_supplicant/.config; \
	  cat ../testbed/build/wpa_supplicant.extra.config >> $(TP)/hostap/wpa_supplicant/.config; }
	$(MAKE) -C $(TP)/hostap/hostapd -j$$(nproc) hostapd hostapd_cli
	$(MAKE) -C $(TP)/hostap/wpa_supplicant -j$$(nproc) wpa_supplicant wpa_cli
	touch $@
