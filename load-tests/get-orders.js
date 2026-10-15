// Consulta pedidos: cria ORDERS pedidos no setup e depois executa GET /orders e GET /orders/{id}.
// Variáveis: BASE_URL, VUS (padrão 10), DURATION (padrão 1m), ORDERS (padrão 20), HTTP_TIMEOUT
import http from 'k6/http';
import { check, sleep } from 'k6';
import { assertWorkshopTarget, BASE_URL, createOrder, HTTP_TIMEOUT, int, orderPayload, uuid, RUN_ID } from './lib/common.js';

export const options = {
  scenarios: { get_orders: { executor: 'constant-vus', vus: int('VUS', 10), duration: __ENV.DURATION || '1m' } },
  thresholds: { http_req_failed: ['rate<0.05'], 'http_req_duration{name:GET /orders/{order_id}}': ['p(95)<500'] },
};

export function setup() {
  assertWorkshopTarget();
  const customer = `customer-${RUN_ID}-reader`;
  const ids = [];
  for (let i = 0; i < int('ORDERS', 20); i++) {
    const res = createOrder(customer, uuid(), orderPayload(customer));
    if (res.status === 201) ids.push(res.json('order_id'));
  }
  if (ids.length === 0) throw new Error('nenhum pedido criado no setup');
  return { customer, ids };
}

export default function (data) {
  const list = http.get(`${BASE_URL}/orders?customer_id=${data.customer}&limit=10`, { timeout: HTTP_TIMEOUT, tags: { name: 'GET /orders' } });
  check(list, { 'GET /orders 200': (r) => r.status === 200, 'lista não vazia': (r) => r.status !== 200 || r.json('count') > 0 });
  const id = data.ids[Math.floor(Math.random() * data.ids.length)];
  const one = http.get(`${BASE_URL}/orders/${id}`, { timeout: HTTP_TIMEOUT, tags: { name: 'GET /orders/{order_id}' } });
  check(one, { 'GET /orders/{id} 200': (r) => r.status === 200, 'order_id correto': (r) => r.status !== 200 || r.json('order_id') === id });
  sleep(0.2);
}
