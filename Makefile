.PHONY: docker-image docker-e2e host-deps fetch build package e2e

docker-image:
	docker build -t android16-aosp-qemu-utm-builder -f docker/Dockerfile .

docker-e2e:
	./scripts/docker-e2e.sh

host-deps:
	./scripts/install-host-deps.sh

fetch:
	./scripts/fetch-aosp.sh

build:
	./scripts/build-aosp.sh

package:
	./scripts/package-qemu-utm.sh

e2e:
	./scripts/e2e.sh
