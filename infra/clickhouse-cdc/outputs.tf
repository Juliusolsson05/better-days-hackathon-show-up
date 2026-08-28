output "clickpipe_id" {
  description = "Managed pipe identifier used for monitoring and import."
  value       = clickhouse_clickpipe.postgres_cdc.id
}

output "clickpipe_state" {
  description = "ClickHouse Cloud's observed lifecycle state for the pipe."
  value       = clickhouse_clickpipe.postgres_cdc.state
}
