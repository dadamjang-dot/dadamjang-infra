resource "cloudflare_r2_bucket" "pending" {
  account_id    = var.cloudflare_account_id
  location      = "apac"
  name          = local.pending_r2_bucket_name
  storage_class = "Standard"

  lifecycle {
    precondition {
      condition     = local.pending_r2_bucket_name != var.cloudflare_r2_final_bucket_name
      error_message = "The pending R2 bucket must be distinct from the final R2 bucket."
    }
  }
}

resource "cloudflare_r2_bucket_lifecycle" "pending" {
  account_id  = var.cloudflare_account_id
  bucket_name = cloudflare_r2_bucket.pending.name
  rules = [{
    conditions = {
      prefix = ""
    }
    delete_objects_transition = {
      condition = {
        max_age = 86400
        type    = "Age"
      }
    }
    enabled = true
    id      = "expire-pending-objects-after-one-day"
  }]
}

resource "cloudflare_r2_managed_domain" "pending" {
  account_id  = var.cloudflare_account_id
  bucket_name = cloudflare_r2_bucket.pending.name
  enabled     = false
}
