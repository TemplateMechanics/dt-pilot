variable "zone_name" {
  type        = string
  description = "Display name for the baseline management zone."
  default     = "dt-pilot-baseline-services"
}

variable "alerting_profile_name" {
  type        = string
  description = "Display name for the baseline alerting profile."
  default     = "dt-pilot-baseline-alerting"
}

variable "slo_name" {
  type        = string
  description = "Display name for the baseline availability SLO."
  default     = "dt-pilot-baseline-availability"
}

variable "target_pct" {
  type        = number
  description = "SLO target percentage (0-100). Warning must be lower."
  default     = 99.5
  validation {
    condition     = var.target_pct > 0 && var.target_pct <= 100
    error_message = "target_pct must be in (0, 100]."
  }
}

variable "warning_pct" {
  type        = number
  description = "SLO warning percentage. MUST be lower (less strict) than target_pct so warnings fire before the SLO breaches."
  default     = 99.0
  validation {
    condition     = var.warning_pct > 0 && var.warning_pct <= 100
    error_message = "warning_pct must be in (0, 100]."
  }
}

variable "notification_name" {
  type        = string
  description = "Display name for the baseline email notification."
  default     = "dt-pilot-baseline-email"
}

variable "recipient_email" {
  type        = string
  description = "Email address that receives baseline problem notifications. Defaults to a placeholder; override per-environment."
  default     = "ops@example.com"
}

variable "owner_tag_value" {
  type        = string
  description = "Tag value used by the management-zone filter rule to select baseline services."
  default     = "dt-pilot-baseline"
}
