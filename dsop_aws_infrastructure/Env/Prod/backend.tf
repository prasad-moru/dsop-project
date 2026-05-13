# For development environment (in environments/development/backend.tf)
terraform {
  backend "s3" {
    bucket       = "store-app-project"
    key          = "production/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}