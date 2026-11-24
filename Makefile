ORBIS_REV := 51162e596fb7135a5617ee56f9ad52f8a7a094a4
COMPOSE := docker compose -p git-orbis -f orbis/docker-compose.yml
# prebuilt by CI, tagged by the Dockerfile hash so any change to it is a new image
VERA_IMAGE ?= ghcr.io/reecepbcups/git-orbis-vera:$(shell git hash-object orbis/vera.Dockerfile | cut -c1-12)
export VERA_IMAGE

.PHONY: tools filter test up setup e2e down vera-image

# patched orbis cli-tool (jubjub, matches the node image) + the git filter process
tools: .tools/bin/cli-tool filter
.tools/bin/cli-tool:
	rm -rf .tools/src && git clone -q https://github.com/sourcenetwork/orbis-rs .tools/src
	cd .tools/src && git checkout -q $(ORBIS_REV) && git apply ../../patches/cli-tool.patch
	cd .tools/src && cargo build --release -p cli-tool --no-default-features --features jubjub
	mkdir -p .tools/bin && cp "$$(cd .tools/src && cargo metadata --format-version 1 --no-deps | python3 -c 'import json,sys;print(json.load(sys.stdin)["target_directory"])')/release/cli-tool" .tools/bin/

# rebuilt every time, it's quick and keeps the filter in step with the code
filter:
	mkdir -p .tools/bin && go build -o .tools/bin/orbis-filter ./cmd/orbis-filter

test:
	go vet ./... && go test -race ./...

up:
	$(COMPOSE) up -d
	@until docker logs git-orbis-funder-1 2>&1 | grep -q "funding complete"; do sleep 2; done
	@echo "stack ready"

setup: tools
	scripts/setup-ring.sh

e2e: tools
	scripts/e2e.sh

down:
	$(COMPOSE) down -v
	rm -f .orbis-ring.env

vera-image:
	@echo $(VERA_IMAGE)
