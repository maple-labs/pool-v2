#!/usr/bin/env bash

while getopts p: flag
do
    case "${flag}" in
        p) profile=${OPTARG};;
    esac
done

export FOUNDRY_PROFILE=production

sizes=$(forge build --sizes)

names=($(cat ./configs/package.yaml | grep "    contractName:" | sed -r 's/.{18}//'))

fail=false

for i in "${!names[@]}"; do
    line=$(echo "$sizes" | grep -w "${names[i]}")

    if [[ $line == *"-"* ]]; then
        echo "${names[i]} is too large"
        fail=true
    fi
done

if $fail
  then
      echo "Contract size check failed"
      exit 1
  else
      echo "Contract size check passed"
fi
