// Cria pedidos a uma taxa constante (constant-arrival-rate).
// Variáveis: BASE_URL, RATE (req/s, padrão 5), DURATION (padrão 1m), VUS (pré-alocados, padrão 20),
//            HTTP_TIMEOUT, ORDERS (limite total opcional), RETRY_ON_ERROR (true|false), CUSTOMERS (padrão 50)
import { sleep } from 'k6';
import { Counter } from 'k6/metrics';
import { assertWorkshopTarget, checkCreated, createOrder, createOrderWithRetry, int, orderPayload, uuid, RUN_ID } from './lib/common.js';

const ordersCreated = new Counter('workshop_orders_created');
const RETRY = (__ENV.RETRY_ON_ERROR || 'true') === 'true';
const CUSTOMERS = int('CUSTOMERS', 50);
const ORDERS = int('ORDERS', 0);

export const options = {
  scenarios: {
    create_orders: ORDERS > 0
      ? { executor: 'shared-iterations', vus: int('VUS', 10), iterations: ORDERS, maxDuration: __ENV.DURATION || '5m' }
      : { executor: 'constant-arrival-rate', rate: int('RATE', 5), timeUnit: '1s', duration: __ENV.DURATION || '1m',
          preAllocatedVUs: int('VUS', 20), maxVUs: int('VUS', 20) * 4 },
  },
  thresholds: {
    http_req_failed: [{ threshold: 'rate<0.05', abortOnFail: false }],
    'http_req_duration{name:POST /orders}': ['p(95)<1500'],
  },
};

export function setup() { assertWorkshopTarget(); }

export default function () {
  const customer = `customer-${RUN_ID}-${Math.floor(Math.random() * CUSTOMERS)}`;
  const payload = orderPayload(customer);
  const res = RETRY ? createOrderWithRetry(customer, payload, 3, sleep).res : createOrder(customer, uuid(), payload);
  if (checkCreated(res)) ordersCreated.add(1);
}
