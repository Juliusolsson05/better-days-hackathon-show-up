terraform {
  required_version = ">= 1.11.0"

  required_providers {
    clickhouse = {
      source  = "ClickHouse/clickhouse"
      version = "~> 3.23"
    }
  }
}
