#!/usr/bin/env bash
# Render the JSON config for one environment into the files Terraform consumes.
#
#   scripts/render-config.sh <env> [out_dir]
#
# Outputs (in out_dir, default .rendered):
#   merged.json                  common.json deep-merged with <env>.json (validated in CI)
#   stack.auto.tfvars.json       -var-file for stacks/website (everything except "backend")
#   bootstrap.auto.tfvars.json   -var-file for bootstrap/ (project, aws, backend, github, tags)
#   backend.hcl                  -backend-config file for `terraform init`
set -euo pipefail

env_name="${1:?usage: render-config.sh <env> [out_dir]}"
out_dir="${2:-.rendered}"
root="$(cd "$(dirname "$0")/.." && pwd)"

common="$root/config/common.json"
env_file="$root/config/${env_name}.json"
[[ -f "$env_file" ]] || { echo "No config for environment '$env_name': $env_file" >&2; exit 1; }

mkdir -p "$out_dir"

# `*` deep-merges objects; arrays and scalars from the env file win.
jq -s '.[0] * .[1]' "$common" "$env_file" > "$out_dir/merged.json"

jq 'del(.backend)' "$out_dir/merged.json" > "$out_dir/stack.auto.tfvars.json"
jq '{project, aws, backend, github, tags}' "$out_dir/merged.json" > "$out_dir/bootstrap.auto.tfvars.json"
jq -r '.backend | to_entries[] | "\(.key) = \(.value | tojson)"' "$out_dir/merged.json" > "$out_dir/backend.hcl"

echo "Rendered '$env_name' config into $out_dir"
