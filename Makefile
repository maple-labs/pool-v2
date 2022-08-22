install:
	@git submodule update --init --recursive

update:
	@forge update

build:
	@scripts/build.sh -p default

release:
	@scripts/release.sh

test:
	@scripts/test.sh -p default

clean:
	@forge clean
