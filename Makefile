build:
	@scripts/build.sh -p production

release:
	@scripts/release.sh

size:
	@scripts/check-sizes.sh

test:
	@scripts/test.sh -p default

# All contracts and all tests are formatted, except the files below: MaplePool.sol,
# the factory and the interfaces that have not changed since the last release are
# deliberately left exactly as released. The wildcards mean a new contract is picked
# up automatically, which an include list would silently miss.
FMT_EXCLUDE = \
	contracts/MaplePool.sol \
	contracts/proxy/MaplePoolManagerFactory.sol \
	contracts/interfaces/IERC4626.sol \
	contracts/interfaces/IMaplePool.sol \
	contracts/interfaces/IMaplePoolManagerFactory.sol \
	contracts/interfaces/Interfaces.sol

FMT_PATHS = $(filter-out $(FMT_EXCLUDE),$(wildcard contracts/*.sol) $(wildcard contracts/*/*.sol)) tests

format:
	@node scripts/align_fmt.js $(FMT_PATHS)

check-format:
	@node scripts/align_fmt.js --check $(FMT_PATHS)
