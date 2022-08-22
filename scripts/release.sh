#!/usr/bin/env bash
set -e

version=$(cat ./configs/package.yaml | grep "version: " | sed -r 's/.{9}//')
name=$(cat ./configs/package.yaml | grep "name: " | sed -r 's/.{6}//')
customDescription=$(cat ./configs/package.yaml | grep "customDescription: " | sed -r 's/.{19}//')

./scripts/build.sh

rm -rf ./package
mkdir -p package

echo "{
  \"name\": \"@maplelabs/${name}\",
  \"version\": \"${version}\",
  \"description\": \"${customDescription}\",
  \"author\": \"Maple Labs\",
  \"license\": \"AGPLv3\",
  \"repository\": {
    \"type\": \"git\",
    \"url\": \"https://github.com/maple-labs/${name}.git\"
  },
  \"bugs\": {
    \"url\": \"https://github.com/maple-labs/${name}/issues\"
  },
  \"homepage\": \"https://github.com/maple-labs/${name}\"
}" > package/package.json

mkdir -p package/artifacts
mkdir -p package/abis

paths=($(cat ./configs/package.yaml | grep "  - path:" | sed -r 's/.{10}//'))
names=($(cat ./configs/package.yaml | grep "    contractName:" | sed -r 's/.{18}//'))

for i in "${!paths[@]}"; do
    cat ./out/${names[i]}.sol/${names[i]}.json | jq "{ abi: .abi, evm: { bytecode: .bytecode, deployedBytecode: .deployedBytecode } }" > package/artifacts/${names[i]}.json
    cat ./out/${names[i]}.sol/${names[i]}.json | jq ".abi" > package/abis/${names[i]}.json
done

npm publish ./package --access public

rm -rf ./package
