FROM rocker/r-ver:4.5.0

RUN apt-get update \
  && apt-get install --yes --no-install-recommends \
    autoconf \
    bison \
    build-essential \
    flex \
    git \
    libnl-route-3-dev \
    libprotobuf-dev \
    libtool \
    pkg-config \
    protobuf-compiler \
  && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://github.com/google/nsjail.git /opt/nsjail \
  && make --directory /opt/nsjail \
  && install --mode 0755 /opt/nsjail/nsjail /usr/local/bin/nsjail

RUN R --vanilla -s -e 'install.packages(c( \
  "callr", "cli", "evaluate", "jsonlite", "later", "processx", "promises", "rlang" \
), repos = "https://cloud.r-project.org")'

WORKDIR /workspace
COPY R/run-r.R R/run-r.R
COPY tools/nsjail-smoke.R tools/nsjail-smoke.R

CMD ["Rscript", "tools/nsjail-smoke.R"]
