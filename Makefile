build:
	@scripts/build.sh -p production

release:
	@scripts/release.sh

size:
	@scripts/check-sizes.sh

test:
	@scripts/test.sh -p default
