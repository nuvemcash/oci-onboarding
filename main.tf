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

variable "renew" {
  type        = string
  default     = "false"
  description = "Modo renovação: reaproveita o usuário svc-nuvemcash existente e cria apenas a API key nova (não cria user/group/policy)."
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

# Modo renew: localiza o usuário dedicado já criado pelo onboarding original.
data "oci_identity_domains_users" "existing" {
  count         = var.renew == "true" ? 1 : 0
  idcs_endpoint = local.idcs_endpoint
  user_filter   = "userName eq \"${local.user_name}\""
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

  renew = var.renew == "true"

  # Usuário localizado no modo renew (null fora do renew ou se não existir mais).
  existing_user = try(one(data.oci_identity_domains_users.existing[0].users), null)

  # OCID/id do usuário de serviço, qualquer que seja o modo. try/splat evitam
  # erro de índice no braço não-tomado do condicional (count = 0).
  svc_user_ocid = local.renew ? try(local.existing_user.ocid, null) : one(oci_identity_domains_user.svc[*].ocid)
  svc_user_id   = local.renew ? try(local.existing_user.id, null) : one(oci_identity_domains_user.svc[*].id)
}

# --- Identidade dedicada (somente leitura) -----------------------------------
resource "oci_identity_domains_user" "svc" {
  count         = local.renew ? 0 : 1
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
  count         = local.renew ? 0 : 1
  idcs_endpoint = local.idcs_endpoint
  schemas       = ["urn:ietf:params:scim:schemas:core:2.0:Group"]
  display_name  = local.group_name
  force_delete  = true
  members {
    type  = "User"
    value = oci_identity_domains_user.svc[0].id
  }
}

resource "oci_identity_domains_api_key" "svc" {
  idcs_endpoint = local.idcs_endpoint
  schemas       = ["urn:ietf:params:scim:schemas:oracle:idcs:apikey"]
  key           = trimspace(local.public_key_pem)
  user {
    ocid  = local.svc_user_ocid
    value = local.svc_user_id
  }

  lifecycle {
    precondition {
      condition     = local.svc_user_ocid != null && local.svc_user_id != null
      error_message = "Usuario svc-nuvemcash nao encontrado neste tenancy. No nuvem.cash, use a opcao 'reinstalar acesso completo' para recriar a identidade."
    }
  }
}

# --- Permissao: policy LEGADA (não há versão domains) -------------------------
# Cobre as DUAS leituras que o nuvem.cash exercita: os relatórios FOCUS (endorse
# cross-tenancy no object storage de reporting) e a Usage API (usage-report do
# próprio tenancy, que ancora o extrato na fatura real — sem ela o extrato subconta).
resource "oci_identity_policy" "cost_readers" {
  count          = local.renew ? 0 : 1
  compartment_id = var.tenancy_ocid
  name           = "nuvemcash-cost-readers"
  description    = "Permite ao grupo nuvemcash-cost-readers ler os relatorios FOCUS e a Usage API"
  statements = [
    "define tenancy reporting as ${local.reporting_tenancy}",
    "endorse group ${oci_identity_domains_group.readers[0].display_name} to read objects in tenancy reporting",
    "allow group ${oci_identity_domains_group.readers[0].display_name} to read usage-report in tenancy",
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
    userOcid    = local.svc_user_ocid
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
output "user_ocid" { value = local.svc_user_ocid }
output "tenancy_ocid" { value = var.tenancy_ocid }
output "region" { value = local.home_region }
