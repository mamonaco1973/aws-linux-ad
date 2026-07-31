# ==============================================================================
# File: accounts.tf
# ------------------------------------------------------------------------------
# Purpose:
#   - Generates Active Directory (AD) credentials for the lab and stores them in
#     AWS Secrets Manager.
#
# Notes:
#   - Admin password is a strong 24-char random string (used programmatically
#     for the domain join / LDAP bind — never typed).
#   - USER passwords are friendly "<word>-<number>" (e.g. orange-481920) so they
#     are easy to type into the shellinabox browser terminals during the demo.
#     lower + digit + "-" satisfies AD's 3-of-4 complexity rule (no uppercase
#     required).
# ==============================================================================

# ==============================================================================
# AD ADMINISTRATOR ACCOUNT (strong, machine-used)
# ==============================================================================
resource "random_password" "admin_password" {
  length           = 24
  special          = true
  override_special = "_-"
}

# Prepend "A" so the admin password can never START with a special character.
# A leading "-"/"_" breaks CLI parsing and some domain-join tooling. Used for
# BOTH the stored secret and the AD account so they always match.
locals {
  admin_password = "A${random_password.admin_password.result}"
}

resource "aws_secretsmanager_secret" "admin_secret" {
  name        = "admin_ad_credentials_efs"
  description = "AD Administrator Credentials"

  lifecycle {
    prevent_destroy = false
  }
}

resource "aws_secretsmanager_secret_version" "admin_secret_version" {
  secret_id = aws_secretsmanager_secret.admin_secret.id

  secret_string = jsonencode({
    username = "${var.netbios}\\Admin"
    password = local.admin_password
  })
}

# ==============================================================================
# STANDARD AD USERS — friendly passwords
# ==============================================================================

locals {
  ad_users = {
    jsmith = "John Smith"
    rpatel = "Raj Patel"
    akumar = "Amit Kumar"
    edavis = "Emily Davis"
  }

  # Memorable words for user passwords (paired with a 6-digit number).
  memorable_words = [
    "bright", "simple", "orange", "window", "little", "people", "friend",
    "yellow", "animal", "family", "circle", "moment", "summer", "button",
    "planet", "rocket", "silver", "forest", "stream", "butter", "castle",
    "wonder", "gentle", "driver", "coffee"
  ]
}

# One random memorable word per user.
resource "random_shuffle" "word" {
  for_each     = local.ad_users
  input        = local.memorable_words
  result_count = 1
}

# One random 6-digit number per user.
resource "random_integer" "num" {
  for_each = local.ad_users
  min      = 100000
  max      = 999999
}

# Final password: <word>-<number>.
locals {
  passwords = {
    for user, fullname in local.ad_users :
    user => format("%s-%d", random_shuffle.word[user].result[0], random_integer.num[user].result)
  }
}

# Per-user Secrets Manager entries.
resource "aws_secretsmanager_secret" "user_secret" {
  for_each    = local.ad_users
  name        = "${each.key}_ad_credentials_efs"
  description = "${each.value} AD credentials"

  lifecycle {
    prevent_destroy = false
  }
}

resource "aws_secretsmanager_secret_version" "user_secret_version" {
  for_each  = local.ad_users
  secret_id = aws_secretsmanager_secret.user_secret[each.key].id

  secret_string = jsonencode({
    username = "${var.netbios}\\${each.key}"
    password = local.passwords[each.key]
  })
}
