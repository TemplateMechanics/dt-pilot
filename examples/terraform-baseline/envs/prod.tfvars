# Shareable per-environment values for the prod environment.
# Real per-developer overrides go in envs/prod.local.tfvars (gitignored).

zone_name             = "dt-pilot-baseline-services-prod"
alerting_profile_name = "dt-pilot-baseline-alerting-prod"
slo_name              = "dt-pilot-baseline-availability-prod"
notification_name     = "dt-pilot-baseline-email-prod"
target_pct            = 99.5
warning_pct           = 99.0
recipient_email       = "ops-prod@example.com"
