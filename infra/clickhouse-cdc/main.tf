provider "clickhouse" {
  organization_id = var.clickhouse_organization_id

  # Authentication intentionally comes from CLICKHOUSE_CLOUD_API_KEY and
  # CLICKHOUSE_CLOUD_API_SECRET. Those management credentials are different from the SQL user
  # consumed by edge functions and must never be represented as Terraform input values/state.
}

locals {
  publication_name = "show_up_clickhouse"
}

resource "clickhouse_clickpipe" "postgres_cdc" {
  name       = "show-up-postgres-cdc"
  service_id = var.clickhouse_service_id

  source = {
    postgres = {
      type     = "supabase"
      host     = var.postgres_host
      tls_host = var.postgres_host
      port     = var.postgres_port
      database = var.postgres_database

      credentials = {
        username            = var.postgres_username
        password_wo         = var.postgres_password
        password_wo_version = var.postgres_password_version
      }

      settings = {
        replication_mode                   = "cdc"
        publication_name                   = local.publication_name
        sync_interval_seconds              = var.sync_interval_seconds
        pull_batch_size                    = 10000
        initial_load_parallelism           = 2
        snapshot_number_of_parallel_tables = 2
        allow_nullable_columns             = true
      }

      # These mappings repeat the database publication deliberately. The publication limits what
      # Postgres can stream; this list limits what ClickPipes asks to snapshot and makes privacy
      # review possible without correlating a remote console with SQL from another subsystem.
      table_mappings = [
        {
          source_schema_name = "public"
          source_table       = "profiles"
          target_table       = "cdc_profiles"
          table_engine       = "ReplacingMergeTree"
          excluded_columns   = ["avatar", "display_name", "passion", "phone", "photo_url"]
        },
        {
          source_schema_name = "public"
          source_table       = "groups"
          target_table       = "cdc_groups"
          table_engine       = "ReplacingMergeTree"
          excluded_columns   = ["formation_key", "venue"]
        },
        {
          source_schema_name = "public"
          source_table       = "group_members"
          target_table       = "cdc_group_members"
          table_engine       = "ReplacingMergeTree"
        },
        {
          source_schema_name = "public"
          source_table       = "rsvps"
          target_table       = "cdc_rsvps"
          table_engine       = "ReplacingMergeTree"
        },
        {
          source_schema_name = "public"
          source_table       = "messages"
          target_table       = "cdc_messages"
          table_engine       = "ReplacingMergeTree"
          excluded_columns   = ["body", "client_msg_id"]
        },
        {
          source_schema_name = "public"
          source_table       = "venue_options"
          target_table       = "cdc_venue_options"
          table_engine       = "ReplacingMergeTree"
          excluded_columns   = ["address", "lat", "lng", "member_scores", "name", "pitch"]
        },
        {
          source_schema_name = "public"
          source_table       = "venue_votes"
          target_table       = "cdc_venue_votes"
          table_engine       = "ReplacingMergeTree"
        },
        {
          source_schema_name = "public"
          source_table       = "reflections"
          target_table       = "cdc_reflections"
          table_engine       = "ReplacingMergeTree"
          excluded_columns   = ["what_stuck"]
        },
        {
          source_schema_name = "public"
          source_table       = "attendance_votes"
          target_table       = "cdc_attendance_votes"
          table_engine       = "ReplacingMergeTree"
        },
        {
          source_schema_name = "public"
          source_table       = "contact_selections"
          target_table       = "cdc_contact_selections"
          table_engine       = "ReplacingMergeTree"
        }
      ]
    }
  }

  destination = {
    database = var.clickhouse_database
  }
}

# CDC compute is shared by every database ClickPipe in a service. Keeping it as a separate
# resource prevents a future pipe from silently changing cost/capacity. The provider exposes this
# endpoint only after the first pipe exists, so the dependency direction is intentionally from
# infrastructure to pipe rather than the tempting inverse.
resource "clickhouse_clickpipe_cdc_infrastructure" "shared" {
  service_id             = var.clickhouse_service_id
  replica_cpu_millicores = 1000
  replica_memory_gb      = 4

  depends_on = [clickhouse_clickpipe.postgres_cdc]
}
