terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    dynatrace = {
      source  = "dynatrace-oss/dynatrace"
      version = "~> 1.78"
    }
  }
}
