#!/bin/bash
# This script is used to check if there are any issues with the migration file state
# It should be run from the project root directory (either directly or via `make check-migrations`)
PROJECT_DIR="$(pwd)"
MIGRATIONS_DIR="src/db/migrations"
SCHEMA_MIGRATION_HASH_FILENAME=".schema_and_migration_hash"
# enable exit on error
set -e

function schema_and_migration_content() {
  # Get the hashed content of DB schema combined with the hash of the Atlas migration files
  # Sort the schema DDL output since the order of CREATE INDEX statements is not deterministic
  echo "$(python scripts/load_models.py | sort; find "$MIGRATIONS_DIR" -type f -exec sha256sum {} + | sort)" | sha256sum
}

function has_schema_or_migrations_changed() {
  # Check if the schema or migration files have been changed since the last time this check was run
  if [ ! -e "$SCHEMA_MIGRATION_HASH_FILENAME" ]; then
    # No schema integrity file found, need to verify and generate
    return 0  # Success
  fi

  if [[ "$(cat "$SCHEMA_MIGRATION_HASH_FILENAME")" != "$(schema_and_migration_content)" ]]; then
    # Schema has changed since last migration files were generated
    return 0  # Success
  fi

  return 1  # Failure
}

function verify_cfn_cr_migration_hash() {
  # Verify that the MigrationHash parameter of the MigrationTrigger custom resource in the CF template
  # matches the hash of the migration files (in atlas.sum file)
  atlas_hash=$(head -n 1 "$MIGRATIONS_DIR/atlas.sum" | cut -c 4-)
  if ! grep -q "MigrationHash: $atlas_hash" "$PROJECT_DIR/cloud-formation.yaml"; then
    echo "Error: MigrationHash parameter of the MigrationTrigger custom resource does not match the hash of the migration files"
    exit 1
  fi
}

# Verify that the MigrationHash parameter of the MigrationTrigger custom resource in the CF template is equal to migration hash
verify_cfn_cr_migration_hash

# Exit early if no schema or migration changes detected
if ! has_schema_or_migrations_changed; then
  echo "No schema changes detected"
  exit 0
fi

# Verify hash integrity of migration files
atlas migrate validate --env project_config

# Check if schema and migration files are in sync
if [[ $(atlas schema diff --env "project_config" --from "file://$MIGRATIONS_DIR" --to "env://src") != "Schemas are synced, no changes to be made." ]]; then
  echo "Error: Migration files are not aligned with DB schema, need to run 'make create-migrations' and commit the changes"
  exit 1
fi

# Lint the most recent migration file and output any associated warnings
# This will involve running the migrations against a temp dev DB,  so any SQL syntax errors will be caught here.
atlas migrate lint --env project_config --latest 1

# Verify that migration files involving modifying indexes CONCURRENTLY start with "-- atlas:txmode none" so they do not run in a transaction
for file in "$MIGRATIONS_DIR"/*.sql; do
  # Skip if no .sql files exist
  [[ -e "$file" ]] || continue

  # Check if the file contains the word "CONCURRENTLY"
  if grep -q "CONCURRENTLY" "$file"; then
    # Check if the first line starts with "-- atlas:txmode none"
    if ! head -n 1 "$file" | grep -q "^-- atlas:txmode none"; then
      echo "Error: Migration file '$file' must start '-- atlas:txmode none' because it involves modifying indexes CONCURRENTLY."
      exit 1
    fi
  fi
done

# Save the current state of the schema and migration files
schema_and_migration_content > "$SCHEMA_MIGRATION_HASH_FILENAME"
