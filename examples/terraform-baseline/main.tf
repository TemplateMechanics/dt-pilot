# Baseline Terraform stack -- mirrors examples/baseline-stack/ (the Monaco
# example) in shape: a management zone gates an alerting profile and an
# SLO; the alerting profile gates an email notification.
#
# NOTE: The nested-block argument shapes below are placeholders that
# illustrate the resource topology; they are NOT a guaranteed exact
# match for any specific dynatrace-oss/dynatrace provider release.
# When adopting, validate against the live provider schema:
#   ./scripts/terraform/Validate-Terraform.ps1 -Path examples/terraform-baseline
# and consult:
#   https://registry.terraform.io/providers/dynatrace-oss/dynatrace/latest/docs

resource "dynatrace_management_zone_v2" "baseline" {
  name = var.zone_name

  rules {
    enabled = true
    type    = "ME"

    attribute_rule {
      entity_type = "SERVICE"

      conditions {
        key            = "SERVICE_TAGS"
        operator       = "EQUALS"
        string_value   = "owner:${var.owner_tag_value}"
        case_sensitive = false
      }

      service_to_host_propagation = true
      service_to_pg_propagation   = true
    }
  }
}

resource "dynatrace_alerting" "baseline" {
  name              = var.alerting_profile_name
  management_zone   = dynatrace_management_zone_v2.baseline.id

  rules {
    severity_level         = "AVAILABILITY"
    delay_in_minutes       = 0
    tag_filter_include_mode = "NONE"
  }

  rules {
    severity_level         = "ERROR"
    delay_in_minutes       = 0
    tag_filter_include_mode = "NONE"
  }

  rules {
    severity_level         = "PERFORMANCE"
    delay_in_minutes       = 5
    tag_filter_include_mode = "NONE"
  }
}

resource "dynatrace_slo_v2" "baseline_availability" {
  name             = var.slo_name
  description      = "Service availability SLO for the baseline management zone."
  enabled          = true
  evaluation_type  = "AGGREGATE"
  evaluation_window = "-1h"

  target = var.target_pct
  warning = var.warning_pct

  filter           = "type(\"SERVICE\"),mzId(${dynatrace_management_zone_v2.baseline.id})"
  metric_expression = "(100)*(builtin:service.errors.successCount:splitBy())/(builtin:service.requestCount.total:splitBy())"
}

resource "dynatrace_notification" "baseline_email" {
  name              = var.notification_name
  active            = true
  alerting_profile  = dynatrace_alerting.baseline.id

  email {
    subject   = "{ProblemSeverity} on {ImpactedEntityNames} (${var.zone_name})"
    to        = [var.recipient_email]
    body      = "{ProblemTitle}\n{ProblemDetailsText}\n\nProblem URL: {ProblemURL}\nManagement zone: ${var.zone_name}\n"
  }
}

output "management_zone_id" {
  description = "ID of the baseline management zone; consume from downstream stacks that need to reference it."
  value       = dynatrace_management_zone_v2.baseline.id
}

output "alerting_profile_id" {
  description = "ID of the baseline alerting profile."
  value       = dynatrace_alerting.baseline.id
}
