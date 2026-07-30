# syntax=docker/dockerfile:1
#
# SWARM testbed image — multi-stage build
# Compiles hostap inside Docker to guarantee glibc compatibility.

# ---------- build stage ----------
FROM debian:bookworm-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential pkg-config libssl-dev libcurl4-openssl-dev zlib1g-dev \
        libnl-3-dev libnl-genl-3-dev libnl-route-3-dev libdbus-1-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

COPY third_party/hostap/ /src/hostap/

RUN if [ ! -d /src/hostap/hostapd ]; then \
      echo "ERROR: hostap source missing. Run: make submodules"; exit 1; \
    fi

COPY testbed/build/hostapd.extra.config        /tmp/hostapd.extra.config
COPY testbed/build/wpa_supplicant.extra.config /tmp/wpa_supplicant.extra.config

RUN set -eu; \
    for d in hostapd wpa_supplicant; do \
      dir="/src/hostap/$d"; \
      if [ -f "$dir/.config" ]; then \
        echo "[build] $d: using existing .config"; \
      elif [ -f "$dir/defconfig" ]; then \
        cp "$dir/defconfig" "$dir/.config"; \
      else \
        echo "ERROR: no .config or defconfig in $dir"; exit 1; \
      fi; \
      cat "/tmp/$d.extra.config" >> "$dir/.config"; \
    done

RUN make -C /src/hostap/hostapd        -j"$(nproc)" hostapd hostapd_cli \
    && make -C /src/hostap/wpa_supplicant -j"$(nproc)" wpa_supplicant wpa_cli

# ---------- runtime stage ----------
FROM debian:bookworm-slim AS runtime

COPY --from=build /src/hostap/hostapd/hostapd               /usr/local/bin/
COPY --from=build /src/hostap/hostapd/hostapd_cli           /usr/local/bin/
COPY --from=build /src/hostap/wpa_supplicant/wpa_supplicant  /usr/local/bin/
COPY --from=build /src/hostap/wpa_supplicant/wpa_cli         /usr/local/bin/

RUN apt-get update && apt-get install -y --no-install-recommends \
        libssl3 libcurl4 zlib1g libnl-3-200 libnl-genl-3-200 libnl-route-3-200 \
        libdbus-1-3 \
        iproute2 iputils-ping tcpdump openssl procps python3 nftables \
    && rm -rf /var/lib/apt/lists/*

COPY testbed/entrypoint-authradius.sh /usr/local/sbin/
COPY testbed/entrypoint-supplicant.sh /usr/local/sbin/
RUN chmod +x /usr/local/sbin/entrypoint-authradius.sh /usr/local/sbin/entrypoint-supplicant.sh

ENTRYPOINT ["hostapd"]
