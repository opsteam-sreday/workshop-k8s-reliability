# LAB 03 — RollingUpdate & PodDisruptionBudget

> ⚠ Rascunho: comportamentos ainda não validados em cluster.

> **Break it → Observe it → Understand it → Fix it → Validate it**
>
> Duração estimada: 40 min

---

## 1. Cenário

O LAB 02 mostrou que cada **réplica** sabe sair do tráfego e encerrar sem erro (readiness, `SIGTERM`, espera de
5 s). Este lab sobe um nível: **quantas réplicas podem estar fora ao mesmo tempo** quando o próprio time mexe no
cluster. Duas configurações decidem isso, cada uma para um tipo de mudança:

| Mudança | Quem decide quantas réplicas saem | Configuração no repo |
|---|---|---|
| **Rollout** (nova versão, `rollout restart`, mudança no template) | o **Deployment controller** | `strategy` — BFF e Orders: `RollingUpdate` com `maxSurge: 1, maxUnavailable: 0`; Inventory: `Recreate` |
| **Evicção voluntária** (`kubectl drain`, upgrade de nó, consolidação do Cluster Autoscaler) | a **Eviction API**, consultando a **PodDisruptionBudget** | `kubernetes/apps/*/pdb.yaml` — `maxUnavailable: 1` nas três APIs |

```mermaid
flowchart LR
    subgraph rollout["Rollout (Deployment controller)"]
        R1["kubectl rollout restart / nova imagem"] --> R2["strategy: maxSurge / maxUnavailable"]
        R2 --> R3["cria Pods novos e encerra antigos<br/>no ritmo da estratégia"]
    end
    subgraph evict["Evicção voluntária (Eviction API)"]
        E1["kubectl drain / upgrade de nó / CA scale-down"] --> E2{"PDB permite?<br/>ALLOWED DISRUPTIONS > 0"}
        E2 -- sim --> E3["Pod removido; ReplicaSet recria em outro nó"]
        E2 -- não --> E4["429: drain retenta a cada 5 s"]
    end
    X1["kubectl delete pod / falha de nó / OOMKilled"] -.->|"não consulta nem estratégia nem PDB"| X2["Pod some na hora"]
```

## 2. Hipótese

1. Com `maxSurge: 1, maxUnavailable: 0`, um rollout sob carga **não gera erros**: um Pod novo só substitui um antigo
   depois de ficar pronto.
2. Com `maxSurge: 0, maxUnavailable: 100%`, o rollout derruba **todas** as réplicas de uma vez e abre uma janela sem
   nenhum endpoint pronto: a BFF responde `503 DEPENDENCY_UNAVAILABLE`.
3. `Recreate` na Inventory (réplica única) sempre tem uma janela de indisponibilidade em cada rollout.
4. Uma PDB com `maxUnavailable: 0` **bloqueia** o `kubectl drain`; com `maxUnavailable: 1`, o drain prossegue um Pod
   por vez.
5. A PDB **não** protege contra `kubectl delete pod`, contra rollouts nem contra falha de nó, e com **1 réplica** ela
   não protege nada.

## 3. Pré-requisitos

- LAB 02 concluído (probes e graceful shutdown); `scripts/reset.sh` executado.
- `export CLUSTER_ID=<seu id>` e kubectl apontando para o seu cluster.
- **3 terminais** na raiz do repositório, todos com o mesmo `CLUSTER_ID`.

## 4. Estado inicial

```bash
kubectl -n ecommerce get deploy -o custom-columns='NAME:.metadata.name,REPLICAS:.spec.replicas,STRATEGY:.spec.strategy.type,SURGE:.spec.strategy.rollingUpdate.maxSurge,UNAVAIL:.spec.strategy.rollingUpdate.maxUnavailable'
kubectl -n ecommerce get pdb
kubectl -n ecommerce get pods -o wide --sort-by=.spec.nodeName
```

Esperado:

| Deployment | Réplicas | Estratégia | maxSurge | maxUnavailable |
|---|---|---|---|---|
| bff-api | 2 | RollingUpdate | 1 | 0 |
| orders-api | 2 (HPA 2–12) | RollingUpdate | 1 | 0 |
| inventory-api | 1 | Recreate | — | — |

| PDB | MAX UNAVAILABLE | ALLOWED DISRUPTIONS |
|---|---|---|
| bff-api | 1 | 1 |
| orders-api | 1 | 1 |
| inventory-api | 1 | 1 (com 1 réplica: a única pode sair) |

## 5. Comandos executáveis

Deixe rodando durante todo o lab:

```bash
# Terminal 1 — Pods e em que nó estão
kubectl -n ecommerce get pods -w -o 'custom-columns=POD:.metadata.name,STATUS:.status.phase,READY:.status.containerStatuses[0].ready,NODE:.spec.nodeName'

# Terminal 2 — carga contínua com retry do cliente (mesma Idempotency-Key)
scripts/k6.sh create-orders.js RATE=10 DURATION=30m
```

O terminal 3 é onde você provoca as mudanças. Marque o início de cada janela para contar as respostas da BFF só
daquele trecho:

```bash
export T0=$(date -u +%FT%TZ)
# ... mudança ...
labs/lab-02/count-responses.sh "$T0"
```

| Parte | Cenário | Ação | Comportamento esperado | Como verificar |
|---|---|---|---|---|
| A | Rollout seguro (1/0) | `kubectl rollout restart deploy/orders-api` | Pod novo sobe e fica pronto antes de um antigo sair; 0 erros | terminal 1; `count-responses.sh` só com `201` |
| B | Rollout agressivo (0/100%) | patch `orders-aggressive-rollout` + `rollout restart` | as 2 réplicas saem juntas; janela sem endpoints; `503` na BFF | terminal 1 (0 Pods prontos); `count-responses.sh` com `503` |
| C | `Recreate` na Inventory | `kubectl rollout restart deploy/inventory-api` | o Pod antigo encerra **antes** de o novo existir; `503 DEPENDENCY_UNAVAILABLE` na janela | terminal 1; `count-responses.sh`; `scripts/fault.sh orders cb` |
| D | PDB bloqueando drain | patch `orders-pdb-zero` + `kubectl drain` | drain retenta `Cannot evict pod as it would violate the pod's disruption budget` | saída do drain; `kubectl get pdb` (ALLOWED 0) |
| D | PDB liberando drain | patch `orders-pdb-restore` + drain de novo | drain conclui, um Pod da Orders por vez | saída do drain; terminal 1 |
| E | O que a PDB não cobre | `kubectl delete pod` e `rollout restart` com a PDB em 0; drain do nó da Inventory | o delete e o rollout ignoram a PDB; o drain remove a única Inventory | terminal 1; `count-responses.sh` com `503` no drain da Inventory |

## 6. Falha provocada

Execute as partes **na ordem** (A → E), no terminal 3.

### Parte A — RollingUpdate seguro (`maxSurge: 1, maxUnavailable: 0`)

```bash
export T0=$(date -u +%FT%TZ)
kubectl -n ecommerce rollout restart deploy/orders-api
kubectl -n ecommerce rollout status deploy/orders-api
sleep 15; labs/lab-02/count-responses.sh "$T0"
```

```mermaid
sequenceDiagram
    autonumber
    participant D as Deployment controller
    participant N as ReplicaSet novo
    participant O as ReplicaSet antigo
    participant S as EndpointSlice da orders-api
    Note over O,S: 2 réplicas antigas prontas
    D->>N: cria 1 Pod (maxSurge 1 = até 3 Pods no total)
    N-->>S: Pod novo pronto (startup + readiness) entra nos endpoints
    D->>O: encerra 1 Pod antigo (maxUnavailable 0 = nunca menos de 2 prontos)
    O-->>S: SIGTERM, readiness 503, sai dos endpoints (LAB 02, parte B)
    D->>N: cria o 2º Pod
    N-->>S: 2º Pod novo pronto
    D->>O: encerra o último antigo
    Note over N,S: sempre houve pelo menos 2 réplicas prontas
```

### Parte B — RollingUpdate agressivo (`maxSurge: 0, maxUnavailable: 100%`)

A estratégia não faz parte do template dos Pods: trocá-la não reinicia nada. O `rollout restart` dispara a troca.

```bash
kubectl -n ecommerce patch deploy orders-api --patch-file kubernetes/labs/rollout/orders-aggressive-rollout.patch.yaml
export T0=$(date -u +%FT%TZ)
kubectl -n ecommerce rollout restart deploy/orders-api
kubectl -n ecommerce rollout status deploy/orders-api
sleep 15; labs/lab-02/count-responses.sh "$T0"

# volta para a estratégia do manifest
kubectl -n ecommerce patch deploy orders-api --patch-file kubernetes/labs/rollout/orders-safe-rollout.patch.yaml
```

```mermaid
sequenceDiagram
    autonumber
    participant D as Deployment controller
    participant O as 2 Pods antigos
    participant N as 2 Pods novos
    participant B as BFF
    D->>O: encerra os 2 de uma vez (maxUnavailable 100%)
    O-->>O: readiness 503, saem dos endpoints
    D->>N: cria os 2 novos (maxSurge 0: só depois dos antigos saírem)
    Note over N: startup: warm-up do DynamoDB (GetItem) antes de ficar pronto
    B->>B: POST /orders sem endpoint pronto na orders-api
    B-->>B: erro de transporte vira 503 DEPENDENCY_UNAVAILABLE + Retry-After 1
    N-->>B: Pods novos prontos: pedidos voltam a 201
```

### Parte C — `Recreate` na Inventory

```bash
export T0=$(date -u +%FT%TZ)
kubectl -n ecommerce rollout restart deploy/inventory-api
kubectl -n ecommerce rollout status deploy/inventory-api
scripts/fault.sh orders cb                # o Circuit Breaker pode ter aberto na janela
sleep 20; labs/lab-02/count-responses.sh "$T0"
scripts/fault.sh inventory reset-stock    # estoque em memória: o Pod novo começa do catálogo inicial
```

```mermaid
flowchart LR
    A["rollout restart<br/>inventory-api"] --> B["Recreate: encerra o único Pod<br/>(SIGTERM, 5 s, drenagem)"]
    B --> C["0 réplicas: Service sem endpoints"]
    C --> D["Orders: GET /inventory/{sku} e reserva falham<br/>(retry, Circuit Breaker)"]
    D --> E["BFF: 503 DEPENDENCY_UNAVAILABLE"]
    C --> F["Pod novo criado só agora"]
    F --> G["pronto: estoque reiniciado<br/>(estado em memória perdido)"]
    G --> H["pedidos voltam a 201<br/>(CB: HALF_OPEN -> CLOSED)"]
```

### Parte D — PDB bloqueando um drain

Desligue o Cluster Autoscaler (ele criaria um nó novo para os Pods despejados — veja o LAB 04, parte E2) e escolha
como **nó A** um nó `apps` **sem** a Inventory:

```bash
kubectl -n kube-system scale deploy -l app.kubernetes.io/name=aws-cluster-autoscaler --replicas=0
INV_NODE=$(kubectl -n ecommerce get pod -l app.kubernetes.io/name=inventory-api -o jsonpath='{.items[0].spec.nodeName}')
export NODE_A=$(kubectl get nodes -l workload=apps -o name | sed 's#node/##' | grep -v "$INV_NODE" | head -1)
echo "A=$NODE_A"
kubectl -n ecommerce get pods -l app.kubernetes.io/name=orders-api -o wide    # confirme que há uma Orders no nó A
```

Zere o orçamento da Orders e tente drenar o nó A (o `--timeout` evita que o drain fique preso para sempre):

```bash
kubectl -n ecommerce patch pdb orders-api --type merge --patch-file kubernetes/labs/rollout/orders-pdb-zero.patch.yaml
kubectl -n ecommerce get pdb orders-api                       # ALLOWED DISRUPTIONS 0
kubectl drain $NODE_A --ignore-daemonsets --delete-emptydir-data --timeout=60s
```

Restaure o orçamento e drene de novo:

```bash
kubectl -n ecommerce patch pdb orders-api --type merge --patch-file kubernetes/labs/rollout/orders-pdb-restore.patch.yaml
export T0=$(date -u +%FT%TZ)
kubectl drain $NODE_A --ignore-daemonsets --delete-emptydir-data --timeout=3m
sleep 30; labs/lab-02/count-responses.sh "$T0"
kubectl uncordon $NODE_A
kubectl -n ecommerce rollout restart deploy/orders-api deploy/bff-api    # redistribui (LAB 04, parte E3)
```

```mermaid
flowchart TD
    A["kubectl drain nó A<br/>(cordon + evicção de cada Pod)"] --> B{"PDB do Pod<br/>ALLOWED DISRUPTIONS"}
    B -- "0 (maxUnavailable 0)" --> C["Eviction API responde 429"]
    C --> D["drain: Cannot evict pod as it would violate<br/>the pod's disruption budget (retenta a cada 5 s)"]
    D --> E["--timeout esgota: drain falha<br/>o nó fica cordoned, a Orders continua nele"]
    B -- "1 (maxUnavailable 1)" --> F["Pod despejado (SIGTERM, graceful shutdown)"]
    F --> G["ReplicaSet recria no outro nó<br/>ALLOWED volta a 1 quando fica pronto"]
    G --> H["drain concluído"]
```

### Parte E — o que a PDB **não** protege

Com a PDB da Orders de novo em 0:

```bash
kubectl -n ecommerce patch pdb orders-api --type merge --patch-file kubernetes/labs/rollout/orders-pdb-zero.patch.yaml

# E1 — delete direto não passa pela Eviction API
POD=$(kubectl -n ecommerce get pod -l app.kubernetes.io/name=orders-api -o jsonpath='{.items[0].metadata.name}')
kubectl -n ecommerce delete pod $POD                # é apagado mesmo com ALLOWED DISRUPTIONS 0

# E2 — o rollout do Deployment não consulta a PDB
kubectl -n ecommerce rollout restart deploy/orders-api
kubectl -n ecommerce rollout status deploy/orders-api

kubectl -n ecommerce patch pdb orders-api --type merge --patch-file kubernetes/labs/rollout/orders-pdb-restore.patch.yaml
```

E3 — a PDB da Inventory com **1** réplica. Drene o nó **da** Inventory:

```bash
INV_NODE=$(kubectl -n ecommerce get pod -l app.kubernetes.io/name=inventory-api -o jsonpath='{.items[0].spec.nodeName}')
kubectl -n ecommerce get pdb inventory-api          # ALLOWED DISRUPTIONS 1: a única réplica pode sair
export T0=$(date -u +%FT%TZ)
kubectl drain $INV_NODE --ignore-daemonsets --delete-emptydir-data --timeout=3m
sleep 30; labs/lab-02/count-responses.sh "$T0"
kubectl uncordon $INV_NODE
scripts/fault.sh inventory reset-stock
kubectl -n kube-system scale deploy -l app.kubernetes.io/name=aws-cluster-autoscaler --replicas=1
```

```mermaid
flowchart LR
    subgraph cobre["A PDB cobre (Eviction API)"]
        C1["kubectl drain"]
        C2["upgrade de node group"]
        C3["scale-down do Cluster Autoscaler"]
    end
    subgraph naocobre["A PDB NÃO cobre"]
        N1["kubectl delete pod"]
        N2["rollout do Deployment<br/>(controlado pela strategy)"]
        N3["falha de nó, OOMKilled,<br/>preemption"]
        N4["réplica única: maxUnavailable 1<br/>libera a única réplica"]
    end
```

## 7. Observações

> Comportamento **esperado**, derivado da semântica do Kubernetes e da configuração do repo. Os valores medidos
> entram aqui depois da validação em cluster.

### A — rollout seguro

| O que aparece | Onde |
|---|---|
| 3 Pods da Orders por alguns segundos (2 antigos + 1 novo), nunca menos de 2 prontos | terminal 1 |
| log `SIGTERM recebido: readiness=false, aguardando 5.0s antes de encerrar` em cada Pod antigo | `kubectl logs` do Pod antigo |
| respostas da BFF só `201` | `count-responses.sh` |

### B — rollout agressivo

| O que aparece | Onde |
|---|---|
| os 2 Pods antigos entram em `Terminating` juntos; nenhum Pod novo até eles saírem | terminal 1 |
| uma janela com **0** Pods prontos da Orders (dura o graceful shutdown + o startup do Pod novo) | terminal 1 |
| `503 DEPENDENCY_UNAVAILABLE` (BFF: "Orders API indisponível", `Retry-After: 1`); o k6 repete e boa parte se recupera | `count-responses.sh`; log da BFF |

### C — `Recreate`

| O que aparece | Onde |
|---|---|
| o Pod antigo some **antes** de o novo aparecer (`Recreate` nunca roda as duas versões juntas) | terminal 1 |
| `503 DEPENDENCY_UNAVAILABLE` na janela; o Circuit Breaker da Orders pode abrir (`OPEN`) e depois voltar a `CLOSED` | `count-responses.sh`; `fault.sh orders cb` |
| o estoque volta ao catálogo inicial (estado em memória do Pod antigo perdido) | `scripts/fault.sh inventory state` |

### D — PDB e drain

| O que aparece | Onde |
|---|---|
| `kubectl get pdb orders-api`: `ALLOWED DISRUPTIONS 0` | terminal 3 |
| drain: `evicting pod ecommerce/orders-api-…` seguido de `error when evicting pods/"orders-api-…" … Cannot evict pod as it would violate the pod's disruption budget` a cada 5 s, até o `--timeout` | saída do drain |
| o nó fica `Ready,SchedulingDisabled`; os outros Pods (BFF, CoreDNS etc.) já foram despejados; a Orders continua lá | `kubectl get nodes`; terminal 1 |
| com `maxUnavailable: 1`: o drain conclui; a Orders sai e é recriada no outro nó | saída do drain; terminal 1 |
| respostas da BFF no drain liberado: só `201` (uma réplica por vez + graceful shutdown) | `count-responses.sh` |

### E — fora da PDB

| O que aparece | Onde |
|---|---|
| E1: `pod "orders-api-…" deleted` mesmo com `ALLOWED DISRUPTIONS 0`; o ReplicaSet recria | terminal 1 |
| E2: o rollout conclui normalmente com a PDB em 0 (o ritmo é o da `strategy`, não o da PDB) | `rollout status` |
| E3: o drain despeja a **única** Inventory sem esperar nada; `503 DEPENDENCY_UNAVAILABLE` até o Pod subir no outro nó | saída do drain; `count-responses.sh` |

## 8. Explicação técnica

- **`maxSurge` e `maxUnavailable` são os dois limites do rollout.** Durante a troca, o Deployment mantém no máximo
  `replicas + maxSurge` Pods e no mínimo `replicas - maxUnavailable` **prontos**. Com `1/0`, o rollout é mais lento
  e usa 1 Pod a mais de capacidade, mas nunca reduz quem atende. Com `0/100%`, não precisa de capacidade extra, mas
  derruba tudo de uma vez. A "pronto" vem das probes do LAB 02: sem readiness correta, `maxUnavailable: 0` não
  protege nada.
- **`Recreate` existe para quando duas versões não podem coexistir.** A Inventory guarda o estoque em memória numa
  réplica única: duas réplicas teriam estoques diferentes. O preço é a janela de indisponibilidade em **todo**
  rollout. A correção de verdade (fase 2) é tirar o estado do Pod (ex.: DynamoDB) e então usar `RollingUpdate` com
  2+ réplicas.
- **A PDB só vale para evicções voluntárias.** O `kubectl drain`, os upgrades de node group e o scale-down do Cluster
  Autoscaler usam a **Eviction API**, que recusa (`429`) uma evicção que deixaria o grupo abaixo do orçamento.
  `kubectl delete pod`, o próprio Deployment num rollout e falhas involuntárias (nó, OOM, preemption) não consultam
  a PDB.
- **`maxUnavailable` em vez de `minAvailable`.** Com HPA (Orders entre 2 e 12), `maxUnavailable: 1` é válido em
  toda a faixa. Um `minAvailable: 2` fixo, com 2 réplicas, daria `ALLOWED 0` e travaria todo drain — o mesmo efeito
  do patch da parte D, que é o erro clássico de "PDB que impede manutenção".
- **PDB com 1 réplica não protege.** Com `maxUnavailable: 1` a única réplica pode sair; com `maxUnavailable: 0` ela
  nunca sai e o drain do nó trava. Não há valor certo: disponibilidade exige 2+ réplicas.
- **Drain + topology spread.** O drain usa as mesmas regras de agendamento: os Pods despejados vão para o outro nó
  (o nó drenado está cordoned e sai da conta do spread) e não voltam sozinhos depois do `uncordon` (LAB 04, parte E3).

## 9. Correção

```bash
kubectl -n ecommerce patch deploy orders-api --patch-file kubernetes/labs/rollout/orders-safe-rollout.patch.yaml    # B
kubectl -n ecommerce patch pdb orders-api --type merge --patch-file kubernetes/labs/rollout/orders-pdb-restore.patch.yaml   # D/E
kubectl uncordon -l workload=apps                                                                                    # D/E
kubectl -n ecommerce rollout restart deploy/orders-api deploy/bff-api                                                # redistribui
kubectl -n kube-system scale deploy -l app.kubernetes.io/name=aws-cluster-autoscaler --replicas=1                    # CA ligado
scripts/fault.sh inventory reset-stock && scripts/fault.sh all reset                                                 # C/E3
```

## 10. Validação

```bash
kubectl -n ecommerce get deploy orders-api -o jsonpath='{.spec.strategy.rollingUpdate}'; echo    # {"maxSurge":1,"maxUnavailable":0}
kubectl -n ecommerce get pdb                                                                         # MAX UNAVAILABLE 1 nas três
kubectl get nodes -l workload=apps                                                                   # nenhum SchedulingDisabled
kubectl -n kube-system get deploy -l app.kubernetes.io/name=aws-cluster-autoscaler                   # READY 1/1
kubectl -n ecommerce get pods -o wide --sort-by=.spec.nodeName                                       # 1 BFF e 1 Orders por nó
scripts/fault.sh orders cb                                                                           # CLOSED
```

| Cenário | Ação | Comportamento esperado | Como verificar |
|---|---|---|---|
| Rollout seguro | `rollout restart` com `1/0` | 0 erros, nunca menos de 2 Pods prontos | `count-responses.sh` só `201` |
| Rollout agressivo | `rollout restart` com `0/100%` | janela sem endpoints, `503` | `count-responses.sh` com `503` |
| Recreate | `rollout restart` da Inventory | janela sem Inventory, `503`, estoque reiniciado | `count-responses.sh`; `fault.sh inventory state` |
| PDB bloqueia | drain com `maxUnavailable: 0` | `Cannot evict pod …` até o timeout | saída do drain |
| PDB libera | drain com `maxUnavailable: 1` | drain conclui, 0 erros | saída do drain; `count-responses.sh` |
| Fora da PDB | `delete pod`, rollout, drain da Inventory | ignoram a PDB / a única réplica sai | terminal 1; `count-responses.sh` |
| Estado final | comandos acima | estratégia e PDB do manifest, nós sem cordon, CA ligado | saída dos comandos |

## 11. Challenge

1. Calcule, para a Orders com HPA em 12 réplicas, quantos Pods existem no pico de um rollout com `1/0` e com
   `25%/25%` (o padrão do Kubernetes). Qual consome mais capacidade? Qual termina mais rápido?
2. Troque a PDB da BFF para `minAvailable: 2` (sem aplicar em produção!) e tente drenar um nó. O que acontece, e por
   que `maxUnavailable: 1` é a escolha do repo?
3. Com o Cluster Autoscaler ligado, um nó subutilizado só é removido se os Pods dele puderem ser despejados. Que PDB
   impediria o scale-down para sempre?
4. O que precisaria mudar na Inventory para trocar `Recreate` por `RollingUpdate` com 2 réplicas sem perder a
   consistência do estoque?

## 12. Critérios de sucesso

- [ ] A: rollout com `1/0` sem erros na BFF.
- [ ] B: você viu a janela sem réplicas prontas e os `503` do rollout agressivo.
- [ ] C: você explica por que a Inventory é `Recreate` e o que se perde em cada rollout.
- [ ] D: o drain travou com a PDB em 0 e concluiu com a PDB em 1.
- [ ] E: você sabe listar o que a PDB **não** protege.

## 13. Reset

```bash
kubectl -n loadtest delete jobs -l app.kubernetes.io/name=k6     # se o k6 ainda estiver rodando
scripts/reset.sh
```

O `scripts/reset.sh` reaplica o overlay (`kubectl apply -k`), que devolve a estratégia da Orders (`1/0`) e a PDB
(`maxUnavailable: 1`) aos valores do manifest, faz `uncordon` dos nós `apps` e religa o Cluster Autoscaler.
