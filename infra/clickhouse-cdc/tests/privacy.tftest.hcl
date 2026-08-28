# Planning against a mock provider proves our local contract without contacting ClickHouse Cloud.
# This catches the highest-risk Terraform drift: a table added without review, a sensitive column
# removed from exclusions, or a switch away from the publication owned by migration 0005.
mock_provider "clickhouse" {}

variables {
  clickhouse_organization_id = "00000000-0000-4000-8000-000000000001"
  clickhouse_service_id      = "00000000-0000-4000-8000-000000000002"
  postgres_host              = "db.example-project.supabase.co"
  postgres_password          = "not-a-live-password-for-contract-testing"
}

run "privacy_and_identity_contract" {
  command = plan

  assert {
    condition     = clickhouse_clickpipe.postgres_cdc.source.postgres.type == "supabase"
    error_message = "the CDC source must remain the externally managed Supabase Postgres"
  }

  assert {
    condition     = clickhouse_clickpipe.postgres_cdc.source.postgres.settings.publication_name == "show_up_clickhouse"
    error_message = "ClickPipes must consume the migration-owned privacy publication"
  }

  assert {
    condition = toset([
      for mapping in clickhouse_clickpipe.postgres_cdc.source.postgres.table_mappings :
      mapping.target_table
      ]) == toset([
      "cdc_profiles",
      "cdc_groups",
      "cdc_group_members",
      "cdc_rsvps",
      "cdc_messages",
      "cdc_venue_options",
      "cdc_venue_votes",
      "cdc_reflections",
      "cdc_attendance_votes",
      "cdc_contact_selections",
    ])
    error_message = "the ClickPipe table allowlist drifted from the reviewed lifecycle contract"
  }

  assert {
    condition = alltrue([
      for mapping in clickhouse_clickpipe.postgres_cdc.source.postgres.table_mappings :
      mapping.table_engine == "ReplacingMergeTree"
    ])
    error_message = "every mutable Postgres table must preserve versions through ReplacingMergeTree"
  }

  assert {
    condition = one([
      for mapping in clickhouse_clickpipe.postgres_cdc.source.postgres.table_mappings :
      mapping.excluded_columns if mapping.source_table == "profiles"
    ]) == toset(["avatar", "display_name", "passion", "phone", "photo_url"])
    error_message = "profile identity or contact content would enter ClickHouse"
  }

  assert {
    condition = one([
      for mapping in clickhouse_clickpipe.postgres_cdc.source.postgres.table_mappings :
      mapping.excluded_columns if mapping.source_table == "messages"
    ]) == toset(["body", "client_msg_id"])
    error_message = "message content or delivery identifiers would enter ClickHouse"
  }

  assert {
    condition = one([
      for mapping in clickhouse_clickpipe.postgres_cdc.source.postgres.table_mappings :
      mapping.excluded_columns if mapping.source_table == "reflections"
    ]) == toset(["what_stuck"])
    error_message = "private reflection prose would enter ClickHouse"
  }
}
