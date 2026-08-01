# ================================================================================
# FILE: linux.tf
#
# Purpose:
#   - Provisions THREE small Ubuntu 24.04 instances, each joined to the same
#     mini-AD a DIFFERENT way, for a side-by-side comparison:
#         sssd-ad    : SSSD, AD provider (realm join, Kerberos)
#         winbind    : Winbind only (realm join --client-software=winbind)
#         sssd-ldap  : SSSD, LDAP provider (no join; LDAPS + bind account)
#   - Each box runs shellinabox on port 80 so you log in from a browser
#     exactly like SSH — which exercises that box's PAM/identity stack.
# ================================================================================

# ================================================================================
# DATA: Canonical Ubuntu 24.04 AMI
# ================================================================================
data "aws_ssm_parameter" "ubuntu_24_04" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

data "aws_ami" "ubuntu_ami" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "image-id"
    values = [data.aws_ssm_parameter.ubuntu_24_04.value]
  }
}

# ================================================================================
# LOCALS: one instance per identity method -> its userdata script
# ================================================================================
locals {
  linux_methods = {
    "sssd-ad"   = "userdata_sssd_ad.sh"
    "winbind"   = "userdata_winbind.sh"
    "sssd-ldap" = "userdata_sssd_ldap.sh"
  }

  # The DC's fully-qualified name (HOSTNAME_DC "ad1" in the mini-ad module).
  # Used by the ldap client for ldaps:// and the /ca.pem fetch. Resolvable
  # because the module's DHCP option set points VPC DNS at the DC.
  dc_fqdn = "${var.dc_hostname}.${var.dns_zone}"

  # Base DN derived from the DNS zone (mcloud.mikecloud.com -> DC=mcloud,DC=...).
  base_dn = join(",", [for p in split(".", var.dns_zone) : "DC=${p}"])
}

# ================================================================================
# RESOURCE: three Ubuntu clients, one per identity method
# ================================================================================
resource "aws_instance" "linux" {
  for_each = local.linux_methods

  ami           = data.aws_ami.ubuntu_ami.id
  instance_type = "t3.small"

  subnet_id                   = data.aws_subnet.vm_subnet_1.id
  vpc_security_group_ids      = [aws_security_group.ad_ssh_sg.id]
  associate_public_ip_address = true

  iam_instance_profile = aws_iam_instance_profile.ec2_secrets_profile.name

  user_data = templatefile("./scripts/${each.value}", {
    admin_secret = "admin_ad_credentials_efs"
    domain_fqdn  = var.dns_zone
    netbios      = var.netbios
    realm        = var.realm
    dc_fqdn      = local.dc_fqdn
    base_dn      = local.base_dn
    bind_dn      = "CN=Admin,CN=Users,${local.base_dn}"
    hostname     = "linux-${each.key}" # -> AD computer object name on join
  })

  tags = {
    Name   = "linux-${each.key}"
    Method = each.key
  }
}
