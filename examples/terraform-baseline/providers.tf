# The provider reads every credential from env vars at runtime. dt-pilot's
# Terraform wrappers (scripts/terraform/Invoke-TerraformPlan.ps1 etc.)
# translate the canonical harness names (DT_ENVIRONMENT,
# DT_PLATFORM_TOKEN, OAUTH_CLIENT_*) to the provider-specific names
# (DT_ENV_URL, DT_API_TOKEN, DT_CLIENT_*) before invoking terraform.
#
# Do NOT add url / api_token / client_id / client_secret arguments here.
# The pre-commit secret-hygiene scanner flags committed credentials and
# the gate will fail.

provider "dynatrace" {}
