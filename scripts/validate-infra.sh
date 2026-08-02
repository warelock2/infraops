#!/bin/bash
# ===========================================================================
# Validate conf/infrastructure.yaml against its JSON Schema.
#
# The CI pipeline runs check-jsonschema directly (enforce-iac.yaml); this
# script is the same check as a standalone CLI. It ensures every field the
# Terraform/Ansible tooling reads exists and has the right type/shape BEFORE
# any provisioning starts. check-jsonschema is installed on demand.
# ===========================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

SCHEMA="$PROJECT_DIR/conf/infrastructure.schema.yaml"
INFRA="$PROJECT_DIR/conf/infrastructure.yaml"

if [ ! -f "$SCHEMA" ]; then
  echo "ERROR: Schema not found: $SCHEMA"
  exit 1
fi

if [ ! -f "$INFRA" ]; then
  echo "ERROR: Infrastructure file not found: $INFRA"
  exit 1
fi

if ! python3 -m check_jsonschema --version &>/dev/null; then
  echo "Installing check-jsonschema..."
  pip install -q check-jsonschema
fi

echo "Validating $INFRA against $SCHEMA"
python3 -m check_jsonschema --schemafile "$SCHEMA" "$INFRA"
