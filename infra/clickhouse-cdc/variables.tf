variable "clickhouse_organization_id" {
  description = "ClickHouse Cloud organization that owns the destination service."
  type        = string
}

variable "clickhouse_service_id" {
  description = "Existing ClickHouse Cloud service that already owns vectors and events."
  type        = string
}

variable "clickhouse_database" {
  description = "Existing ClickHouse database that receives the cdc_* managed tables."
  type        = string
  default     = "default"
}

variable "postgres_host" {
  description = "Direct Supabase database host; pooler hosts cannot expose logical replication."
  type        = string

  validation {
    condition     = !strcontains(lower(var.postgres_host), "pooler")
    error_message = "ClickPipes requires the direct Supabase database host, never the pooler."
  }
}
variable "postgres_port" {
  description = "Direct Postgres port."
  type        = number
  default     = 5432

  validation {
    condition     = var.postgres_port == 5432
    error_message = "Supabase CDC must use direct port 5432; port 6543 is the unsupported pooler."
  }
}

variable "postgres_database" {
  description = "Supabase Postgres database name."
  type        = string
  default     = "postgres"
}

variable "postgres_username" {
  description = "Dedicated BYPASSRLS replication login created by configure_clickpipes_source.sh."
  type        = string
  default     = "clickpipes_user"
}

# Ephemeral plus the provider's write-only password_wo field keeps this credential out of the
# Terraform plan and state. Marking a normal variable merely sensitive would redact the CLI while
# still persisting the secret in state, which is not an acceptable boundary for a database login.
variable "postgres_password" {
  description = "Password for the dedicated ClickPipes Postgres login."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "postgres_password_version" {
  description = "Increment to rotate the write-only Postgres password in ClickPipes."
  type        = number
  default     = 1
}

variable "sync_interval_seconds" {
  description = "Maximum normal batching interval before committed Postgres changes reach ClickHouse."
  type        = number
  default     = 60

  validation {
    condition     = var.sync_interval_seconds >= 10
    error_message = "ClickPipes sync intervals shorter than ten seconds are not supported."
  }
}
