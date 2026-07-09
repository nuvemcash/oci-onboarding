#!/usr/bin/env bash
# Reparo idempotente da policy nuvemcash-cost-readers em tenants já conectados:
# SÓ ADICIONA os statements ausentes — nunca remove nem substitui os existentes.
#
# Requisitos: OCI CLI autenticada com permissão de administrar policies no
# compartimento raiz do tenancy, e jq.
#
# Uso: ./repair-policy.sh <tenancy_ocid> [profile]
#   GROUP=<nome> ./repair-policy.sh ...  # sobrescreve o nome do grupo (ex.:
#   "'MeuDominio'/nuvemcash-cost-readers" em Identity Domains fora do Default)
set -euo pipefail

TENANCY_OCID="${1:?uso: $0 <tenancy_ocid> [profile]}"
PROFILE="${2:-DEFAULT}"
GROUP="${GROUP:-nuvemcash-cost-readers}"
POLICY_NAME="nuvemcash-cost-readers"

REPORTING_TENANCY="ocid1.tenancy.oc1..aaaaaaaaned4fkpkisbwjlr56u7cj63lf3wffbilvqknstgtvzub7vhqkggq"
REQUIRED=(
  "define tenancy reporting as ${REPORTING_TENANCY}"
  "endorse group ${GROUP} to read objects in tenancy reporting"
  "allow group ${GROUP} to read usage-report in tenancy"
)

policy_json=$(oci --profile "$PROFILE" iam policy list \
  --compartment-id "$TENANCY_OCID" --all |
  jq --arg name "$POLICY_NAME" '[.data[] | select(.name == $name)] | first')

if [[ -z "$policy_json" || "$policy_json" == "null" ]]; then
  echo "ERRO: policy '$POLICY_NAME' não encontrada no compartimento raiz." >&2
  exit 1
fi

policy_id=$(jq -r '.id' <<<"$policy_json")
current=$(jq '.statements' <<<"$policy_json")

missing=()
for stmt in "${REQUIRED[@]}"; do
  if ! jq -e --arg s "$stmt" 'map(ascii_downcase) | index($s | ascii_downcase)' \
    <<<"$current" >/dev/null; then
    missing+=("$stmt")
  fi
done

if [[ ${#missing[@]} -eq 0 ]]; then
  echo "OK: todos os statements já presentes — nada a fazer."
  exit 0
fi

new_json=$(printf '%s\n' "${missing[@]}" | jq -R . | jq -s .)
merged=$(jq -c --argjson add "$new_json" '. + $add' <<<"$current")

echo "Adicionando ${#missing[@]} statement(s) à policy $policy_id:"
printf '  + %s\n' "${missing[@]}"

oci --profile "$PROFILE" iam policy update \
  --policy-id "$policy_id" \
  --statements "$merged" \
  --force >/dev/null

echo "OK: policy atualizada."
