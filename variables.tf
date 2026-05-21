# =============================================================================
# Variables
# =============================================================================

variable "cluster_name" {
  description = "Name of the Aurora PostgreSQL cluster (used to derive the log group path)"
  type        = string
}

variable "environment" {
  description = "Deployment environment label (e.g. dev, staging, production)"
  type        = string
  default     = "production"
}

variable "alert_email" {
  description = "Email address for audit alert notifications"
  type        = string
}

variable "incident_platform_url" {
  description = "HTTPS webhook URL for the incident management platform (Opsgenie, PagerDuty, VictorOps, etc.)"
  type        = string
  sensitive   = true
}

variable "query_window_minutes" {
  description = "Log Insights look-back window in minutes (should match EventBridge schedule)"
  type        = number
  default     = 5
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days. Set to match your compliance requirement."
  type        = number
  default     = 365
  # Common values: 90, 365, 2557 (7 years)
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}
