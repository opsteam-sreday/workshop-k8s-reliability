# VPCs do workshop — plano de endereçamento

Uma VPC `/16` por cluster, entre `10.201.0.0/16` e `10.240.0.0/16` (40 alunos, inclusive o instrutor, sem
sobreposição: permite peering/VPN entre elas no futuro; `10.200.0.0/16` fica livre). Criada por `infrastructure/vpc/vpc.sh create` (chamado pelo `scripts/setup.sh` antes do eksctl)
a partir de `vpc.yaml`; removida pelo `scripts/teardown.sh` depois do cluster.

| Subnet | CIDR | Uso |
|---|---|---|
| pública A | `10.X.0.0/20` | ENIs do control plane do EKS (`controlPlaneSubnetIDs`) + **NAT Gateway** |
| pública B | `10.X.16.0/20` | ENIs do control plane do EKS |
| privada A | `10.X.64.0/18` | node groups `apps` e `observability` (saída pela NAT) |
| privada B | `10.X.128.0/18` | node groups |

- **Privadas maiores:** o VPC CNI dá a cada Pod um IP da VPC (cada `m6i.large` reserva dezenas).
- **NAT único por VPC (AZ A):** 40 clusters × 2 NATs não caberiam na quota de Elastic IPs (50). Se a AZ A cair, os
  nós da AZ B perdem saída para a internet — aceitável para um workshop.
- **Endpoint da API:** público (kubectl de alunos e pipeline) + privado (nós falam com a API dentro da VPC). Estar em
  subnets públicas define onde ficam as ENIs do control plane; a exposição da API é o `clusterEndpoints`.
- **AZs:** giram por cluster entre as AZs elegíveis (`use1-az3` excluída: sem control plane do EKS e sem `m6i`),
  espalhando os NATs (quota: NAT gateways por AZ). Nomes de AZ variam por conta; a tabela abaixo é da conta do workshop.
- `VPC_SECOND_OCTET=<200..240>` sobrescreve o cálculo para IDs de aluno sem número final.

| Cluster | VPC | AZ A (NAT) | AZ B |
|---|---|---|---|
| `rw-aluno01` | `10.201.0.0/16` | us-east-1b | us-east-1c |
| `rw-aluno02` | `10.202.0.0/16` | us-east-1c | us-east-1f |
| `rw-aluno03` | `10.203.0.0/16` | us-east-1f | us-east-1d |
| `rw-aluno04` | `10.204.0.0/16` | us-east-1d | us-east-1a |
| `rw-aluno05` | `10.205.0.0/16` | us-east-1a | us-east-1b |
| `rw-aluno06` | `10.206.0.0/16` | us-east-1b | us-east-1c |
| `rw-aluno07` | `10.207.0.0/16` | us-east-1c | us-east-1f |
| `rw-aluno08` | `10.208.0.0/16` | us-east-1f | us-east-1d |
| `rw-aluno09` | `10.209.0.0/16` | us-east-1d | us-east-1a |
| `rw-aluno10` | `10.210.0.0/16` | us-east-1a | us-east-1b |
| `rw-aluno11` | `10.211.0.0/16` | us-east-1b | us-east-1c |
| `rw-aluno12` | `10.212.0.0/16` | us-east-1c | us-east-1f |
| `rw-aluno13` | `10.213.0.0/16` | us-east-1f | us-east-1d |
| `rw-aluno14` | `10.214.0.0/16` | us-east-1d | us-east-1a |
| `rw-aluno15` | `10.215.0.0/16` | us-east-1a | us-east-1b |
| `rw-aluno16` | `10.216.0.0/16` | us-east-1b | us-east-1c |
| `rw-aluno17` | `10.217.0.0/16` | us-east-1c | us-east-1f |
| `rw-aluno18` | `10.218.0.0/16` | us-east-1f | us-east-1d |
| `rw-aluno19` | `10.219.0.0/16` | us-east-1d | us-east-1a |
| `rw-aluno20` | `10.220.0.0/16` | us-east-1a | us-east-1b |
| `rw-aluno21` | `10.221.0.0/16` | us-east-1b | us-east-1c |
| `rw-aluno22` | `10.222.0.0/16` | us-east-1c | us-east-1f |
| `rw-aluno23` | `10.223.0.0/16` | us-east-1f | us-east-1d |
| `rw-aluno24` | `10.224.0.0/16` | us-east-1d | us-east-1a |
| `rw-aluno25` | `10.225.0.0/16` | us-east-1a | us-east-1b |
| `rw-aluno26` | `10.226.0.0/16` | us-east-1b | us-east-1c |
| `rw-aluno27` | `10.227.0.0/16` | us-east-1c | us-east-1f |
| `rw-aluno28` | `10.228.0.0/16` | us-east-1f | us-east-1d |
| `rw-aluno29` | `10.229.0.0/16` | us-east-1d | us-east-1a |
| `rw-aluno30` | `10.230.0.0/16` | us-east-1a | us-east-1b |
| `rw-aluno31` | `10.231.0.0/16` | us-east-1b | us-east-1c |
| `rw-aluno32` | `10.232.0.0/16` | us-east-1c | us-east-1f |
| `rw-aluno33` | `10.233.0.0/16` | us-east-1f | us-east-1d |
| `rw-aluno34` | `10.234.0.0/16` | us-east-1d | us-east-1a |
| `rw-aluno35` | `10.235.0.0/16` | us-east-1a | us-east-1b |
| `rw-aluno36` | `10.236.0.0/16` | us-east-1b | us-east-1c |
| `rw-aluno37` | `10.237.0.0/16` | us-east-1c | us-east-1f |
| `rw-aluno38` | `10.238.0.0/16` | us-east-1f | us-east-1d |
| `rw-aluno39` | `10.239.0.0/16` | us-east-1d | us-east-1a |
| `rw-aluno40` | `10.240.0.0/16` | us-east-1a | us-east-1b |
