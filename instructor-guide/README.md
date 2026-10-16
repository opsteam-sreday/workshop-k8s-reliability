# Guia do Instrutor — Kubernetes: Reliability ou Chaos?

> **Tese:** Kubernetes não cria resiliência automaticamente. Ele automatiza aquilo que configuramos — inclusive nossos erros.
>
> **Metodologia de todos os labs:** Break it → Observe it → Understand it → Fix it → Validate it.

## 1. Agenda sugerida (4h55)

| Horário | Bloco | Duração |
|---|---|---|
| 0:00 | Abertura: tese, arquitetura, contrato idempotente, tour do HyperDX | 20 min |
| 0:20 | **LAB 01** — First Successful Order | 35 min |
| 0:55 | **LAB 02** — CPU Stress & Autoscaling (HPA + Cluster Autoscaler) | 45 min |
| 1:40 | Intervalo | 10 min |
| 1:50 | **LAB 03** — QoS & PriorityClass | 45 min |
| 2:35 | **LAB 04** — Circuit Breaker | 35 min |
| 3:10 | **LAB 05** — ClickStack Alerting (anti-pattern) | 35 min |
| 3:45 | **LAB 06** — Probes, Graceful Shutdown & Topology Spread | 55 min |
| 4:40 | Retrospectiva: as 12 configurações e o que fica para a fase 2 | 15 min |

**Dica:** o scale-out de nós do LAB 02 leva de 2 a 4 minutos. Use esse tempo para discutir HPA × CA. Já o scale-down leva cerca de 4 minutos depois que a carga para (stabilization de 120 s + `scale-down-unneeded-time` de 2 min). Não espere por ele: siga para o intervalo.

**Modo de condução:**

- O cluster é **compartilhado**. O instrutor executa as falhas (`scripts/fault.sh`), e os alunos observam pelo `kubectl` e pelo HyperDX.
- Se cada aluno tiver um cluster, cada um executa todos os comandos.

## 2. Checklist pré-workshop

Faça com pelo menos 1 dia de antecedência:

- [ ] Conta AWS com permissão para EKS, EC2, IAM, DynamoDB, ECR e CloudFormation. Confirme com `aws sts get-caller-identity`.
- [ ] Região escolhida (padrão `us-east-1`; `export AWS_REGION=...`).
- [ ] **Cotas**: *Running On-Demand Standard instances* ≥ 32 vCPUs na região (pico: 5×`m6i.large` + 1×`m6i.xlarge` = 14 vCPUs, com folga para outros usos). Verifique também se há 1 Elastic IP livre para o NAT Gateway.
- [ ] Ferramentas: `aws` v2, `kubectl` ≥ 1.34, `eksctl` ≥ 0.231, `helm` ≥ 3.14 (testado com 4.3), `docker` com buildx, `python3`, `k6` (opcional: os testes rodam como Job no cluster).
- [ ] Estimativa de custo comunicada ao responsável pela conta:
  - ~US$ 0,55/h em repouso: EKS US$ 0,10 + 2×m6i.large + 1×m6i.xlarge + NAT + EBS.
  - ~US$ 0,85/h no pico do LAB 02, com 5 nós apps.
  - Um dia de workshop (setup na véspera + 8h) custa cerca de US$ 15–20.
- [ ] Execute `scripts/setup.sh` com **35–45 min de antecedência**. A criação do EKS leva de 15 a 20 min, e o ClickStack, mais 10 a 15 min.
- [ ] Execute `scripts/deploy.sh` (build e push das imagens + deploy, ≈5–10 min).
- [ ] Execute `scripts/validate.sh`. O relatório fica em `.workshop/validation-report.md`, e **todos os itens devem estar ✅**.
- [ ] Abra o HyperDX: `kubectl -n observability port-forward svc/clickstack-app 3000:3000`. As credenciais estão em `.workshop/hyperdx-credentials.json`. Confirme que existem logs, traces e as 4 alertas.
- [ ] Gere tráfego de base por 2 min (`scripts/k6.sh create-orders.js RATE=3 DURATION=2m`) para os gráficos não começarem vazios.
- [ ] Se os alunos forem acessar o cluster, distribua o kubeconfig e as credenciais do HyperDX e confirme o acesso RBAC (é preciso permissão de `pods/exec` para usar `scripts/fault.sh`).

### 2.1 Turma: um ambiente isolado por aluno (mesma conta)

Cada linha do roster (`infrastructure/students.csv`, formato em `students.example.csv`, fora do git) vira um
ambiente completo `rw-<id>` com isolamento próprio:

| Recurso | Nome | Isolamento |
|---|---|---|
| Cluster EKS + VPC + ClickStack | `rw-<id>` | VPC e node groups próprios |
| Tabela DynamoDB | `rw-<id>-orders` | só a Orders API do cluster `rw-<id>` grava (policy por tabela + session tag `eks-cluster-name`) |
| Role dos Pods (Pod Identity) | `rw-<id>-orders-api` | trust só no cluster `rw-<id>` |
| Role do aluno (humano) | `rw-<id>-student` | trust só na sessão SSO **daquele** usuário (`aws:userid`); acesso AWS só ao próprio cluster/tabela/secret; admin só no próprio cluster (access entry) |
| Credenciais do HyperDX | Secrets Manager `reliability-workshop/rw-<id>/hyperdx-credentials` | legível só pela role do aluno |
| Imagens | ECR `reliability-workshop/*` | compartilhadas, build único; nós só fazem pull. Tag por app = hash git de `apps/<app>` + `apps/shared` (`scripts/images.sh tag <app>`); `<tag>` é índice multi-arch (amd64 + arm64), repositórios `IMMUTABLE`; base fixada por digest e dependências só de `apps/*/requirements.lock` (com hash, `make lock`) |

**Com 1 semana de antecedência:**

1. `make fleet-quotas` — com 40 alunos, aumente em `us-east-1` **VPCs, Internet gateways e Elastic IPs** (padrão 5;
   ~50), **NAT gateways por AZ** (padrão 5; ~20 — o NAT de cada cluster cai em uma AZ) e **vCPU On-Demand Standard** (≥ 600: 8 vCPU/aluno em repouso, até 14 no LAB 02). Peça com antecedência.
2. Com credenciais da **conta de gerenciamento** da organização (dona do IAM Identity Center):
   `WORKSHOP_ACCOUNT_ID=<conta do workshop> make identity-center` — cria o permission set `ReliabilityWorkshopStudent`
   (só `sts:AssumeRole` em `rw-*-student`), os usuários (`CREATE_USERS=false` se o diretório for externo/SCIM) e a
   atribuição à conta. Usuários criados via API recebem o convite pelo console (*Reset password → Send email*).

**Na véspera (≈ 1 h para 40 alunos com `PARALLEL=8`; custo ≈ US$ 22/h para a turma em repouso):**

3. Suba a turma por **um** dos caminhos (mesmo fluxo por aluno: setup + deploy + role do aluno + validação):
   - **GitHub Actions (recomendado):** *Actions › fleet-up › Run workflow* com
     `students = aluno01:bruno@ops.team aluno02:ana@ops.team …` (id:username do roster). Build único das imagens e
     um job por aluno (`max_parallel`, padrão 8), cada um com log próprio. Não depende da sua máquina ligada.
     Com *Required reviewers* no environment `workshop`, aprove os jobs pendentes (eles chegam em ondas de
     `max_parallel`).
   - **Local:** `make fleet-up ASSUME_YES=true`. Estado e logs por aluno em `.workshop/fleet/rw-<id>/`.
4. `make fleet-status` — todos `ACTIVE` e validação sem falhas. Se a role SSO ainda não existia no passo 3:
   `make fleet-access`.
5. Envie a cada aluno o resultado de `make fleet-profile STUDENT_ID=<id>` (bloco do `~/.aws/config`).

**Um aluno com problema** (ambiente falhou, aluno novo, recriar do zero):

- Actions: *Re-run failed jobs* no run do `fleet-up` (refaz só os que falharam) ou *workshop-up* com o
  `student_id`/`student_username` dele.
- Local: `make student-up STUDENT_ID=aluno07` — mesmo fluxo de um aluno do `fleet-up`, em primeiro plano, com o
  username do roster; as etapas são idempotentes (o que já existe é mantido). Log em `.workshop/fleet/rw-aluno07/up.log`.
- Para recriar do zero: `make student-down STUDENT_ID=aluno07 ASSUME_YES=true` e depois `make student-up …`.

**Depois do evento:** `make fleet-down ASSUME_YES=true` (as imagens ECR ficam; `DELETE_IMAGES=true` remove) e,
na conta de gerenciamento, `infrastructure/identity-center.sh remove infrastructure/students.csv`.

## 3. Roteiro por laboratório

### LAB 01 — First Successful Order

- **Break/Observe:** primeiro pedido pela BFF; reenvio com a mesma chave; reenvio com payload diferente; `idempotency-concurrency.js`.
- **Pontos de discussão:**
  - O Kubernetes reinicia Pods, mas **não** impede pedidos duplicados quando o cliente faz retry. Idempotência é uma decisão da aplicação.
  - Por que `ConditionExpression=attribute_not_exists(PK)` e não "GetItem e depois PutItem"? A segunda forma tem uma condição de corrida (TOCTOU).
  - Lease + fencing (`version`): um Pod que morreu no meio da operação não pode sobrescrever o resultado de quem assumiu depois.
  - Pod Identity: a credencial pertence à **ServiceAccount**, não ao nó. Por que bloquear o IMDS? Sem isso, qualquer Pod herdaria a role do nó.
  - Autenticação AWS (quem é você para a AWS), identidade Kubernetes (qual SA) e autorização entre aplicações (BFF → Orders) são camadas diferentes.
- **Pontos de atenção:** no trace distribuído, mostre os spans `Idempotency Claim`, `Reserve Inventory` e `Complete Order` (TransactWriteItems).

### LAB 02 — CPU Stress & Autoscaling

- **Break:** `ORDERS_CPU_WORK_MS=40` + `stress-orders.js`.
- **Observe:** HPA (`TARGETS` acima de 60%), réplicas subindo, Pods `Pending` (`FailedScheduling`), `TriggeredScaleUp` e nós novos.
- **Pontos de discussão:**
  - O HPA calcula a utilização sobre `requests.cpu`. Com request de 250m, 150m de uso já são 60%. Requests mal dimensionados geram escala excessiva ou insuficiente.
  - HPA (segundos) × CA (minutos: EC2 + bootstrap + imagem). O "buraco" entre os dois é onde a latência explode. Vale discutir overprovisioning e pausa de Pods como fase 2.
  - Python com GIL: 1 processo usa no máximo 1 core. O limite de 1000m é o teto real por Pod.
  - Scale-down: `stabilizationWindowSeconds` evita *flapping*. O CA espera `scale-down-unneeded-time`.
- **Lembrete:** o observability node group tem tamanho fixo (1) e taint. O CA e o k6 rodam lá e não competem com a carga.

### LAB 03 — QoS & PriorityClass

- **Break:**
  1. Perfis BestEffort, Burstable e Guaranteed (`labs/lab-03/qos.sh`).
  2. `cpu-burn` com limite de 500m, que causa **throttling** (`labs/lab-03/cpu-stat.sh`).
  3. `memory 700` com limite de 512Mi, que causa **OOMKilled**. O restart zera o estoque em memória.
  4. Preemption: CA em 0 + Inventory em `low-priority-services` + `fill-capacity.py` + scale da Orders.
- **Pontos de discussão:**
  - QoS decide **quem sofre primeiro** sob pressão do nó. PriorityClass decide **quem é agendado e quem é removido** quando falta capacidade. São problemas diferentes: um Pod **Guaranteed** de baixa prioridade é preemptado mesmo assim.
  - Throttling não aparece como restart: o Pod fica "saudável" e lento. Por isso a métrica `container.cpu.throttled_time` existe.
  - Atribuir prioridade baixa à Inventory é um anti-pattern **intencional**. Ela participa da transação STRICT, então removê-la derruba 100% dos pedidos, mesmo com BFF e Orders "críticas".
  - Prioridade é transitiva: as dependências síncronas do caminho crítico herdam a criticidade.
- **Pontos de atenção:** depois da preemption, a Inventory fica Pending. A correção (`critical-services`) **não basta** sem capacidade: Pods de mesma prioridade não se preemptam. Reative o CA (`scripts/reset.sh` ou escalar o CA para 1) para que um nó novo seja criado.

### LAB 04 — Circuit Breaker

- **Break:** latência de 800 ms na reserva (timeout de 500 ms) e depois HTTP 503.
- **Observe:**
  - `labs/lab-04/watch-cb.sh`: CLOSED → OPEN → HALF_OPEN → OPEN/CLOSED.
  - Respostas 503 com `reason=circuit_open` voltando em menos de 10 ms.
  - Traces com eventos `retry` e `attempt.failed`.
- **Pontos de discussão:**
  - Sem o circuit breaker, cada requisição esperaria cerca de 3×500 ms + backoff, prendendo conexões e workers. O fail fast protege a Orders **e** a Inventory degradada.
  - Retry amplification (exemplo hipotético): se cliente, BFF e Orders fizessem 3 tentativas cada, uma requisição poderia virar 3×3×3 = 27 chamadas à Inventory. Neste workshop só a Orders faz retry para a Inventory (até 2 retries, com orçamento de 2 s) e o circuito aberto interrompe os retries. O SDK do DynamoDB tem retry próprio (max_attempts=3) — outra camada a considerar.
  - O estado do circuito é local por réplica. Com 4 réplicas, até 8 chamadas de teste em HALF_OPEN. Compartilhar estado é fase 2.
  - Timeout após o commit (`slow-after-commit`): a reserva **aconteceu**. Por isso não há compensação cega, e o retry reutiliza a mesma reserva (idempotência na Inventory).
  - Readiness não verifica a Inventory, de propósito. Se verificasse, todas as réplicas da Orders sairiam do Service (cascata).

### LAB 05 — ClickStack Alerting

- **Break:** falhas na Orders (`db FAIL_READS`, Inventory 503) e na Inventory (`http-503 RESERVATIONS` e `QUERIES`) + `inventory-errors.js`.
- **Observe:**
  - As 4 alertas disparam. O webhook recebe as notificações (`kubectl -n observability logs deploy/alert-webhook`).
  - `labs/lab-05/compare-counts.sh` compara: COUNT(logs ERROR) ≈ **2×** as requisições reais (log contextual + log de conclusão). Os spans HTTP SERVER e a métrica `http.server.request.duration` mostram o número verdadeiro.
- **Pontos de discussão:**
  - O alerta conta **linhas de log**, não requisições. Mudar o formato de log (ex.: adicionar um `log.error` de contexto) muda o alerta sem mudar a realidade.
  - Falhas sem ERROR: um crash (`crash-after-reservation`, exit 137) não gera log de conclusão. O 503 aparece na BFF, mas nenhum ERROR aparece na Orders para aquela rota (consulta (e) do script).
  - Amostragem: com sampling < 100%, contar spans também distorce. A fonte certa para taxa de erro são métricas HTTP não amostradas (fase 2: alertas corrigidos, SLOs, error budgets).

## 4. Respostas esperadas dos Challenges

| Lab | Challenge (resumo) | Resposta esperada |
|---|---|---|
| 01 | Por que a mesma chave com payload diferente retorna 409 e não "cria outro pedido"? | A chave identifica a **intenção**. O hash canônico diferente indica reuso indevido. Aceitar o novo payload quebraria o contrato e esconderia bugs no cliente |
| 01 | O que acontece se o Pod morrer após reservar e antes de persistir? | O registro fica IN_PROGRESS com lease. Requisições seguintes recebem 409 `ORDER_IN_PROGRESS` + `Retry-After`. Depois que o lease expira, um executor faz takeover (`version+1`) e reenvia a reserva com o mesmo `reservation_id`. A Inventory responde como replay (sem novo decremento) e o pedido é confirmado. Os testes de integração `test_07` comprovam esse fluxo |
| 01 | Como provar que a BFF não acessa o DynamoDB? | `scripts/validate-iam.sh`: a SA `bff-api-sa` não tem associação (`Unable to locate credentials`) e o IMDS está bloqueado |
| 02 | Remova `requests.cpu` da Orders. O que o HPA faz? | `TARGETS` mostra `<unknown>`: sem request não existe utilização, e o HPA não escala (`FailedGetResourceMetric`) |
| 02 | Por que os Pods ficam Pending antes do nó novo aparecer? | O HPA cria réplicas em segundos. O CA só age quando surge um Pending, e o EC2 leva minutos para entrar no cluster |
| 02 | Como reduzir o tempo de reação? | Requests corretos, `minReplicas` maior em horários de pico, overprovisioning com Pods de baixa prioridade (pause) e instâncias/AMIs com imagens pré-carregadas |
| 03 | Qual Pod morre primeiro numa pressão de memória do nó? | BestEffort (`oom_score_adj` 1000), depois Burstable acima do request, e Guaranteed por último |
| 03 | Guaranteed protege contra preemption? | Não. Preemption depende só da PriorityClass. O LAB demonstra isso com a Inventory Guaranteed sendo preemptada |
| 03 | Qual a correção para a Inventory? | `critical-services` (a mesma prioridade do caminho crítico) + capacidade (CA) + requests realistas. Na fase 2: réplicas com estado compartilhado + PDB |
| 04 | Por que não fazer retry na BFF também? | Amplificação multiplicativa. Além disso, a BFF não sabe se o POST foi aplicado. O cliente final repete com a mesma Idempotency-Key, respeitando `Retry-After` |
| 04 | Com 5 réplicas da Orders, quantas falhas até "todo o sistema" abrir o circuito? | Cada réplica precisa de 5 falhas consecutivas próprias. Como o tráfego é distribuído, o total é ≈ 25 falhas, e o comportamento é inconsistente entre réplicas (estado local) |
| 05 | Por que o alerta "Orders Creation Errors" mostra o dobro das falhas? | Cada 503 gera 2 logs ERROR com a mesma rota e status: "Inventory API indisponível" e "HTTP request completed" |
| 05 | Proponha o alerta correto | Taxa de 5xx sobre o total por rota a partir de `http.server.request.duration` (count por `http.response.status_code`) ou de spans `SpanKind=Server`. Com janela e burn rate (fase 2) |

## 5. Troubleshooting

| Sintoma | Diagnóstico | Ação |
|---|---|---|
| `ImagePullBackOff` nas APIs | `kubectl -n ecommerce describe pod <pod>`: repositório ECR inexistente ou tag não publicada | Confira a tag (`scripts/images.sh tag orders-api`) e `aws ecr describe-images --repository-name reliability-workshop/orders-api`. Publique com `scripts/images.sh all` (ou o workflow `images`) e reaplique com `scripts/deploy.sh --skip-build` |
| Pods `Pending` com `untolerated taint {workload: observability}` | O workload foi para o node group errado | As APIs usam `nodeSelector: workload=apps`. Verifique `kubectl get nodes -L workload`. No ClickStack, confira `observability/clickstack/values.yaml` |
| Pods `Pending` com `Insufficient cpu` fora do LAB 02/03 | Sobras de laboratório (ballast, HPA alto, CA em 0) | `scripts/reset.sh`. Confira `kubectl -n kube-system get deploy -l app.kubernetes.io/name=aws-cluster-autoscaler` (réplicas = 1) |
| APIs nunca ficam Ready (readiness/liveness falhando) com NetworkPolicy | Possível bloqueio das probes do kubelet pela NetworkPolicy | **Diagnóstico temporário:** `kubectl -n ecommerce delete networkpolicy default-deny-ingress`. Se os Pods ficarem Ready, o problema é a policy: reaplique com `kubectl apply -k kubernetes/overlays/generated` e verifique a versão do VPC CNI (`enableNetworkPolicy`). Não deixe a policy removida |
| Orders não fica Ready (startup 503) | `kubectl -n ecommerce logs deploy/orders-api \| grep Warm-up`: AccessDenied ou ResourceNotFound | `infrastructure/pod-identity.sh status`, `infrastructure/dynamodb.sh status`. Confira `ORDERS_TABLE_NAME`/`AWS_REGION` no ConfigMap `orders-config` |
| HyperDX sem dados das APIs | Secret ou ingestion key incorreta, ou gateway com erro 401 | `kubectl -n observability get secret clickstack-ingestion`, `kubectl -n observability logs deploy/otel-gateway \| grep -iE "error\|401"`. Reexecute `scripts/setup.sh`: ele é idempotente, recria o Secret e reinicia o gateway |
| HyperDX sem métricas k8s.* | Agent sem acesso ao kubelet | `kubectl -n observability logs ds/otel-agent \| grep kubeletstats` |
| Cluster Autoscaler não escala (`AccessDenied` nos logs) | Pod Identity Association ausente | `aws eks list-pod-identity-associations --cluster-name $CLUSTER_NAME --namespace kube-system` deve listar `cluster-autoscaler`. Confira `rbac.serviceAccount.name=cluster-autoscaler` e reinicie o Pod do CA |
| CA não escala, sem erro | Máximo do node group atingido (5) ou Pod sem caber em nenhum template | Logs: `kubectl -n kube-system logs deploy/cluster-autoscaler-aws-cluster-autoscaler \| grep -i "scale-up"` |
| HPA com `<unknown>` | Metrics Server indisponível | `kubectl top nodes`, `kubectl -n kube-system get deploy metrics-server`, `aws eks describe-addon --addon-name metrics-server --cluster-name $CLUSTER_NAME` |
| `scripts/fault.sh` com `Forbidden` | RBAC sem `pods/exec` | Conceda `pods/exec` no namespace `ecommerce` ao grupo do aluno, ou deixe a execução com o instrutor |
| Alertas não chegam ao webhook | O webhook não existe ou o alerta está em `OK` | `kubectl -n observability logs deploy/alert-webhook`. Reexecute `observability/alerts/create_alerts.py` via port-forward (idempotente). As alertas são avaliadas a cada minuto em janelas de 5 min |

## 6. Reset entre turmas

```bash
scripts/reset.sh                   # falhas, CB, perfis QoS/Priority, HPA, CA, jobs k6, ballast
scripts/fault.sh inventory reset-stock
scripts/validate.sh --quick        # confirma o baseline
```

O reset **não** apaga os pedidos no DynamoDB nem os dados do ClickStack. Isso é intencional: o histórico ajuda nas discussões. Para começar do zero, use `infrastructure/dynamodb.sh delete && infrastructure/dynamodb.sh create` e reinicie a Orders.

## 7. Teardown e verificação de custos

```bash
scripts/teardown.sh   # remove namespaces/PVCs (volumes EBS), Helm releases, Pod Identity/IAM, DynamoDB, ECR e o cluster
```

O próprio script verifica os volumes EBS com a tag do cluster e as stacks CloudFormation `eksctl-<cluster>`. Depois, confira manualmente:

```bash
aws eks list-clusters --region $AWS_REGION
aws ec2 describe-volumes --region $AWS_REGION --filters Name=status,Values=available --query 'Volumes[].VolumeId'
aws ec2 describe-nat-gateways --region $AWS_REGION --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId'
aws ec2 describe-addresses --region $AWS_REGION --query 'Addresses[?AssociationId==null].PublicIp'
aws iam list-roles --query "Roles[?starts_with(RoleName, 'rw-')].RoleName"   # vazio = roles removidas
aws dynamodb list-tables --region $AWS_REGION
```

No dia seguinte, verifique no **Cost Explorer** se há custos residuais com a tag `workshop=kubernetes-reliability`.

## 8. Limitações conhecidas do MVP

- **Circuit Breaker local por réplica:** cada Pod da Orders tem o próprio estado. N réplicas podem fazer até N×`CB_HALF_OPEN_MAX_CALLS` chamadas de teste e se comportar de forma inconsistente.
- **Inventory em memória, réplica única:** não há durabilidade. Um restart (OOMKilled, preemption, rollout) zera o estoque e as reservas, e não há recuperação garantida das reservas. Deployment com strategy `Recreate`.
- **Identidade simulada:** o cliente é identificado por `X-Customer-ID` ou pelo `customer_id` do body. Em produção, isso viria de um token autenticado (JWT validado); o body nunca deve ser a fonte de identidade.
- **`unit_price` vem do cliente:** a Orders confia no preço enviado. Em produção, o preço viria do catálogo.
- **Sampling de 100%:** adequado ao workshop. Em produção, seria necessário sampling (head/tail), e a contagem por spans passaria a ser estimativa.
- **Alertas por contagem de logs:** anti-pattern **intencional**, com comentário obrigatório em `observability/alerts/create_alerts.py`. A correção, com métricas ou spans HTTP SERVER, fica para a fase 2.
- **TTL do DynamoDB é assíncrono:** itens expirados podem permanecer por dias. A aplicação também verifica `expires_at` logicamente. Depois de 24h, a mesma chave pode gerar uma nova operação.
- **Reserva com resultado desconhecido:** se o cliente nunca repetir a requisição, uma reserva `UNKNOWN`/`COMPENSATION_PENDING` permanece. Não há reconciliação automática (fase 2).
- **Readiness não verifica dependências:** é uma escolha deliberada para evitar cascata. Por isso, a indisponibilidade da Inventory aparece como 503 de negócio, não como Pods NotReady.
- **Somente modo STRICT:** DEGRADED mode, PDB, TopologySpread, VPA e dashboards avançados ficam fora do escopo (fase 2).
