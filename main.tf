# Template de onboarding OCI do nuvem.cash — GENÉRICO, público e estático.
#
# Cria uma identidade somente-leitura (usuário + grupo + API key + policy) que
# permite ao nuvem.cash ler os relatórios de custo FOCUS da sua tenancy, e dispara
# um callback de volta com o OCID do usuário criado.
#
# Os valores por-tenant chegam como VARIÁVEIS, pré-preenchidas pelo Resource Manager
# via `zipUrlVariables` na deployURL (o botão "Deploy to Oracle Cloud"). A chave
# usada é a PÚBLICA RSA do nuvem.cash; a privada nunca sai do backend. A chave vem
# em base64 (uma linha) e é decodificada aqui — assim nenhuma quebra de linha trafega
# na URL. Família oci_identity_domains_* — exigida em tenancies com Identity Domains.

terraform {
  required_version = ">= 1.3"
  required_providers {
    oci  = { source = "oracle/oci", version = ">= 5.0" }
    http = { source = "hashicorp/http", version = ">= 3.4" }
  }
}

# Injetadas pelo Resource Manager (variáveis reservadas).
variable "tenancy_ocid" { type = string }
variable "region" { type = string }

# Injetadas pela deployURL via zipUrlVariables (valores por-tenant).
variable "public_key_pem_b64" {
  type        = string
  description = "Chave pública RSA do nuvem.cash em PEM, codificada em base64 (uma linha)."
}
variable "callback_url" {
  type        = string
  description = "URL de callback do nuvem.cash (recebe o OCID do usuário criado)."
}
variable "onboarding_token" {
  type        = string
  description = "Token de uso único que autentica o callback."
}

provider "oci" { region = var.region }

# Descobre o idcs_endpoint do domínio (o admin que roda o RMS tem permissão).
data "oci_identity_domains" "this" {
  compartment_id = var.tenancy_ocid
}

# Resolve a HOME REGION do tenancy: única região onde a Oracle entrega o FOCUS.
data "oci_identity_region_subscriptions" "this" {
  tenancy_id = var.tenancy_ocid
}

locals {
  group_name        = "nuvemcash-cost-readers"
  user_name         = "svc-nuvemcash"
  reporting_tenancy = "ocid1.tenancy.oc1..aaaaaaaaned4fkpkisbwjlr56u7cj63lf3wffbilvqknstgtvzub7vhqkggq"

  # PEM reconstruído (com quebras de linha) a partir do base64 de uma linha.
  public_key_pem = base64decode(var.public_key_pem_b64)

  home_region = one([
    for s in data.oci_identity_region_subscriptions.this.region_subscriptions :
    s.region_name if s.is_home_region
  ])

  idcs_endpoint = try(
    [for d in data.oci_identity_domains.this.domains : d.url if d.display_name == "Default"][0],
    data.oci_identity_domains.this.domains[0].url
  )
}

# --- Identidade dedicada (somente leitura) -----------------------------------
resource "oci_identity_domains_user" "svc" {
  idcs_endpoint = local.idcs_endpoint
  schemas       = ["urn:ietf:params:scim:schemas:core:2.0:User"]
  user_name     = local.user_name
  display_name  = local.user_name
  description   = "Acesso de leitura dos relatorios de custo FOCUS para o nuvem.cash"
  force_delete  = true

  name {
    family_name = "Nuvemcash"
    given_name  = "Collector"
  }
  emails {
    type    = "work"
    value   = "svc-nuvemcash@nuvem.cash"
    primary = true
  }
  emails {
    type  = "recovery"
    value = "svc-nuvemcash@nuvem.cash"
  }
}

resource "oci_identity_domains_group" "readers" {
  idcs_endpoint = local.idcs_endpoint
  schemas       = ["urn:ietf:params:scim:schemas:core:2.0:Group"]
  display_name  = local.group_name
  force_delete  = true
  members {
    type  = "User"
    value = oci_identity_domains_user.svc.id
  }
}

resource "oci_identity_domains_api_key" "svc" {
  idcs_endpoint = local.idcs_endpoint
  schemas       = ["urn:ietf:params:scim:schemas:oracle:idcs:apikey"]
  key           = trimspace(local.public_key_pem)
  user {
    ocid  = oci_identity_domains_user.svc.ocid
    value = oci_identity_domains_user.svc.id
  }
}

# --- Permissao: policy LEGADA (não há versão domains) -------------------------
# Cobre as DUAS leituras que o nuvem.cash exercita: os relatórios FOCUS (endorse
# cross-tenancy no object storage de reporting) e a Usage API (usage-report do
# próprio tenancy, que ancora o extrato na fatura real — sem ela o extrato subconta).
resource "oci_identity_policy" "cost_readers" {
  compartment_id = var.tenancy_ocid
  name           = "nuvemcash-cost-readers"
  description    = "Permite ao grupo nuvemcash-cost-readers ler os relatorios FOCUS e a Usage API"
  statements = [
    "define tenancy reporting as ${local.reporting_tenancy}",
    "endorse group ${oci_identity_domains_group.readers.display_name} to read objects in tenancy reporting",
    "allow group ${oci_identity_domains_group.readers.display_name} to read usage-report in tenancy",
  ]
}

# --- Callback: devolve só o user_ocid (o backend já calcula o fingerprint) ----
data "http" "callback" {
  url    = var.callback_url
  method = "POST"
  request_headers = {
    "Content-Type"       = "application/json"
    "X-Onboarding-Token" = var.onboarding_token
  }
  request_body = jsonencode({
    userOcid    = oci_identity_domains_user.svc.ocid
    tenancyOcid = var.tenancy_ocid
    region      = local.home_region
  })
  depends_on = [
    oci_identity_domains_api_key.svc,
    oci_identity_domains_group.readers,
    oci_identity_policy.cost_readers,
  ]
}

# --- Fallback: visiveis na aba Outputs do RMS para o admin copiar ------------
output "user_ocid" { value = oci_identity_domains_user.svc.ocid }
output "tenancy_ocid" { value = var.tenancy_ocid }
output "region" { value = local.home_region }
