# A small Linux box to run the test suite in: no endpoint-security scanner on every spawned process, so timings are close to CI.
# Used by tests/docker.sh. Only what the kit's scripts and tests call.
FROM debian:trixie-slim
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends bash git jq gawk python3 perl procps ca-certificates curl >/dev/null && rm -rf /var/lib/apt/lists/*
# the kit's jq programs need jq >= 1.8 (Debian ships 1.7): the official static binary
RUN a="$(dpkg --print-architecture)" && curl -fsSL -o /usr/local/bin/jq "https://github.com/jqlang/jq/releases/download/jq-1.8.1/jq-linux-$a" && chmod +x /usr/local/bin/jq && jq --version
RUN git config --system user.email t@t && git config --system user.name t && git config --system init.defaultBranch main && git config --system --add safe.directory '*'
RUN useradd -m tester && mkdir /work && chown tester /work
USER tester
WORKDIR /work
