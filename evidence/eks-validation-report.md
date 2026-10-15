# Relatório de validação — 2026-10-14T16:59:49Z

Cluster: `reliability-workshop` · Região: `us-east-1` · Conta: `<AWS_ACCOUNT_ID>`

| | Critério | Evidência |
|---|---|---|
| ✅ | EKS provisionado | ACTIVE	1.36 |
| ✅ | Managed Node Groups operacionais | apps=ACTIVE observability=ACTIVE nodes_ready=3 |
| ✅ | Metrics Server funcionando | ip-192-168-118-236.ec2.internal   74m    3%    885Mi    12%   ;ip-192-168-67-176.ec2.internal    91m    4%    845Mi    11%   ;ip-192-168-78-254.ec2.internal    259m   6%    2773Mi   18%   ; |
| ✅ | Cluster Autoscaler em execução | registry.k8s.io/autoscaling/cluster-autoscaler:v1.36.1 |
| ✅ | Três APIs Ready | bff-api=2/2 orders-api=2/2 inventory-api=1/1  |
| ✅ | Pedido criado pela BFF (CONFIRMED) | HTTP 201 replayed=false
order_id=ord-66ca8dc4b71d47d4bfb6f04e0ec1f1e7 status=CONFIRMED |
| ✅ | Reserva de estoque registrada | "reservations_total":1353 |
| ✅ | Pedido persistido no DynamoDB | CONFIRMED |
| ✅ | Pedido consultável (GET /orders/{id}) | HTTP 200 |
| ✅ | Retry com mesma chave = replay do mesmo pedido | HTTP 201 replayed=true |
| ✅ | Idempotência sob concorrência (k6, 20 requisições) | time="2026-10-14T16:58:52Z" level=info msg="pedidos persistidos=1 order_id=ord-ae2d7f086ac34507afdc7458f9fa6a64" source=console     ✓ 'rate==1' rate=100.00%     idempotency_violations     ✓ 'count==0' count=0     ✓ status 201 ou 409 ORDER_IN_PROGRESS     ✓ replay final 201 com Idempotency-Replayed=true     ✓ exatamente 1 pedido persistido para o cliente     ✓ o pedido persistido é o retornado     idempotency_violations.........: 0      0/s  |
| ✅ | EKS Pod Identity + isolamento IAM | [1;34m==>[0m Pod Identity/IAM: 12 PASS, 0 FAIL |
| ✅ | Métricas, logs e traces no ClickStack | logs: bff-api=6131 inventory-api=5082 orders-api=15256 ; serviços por trace=3; http_metrics=4463 k8s_metrics=4867 |
| ✅ | Quatro alertas configurados no HyperDX | 4 Orders Creation Errors=ALERT;Orders Query Errors=ALERT;Inventory Creation Errors=ALERT;Inventory Query Errors=ALERT |
