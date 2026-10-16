# LAB 05 — QoS & PriorityClass

> **Break it → Observe it → Understand it → Fix it → Validate it**
>
> Duração estimada: 50–60 min · Parte A (QoS) ≈ 25 min · Parte B (PriorityClass/Preemption) ≈ 25 min

---

## 1. Cenário

A Inventory API participa **de toda transação de pedido** (pré-consulta `GET /inventory/{sku}` e reserva
`POST /inventory/reservations`). No modo STRICT do MVP, um pedido só é `CONFIRMED` depois da reserva de estoque.

O time de plataforma "otimizou custos": a Inventory API ganhou requests/limits genéricos e, num cluster
apertado, foi marcada como **baixa prioridade** porque "é só um serviço de estoque". Neste laboratório você vai
ver o que acontece com essa dependência quando:

- o **nó** fica sob pressão de CPU/memória (domínio do **QoS**);
- o **scheduler** fica sem capacidade para agendar Pods críticos (domínio da **PriorityClass/preemption**).

```mermaid
flowchart LR
    subgraph NODE["Pressão no NÓ → kubelet / kernel (QoS: requests/limits)"]
        direction TB
        C1["Uso de CPU acima do limit"] --> T1["CPU throttling (CFS cpu.max)<br/>Pod continua vivo, fica lento"]
        M1["Memória do container atinge o limit"] --> O1["OOMKilled (kernel)<br/>container reinicia, estado em memória perdido"]
        N1["Nó sem memória (memory.available baixo)"] --> E1["Eviction (kubelet)<br/>BestEffort primeiro, depois Burstable acima do request"]
    end
    subgraph SCHED["Falta de capacidade de AGENDAMENTO → kube-scheduler (PriorityClass)"]
        direction TB
        P1["Pod novo não cabe em nenhum nó"] --> P2{"Existe Pod de prioridade<br/>ESTRITAMENTE menor que libere o suficiente?"}
        P2 -- sim --> P3["Preemption: vítima removida<br/>(QoS não entra na conta)"]
        P2 -- não --> P4["Pod fica Pending<br/>(Cluster Autoscaler, se ligado, cria nó)"]
    end
```

## 2. Hipótese

1. Requests/limits determinam a `QoSClass` (`BestEffort`, `Burstable`, `Guaranteed`), e cada classe sofre de forma
   diferente: **limit de CPU causa throttling** (não mata), **limit de memória causa OOMKilled** (mata o container),
   **pressão no nó causa eviction** (kubelet remove Pods — BestEffort primeiro).
2. `Guaranteed` **não** protege contra preemption: um Pod Guaranteed de baixa prioridade é removido pelo scheduler para
   abrir espaço a um Pod de prioridade maior.
3. Como a Inventory API é dependência transacional, removê-la derruba **todos** os pedidos (503 + Circuit Breaker OPEN).
   QoS e PriorityClass resolvem problemas **diferentes**.

## 3. Pré-requisitos

- LAB 01 concluído (`scripts/validate.sh` sem falhas).
- `kubectl` apontando para o cluster do workshop; `python3` local (para `fill-capacity.py`).
- Acesso ao HyperDX: `kubectl -n observability port-forward svc/clickstack-app 3000:3000` → <http://localhost:3000>
  (credenciais em `.workshop/hyperdx-credentials.json`).
- Três terminais: **T1** comandos, **T2** observação (`watch`/scripts), **T3** carga k6.

## 4. Estado inicial

```bash
scripts/reset.sh
kubectl -n ecommerce get pods -o custom-columns=POD:.metadata.name,QOS:.status.qosClass,PRIORITY:.spec.priorityClassName,NODE:.spec.nodeName
kubectl get priorityclass critical-services low-priority-services
kubectl get nodes -l workload=apps
```

Esperado:

| Workload | QoSClass | PriorityClass |
|---|---|---|
| bff-api (2) | Burstable (200m/256Mi → 1000m/256Mi) | `critical-services` (1000) |
| orders-api (2+) | Burstable (250m/256Mi → 1000m/384Mi) | `critical-services` (1000) |
| inventory-api (1) | Burstable (100m/128Mi → 500m/512Mi) | `critical-services` (1000) — o lab troca para `low-priority-services` |

2 nós `apps` (`m6i.large`), Cluster Autoscaler com 1 réplica.

---

## 5. Comandos executáveis

### Parte A — QoS

#### A.1 Classificação QoS dos três perfis

```bash
labs/lab-05/qos.sh besteffort     # resources: {}                         -> BestEffort
labs/lab-05/qos.sh burstable      # requests 100m/128Mi, limits 500m/512Mi -> Burstable
labs/lab-05/qos.sh guaranteed     # requests == limits 500m/512Mi          -> Guaranteed
```

```mermaid
flowchart TD
    R["resources do container"] --> Q1{"Algum request ou limit?"}
    Q1 -- "não ({})" --> BE["BestEffort<br/>(perfil besteffort)"]
    Q1 -- sim --> Q2{"requests == limits<br/>para CPU e memória?"}
    Q2 -- "sim (500m/512Mi = 500m/512Mi)" --> G["Guaranteed<br/>(perfil guaranteed)"]
    Q2 -- "não (100m/128Mi → 500m/512Mi)" --> BU["Burstable<br/>(perfil burstable, padrão da Inventory)"]
```

| Cenário | Ação | Comportamento esperado | Como verificar |
|---|---|---|---|
| Sem resources | `qos.sh besteffort` | Pod recriado (`Recreate`) como `BestEffort`; estoque em memória reiniciado | `kubectl -n ecommerce get pod -l app.kubernetes.io/name=inventory-api -o jsonpath='{.items[0].status.qosClass}'` |
| Request < limit | `qos.sh burstable` | `Burstable` (100m/128Mi → 500m/512Mi) | idem |
| Request = limit | `qos.sh guaranteed` | `Guaranteed` (500m/512Mi) | idem |

Os perfis estão em `kubernetes/labs/qos/inventory-*.patch.json` (JSON patch sobre `containers[0].resources`).
A Inventory API usa `strategy: Recreate` (réplica única com estado em memória), então cada troca de perfil
**recria o Pod** — e reinicia o estoque/reservas em memória.

> **💡 O que você deveria ter notado (A.1)**
>
> - A `QoSClass` veio só dos `resources`: `{}` → `BestEffort`; request < limit (100m/128Mi → 500m/512Mi) →
>   `Burstable`; request = limit (500m/512Mi) → `Guaranteed`.
> - Cada troca de perfil **recriou** o Pod da Inventory (`strategy: Recreate`) e reiniciou o estoque em memória.
>
> **Lição:** QoS não é configurada diretamente — é **consequência** de requests e limits.

Os dois experimentos seguintes batem no **limit** do container, mas o resultado é oposto porque CPU é comprimível
e memória não:

```mermaid
flowchart LR
    subgraph CPU["A.2 — cpu-burn 2 (~2 cores) contra limit 500m"]
        direction TB
        a1["Processo pede mais CPU"] --> a2["CFS: cota cpu.max 50000/100000 esgotada"]
        a2 --> a3["Processo pausado até o próximo período de 100 ms"]
        a3 --> a4["nr_throttled ↑ · latência ↑ · RESTARTS igual"]
    end
    subgraph MEM["A.3 — memory 700 contra limit 512Mi"]
        direction TB
        b1["Ballast cresce 16 MiB / 250 ms"] --> b2["cgroup atinge memory.max (512Mi)"]
        b2 --> b3["Kernel mata o processo (OOM killer)"]
        b3 --> b4["OOMKilled · RESTARTS +1 · estoque/reservas zerados"]
    end
```

#### A.2 CPU throttling (perfil com limit de CPU)

```bash
# T1 — perfil Burstable (limit 500m) e 2 processos consumindo 1 core cada
labs/lab-05/qos.sh burstable
scripts/fault.sh inventory cpu-burn 2

# T2 — contadores do cgroup v2 a cada 5s
labs/lab-05/cpu-stat.sh
```

Saída esperada do `cpu-stat.sh`:

```text
10:41:05 cpu.max=[50000 100000] nr_periods 1200 nr_throttled 1150 throttled_usec 61234567
```

`cpu.max = 50000 100000` → 50 ms de CPU a cada período de 100 ms = **500m**. Com demanda de ~2 cores,
praticamente todo período é throttled.

Meça o efeito na latência pelo caminho real do pedido (a NetworkPolicy só permite Orders → Inventory):

```bash
# T3 — carga leve de pedidos durante o throttling
scripts/k6.sh create-orders.js RATE=5 DURATION=2m
```

Compare `http_req_duration p(95)` com e sem `cpu-burn`. No HyperDX:

- **Metrics** → `container.cpu.throttled_time` (counter, segundos) e `container.cpu.throttled_periods`,
  filtro `ServiceName = inventory-api`;
- **Metrics** → `k8s.pod.cpu_limit_utilization` (kubeletstats) próximo de 1.0;
- **Traces** → spans `POST /inventory/reservations` mais lentos.

Desligue o stress:

```bash
scripts/fault.sh inventory cpu-burn 0
```

> **💡 O que você deveria ter notado (A.2)**
>
> - `cpu.max = 50000 100000`: o limit de 500m vira uma cota de 50 ms a cada 100 ms.
> - `nr_throttled` subiu quase junto com `nr_periods` (na validação do workshop: de 24 para 250 em 20 s).
> - O Pod **não** reiniciou: `RESTARTS` ficou igual; o efeito foi só a latência maior dos pedidos.
>
> **Lição:** estourar o limit de **CPU** deixa o container mais lento (throttling), não o mata.

#### A.3 OOMKilled (limit de memória)

```bash
labs/lab-05/qos.sh burstable                 # limit 512Mi (mesmo resultado com guaranteed)
scripts/fault.sh inventory memory 700        # ballast cresce 16 MiB a cada 250 ms até 700 MiB
kubectl -n ecommerce get pods -l app.kubernetes.io/name=inventory-api -w
```

Após ~10 s o contador `RESTARTS` incrementa. Confirme o motivo:

```bash
kubectl -n ecommerce get pod -l app.kubernetes.io/name=inventory-api \
  -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated.reason}{"\n"}'
# OOMKilled
kubectl -n ecommerce describe pod -l app.kubernetes.io/name=inventory-api | grep -A5 "Last State"
```

> O container reinicia com a configuração de falhas **padrão** (ballast = 0), então não entra em loop.

**Consequência de negócio:** o estoque e as reservas vivem em memória. Após o OOMKilled:

```bash
scripts/fault.sh inventory state      # reservations_total volta a 0, estoque volta ao inicial
```

Pedidos já `CONFIRMED` no DynamoDB continuam lá, mas a Inventory "esqueceu" as reservas. Essa é a
**limitação documentada do MVP** (sem durabilidade das reservas após restart) — não um bug escondido.

> **💡 O que você deveria ter notado (A.3)**
>
> - Em ~10 s o `RESTARTS` subiu; `lastState.terminated.reason` = **`OOMKilled`** (exit **137**).
> - O container voltou com o ballast em 0 (falhas padrão), então não entrou em loop.
> - `fault.sh inventory state`: `reservations_total` voltou a 0 e o estoque ao inicial — o estado em memória se perdeu.
>
> **Lição:** estourar o limit de **memória** mata o container (kernel), e o que estava só em memória vai junto.

#### A.4 BestEffort + vizinho barulhento (contenção)

```bash
labs/lab-05/qos.sh besteffort
kubectl apply -f kubernetes/labs/qos/noisy-neighbor.yaml        # 2x `yes` no MESMO nó da Inventory (podAffinity), auto-encerra em 10 min
kubectl -n loadtest get pod noisy-neighbor -o wide
scripts/k6.sh create-orders.js RATE=5 DURATION=2m
kubectl top pods -A --sort-by=cpu | head
```

Sem requests, a Inventory recebe o **peso mínimo de CPU** (`cpu.weight` mínimo para BestEffort) e disputa CPU
com o vizinho em desvantagem. Observe a latência p95 e os spans de `inventory-api` no HyperDX. Depois:

```bash
kubectl -n loadtest delete pod noisy-neighbor
```

> **💡 O que você deveria ter notado (A.4)**
>
> - Sem requests, a Inventory (`BestEffort`) disputou CPU com o vizinho em desvantagem: latência p95 maior e spans de
>   `inventory-api` mais lentos.
> - Nenhum restart: contenção de CPU degrada, não derruba.
>
> **Lição:** `BestEffort` não tem nenhuma garantia de CPU — é o primeiro a sofrer num nó disputado.

**Resumo da Parte A**

| Cenário | Ação | Comportamento esperado | Como verificar |
|---|---|---|---|
| CPU acima do limit | `qos.sh burstable` + `fault.sh inventory cpu-burn 2` | Throttling em quase todo período; Pod **não** reinicia; p95 dos pedidos sobe | `labs/lab-05/cpu-stat.sh` (`nr_throttled` ≈ `nr_periods`); `container.cpu.throttled_time` no HyperDX; `RESTARTS` igual |
| Memória acima do limit | `qos.sh burstable` + `fault.sh inventory memory 700` | `OOMKilled` em ~10 s; container reinicia sem a falha; estoque e reservas voltam ao inicial | `lastState.terminated.reason` = `OOMKilled`; `RESTARTS +1`; `fault.sh inventory state` (`reservations_total` = 0) |
| BestEffort + vizinho barulhento | `qos.sh besteffort` + `noisy-neighbor.yaml` | Inventory disputa CPU com peso mínimo; latência maior, sem restart | `kubectl top pods -A --sort-by=cpu`; p95 do k6; spans `inventory-api` |

### Parte B — PriorityClass & Preemption (sequência determinística)

```bash
# B.1 — ponto de partida limpo
scripts/reset.sh

# B.2 — Inventory Guaranteed (500m). A vítima precisa liberar >= 250m (request de 1 Pod da Orders);
#        com o perfil Burstable (100m) + 100m de folga, a preempção NÃO resolveria e o scheduler não preemptaria.
labs/lab-05/qos.sh guaranteed

# B.3 — impedir que o Cluster Autoscaler adicione nós ANTES de observarmos a preempção
kubectl -n kube-system scale deploy -l app.kubernetes.io/name=aws-cluster-autoscaler --replicas=0

# B.4 — ANTI-PATTERN INTENCIONAL: dependência transacional com prioridade baixa
kubectl -n ecommerce patch deploy inventory-api --patch-file kubernetes/labs/priority/inventory-low-priority.patch.yaml
kubectl -n ecommerce rollout status deploy/inventory-api

# B.5 — ocupar a CPU livre dos nós apps com ballasts de prioridade critical-services (deixa 100m livres por nó)
python3 labs/lab-05/fill-capacity.py --slack 100
kubectl -n loadtest get pods -l app.kubernetes.io/name=capacity-ballast -o wide

# B.6 — remover o HPA (senão ele "desfaz" o scale manual) e escalar a Orders API em +2 réplicas
kubectl -n ecommerce delete hpa orders-api
CURRENT=$(kubectl -n ecommerce get deploy orders-api -o jsonpath='{.spec.replicas}')
kubectl -n ecommerce scale deploy orders-api --replicas=$((CURRENT + 2))
```

Em paralelo (T3), gere pedidos durante todo o experimento:

```bash
scripts/k6.sh create-orders.js RATE=5 DURATION=4m
```

E observe (T2):

```bash
kubectl get events -n ecommerce --sort-by=.lastTimestamp -w | grep -E "Preempted|FailedScheduling|Scheduled"
# outro terminal:
kubectl -n ecommerce get pods -o wide -w
labs/lab-05/watch-cb.sh        # estado do Circuit Breaker por réplica da Orders
```

Sequência esperada da Parte B (2 nós `apps`, CA desligado, ballasts deixando 100m livres por nó):

```mermaid
sequenceDiagram
    autonumber
    participant U as kubectl scale (+2)
    participant S as kube-scheduler
    participant NA as Nó A (Inventory low-priority, Guaranteed 500m)
    participant NB as Nó B (só ballasts critical-services)
    participant O as Orders API
    U->>S: 2 novos Pods orders-api (critical-services 1000, request 250m)
    S-->>S: Pending — "Insufficient cpu" (100m livres por nó)
    S->>NA: Preemption: remove a Inventory (prioridade 100 < 1000)
    NA-->>S: libera 500m → Orders #3 agendada no nó A
    S-->>S: Inventory recriada pelo ReplicaSet fica Pending (não pode preemptar ninguém)
    S-->>S: Orders #4 Pending — nó A violaria maxSkew 1, nó B sem vítimas
    O->>O: pré-consulta/reserva sem endpoints → retries → Circuit Breaker OPEN
    O-->>U: POST /orders → 503 DEPENDENCY_UNAVAILABLE (reason=circuit_open)
```

| Cenário | Ação | Comportamento esperado | Como verificar |
|---|---|---|---|
| Dependência com prioridade baixa | B.2 + B.4 (Guaranteed 500m + `low-priority-services`) | Inventory `Running`, `PRIORITY` 100, `QOS` Guaranteed | `kubectl -n ecommerce get pods -o custom-columns=POD:.metadata.name,QOS:.status.qosClass,PRIORITY:.spec.priorityClassName` |
| Cluster sem folga | B.3 (CA = 0) + B.5 (`fill-capacity.py --slack 100`) | Ballasts `Running` nos 2 nós `apps`; ~100m livres por nó | `kubectl -n loadtest get pods -l app.kubernetes.io/name=capacity-ballast -o wide` |
| Orders +2 réplicas | B.6 | Evento `Preempted` na Inventory; uma Orders nova agendada no nó dela | `kubectl get events -n ecommerce --field-selector reason=Preempted` |
| Vítima não reagenda | — | Inventory nova `Pending` (`Insufficient cpu`; nenhuma vítima de prioridade menor) | `kubectl -n ecommerce get pods -l app.kubernetes.io/name=inventory-api` |
| Spread impede empilhar | — | 4ª Orders `Pending`: *"didn't match pod topology spread constraints … Preemption is not helpful"* | `kubectl -n ecommerce describe pod <orders Pending>` |
| Impacto no negócio | k6 em T3 | `POST /orders` `201` → ~0%; `503 DEPENDENCY_UNAVAILABLE`; CB `OPEN` em cada réplica | saída do k6; `labs/lab-05/watch-cb.sh`; `circuit_breaker.state` = 2 no HyperDX |

> **💡 O que você deveria ter notado (Parte B)**
>
> - Evento **`Preempted`** na Inventory (*"Preempted by pod … on node …"*): uma Orders nova ocupou o lugar dela.
> - A Inventory recriada ficou **`Pending`** (`Insufficient cpu`) e não pôde preemptar ninguém: todo o resto é
>   `critical-services` ou `system-*`.
> - A outra Orders nova também ficou `Pending`, pelo topology spread (*"didn't match pod topology spread constraints"*).
> - Sem Inventory, o Circuit Breaker abriu (**`OPEN`**) em cada réplica e os pedidos viraram
>   `503 DEPENDENCY_UNAVAILABLE`: `POST /orders 201` caiu para ~0% (na validação do workshop, 82% das requisições
>   falharam até a correção).
> - O Pod da Inventory era **`Guaranteed`** e mesmo assim foi removido.
>
> **Lição:** QoS protege contra pressão **no nó**; contra falta de capacidade **no scheduler**, quem decide é a
> PriorityClass — e uma dependência transacional com prioridade baixa derruba todos os pedidos.

## 6. Falha provocada

- **Parte A:** CPU throttling (`cpu-burn 2` contra limit 500m), OOMKilled (`memory 700` contra limit 512Mi),
  contenção de CPU (BestEffort + `noisy-neighbor`).
- **Parte B:** falta de capacidade de scheduling para Pods `critical-services` com a dependência transacional
  configurada como `low-priority-services` e o Cluster Autoscaler desligado.

## 7. Observações

**Parte A**

| Experimento | Onde observar | O que esperar |
|---|---|---|
| Throttling | `cpu-stat.sh`, métrica `container.cpu.throttled_time` | `nr_throttled` crescendo quase 1:1 com `nr_periods`; Pod **não** reinicia; latência sobe |
| OOMKilled | `lastState.terminated.reason`, evento `BackOff`/restart, `k8s.container.restarts` | Container morto pelo kernel, `RESTARTS+1`, estado em memória perdido |
| Contenção BestEffort | `kubectl top`, p95 k6, spans `inventory-api` | Latência maior; nenhuma garantia de CPU |

**Parte B** — linha do tempo típica:

1. Novos Pods `orders-api` ficam `Pending` (`FailedScheduling: Insufficient cpu`).
2. O scheduler identifica a Inventory (prioridade 100) como vítima no nó onde ela roda: evento
   `Preempted` — *"Preempted by pod … on node …"*. O Pod da Orders é agendado nesse nó (`nominatedNodeName`).
3. A Inventory é recriada pelo ReplicaSet e fica `Pending`: não há espaço e ela **não pode** preemptar ninguém
   (todos os demais são `critical-services` ou `system-*`).
4. O outro novo Pod da Orders continua `Pending`. O topology spread da Orders (`maxSkew: 1` por nó, LAB 04) exige
   que ele vá para o **outro** nó, que está cheio de ballasts `critical-services` (sem vítimas):
   *"0/3 nodes are available: 1 Insufficient cpu, 1 node(s) didn't match pod topology spread constraints … preemption:
   … Preemption is not helpful for scheduling"*.
5. Os pedidos começam a falhar: a pré-consulta/reserva da Inventory falha (sem endpoints → erro de transporte) →
   retries → **Circuit Breaker OPEN** em cada réplica → `503 DEPENDENCY_UNAVAILABLE` com `reason=circuit_open`.
   O k6 mostra `POST /orders 201` caindo para ~0%.

No HyperDX:

- **Logs** (source Logs): eventos Kubernetes coletados pelo gateway (`k8sobjects`) — busque `Preempted` e
  `FailedScheduling`;
- **Logs**: `ServiceName:"orders-api" Body:"Circuit breaker transition"` e `Body:"Inventory API indisponível"`;
- **Metrics**: `k8s.pod.phase` (Pending = 1), `circuit_breaker.state` (2 = OPEN), `orders.failed` por `reason`.

## 8. Explicação técnica

**QoSClass** é derivada automaticamente dos `resources`:

| QoS | Regra | `oom_score_adj` | Eviction por pressão do nó |
|---|---|---|---|
| BestEffort | nenhum request/limit | 1000 (primeiro a morrer) | primeiro candidato |
| Burstable | algum request, não todos iguais aos limits | 2–999 (proporcional) | quem usa acima do request primeiro |
| Guaranteed | requests == limits para CPU e memória em todos os containers | -997 | último candidato |

Três mecanismos **diferentes**:

- **CPU throttling** — o CFS aplica a cota `cpu.max` (limit). O processo é *pausado* até o próximo período;
  nada é morto. CPU é um recurso **comprimível**.
- **OOMKilled** — o uso de memória do cgroup do container atinge `memory.max` (limit) e o **kernel** mata o
  processo. Acontece mesmo com o nó folgado. Memória é **incompressível**.
- **Eviction** — o **kubelet** detecta pressão no **nó** (ex.: `memory.available` abaixo do threshold) e remove Pods
  inteiros, ordenando por uso acima do request, prioridade e QoS. Pode acontecer sem nenhum limit atingido.

**PriorityClass** age no **scheduler**: quando um Pod não cabe, o scheduler procura nós onde remover Pods de
prioridade **estritamente menor** libere recursos suficientes (preemption). QoS não entra nessa conta — por isso
um Pod `Guaranteed` de prioridade 100 foi removido. Prioridade **igual** nunca preempta (por isso os ballasts
`critical-services` e as outras réplicas da Orders ficaram intocados).

O perfil Guaranteed (500m) foi necessário para a preempção acontecer: a vítima precisa liberar recursos
suficientes para o Pod pendente (250m da Orders). Com 100m livres + 100m da Inventory Burstable = 200m < 250m,
o scheduler não teria vítima válida.

| Pergunta | Quem responde |
|---|---|
| Quem sofre primeiro quando o **nó** está sem CPU/memória? | QoS (requests/limits) |
| Quem é **agendado** primeiro / quem é **removido** quando falta capacidade de scheduling? | PriorityClass |

O anti-pattern: a prioridade deve refletir a **criticidade do fluxo de negócio**, não a "importância percebida"
do serviço. Uma dependência síncrona do caminho crítico tem, no mínimo, a mesma prioridade de quem a chama.

### Os mecanismos nos diagramas da documentação do Kubernetes

Cada mecanismo do lab, ilustrado com os exemplos de [kubernetes.io](https://kubernetes.io/docs/)
(conteúdo sob [CC BY 4.0](https://github.com/kubernetes/website/blob/main/LICENSE)). As páginas de QoS, recursos,
node-pressure eviction e priority/preemption explicam só com texto e tabelas — **nenhuma tem diagrama**. Todos os
diagramas abaixo são **adaptados**: desenham o texto oficial da página citada, no estilo visual dos diagramas da doc.

**1. Como a QoS é atribuída — parte A** (adaptado de
[Pod Quality of Service Classes › Criteria](https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/#quality-of-service-classes)).
A classe sai só dos `resources` dos containers, é calculada na criação do Pod e não muda depois:

```mermaid
graph TB
    S(Pod criado) --> G{"todo container tem request = limit<br/>> 0 para CPU e memória?"}
    G -- "sim" --> QG(Guaranteed)
    G -- "não" --> B{"algum container tem algum<br/>request ou limit de CPU/memória?"}
    B -- "sim" --> QB(Burstable)
    B -- "não" --> QE(BestEffort)

    classDef plain fill:#ddd,stroke:#fff,stroke-width:4px,color:#000;
    classDef k8s fill:#326ce5,stroke:#fff,stroke-width:4px,color:#fff;
    class S,G,B plain;
    class QG,QB,QE k8s;
```

O `labs/lab-05/qos.sh` troca entre os três perfis justamente mexendo nesses campos.

**2. Limit de CPU × limit de memória — parte A** (adaptado de
[Resource Management › How Kubernetes applies resource requests and limits](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/#how-pods-with-resource-limits-are-run)).
O kubelet passa requests e limits para o runtime, que os aplica como cgroups. Os dois limits geram efeitos opostos:

```mermaid
graph LR
    subgraph CPU["CPU — comprimível"]
        c1("limit = teto de tempo de CPU<br/>por período") --> c2("acima do limit:<br/>o kernel pausa o cgroup")
        c2 --> c3("throttling: lento,<br/>nunca morto")
        c4("request = peso<br/>na disputa por CPU")
    end
    subgraph MEM["memória — incompressível"]
        m1("limit = teto do cgroup") --> m2("alocou acima do limit:<br/>OOM killer do kernel")
        m2 --> m3("OOMKilled: o container<br/>reinicia (restartPolicy)")
        m4("request = usado no agendamento<br/>e na ordem de eviction")
    end

    classDef plain fill:#ddd,stroke:#fff,stroke-width:4px,color:#000;
    classDef k8s fill:#326ce5,stroke:#fff,stroke-width:4px,color:#fff;
    classDef cluster fill:#fff,stroke:#bbb,stroke-width:2px,color:#326ce5;
    class c1,c2,c4,m1,m2,m4 k8s;
    class c3,m3 plain;
    class CPU,MEM cluster;
```

É o `cpu-burn` (throttling, `nr_throttled` subindo, Pod vivo) contra o `memory 700` (OOMKilled, estoque zerado) do lab.
A doc é explícita: *"container runtimes don't terminate Pods or containers for excessive CPU usage"*.

**3. Quem sai primeiro quando o nó fica sem memória — parte A** (adaptado de
[Node-pressure Eviction › Pod selection for kubelet eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/#pod-selection-for-kubelet-eviction)
e [Node out of memory behavior](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/#node-out-of-memory-behavior)).
Há dois caminhos, conforme quem age primeiro — o kubelet (eviction do Pod inteiro) ou o kernel (OOM kill de um
container):

```mermaid
graph TB
    P(nó sem memória) --> K{"o kubelet percebe a<br/>pressão a tempo?"}
    K -- "sim: eviction" --> E1("1º — BestEffort/Burstable com uso acima do request<br/>ordenados por Priority, depois pelo excesso sobre o request")
    E1 --> E2("2º — Guaranteed e Burstable abaixo do request<br/>ordenados por Priority")
    K -- "não: OOM do nó" --> O("oom_killer: oom_score = % de memória usada + oom_score_adj<br/>BestEffort 1000 · Burstable 2–999 · Guaranteed −997")
    O --> O2("morre o container com maior score;<br/>o kubelet pode reiniciá-lo")

    classDef plain fill:#ddd,stroke:#fff,stroke-width:4px,color:#000;
    classDef k8s fill:#326ce5,stroke:#fff,stroke-width:4px,color:#fff;
    class P,K plain;
    class E1,E2,O,O2 k8s;
```

A doc destaca que o kubelet **não** usa a classe de QoS diretamente na ordem de eviction (usa uso × request e
Priority); a QoS só **estima** a ordem provável. A node-pressure eviction também **não respeita PDB** — o mesmo
"despejo sem PDB" do taint `NoExecute` no LAB 04.

**4. Preemption — parte B** (adaptado de
[Pod Priority and Preemption › Preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/#preemption)
e [User exposed information](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/#user-exposed-information)).
O Pod P não cabe em nenhum nó; o scheduler procura um nó N onde remover Pods de prioridade **menor** que a de P
libere espaço suficiente:

```mermaid
sequenceDiagram
    participant P as Pod P (Pending, alta prioridade)
    participant S as Scheduler
    participant N as Nó N
    participant V as Vítima (prioridade menor)
    S->>S: filtro: nenhum nó comporta P
    S->>S: preemption: em qual nó, removendo Pods de prioridade menor, P cabe?
    S->>P: status.nominatedNodeName = N
    S->>V: despejo (com graceful termination)
    V-->>N: recursos liberados
    S->>N: P agendado (se outro nó não ficou livre antes)
```

No lab, P é a réplica nova da Orders (`critical-services`) e a vítima é a Inventory (`low-priority-services`). Os
detalhes da doc batem com o que você viu: `nominatedNodeName` aparece no Pod pendente; a vítima recebe graceful
termination; e se a remoção de vítimas não liberar recursos suficientes, **não há preemption** — o motivo do perfil
Guaranteed de 500m na B.2.

**5. Priority × QoS: dois eixos independentes — partes A e B** (adaptado de
[Interactions between Pod priority and quality of service](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/#interactions-of-pod-priority-and-qos)).
*"Pod priority and QoS class are two orthogonal features"*:

```mermaid
graph LR
    subgraph SCH["kube-scheduler — falta de capacidade de agendamento"]
        s1("preemption") --> s2("considera só a Priority<br/>(a QoS não entra)")
    end
    subgraph KUB["kubelet — pressão no nó"]
        k1("node-pressure eviction") --> k2("uso acima do request,<br/>depois Priority")
    end
    subgraph KER["kernel — OOM"]
        o1("oom_killer") --> o2("oom_score_adj<br/>derivado da QoS")
    end

    classDef k8s fill:#326ce5,stroke:#fff,stroke-width:4px,color:#fff;
    classDef plain fill:#ddd,stroke:#fff,stroke-width:4px,color:#000;
    classDef cluster fill:#fff,stroke:#bbb,stroke-width:2px,color:#326ce5;
    class s1,k1,o1 k8s;
    class s2,k2,o2 plain;
    class SCH,KUB,KER cluster;
```

Por isso a Inventory **Guaranteed** foi preemptada na parte B: Guaranteed protege contra eviction e OOM, mas não contra
a preemption de um Pod de prioridade maior.

## 9. Correção

```bash
# 1. Dependência transacional com a mesma prioridade do caminho crítico
kubectl -n ecommerce patch deploy inventory-api --patch-file kubernetes/labs/priority/inventory-restore-priority.patch.yaml

# 2. Capacidade: reativar o Cluster Autoscaler
kubectl -n kube-system scale deploy -l app.kubernetes.io/name=aws-cluster-autoscaler --replicas=1
```

O novo Pod da Inventory (prioridade 1000) **não** consegue preemptar ninguém (todos têm prioridade igual ou
maior) — ele fica `Pending` e isso dispara o **Cluster Autoscaler**, que adiciona um nó `apps` (2–4 min).
A Inventory é agendada, o Circuit Breaker passa por `HALF_OPEN` → `CLOSED`, e os pedidos voltam a `201`.

```bash
kubectl -n kube-system logs deploy/cluster-autoscaler-aws-cluster-autoscaler --since=10m | grep -iE "scale-up|ScaleUp"
kubectl get nodes -l workload=apps -w
```

Correção de QoS (Parte A): manter a Inventory **Burstable** com requests realistas (ou Guaranteed se a latência
for crítica), limit de memória dimensionado pelo uso real + margem, e **não** depender de estado em memória em
produção (fase 2: estado compartilhado/durável).

## 10. Validação

| Cenário | Ação | Comportamento esperado | Como verificar |
|---|---|---|---|
| Prioridade corrigida | patch `inventory-restore-priority` (seção 9) | Inventory nova com prioridade 1000 fica `Pending` (não preempta prioridade igual) | `kubectl -n ecommerce get pod -l app.kubernetes.io/name=inventory-api -o wide` |
| Capacidade restaurada | CA = 1 (seção 9) | CA adiciona um nó `apps` em 2–4 min; Inventory `Running` | `kubectl get nodes -l workload=apps -w`; logs do CA (`scale-up`) |
| Recuperação do fluxo | — | CB `HALF_OPEN` → `CLOSED` em todas as réplicas; pedidos voltam a `201` | `scripts/fault.sh orders cb`; k6 com `http_req_failed < 5%` |
| Evidência da preempção | — | Evento `Preempted` da Inventory registrado | `kubectl get events -n ecommerce --field-selector reason=Preempted` |

```mermaid
flowchart LR
    F1["Inventory → critical-services (1000)"] --> F2["Pod novo Pending<br/>(não preempta prioridade igual)"]
    F2 --> F3["Cluster Autoscaler (replicas=1)<br/>cria nó apps em 2–4 min"]
    F3 --> F4["Inventory Running"] --> F5["CB HALF_OPEN → CLOSED"] --> F6["POST /orders 201"]
```

```bash
kubectl -n ecommerce get pod -l app.kubernetes.io/name=inventory-api \
  -o custom-columns=POD:.metadata.name,STATUS:.status.phase,QOS:.status.qosClass,PRIORITY:.spec.priority
# STATUS=Running  PRIORITY=1000
kubectl get events -n ecommerce --field-selector reason=Preempted
scripts/fault.sh orders cb             # todas as réplicas: "state": "CLOSED"
scripts/k6.sh create-orders.js RATE=5 DURATION=1m   # thresholds OK (http_req_failed < 5%)
```

## 11. Challenge

1. **Eviction controlada (opcional):** com `labs/lab-05/qos.sh besteffort`, eleve a pressão de memória no nó:
   `scripts/fault.sh inventory memory 2048` (teto `INVENTORY_MEMORY_STRESS_MAX_MB=2048` — a carga é limitada por
   design). Repita junto com `kubectl apply -f kubernetes/labs/qos/noisy-neighbor.yaml`. Observe `kubectl describe node`
   (condição `MemoryPressure`) e os eventos `Evicted`. Discuta: em nós com pouca memória livre, o **OOM killer do
   kernel** pode agir antes da eviction do kubelet (que avalia a cada ~10 s); como o `oom_score_adj` do BestEffort é
   1000, ele morre primeiro de qualquer forma. Com 2048 MiB num `m6i.large` a eviction pode **não** ocorrer — explique
   por quê (allocatable × uso real × threshold `memory.available`).
2. Por que o HPA precisou ser removido na Parte B? O que aconteceria com `minReplicas` maior que a capacidade?
3. Qual seria o efeito de `preemptionPolicy: Never` na `critical-services`?
4. Proponha um `PodDisruptionBudget` para a Inventory (fase 2). Ele impediria a preempção? (Dica: PDB é
   respeitado em *best effort* pelo scheduler na preempção.)

## 12. Critérios de sucesso

- [ ] Os três perfis produziram `BestEffort`, `Burstable` e `Guaranteed` em `.status.qosClass`.
- [ ] `nr_throttled` cresceu com `cpu-burn 2` e o Pod **não** reiniciou.
- [ ] `lastState.terminated.reason = OOMKilled` com `memory 700` e o estado em memória foi perdido.
- [ ] Evento `Preempted` para a Inventory API registrado, com a Orders agendada no lugar.
- [ ] Pedidos falharam com `503 DEPENDENCY_UNAVAILABLE` e Circuit Breaker `OPEN` durante a preempção.
- [ ] Após a correção: Inventory `Running` com prioridade 1000, CB `CLOSED`, pedidos `201`.
- [ ] O aluno explica a diferença entre throttling, OOMKilled, eviction e preemption.

## 13. Reset

```bash
kubectl -n loadtest delete pod -l app.kubernetes.io/name=capacity-ballast --ignore-not-found
kubectl -n loadtest delete pod noisy-neighbor --ignore-not-found
scripts/reset.sh        # perfil Burstable, Inventory de volta a critical-services, reaplica HPA, CA=1, limpa falhas
kubectl -n ecommerce get pods -o custom-columns=POD:.metadata.name,QOS:.status.qosClass,PRIORITY:.spec.priorityClassName
```

Nós extras criados pelo Cluster Autoscaler são removidos automaticamente após ~2 min ociosos
(`scale-down-unneeded-time=2m`).
