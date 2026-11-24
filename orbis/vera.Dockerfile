# Vera with the mizu cometbft fork (proof_block_mode = only_after_tx), so the
# chain only makes blocks when there are txs. Vera itself is untouched, we just
# swap the cometbft module before building.
FROM golang:1.26.2-bookworm AS builder
ARG VERA_REV=8b57a29410dfc584fa533b5554754e6ef17ba4c5
ARG COMET=github.com/mizufinance/cometbft@v0.38.21-mizu.1
RUN git clone -q https://github.com/sourcenetwork/vera /app && git -C /app checkout -q $VERA_REV
WORKDIR /app
RUN go mod edit -replace github.com/cometbft/cometbft=$COMET && go mod tidy
RUN --mount=type=cache,target=/root/.cache go build -o /verad ./cmd/verad

FROM debian:bookworm-slim
COPY --from=builder /verad /usr/local/bin/verad
RUN useradd --create-home --home-dir /home/node node && mkdir /home/node/.vera && chown node:node /home/node/.vera
USER node
