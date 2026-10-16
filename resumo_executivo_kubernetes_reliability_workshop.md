# Kubernetes Reliability Engineering Workshop

**Resumo executivo dos 5 laboratórios — MVP | Amazon EKS + ClickStack**

## Objetivo

Demonstrar, na prática, como Kubernetes e aplicações distribuídas respondem a picos de tráfego, falhas, contenção de recursos e decisões de arquitetura.

Os participantes irão trabalhar com uma plataforma transacional de pedidos e, ao longo de cinco laboratórios, provocar falhas, investigar suas causas e implementar mecanismos de resiliência.

**Metodologia:** Break it → Observe it → Understand it → Fix it → Validate it.

## Arquitetura utilizada

```text
                  k6 / Clients
                       |
                       v
                    BFF API
                       |
                       v
                   Orders API
                    /      \
                   v        v
            Inventory API  DynamoDB
           (reservas/CB)   (pedidos)

     BFF + Orders + Inventory
                |
          OpenTelemetry
                |
           OTel Collector
                |
             ClickStack
        (ClickHouse + HyperDX)
```

O **Circuit Breaker** é implementado na **Orders API** para proteger as chamadas à Inventory API. A Orders API usa **EKS Pod Identity** para acessar o DynamoDB, sem conceder esse acesso à BFF nem à Inventory API.

## LAB 01 — First Successful Order

**Tema:** Fundação transacional e segurança.

Provisionar o EKS, implantar as três APIs e criar o primeiro pedido. Validar a reserva de estoque, a persistência no DynamoDB, a idempotência e a autorização via EKS Pod Identity. Consultar o pedido criado e examinar o trace distribuído.

**Aprendizado principal:** como uma transação atravessa múltiplos serviços mantendo segurança e consistência.

**Duração sugerida:** 90 minutos.

## LAB 06 — CPU Stress & Autoscaling

**Tema:** Escalabilidade e capacidade.

Gerar sobrecarga controlada de CPU na Orders API, observar o HPA criando novas réplicas e o Cluster Autoscaler adicionando nós quando não houver capacidade suficiente para agendar novos Pods. Interromper a carga e acompanhar a recuperação.

**Aprendizado principal:** escalar Pods não significa dispor de capacidade computacional imediatamente.

**Duração sugerida:** 75 minutos.

## LAB 05 — QoS & PriorityClass

**Tema:** Contenção de recursos e prioridades.

Testar as classes **BestEffort, Burstable e Guaranteed** na Inventory API. Simular escassez de recursos e observar os efeitos de requests, limits, PriorityClass e preempção. Demonstrar como atribuir baixa prioridade a um serviço necessário à confirmação de pedidos pode provocar indisponibilidade transacional.

**Aprendizado principal:** prioridades de infraestrutura mal definidas podem prejudicar funções críticas do negócio. QoS e PriorityClass têm finalidades distintas.

**Duração sugerida:** 60 minutos.

## LAB X1 — ClickStack Observability & Alerting

**Tema:** Métricas, logs, traces e alertas.

Investigar requisições ponta a ponta usando OpenTelemetry e HyperDX. Examinar latência por rota, status HTTP e logs correlacionados por `trace_id`. Criar quatro alertas para erros na criação e consulta de pedidos e na reserva e consulta de estoque, inicialmente baseados em contagem de logs.

**Anti-pattern intencional:** `COUNT(logs)` não mede de maneira confiável a quantidade de requisições malsucedidas: uma requisição pode gerar vários logs, e outra pode falhar sem gerar logs ERROR. O exercício prepara a evolução para alertas orientados a métricas HTTP não amostradas ou spans adequados.

**Aprendizado principal:** observar erros não equivale a contabilizar corretamente transações com falha; métricas, logs e traces são complementares.

**Duração sugerida:** 75 minutos.

## Agenda sugerida

| Laboratório | Duração |
|---|---:|
| LAB 01 — Plataforma transacional | 90 min |
| LAB 06 — Autoscaling | 75 min |
| LAB 05 — QoS e prioridades | 60 min |
| LAB X1 — ClickStack e alertas | 75 min |
| **Total hands-on** | **300 min (5 horas)** |

Com abertura, intervalo e encerramento, planejar **aproximadamente 6 horas**. Recomenda-se disponibilizar a infraestrutura pré-provisionada para manter a agenda.

## Mensagem de encerramento para a reunião

> **O workshop não é sobre aprender comandos de Kubernetes. É sobre entender por que sistemas distribuídos falham, como Kubernetes pode amplificar essas falhas e quais decisões de engenharia tornam uma operação realmente resiliente.**

Ao final, cada participante terá trabalhado com uma plataforma transacional, provocado incidentes controlados e utilizado o ClickStack para investigar suas causas, conectando **infraestrutura, aplicação e impacto no negócio**.
