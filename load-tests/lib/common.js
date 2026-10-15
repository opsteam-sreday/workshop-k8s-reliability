// Utilitários compartilhados pelos scripts k6 do workshop.
import http from 'k6/http';
import { check, fail } from 'k6';

// Somente endpoints do workshop podem ser alvo da carga.
const ALLOWED_HOSTS = [
  'bff-api.ecommerce.svc.cluster.local', 'bff-api.ecommerce.svc', 'bff-api.ecommerce', 'bff-api',
  'localhost', '127.0.0.1',
];

export const BASE_URL = (__ENV.BASE_URL || 'http://bff-api.ecommerce.svc.cluster.local:8080').replace(/\/$/, '');
export const HTTP_TIMEOUT = __ENV.HTTP_TIMEOUT || '10s';
export const RUN_ID = __ENV.RUN_ID || `${Date.now().toString(36)}`;

export function assertWorkshopTarget() {
  const match = BASE_URL.match(/^https?:\/\/([^/:]+)(:\d+)?$/);
  if (!match) fail(`BASE_URL inválida: ${BASE_URL}`);
  if (!ALLOWED_HOSTS.includes(match[1])) {
    fail(`BASE_URL ${BASE_URL} não é um endpoint do workshop. Permitidos: ${ALLOWED_HOSTS.join(', ')}`);
  }
}

export function uuid() {
  return crypto.randomUUID();
}

const SKUS = (__ENV.SKUS || 'product-001,product-002,product-003,product-004,product-005').split(',');

export function orderPayload(customerId, sku) {
  return {
    customer_id: customerId,
    items: [{ sku: sku || SKUS[Math.floor(Math.random() * SKUS.length)], quantity: 1 + Math.floor(Math.random() * 3), unit_price: '49.90' }],
  };
}

export function createOrder(customerId, idempotencyKey, payload, tags = {}) {
  return http.post(`${BASE_URL}/orders`, JSON.stringify(payload || orderPayload(customerId)), {
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey, 'X-Request-ID': `k6-${RUN_ID}-${uuid().slice(0, 8)}` },
    timeout: HTTP_TIMEOUT,
    tags: { name: 'POST /orders', ...tags },
  });
}

// Cliente bem-comportado: em 409 ORDER_IN_PROGRESS / 503 / 504 repete com a MESMA chave,
// respeitando Retry-After, com no máximo `maxRetries` tentativas.
export function createOrderWithRetry(customerId, payload, maxRetries = 3, sleepFn) {
  const key = uuid();
  let res;
  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    res = createOrder(customerId, key, payload, { attempt: String(attempt) });
    if (![409, 503, 504].includes(res.status)) break;
    if (res.status === 409 && res.json('error') !== 'ORDER_IN_PROGRESS') break;
    const retryAfter = parseFloat(res.headers['Retry-After'] || '1');
    sleepFn(Math.min(retryAfter, 5) * (0.5 + Math.random()));
  }
  return { res, key };
}

export function checkCreated(res) {
  return check(res, {
    'POST /orders 201': (r) => r.status === 201,
    'pedido CONFIRMED': (r) => r.status !== 201 || r.json('status') === 'CONFIRMED',
  });
}

export function int(name, def) {
  return __ENV[name] ? parseInt(__ENV[name], 10) : def;
}
