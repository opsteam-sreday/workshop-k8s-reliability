// 20 requisições CONCORRENTES com a MESMA Idempotency-Key => exatamente 1 pedido.
// Variáveis: BASE_URL, IDEMPOTENCY_KEY (padrão: gerada), CONCURRENCY (padrão 20), HTTP_TIMEOUT
import http from 'k6/http';
import { check, fail } from 'k6';
import { Counter } from 'k6/metrics';
import { assertWorkshopTarget, BASE_URL, createOrder, HTTP_TIMEOUT, int, RUN_ID, uuid } from './lib/common.js';

const N = int('CONCURRENCY', 20);
// 409 ORDER_IN_PROGRESS é uma resposta CORRETA do contrato, não uma falha HTTP.
http.setResponseCallback(http.expectedStatuses(201, 409));
const violations = new Counter('idempotency_violations');
const replayed = new Counter('idempotency_replayed');
const inProgress = new Counter('idempotency_in_progress');

export const options = {
  scenarios: { burst: { executor: 'per-vu-iterations', vus: N, iterations: 1, maxDuration: '1m' } },
  thresholds: { idempotency_violations: ['count==0'], checks: ['rate==1'] },
};

export function setup() {
  assertWorkshopTarget();
  const key = __ENV.IDEMPOTENCY_KEY || uuid();
  const customer = `customer-idem-${RUN_ID}`;
  console.log(`Idempotency-Key=${key} customer=${customer}`);
  return { key, customer, payload: { customer_id: customer, items: [{ sku: 'product-001', quantity: 2, unit_price: '49.90' }] } };
}

export default function (data) {
  const res = createOrder(data.customer, data.key, data.payload);
  const ok = check(res, { 'status 201 ou 409 ORDER_IN_PROGRESS': (r) => r.status === 201 || (r.status === 409 && r.json('error') === 'ORDER_IN_PROGRESS') });
  if (!ok) violations.add(1);
  if (res.status === 201 && res.headers['Idempotency-Replayed'] === 'true') replayed.add(1);
  if (res.status === 409) inProgress.add(1);
}

export function teardown(data) {
  // Repete após a conclusão: deve devolver o MESMO resultado (replay).
  let final;
  for (let i = 0; i < 10; i++) {
    final = createOrder(data.customer, data.key, data.payload);
    if (final.status === 201) break;
  }
  const list = http.get(`${BASE_URL}/orders?customer_id=${data.customer}&limit=50`, { timeout: HTTP_TIMEOUT });
  const count = list.json('count');
  const passed = check(null, {
    'replay final 201 com Idempotency-Replayed=true': () => final.status === 201 && final.headers['Idempotency-Replayed'] === 'true',
    'exatamente 1 pedido persistido para o cliente': () => count === 1,
    'o pedido persistido é o retornado': () => count === 1 && list.json('orders.0.order_id') === final.json('order_id'),
  });
  console.log(`pedidos persistidos=${count} order_id=${final.json('order_id')}`);
  if (!passed) { violations.add(1); fail('violação de idempotência detectada'); }
}
