# Shareable per-environment values for the dev environment.
# Real per-developer overrides go in envs/dev.local.tfvars (gitignored).

zone_name             = "dt-pilot-baseline-services-dev"
alerting_profile_name = "dt-pilot-baseline-alerting-dev"
slo_name              = "dt-pilot-baseline-availability-dev"
notification_name     = "dt-pilot-baseline-email-dev"
target_pct            = 99.0
warning_pct           = 98.0
recipient_email       = "ops-dev@example.com"
