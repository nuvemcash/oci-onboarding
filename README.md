# nuvem.cash — Onboarding OCI (template público)

Template Terraform **público e genérico** usado pelo onboarding "um clique" do
[nuvem.cash](https://nuvem.cash) para conectar uma tenancy Oracle Cloud (OCI).

Ao ser aplicado pelo Oracle Resource Manager, ele cria na **sua** tenancy, de forma
**somente leitura**:

- um usuário de serviço `svc-nuvemcash` e um grupo `nuvemcash-cost-readers`;
- uma API key registrada com a **chave pública** do nuvem.cash (a privada nunca sai
  do backend do nuvem.cash);
- uma policy que autoriza esse grupo a **ler os relatórios de custo FOCUS**.

Ao final, dispara um callback para o nuvem.cash com o OCID do usuário criado.

## Como os valores chegam

O nuvem.cash gera a deployURL do botão "Deploy to Oracle Cloud" apontando para o
arquivo `main.zip` deste repositório e passa os valores por-tenant via
`zipUrlVariables` (`public_key_pem_b64`, `callback_url`, `onboarding_token`). Nada
sensível fica neste repositório — ele é totalmente auditável.

## Reverter

Rodar `destroy` na stack do Resource Manager remove o usuário, grupo, API key e
policy criados.

## Tenants já conectados (reparo de permissões)

Versões antigas deste template não concediam `read usage-report in tenancy`
(Usage API) — sem ela o nuvem.cash lê o FOCUS mas não ancora o extrato na
fatura real, e o custo aparece subcontado. Duas rotas de reparo, ambas
aditivas (nada é removido):

**Console:** Identity & Security › Policies › `nuvemcash-cost-readers`
(compartimento raiz) → Edit → acrescente o statement:

    allow group nuvemcash-cost-readers to read usage-report in tenancy

**Script idempotente** (requer OCI CLI autenticada como admin do tenancy e jq):

    ./scripts/repair-policy.sh <tenancy_ocid> [profile]

O script só ADICIONA statements ausentes; nunca remove nem substitui os
existentes. Alternativa equivalente: reaplicar o stack no Resource Manager
com a versão atual deste template.
