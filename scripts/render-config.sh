#!/usr/bin/env bash
# Render the JSON config for one environment into the files Terraform consumes.
#
#   scripts/render-config.sh <env> [out_dir] [stack]
#
# `stack` defaults to "website" (so existing call sites are unaffected). Pass
# "tools" (or any other stack name) to render that stack's backend key instead.
#
# Outputs (in out_dir, default .rendered):
#   merged.json                  common.json deep-merged with <env>.json (validated in CI)
#   stack.auto.tfvars.json       -var-file for stacks/<stack> (everything except "backend"/"backends")
#   bootstrap.auto.tfvars.json   -var-file for bootstrap/ (project, aws, backend, github, tags)
#   backend.hcl                  -backend-config file for `terraform init`, for this stack
set -euo pipefail

env_name="${1:?usage: render-config.sh <env> [out_dir] [stack]}"
out_dir="${2:-.rendered}"
stack="${3:-website}"
root="$(cd "$(dirname "$0")/.." && pwd)"

common="$root/config/common.json"
env_file="$root/config/${env_name}.json"
[[ -f "$env_file" ]] || { echo "No config for environment '$env_name': $env_file" >&2; exit 1; }

mkdir -p "$out_dir"

# `*` deep-merges objects; arrays and scalars from the env file win.
jq -s '.[0] * .[1]' "$common" "$env_file" > "$out_dir/merged.json"

jq 'del(.backend, .backends)' "$out_dir/merged.json" > "$out_dir/stack.auto.tfvars.json"
jq '{project, aws, backend, github, tags}' "$out_dir/merged.json" > "$out_dir/bootstrap.auto.tfvars.json"

# The website stack (the default) uses `.backend` as-is; any other stack merges
# its `.backends[<stack>]` override (currently just `key`) onto `.backend`.
jq --arg stack "$stack" '.backend * (.backends[$stack] // {})' "$out_dir/merged.json" \
  | jq -r 'to_entries[] | "\(.key) = \(.value | tojson)"' > "$out_dir/backend.hcl"

echo "Rendered '$env_name' config (stack '$stack') into $out_dir"
